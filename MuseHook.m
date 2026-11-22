//
//  MuseHook.m — 暮色 手动选择式下载 dylib（TrollFools 注入）
//
//  与上一版的区别：**不再自动下载**。
//    · 播放时只把抓到的 .m3u8 记成「候选」，不产生任何下载流量
//    · 暮色界面右侧浮出一个悬浮球，角标 = 新候选数
//    · 点悬浮球 → 原生列表，勾选 → 点「下载选中」才真正下
//
//  原理：在原生播放器的数据源入口记录 URL 和请求头。
//        dylib 观察 BetterPlayer、FSPlayer 和 AVURLAsset 收到的明文播放地址。
//        UI 把悬浮球加到应用现有主窗口，列表由现有控制器弹出。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <sys/socket.h>
#include <unistd.h>
#include <sys/uio.h>
#include <errno.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <CommonCrypto/CommonCryptor.h>

// ───────────────────────── 输出目录 ─────────────────────────
static NSString *const kSharedDir = @"/var/mobile/Media/暮色下载";
static NSString *gOutDir = nil;
static NSString *gLogPath = nil;

static NSString *out_dir(void) {
    if (gOutDir) return gOutDir;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm createDirectoryAtPath:kSharedDir withIntermediateDirectories:YES attributes:nil error:nil] &&
        [fm isWritableFileAtPath:kSharedDir]) {
        gOutDir = kSharedDir;
    } else {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *p = [docs stringByAppendingPathComponent:@"暮色下载"];
        [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
        gOutDir = p;
    }
    return gOutDir;
}

static void mlog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *dir = out_dir();
        if (!gLogPath) gLogPath = [dir stringByAppendingPathComponent:@"hook.log"];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle], s];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!fh) {
            [line writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
            @catch (__unused NSException *e) {}
        }
        NSLog(@"[MuseHook] %@", s);
    }
}

// ───────────────────────── 候选模型 ─────────────────────────
typedef NS_ENUM(NSInteger, CandStatus) {
    CandIdle = 0, CandRunning, CandDone, CandFailed
};

@interface MuseCandidate : NSObject
@property (nonatomic, copy) NSString *url;
@property (atomic, copy) NSString *title;
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, assign) BOOL selected;
@property (atomic, assign) CandStatus status;
@property (atomic, assign) double progress;   // 0~1
@property (atomic, assign) BOOL isFmp4;
@property (atomic, assign) double bytesPerSecond;
@property (atomic, assign) NSUInteger connections;
@property (atomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (atomic, copy) NSString *errorText;
@end

@implementation MuseCandidate
@end

// 全局表
static NSMutableArray<MuseCandidate *> *gCands;   // 最新在前
static NSMutableDictionary<NSString *, MuseCandidate *> *gSeen;
static NSLock *gLock;
static NSInteger gUnseen = 0;                     // 角标
static _Atomic(BOOL) gReady = NO;

static void notify_list_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MuseListChanged" object:nil];
    });
}

static MuseCandidate *add_candidate(NSString *url, NSString *title, NSDictionary *headers) {
    if (url.length < 8) return nil;
    [gLock lock];
    MuseCandidate *existing = gSeen[url];
    if (existing) {
        if (headers.count) existing.headers = headers;
        if (title.length) existing.title = title;
        [gLock unlock];
        notify_list_changed();
        return existing;
    }
    MuseCandidate *c = [MuseCandidate new];
    c.url = url;
    c.title = title.length ? title : [NSString stringWithFormat:@"候选 %lu", (unsigned long)(gCands.count + 1)];
    c.time = [NSDate date];
    c.selected = NO;
    c.status = CandIdle;
    c.headers = headers;
    gSeen[url] = c;
    [gCands insertObject:c atIndex:0];
    gUnseen++;
    [gLock unlock];
    mlog(@"📌 记下候选: %@  (%@)", c.title, url);
    notify_list_changed();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MuseBadgeChanged" object:nil];
    });
    return c;
}

// ───────────────────────── 下载器 ─────────────────────────
// Downloads are staged on disk and committed only after every piece succeeds.
#include <CommonCrypto/CommonCryptor.h>
#include <stdint.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static NSError *muse_download_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MuseHook.Download" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL muse_download_number(NSString *text, uint64_t *number) {
    if (!text.length || [text hasPrefix:@"-"] || [text hasPrefix:@"+"]) return NO;
    const char *start = text.UTF8String;
    if (!start) return NO;
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(start, &end, 10);
    if (errno || !end || *end) return NO;
    *number = value;
    return YES;
}

static NSDictionary<NSString *, NSString *> *muse_hls_attributes(NSString *line) {
    NSRange separator = [line rangeOfString:@":"];
    if (separator.location == NSNotFound) return @{};
    NSString *attributes = [line substringFromIndex:NSMaxRange(separator)];
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
                   @"([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)" options:0 error:NULL];
    });
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *match in [pattern matchesInString:attributes options:0
                                                           range:NSMakeRange(0, attributes.length)]) {
        NSString *key = [attributes substringWithRange:[match rangeAtIndex:1]];
        NSString *value = [attributes substringWithRange:[match rangeAtIndex:2]];
        if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""])
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        result[key] = value;
    }
    return result;
}

static NSURL *muse_hls_url(NSString *reference, NSURL *base) {
    if (!reference.length) return nil;
    NSURL *url = [NSURL URLWithString:reference relativeToURL:base].absoluteURL;
    NSString *scheme = url.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) && url.host.length ? url : nil;
}

static BOOL muse_copy_file_range(NSURL *source, NSURL *destination, uint64_t offset,
                                 uint64_t length, NSError **error) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:source error:error];
    if (!input) return NO;
    if (![NSFileManager.defaultManager createFileAtPath:destination.path contents:nil attributes:nil]) {
        [input closeFile];
        if (error) *error = muse_download_error(1, @"无法创建临时下载文件");
        return NO;
    }
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:destination error:error];
    if (!output) { [input closeFile]; return NO; }
    BOOL success = NO;
    @try {
        [input seekToFileOffset:offset];
        while (length) {
            @autoreleasepool {
                NSData *data = [input readDataOfLength:(NSUInteger)MIN(length, (uint64_t)65536)];
                if (!data.length) {
                    if (error) *error = muse_download_error(2, @"下载内容长度不足");
                    break;
                }
                [output writeData:data];
                length -= data.length;
            }
        }
        success = length == 0;
    } @catch (NSException *exception) {
        if (error) *error = muse_download_error(3, exception.reason ?: @"文件读写失败");
    } @finally {
        [input closeFile];
        [output closeFile];
    }
    return success;
}

@interface MuseDownloadJob : NSObject
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (nonatomic, strong) NSURL *destination;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, weak) MuseCandidate *candidate;
@property (nonatomic, assign) BOOL hasRange;
@property (nonatomic, assign) uint64_t offset;
@property (nonatomic, assign) uint64_t length;
@property (nonatomic, assign) NSTimeInterval lastProgress;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, copy) NSData *resumeData;
@property (nonatomic, assign) BOOL resuming;
@property (nonatomic, assign) int64_t resumeOffset;
@property (nonatomic, assign) int64_t receivedBytes;
@property (nonatomic, assign) int64_t expectedBytes;
@property (nonatomic, assign) BOOL probe;
@property (nonatomic, assign) BOOL strictRange;
@property (nonatomic, assign) uint64_t totalLength;
@property (nonatomic, copy) void (^progressHandler)(int64_t bytes);
@end
@implementation MuseDownloadJob
@end

@interface MuseDl : NSObject <NSURLSessionDownloadDelegate, NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MuseDownloadJob *> *jobs;
@property (nonatomic, strong) NSLock *jobsLock;
@property (nonatomic, strong) NSLock *filesLock;
@end

@implementation MuseDl
+ (instancetype)shared {
    static MuseDl *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [MuseDl new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jobs = [NSMutableDictionary dictionary];
        _jobsLock = [NSLock new];
        _filesLock = [NSLock new];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.timeoutIntervalForRequest = 90;
        configuration.timeoutIntervalForResource = 7200;
        configuration.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    }
    return self;
}

- (MuseDownloadJob *)jobForTask:(NSURLSessionTask *)task {
    [self.jobsLock lock];
    MuseDownloadJob *job = self.jobs[@(task.taskIdentifier)];
    [self.jobsLock unlock];
    return job;
}

- (NSMutableURLRequest *)requestForURL:(NSURL *)url candidate:(MuseCandidate *)candidate range:(NSDictionary *)range {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
   forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    NSURL *origin = [NSURL URLWithString:candidate.url];
    NSNumber *originPort = origin.port ?: @([origin.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80);
    NSNumber *requestPort = url.port ?: @([url.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80);
    BOOL sameOrigin = [origin.host.lowercaseString isEqualToString:url.host.lowercaseString] &&
                      [origin.scheme.lowercaseString isEqualToString:url.scheme.lowercaseString] &&
                      [originPort isEqual:requestPort];
    [gLock lock];
    NSDictionary *capturedHeaders = candidate.headers;
    [gLock unlock];
    for (NSString *name in capturedHeaders) {
        id value = capturedHeaders[name];
        if (![name isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class]) continue;
        NSString *lower = name.lowercaseString;
        if ([@[@"host", @"connection", @"content-length", @"range"] containsObject:lower]) continue;
        if (!sameOrigin && [@[@"authorization", @"cookie"] containsObject:lower]) continue;
        [request setValue:value forHTTPHeaderField:name];
    }
    if (range) {
        uint64_t start = [range[@"offset"] unsignedLongLongValue];
        uint64_t length = [range[@"length"] unsignedLongLongValue];
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu",
                          (unsigned long long)start, (unsigned long long)(start + length - 1)]
       forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        if ([range[@"validator"] length])
            [request setValue:range[@"validator"] forHTTPHeaderField:@"If-Range"];
    }
    return request;
}

- (MuseDownloadJob *)fetchURL:(NSURL *)url candidate:(MuseCandidate *)candidate range:(NSDictionary *)range
                   directory:(NSURL *)directory showProgress:(BOOL)showProgress {
    return [self fetchURL:url candidate:candidate range:range directory:directory
             showProgress:showProgress progress:nil];
}

- (MuseDownloadJob *)fetchURL:(NSURL *)url candidate:(MuseCandidate *)candidate range:(NSDictionary *)range
                   directory:(NSURL *)directory showProgress:(BOOL)showProgress
                    progress:(void (^)(int64_t))progressHandler {
    MuseDownloadJob *last = nil;
    NSData *resumeData = nil;
    int64_t furthest = 0;
    int64_t expectedBytes = 0;
    NSUInteger stalled = 0;
    NSUInteger attempt = 0;
    NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + 7200;
    while (stalled < 3 && NSDate.timeIntervalSinceReferenceDate < deadline) {
        attempt++;
        MuseDownloadJob *job = [MuseDownloadJob new];
        job.done = dispatch_semaphore_create(0);
        job.startedAt = NSDate.timeIntervalSinceReferenceDate;
        job.destination = [directory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        job.candidate = showProgress ? candidate : nil;
        job.hasRange = range != nil;
        job.offset = [range[@"offset"] unsignedLongLongValue];
        job.length = [range[@"length"] unsignedLongLongValue];
        job.resuming = resumeData.length > 0;
        job.expectedBytes = expectedBytes;
        job.strictRange = [range[@"strict"] boolValue];
        job.totalLength = [range[@"total"] unsignedLongLongValue];
        job.progressHandler = progressHandler;
        NSURLSessionDownloadTask *task;
        if (job.resuming) {
            task = [self.session downloadTaskWithResumeData:resumeData];
            mlog(@"断点续传 %@，第 %lu 次请求，已接收 %lld 字节", candidate.title,
                 (unsigned long)attempt, (long long)furthest);
        } else {
            task = [self.session downloadTaskWithRequest:[self requestForURL:url candidate:candidate range:range]];
        }
        [self.jobsLock lock];
        self.jobs[@(task.taskIdentifier)] = job;
        [self.jobsLock unlock];
        [task resume];
        dispatch_semaphore_wait(job.done, DISPATCH_TIME_FOREVER);
        last = job;
        if (!job.error) return job;
        int64_t position = job.resumeOffset + job.receivedBytes;
        mlog(@"下载请求中断 %@，%@/%ld，位置 %lld，原因 %@",
             candidate.title, job.error.domain, (long)job.error.code,
             (long long)position, job.error.localizedDescription);
        if (showProgress) candidate.errorText = [NSString stringWithFormat:@"续传中：%@", job.error.localizedDescription];
        [NSFileManager.defaultManager removeItemAtURL:job.destination error:NULL];
        NSInteger status = job.response.statusCode;
        if (status >= 400 && status < 500 && status != 408 && status != 429) break;
        if ([job.error.domain isEqualToString:@"MuseHook.Download"] && status < 500) break;
        if (position > furthest) {
            furthest = position;
            stalled = 0;
        } else {
            stalled++;
        }
        expectedBytes = job.expectedBytes;
        resumeData = range ? nil : job.resumeData;
        if (!range && position > 0 && !resumeData.length) {
            job.error = muse_download_error(40, [NSString stringWithFormat:@"连接中断且没有可用的续传数据：%@",
                                                job.error.localizedDescription]);
            break;
        }
        if (range) stalled = attempt;
    }
    return last;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)expected {
    MuseDownloadJob *job = [self jobForTask:task];
    if (!job) return;
    if (job.strictRange && [task.response isKindOfClass:NSHTTPURLResponse.class] &&
        [(NSHTTPURLResponse *)task.response statusCode] != 206) {
        job.error = muse_download_error(41, @"服务器未接受分块请求，改用单连接");
        [task cancel];
        return;
    }
    job.receivedBytes += MAX(bytesWritten, (int64_t)0);
    if (!job.resuming || job.expectedBytes <= 0) job.expectedBytes = expected;
    if (job.candidate || job.progressHandler) {
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (now - job.lastProgress < 0.2) return;
        job.lastProgress = now;
        int64_t position = job.resumeOffset + job.receivedBytes;
        if (job.progressHandler) job.progressHandler(position);
        if (job.candidate && job.expectedBytes > 0) {
            double progress = (double)position / (double)job.expectedBytes;
            NSString *mime = task.response.MIMEType.lowercaseString;
            BOOL playlist = [mime containsString:@"mpegurl"] ||
                            [task.currentRequest.URL.path.pathExtension.lowercaseString isEqualToString:@"m3u8"];
            double value = playlist ? 0.05 * MIN(1.0, progress) : MIN(0.95, progress);
            job.candidate.progress = MAX(job.candidate.progress, value);
            job.candidate.bytesPerSecond = (double)job.receivedBytes / MAX(0.2, now - job.startedAt);
            notify_list_changed();
        }
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didResumeAtOffset:(int64_t)offset expectedTotalBytes:(int64_t)expected {
    MuseDownloadJob *job = [self jobForTask:task];
    if (!job) return;
    job.resumeOffset = offset;
    if (expected > 0) job.expectedBytes = expected;
    mlog(@"续传位置确认 %@：%lld / %lld 字节", job.candidate.title ?: @"分片",
         (long long)offset, (long long)job.expectedBytes);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
 didFinishDownloadingToURL:(NSURL *)location {
    MuseDownloadJob *job = [self jobForTask:task];
    if (!job) return;
    @try {
        job.response = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (id)task.response : nil;
        NSInteger status = job.response.statusCode;
        if (!job.response || status < 200 || status >= 300) {
            job.error = muse_download_error(status, [NSString stringWithFormat:@"HTTP 请求失败（%ld）", (long)status]);
            return;
        }
        uint64_t fileLength = [[NSFileManager.defaultManager attributesOfItemAtPath:location.path error:NULL][NSFileSize]
                               unsignedLongLongValue];
        if (job.hasRange && status == 200) {
            if (job.offset > fileLength || job.length > fileLength - job.offset) {
                job.error = muse_download_error(4, @"服务器返回的内容不足以满足分片范围");
                return;
            }
            NSError *copyError = nil;
            if (!muse_copy_file_range(location, job.destination, job.offset, job.length, &copyError))
                job.error = copyError ?: muse_download_error(4, @"分片范围复制失败");
            return;
        }
        if (status == 206) {
            NSString *header = nil;
            for (NSString *key in job.response.allHeaderFields) {
                if ([key.lowercaseString isEqualToString:@"content-range"]) header = job.response.allHeaderFields[key];
            }
            static NSRegularExpression *pattern;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                pattern = [NSRegularExpression regularExpressionWithPattern:@"^bytes ([0-9]+)-([0-9]+)/([0-9]+|\\*)$"
                                                                   options:NSRegularExpressionCaseInsensitive error:NULL];
            });
            NSTextCheckingResult *match = [pattern firstMatchInString:header ?: @"" options:0
                                                              range:NSMakeRange(0, header.length)];
            uint64_t start = 0, end = 0, total = 0;
            BOOL valid = match && muse_download_number([header substringWithRange:[match rangeAtIndex:1]], &start) &&
                         muse_download_number([header substringWithRange:[match rangeAtIndex:2]], &end) && end >= start;
            if (valid && job.hasRange) {
                valid = start == job.offset && end - start + 1 == job.length && fileLength == job.length;
                if (job.strictRange) {
                    valid &= muse_download_number([header substringWithRange:[match rangeAtIndex:3]], &total) &&
                             total == job.totalLength;
                }
            } else if (valid) {
                valid = muse_download_number([header substringWithRange:[match rangeAtIndex:3]], &total) &&
                        start == (uint64_t)job.resumeOffset && total > 0 && end == total - 1 && fileLength == total;
            }
            if (!valid) {
                job.error = muse_download_error(5, @"服务器仅返回了不完整的内容范围");
                return;
            }
        }
        NSError *error = nil;
        if (![NSFileManager.defaultManager moveItemAtURL:location toURL:job.destination error:&error]) job.error = error;
    } @catch (NSException *exception) {
        job.error = muse_download_error(31, exception.reason ?: @"下载文件处理失败");
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    MuseDownloadJob *job = [self jobForTask:task];
    if (!job) return;
    @try {
        if (error) {
            if (!job.error) job.error = error;
            id data = error.userInfo[NSURLSessionDownloadTaskResumeData];
            if ([data isKindOfClass:NSData.class]) job.resumeData = data;
            if ([task.response isKindOfClass:NSHTTPURLResponse.class]) job.response = (id)task.response;
        }
        if (job.probe && job.response && error.code == NSURLErrorCancelled) job.error = nil;
        if (!job.probe && !job.error && ![NSFileManager.defaultManager fileExistsAtPath:job.destination.path])
            job.error = muse_download_error(6, @"没有收到下载文件");
    } @catch (NSException *exception) {
        job.error = muse_download_error(34, exception.reason ?: @"下载完成处理失败");
    } @finally {
        [self.jobsLock lock];
        [self.jobs removeObjectForKey:@(task.taskIdentifier)];
        [self.jobsLock unlock];
        dispatch_semaphore_signal(job.done);
    }
}

- (NSString *)playlistAtURL:(NSURL *)file error:(NSError **)error {
    uint64_t length = [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:error][NSFileSize]
                       unsignedLongLongValue];
    if (!length || length > 2 * 1024 * 1024) {
        if (error) *error = muse_download_error(7, @"播放列表为空或超过可解析大小");
        return nil;
    }
    NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:error];
    NSMutableCharacterSet *trim = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [trim addCharactersInString:@"\ufeff"];
    text = [text stringByTrimmingCharactersInSet:trim];
    if (![text hasPrefix:@"#EXTM3U"]) {
        if (error) *error = muse_download_error(8, @"返回内容不是 HLS 播放列表");
        return nil;
    }
    return text;
}

- (BOOL)isMP4AtURL:(NSURL *)file {
    uint64_t length = [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL][NSFileSize]
                       unsignedLongLongValue];
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:file error:NULL];
    if (!input) return NO;
    if (length < 24) { [input closeFile]; return NO; }
    BOOL hasType = NO, hasMovie = NO, hasMedia = NO, valid = YES;
    @try {
        uint64_t offset = 0;
        NSUInteger boxes = 0;
        while (offset < length && ++boxes <= 200000) {
            [input seekToFileOffset:offset];
            NSData *header = [input readDataOfLength:16];
            if (header.length < 8) { valid = NO; break; }
            const uint8_t *bytes = header.bytes;
            uint64_t size = ((uint64_t)bytes[0] << 24) | ((uint64_t)bytes[1] << 16) |
                            ((uint64_t)bytes[2] << 8) | bytes[3];
            uint64_t minimum = 8;
            if (size == 1) {
                if (header.length < 16) { valid = NO; break; }
                minimum = 16;
                size = 0;
                for (int index = 8; index < 16; index++) size = (size << 8) | bytes[index];
            } else if (size == 0) size = length - offset;
            if (size < minimum || size > length - offset) { valid = NO; break; }
            hasType |= memcmp(bytes + 4, "ftyp", 4) == 0;
            hasMovie |= memcmp(bytes + 4, "moov", 4) == 0;
            hasMedia |= memcmp(bytes + 4, "mdat", 4) == 0;
            offset += size;
        }
        valid &= offset == length;
    } @catch (__unused NSException *exception) {
        valid = NO;
    } @finally {
        [input closeFile];
    }
    return valid && hasType && hasMovie && hasMedia;
}

- (NSURL *)variantFromPlaylist:(NSString *)text base:(NSURL *)base error:(NSError **)error {
    NSArray *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableSet *separateAudio = [NSMutableSet set];
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![line hasPrefix:@"#EXT-X-MEDIA:"]) continue;
        NSDictionary *attributes = muse_hls_attributes(line);
        if ([attributes[@"TYPE"] isEqualToString:@"AUDIO"] && [attributes[@"URI"] length])
            [separateAudio addObject:attributes[@"GROUP-ID"] ?: @""];
    }
    NSURL *best = nil;
    uint64_t bestBandwidth = 0;
    BOOL sawVariant = NO;
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = [lines[index] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
        sawVariant = YES;
        NSDictionary *attributes = muse_hls_attributes(line);
        if ([separateAudio containsObject:attributes[@"AUDIO"] ?: @""]) continue;
        uint64_t bandwidth = 0;
        muse_download_number(attributes[@"BANDWIDTH"], &bandwidth);
        for (NSUInteger next = index + 1; next < lines.count; next++) {
            NSString *reference = [lines[next] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!reference.length || [reference hasPrefix:@"#"]) continue;
            NSURL *url = muse_hls_url(reference, base);
            if (url && (!best || bandwidth > bestBandwidth)) { best = url; bestBandwidth = bandwidth; }
            break;
        }
    }
    if (sawVariant && !best && error)
        *error = muse_download_error(9, @"播放列表需要独立音轨封装或没有有效的视频线路");
    return best;
}

- (NSDictionary *)rangeForText:(NSString *)text previousEnd:(uint64_t)previousEnd
                     sameResource:(BOOL)same error:(NSError **)error {
    NSArray *parts = [text componentsSeparatedByString:@"@"];
    uint64_t length = 0, offset = previousEnd;
    BOOL valid = parts.count <= 2 && muse_download_number(parts.firstObject, &length) && length > 0;
    if (parts.count == 2) valid &= muse_download_number(parts[1], &offset);
    else valid &= same;
    valid &= offset <= UINT64_MAX - length;
    if (!valid) {
        if (error) *error = muse_download_error(10, @"无效的分片字节范围");
        return nil;
    }
    return @{@"offset": @(offset), @"length": @(length)};
}

- (NSArray<NSDictionary *> *)piecesFromPlaylist:(NSString *)text base:(NSURL *)base
                                          fmp4:(BOOL *)fmp4 error:(NSError **)error {
    NSMutableArray *pieces = [NSMutableArray array];
    NSDictionary *key = nil;
    NSDictionary *lastMap = nil;
    NSString *pendingRange = nil;
    NSURL *lastRangeURL = nil;
    uint64_t lastRangeEnd = 0, sequence = 0;
    BOOL sawMedia = NO;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        if ([line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
            if (!muse_download_number([line substringFromIndex:22], &sequence)) {
                if (error) *error = muse_download_error(11, @"无效的媒体分片序号");
                return nil;
            }
        } else if ([line hasPrefix:@"#EXT-X-KEY:"]) {
            NSDictionary *attributes = muse_hls_attributes(line);
            NSString *method = attributes[@"METHOD"];
            if ([method isEqualToString:@"NONE"]) { key = nil; continue; }
            if (![method isEqualToString:@"AES-128"] ||
                (attributes[@"KEYFORMAT"] && ![attributes[@"KEYFORMAT"] isEqualToString:@"identity"])) {
                if (error) *error = muse_download_error(12, @"此播放列表的加密方式暂不支持");
                return nil;
            }
            NSURL *keyURL = muse_hls_url(attributes[@"URI"], base);
            if (!keyURL) {
                if (error) *error = muse_download_error(13, @"播放列表缺少有效的 AES 密钥地址");
                return nil;
            }
            key = @{@"url": keyURL, @"iv": attributes[@"IV"] ?: @"", @"token": NSUUID.UUID.UUIDString};
        } else if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSDictionary *attributes = muse_hls_attributes(line);
            NSURL *url = muse_hls_url(attributes[@"URI"], base);
            if (!url) { if (error) *error = muse_download_error(14, @"初始化分片地址无效"); return nil; }
            NSMutableDictionary *map = [@{@"url": url, @"init": @YES} mutableCopy];
            if (attributes[@"BYTERANGE"]) {
                NSDictionary *range = [self rangeForText:attributes[@"BYTERANGE"] previousEnd:0 sameResource:YES error:error];
                if (!range) return nil;
                map[@"range"] = range;
            }
            if (key) {
                if (![key[@"iv"] length]) {
                    if (error) *error = muse_download_error(15, @"加密初始化分片需要明确的 IV");
                    return nil;
                }
                map[@"key"] = key;
            }
            if (lastMap && ![lastMap isEqual:map] && sawMedia) {
                if (error) *error = muse_download_error(16, @"多个初始化段需要重新封装，当前下载器暂不支持");
                return nil;
            }
            if (!lastMap || ![lastMap isEqual:map]) [pieces addObject:map];
            lastMap = map;
            *fmp4 = YES;
        } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            pendingRange = [line substringFromIndex:17];
        } else if (![line hasPrefix:@"#"]) {
            NSURL *url = muse_hls_url(line, base);
            if (!url) { if (error) *error = muse_download_error(17, @"媒体分片地址无效"); return nil; }
            NSMutableDictionary *piece = [@{@"url": url, @"sequence": @(sequence)} mutableCopy];
            if (key) piece[@"key"] = key;
            if (pendingRange) {
                NSDictionary *range = [self rangeForText:pendingRange previousEnd:lastRangeEnd
                                            sameResource:[url isEqual:lastRangeURL] error:error];
                if (!range) return nil;
                piece[@"range"] = range;
                lastRangeEnd = [range[@"offset"] unsignedLongLongValue] + [range[@"length"] unsignedLongLongValue];
                lastRangeURL = url;
                pendingRange = nil;
            } else lastRangeURL = nil;
            [pieces addObject:piece];
            sawMedia = YES;
            if (sequence == UINT64_MAX) { if (error) *error = muse_download_error(18, @"分片序号溢出"); return nil; }
            sequence++;
        }
    }
    if (!sawMedia || pendingRange) {
        if (error) *error = muse_download_error(19, @"没有完整的媒体分片列表");
        return nil;
    }
    return pieces;
}

- (NSData *)ivForKey:(NSDictionary *)key sequence:(uint64_t)sequence error:(NSError **)error {
    NSMutableData *iv = [NSMutableData dataWithLength:16];
    NSString *explicit = key[@"iv"];
    if (explicit.length) {
        if (![explicit hasPrefix:@"0x"] && ![explicit hasPrefix:@"0X"]) {
            if (error) *error = muse_download_error(20, @"AES IV 格式无效");
            return nil;
        }
        NSString *hex = [explicit substringFromIndex:2];
        if (!hex.length || hex.length > 32 ||
            [hex rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) {
            if (error) *error = muse_download_error(20, @"AES IV 格式无效");
            return nil;
        }
        hex = [[@"" stringByPaddingToLength:32 - hex.length withString:@"0" startingAtIndex:0] stringByAppendingString:hex];
        for (NSUInteger index = 0; index < 16; index++) {
            unsigned int byte = 0;
            sscanf([[hex substringWithRange:NSMakeRange(index * 2, 2)] UTF8String], "%2x", &byte);
            ((uint8_t *)iv.mutableBytes)[index] = byte;
        }
    } else {
        for (int index = 15; index >= 8; index--) {
            ((uint8_t *)iv.mutableBytes)[index] = (uint8_t)sequence;
            sequence >>= 8;
        }
    }
    return iv;
}

- (BOOL)decryptFile:(NSURL *)inputURL output:(NSURL *)outputURL key:(NSData *)key
                iv:(NSData *)iv error:(NSError **)error {
    if (key.length != 16 || iv.length != 16) {
        if (error) *error = muse_download_error(21, @"AES 密钥或 IV 长度错误");
        return NO;
    }
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus status = CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                            key.bytes, key.length, iv.bytes, &cryptor);
    if (status != kCCSuccess) { if (error) *error = muse_download_error(22, @"无法初始化 AES 解密"); return NO; }
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:inputURL error:error];
    [NSFileManager.defaultManager createFileAtPath:outputURL.path contents:nil attributes:nil];
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:outputURL error:error];
    if (!input || !output) {
        [input closeFile]; [output closeFile]; CCCryptorRelease(cryptor); return NO;
    }
    BOOL success = NO;
    @try {
        unsigned char decoded[65536 + kCCBlockSizeAES128];
        while (YES) {
            @autoreleasepool {
                NSData *data = [input readDataOfLength:65536];
                if (!data.length) break;
                size_t moved = 0;
                status = CCCryptorUpdate(cryptor, data.bytes, data.length, decoded, sizeof(decoded), &moved);
                if (status != kCCSuccess) break;
                [output writeData:[NSData dataWithBytes:decoded length:moved]];
            }
        }
        if (status == kCCSuccess) {
            size_t moved = 0;
            status = CCCryptorFinal(cryptor, decoded, sizeof(decoded), &moved);
            if (status == kCCSuccess) [output writeData:[NSData dataWithBytes:decoded length:moved]];
        }
        success = status == kCCSuccess;
        if (!success && error) *error = muse_download_error(23, @"AES 解密失败，分片未写入成品");
    } @catch (NSException *exception) {
        if (error) *error = muse_download_error(24, exception.reason ?: @"解密文件读写失败");
    } @finally {
        [input closeFile]; [output closeFile]; CCCryptorRelease(cryptor);
    }
    return success;
}

- (BOOL)validateMediaFile:(NSURL *)file initialization:(BOOL)initialization fmp4:(BOOL)fmp4
                    error:(NSError **)error {
    uint64_t length = [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:error][NSFileSize]
                       unsignedLongLongValue];
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:file error:error];
    if (!input) return NO;
    BOOL valid = NO;
    @try {
        if (fmp4) {
            BOOL movie = NO, fragment = NO, media = NO;
            uint64_t offset = 0;
            NSUInteger boxes = 0;
            valid = length >= 8;
            while (valid && offset < length && ++boxes <= 200000) {
                @autoreleasepool {
                    [input seekToFileOffset:offset];
                    NSData *header = [input readDataOfLength:16];
                    if (header.length < 8) { valid = NO; break; }
                    const uint8_t *bytes = header.bytes;
                    uint64_t size = ((uint64_t)bytes[0] << 24) | ((uint64_t)bytes[1] << 16) |
                                    ((uint64_t)bytes[2] << 8) | bytes[3];
                    uint64_t minimum = 8;
                    if (size == 1) {
                        if (header.length < 16) { valid = NO; break; }
                        minimum = 16;
                        size = 0;
                        for (int index = 8; index < 16; index++) size = (size << 8) | bytes[index];
                    } else if (!size) size = length - offset;
                    if (size < minimum || size > length - offset) { valid = NO; break; }
                    movie |= memcmp(bytes + 4, "moov", 4) == 0;
                    fragment |= memcmp(bytes + 4, "moof", 4) == 0;
                    media |= memcmp(bytes + 4, "mdat", 4) == 0;
                    offset += size;
                }
            }
            valid &= offset == length && (initialization ? movie : (fragment && media));
        } else {
            NSData *prefix = [input readDataOfLength:(NSUInteger)MIN(length, (uint64_t)(192 * 5))];
            const uint8_t *bytes = prefix.bytes;
            for (NSUInteger stride = 188; stride <= 192; stride += 4) {
                NSUInteger first = stride == 188 ? 0 : 4;
                if (length < stride || length % stride != 0) continue;
                BOOL synchronized = YES;
                for (NSUInteger offset = first; offset < prefix.length; offset += stride) {
                    if (bytes[offset] != 0x47) { synchronized = NO; break; }
                }
                if (synchronized) { valid = YES; break; }
            }
        }
    } @catch (NSException *exception) {
        if (error) *error = muse_download_error(32, exception.reason ?: @"媒体分片读取失败");
        valid = NO;
    } @finally {
        [input closeFile];
    }
    if (!valid && error && !*error)
        *error = muse_download_error(33, @"分片响应不是有效的 TS/fMP4 数据，可能返回了登录页或错误页面");
    return valid;
}

- (NSURL *)assemblePieces:(NSArray<NSDictionary *> *)pieces candidate:(MuseCandidate *)candidate
                directory:(NSURL *)directory error:(NSError **)error {
    NSMutableDictionary *keys = [NSMutableDictionary dictionary];
    for (NSDictionary *piece in pieces) {
        NSDictionary *key = piece[@"key"];
        if (!key || keys[key[@"token"]]) continue;
        MuseDownloadJob *job = [self fetchURL:key[@"url"] candidate:candidate range:nil directory:directory showProgress:NO];
        if (job.error) { if (error) *error = job.error; return nil; }
        uint64_t keyLength = [[NSFileManager.defaultManager attributesOfItemAtPath:job.destination.path error:NULL][NSFileSize]
                              unsignedLongLongValue];
        if (keyLength != 16) { if (error) *error = muse_download_error(25, @"AES 密钥响应不是 16 字节"); return nil; }
        NSData *bytes = [NSData dataWithContentsOfURL:job.destination];
        if (bytes.length != 16) { if (error) *error = muse_download_error(25, @"AES 密钥读取失败"); return nil; }
        keys[key[@"token"]] = bytes;
    }
    NSOperationQueue *workers = [NSOperationQueue new];
    workers.maxConcurrentOperationCount = 6;
    NSLock *resultsLock = [NSLock new];
    NSMutableArray *files = [NSMutableArray arrayWithCapacity:pieces.count];
    for (NSUInteger index = 0; index < pieces.count; index++) [files addObject:NSNull.null];
    __block NSError *firstError = nil;
    __block NSUInteger completed = 0;
    __block uint64_t downloaded = 0;
    NSTimeInterval assemblyStarted = NSDate.timeIntervalSinceReferenceDate;
    candidate.connections = MIN((NSUInteger)6, pieces.count);
    for (NSUInteger index = 0; index < pieces.count; index++) {
        [workers addOperationWithBlock:^{
            @autoreleasepool {
                NSDictionary *piece = pieces[index];
                NSError *pieceError = nil;
                NSURL *file = nil;
                @try {
                    MuseDownloadJob *job = [self fetchURL:piece[@"url"] candidate:candidate range:piece[@"range"]
                                              directory:directory showProgress:NO];
                    pieceError = job.error;
                    file = job.destination;
                    NSDictionary *key = piece[@"key"];
                    if (!pieceError && key) {
                        NSData *iv = [self ivForKey:key sequence:[piece[@"sequence"] unsignedLongLongValue] error:&pieceError];
                        NSURL *decoded = [directory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
                        if (iv && [self decryptFile:file output:decoded key:keys[key[@"token"]] iv:iv error:&pieceError]) file = decoded;
                    }
                    uint64_t length = [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL][NSFileSize]
                                       unsignedLongLongValue];
                    if (!pieceError && !length) pieceError = muse_download_error(26, @"媒体分片为空");
                    if (!pieceError)
                        [self validateMediaFile:file initialization:[piece[@"init"] boolValue] fmp4:candidate.isFmp4 error:&pieceError];
                } @catch (NSException *exception) {
                    pieceError = muse_download_error(35, exception.reason ?: @"媒体分片处理失败");
                }
                [resultsLock lock];
                if (pieceError && !firstError) firstError = pieceError;
                if (!pieceError) files[index] = file;
                completed++;
                if (!pieceError)
                    downloaded += [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL][NSFileSize] unsignedLongLongValue];
                candidate.progress = MAX(candidate.progress, 0.05 + 0.90 * (double)completed / (double)pieces.count);
                candidate.bytesPerSecond = (double)downloaded / MAX(0.2, NSDate.timeIntervalSinceReferenceDate - assemblyStarted);
                [resultsLock unlock];
                notify_list_changed();
            }
        }];
    }
    [workers waitUntilAllOperationsAreFinished];
    if (firstError) { if (error) *error = firstError; return nil; }
    return [self mergeFiles:files directory:directory error:error];
}

- (NSURL *)commitFile:(NSURL *)staged directory:(NSURL *)directory name:(NSString *)name
            extension:(NSString *)extension error:(NSError **)error {
    [self.filesLock lock];
    NSURL *destination = nil;
    @try {
        NSUInteger suffix = 1;
        do {
            NSString *filename = suffix == 1 ? [name stringByAppendingPathExtension:extension] :
                [[NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)suffix] stringByAppendingPathExtension:extension];
            destination = [directory URLByAppendingPathComponent:filename];
            suffix++;
        } while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]);
        if (![NSFileManager.defaultManager moveItemAtURL:staged toURL:destination error:error]) destination = nil;
    } @finally { [self.filesLock unlock]; }
    return destination;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    MuseDownloadJob *job = [self jobForTask:task];
    if (job.probe) {
        job.response = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    }
    completionHandler(NSURLSessionResponseCancel);
}

- (MuseDownloadJob *)probeURL:(NSURL *)url candidate:(MuseCandidate *)candidate {
    MuseDownloadJob *job = [MuseDownloadJob new];
    job.probe = YES;
    job.done = dispatch_semaphore_create(0);
    NSMutableURLRequest *request = [self requestForURL:url candidate:candidate
                                              range:@{@"offset": @0, @"length": @1}];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    [self.jobsLock lock];
    self.jobs[@(task.taskIdentifier)] = job;
    [self.jobsLock unlock];
    [task resume];
    dispatch_semaphore_wait(job.done, DISPATCH_TIME_FOREVER);
    return job;
}

- (NSString *)header:(NSString *)name response:(NSHTTPURLResponse *)response {
    for (NSString *key in response.allHeaderFields) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return [response.allHeaderFields[key] description];
    }
    return nil;
}

- (NSURL *)mergeFiles:(NSArray<NSURL *> *)files directory:(NSURL *)directory error:(NSError **)error {
    NSURL *merged = [directory URLByAppendingPathComponent:@"merged"];
    [NSFileManager.defaultManager createFileAtPath:merged.path contents:nil attributes:nil];
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:merged error:error];
    if (!output) return nil;
    BOOL success = YES;
    @try {
        for (NSURL *file in files) {
            NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:file error:error];
            if (!input) { success = NO; break; }
            @try {
                while (YES) {
                    @autoreleasepool {
                        NSData *data = [input readDataOfLength:65536];
                        if (!data.length) break;
                        [output writeData:data];
                    }
                }
            } @finally { [input closeFile]; }
        }
    } @catch (NSException *exception) {
        success = NO;
        if (error) *error = muse_download_error(27, exception.reason ?: @"分块合并失败");
    } @finally { [output closeFile]; }
    return success ? merged : nil;
}

- (NSURL *)parallelMP4:(NSHTTPURLResponse *)response candidate:(MuseCandidate *)candidate
             directory:(NSURL *)directory error:(NSError **)error {
    if (response.statusCode != 206) return nil;
    NSString *contentRange = [self header:@"Content-Range" response:response];
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^bytes 0-0/([0-9]+)$" options:0 error:NULL];
    });
    NSTextCheckingResult *match = [pattern firstMatchInString:contentRange ?: @"" options:0
                                                      range:NSMakeRange(0, contentRange.length)];
    uint64_t total = 0;
    if (!match || !muse_download_number([contentRange substringWithRange:[match rangeAtIndex:1]], &total) ||
        total <= 8 * 1024 * 1024 || total > INT64_MAX) return nil;
    NSString *mime = response.MIMEType.lowercaseString;
    if (![mime isEqualToString:@"video/mp4"] &&
        ![response.URL.path.pathExtension.lowercaseString isEqualToString:@"mp4"]) return nil;
    NSString *validator = [self header:@"ETag" response:response];
    if (!validator.length || [validator hasPrefix:@"W/"]) validator = [self header:@"Last-Modified" response:response];
    uint64_t chunkSize = 4 * 1024 * 1024;
    NSUInteger count = (NSUInteger)((total + chunkSize - 1) / chunkSize);
    NSUInteger connections = MIN((NSUInteger)6, count);
    candidate.connections = connections;
    mlog(@"并发下载 %@：%lu 路，%llu 字节，%lu 个分块", candidate.title, (unsigned long)connections,
         (unsigned long long)total, (unsigned long)count);
    NSOperationQueue *workers = [NSOperationQueue new];
    workers.maxConcurrentOperationCount = connections;
    NSLock *lock = [NSLock new];
    NSMutableArray *files = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *written = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [files addObject:NSNull.null];
        [written addObject:@0];
    }
    __block NSError *firstError = nil;
    NSTimeInterval started = NSDate.timeIntervalSinceReferenceDate;
    void (^update)(NSUInteger, uint64_t) = ^(NSUInteger index, uint64_t amount) {
        [lock lock];
        written[index] = @(MAX(written[index].unsignedLongLongValue, amount));
        uint64_t received = 0;
        for (NSNumber *bytes in written) received += bytes.unsignedLongLongValue;
        candidate.progress = MAX(candidate.progress, 0.95 * (double)received / (double)total);
        candidate.bytesPerSecond = (double)received / MAX(0.2, NSDate.timeIntervalSinceReferenceDate - started);
        [lock unlock];
        notify_list_changed();
    };
    for (NSUInteger index = 0; index < count; index++) {
        uint64_t offset = (uint64_t)index * chunkSize;
        uint64_t length = MIN(chunkSize, total - offset);
        [workers addOperationWithBlock:^{
            @autoreleasepool {
                NSDictionary *range = @{@"offset": @(offset), @"length": @(length), @"strict": @YES,
                                        @"total": @(total), @"validator": validator ?: @""};
                MuseDownloadJob *job = nil;
                NSError *chunkError = nil;
                @try {
                    job = [self fetchURL:response.URL candidate:candidate range:range directory:directory
                             showProgress:NO progress:^(int64_t bytes) {
                        update(index, MIN(length, (uint64_t)MAX(bytes, (int64_t)0)));
                    }];
                    chunkError = job.error;
                } @catch (NSException *exception) {
                    chunkError = muse_download_error(43, exception.reason ?: @"分块下载失败");
                }
                [lock lock];
                if (chunkError && !firstError) firstError = chunkError;
                if (!chunkError) files[index] = job.destination;
                [lock unlock];
                if (!chunkError) update(index, length);
            }
        }];
    }
    [workers waitUntilAllOperationsAreFinished];
    if (firstError) { if (error) *error = firstError; return nil; }
    NSURL *merged = [self mergeFiles:files directory:directory error:error];
    uint64_t length = [[NSFileManager.defaultManager attributesOfItemAtPath:merged.path error:NULL][NSFileSize] unsignedLongLongValue];
    if (merged && (length != total || ![self isMP4AtURL:merged])) {
        if (error) *error = muse_download_error(42, @"分块合并后的 MP4 不完整");
        return nil;
    }
    return merged;
}

- (void)downloadCandidate:(MuseCandidate *)candidate {
    @autoreleasepool {
        NSURL *working = nil;
        NSError *error = nil;
        NSURL *completed = nil;
        @try {
            candidate.status = CandRunning;
            candidate.errorText = nil;
            candidate.progress = 0;
            candidate.bytesPerSecond = 0;
            candidate.connections = 1;
            notify_list_changed();
            NSString *safe = [[candidate.title componentsSeparatedByCharactersInSet:
                              [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r"]]
                             componentsJoinedByString:@"_"];
            if (!safe.length || [safe isEqualToString:@"."] || [safe isEqualToString:@".."]) safe = @"MuseVideo";
            if (safe.length > 60) safe = [safe substringWithRange:[safe rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 60)]];
            if ([safe lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) safe = @"MuseVideo";
            NSURL *directory = [NSURL fileURLWithPath:[out_dir() stringByAppendingPathComponent:safe] isDirectory:YES];
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error])
                @throw [NSException exceptionWithName:@"MuseDownload" reason:error.localizedDescription userInfo:nil];
            working = [directory URLByAppendingPathComponent:[@".work-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
            if (![NSFileManager.defaultManager createDirectoryAtURL:working withIntermediateDirectories:NO attributes:nil error:&error])
                @throw [NSException exceptionWithName:@"MuseDownload" reason:error.localizedDescription userInfo:nil];
            NSURL *url = muse_hls_url(candidate.url, nil);
            if (!url) @throw [NSException exceptionWithName:@"MuseDownload" reason:@"播放地址无效" userInfo:nil];
            MuseDownloadJob *probe = [self probeURL:url candidate:candidate];
            NSURL *parallel = [self parallelMP4:probe.response candidate:candidate directory:working error:&error];
            if (parallel) {
                candidate.isFmp4 = YES;
                completed = [self commitFile:parallel directory:directory name:safe extension:@"mp4" error:&error];
            } else {
                if ([error.domain isEqualToString:@"MuseHook.Download"] && error.code == 41) error = nil;
                if (error) @throw [NSException exceptionWithName:@"MuseDownload" reason:error.localizedDescription userInfo:nil];
                candidate.connections = 1;
                MuseDownloadJob *root = [self fetchURL:url candidate:candidate range:nil directory:working showProgress:YES];
                if (root.error) error = root.error;
                NSURL *mediaFile = nil;
                NSString *extension = @"mp4";
                if (!error && [self isMP4AtURL:root.destination]) {
                    candidate.isFmp4 = YES;
                    mediaFile = root.destination;
                } else if (!error) {
                    NSString *text = [self playlistAtURL:root.destination error:&error];
                    NSURL *base = root.response.URL;
                    NSMutableSet *visited = [NSMutableSet set];
                    for (NSUInteger depth = 0; text && [text containsString:@"#EXT-X-STREAM-INF:"] && depth < 5; depth++) {
                        NSURL *variant = [self variantFromPlaylist:text base:base error:&error];
                        if (!variant || [visited containsObject:variant.absoluteString]) {
                            if (!error) error = muse_download_error(28, @"播放列表循环引用");
                            text = nil;
                            break;
                        }
                        [visited addObject:variant.absoluteString];
                        MuseDownloadJob *next = [self fetchURL:variant candidate:candidate range:nil directory:working showProgress:NO];
                        if (next.error) { error = next.error; text = nil; break; }
                        base = next.response.URL;
                        text = [self playlistAtURL:next.destination error:&error];
                    }
                    if (text && [text containsString:@"#EXT-X-STREAM-INF:"]) {
                        error = muse_download_error(29, @"播放列表嵌套过深");
                        text = nil;
                    }
                    BOOL fmp4 = NO;
                    NSArray *pieces = text ? [self piecesFromPlaylist:text base:base fmp4:&fmp4 error:&error] : nil;
                    candidate.isFmp4 = fmp4;
                    extension = fmp4 ? @"mp4" : @"ts";
                    if (pieces) mediaFile = [self assemblePieces:pieces candidate:candidate directory:working error:&error];
                }
                if (mediaFile && !error) completed = [self commitFile:mediaFile directory:directory name:safe extension:extension error:&error];
            }
        } @catch (NSException *exception) {
            if (!error) error = muse_download_error(30, exception.reason ?: @"下载失败");
        } @finally {
            if (working) [NSFileManager.defaultManager removeItemAtURL:working error:NULL];
        }
        if (completed) {
            candidate.status = CandDone;
            candidate.progress = 1;
            candidate.errorText = nil;
            mlog(@"下载完成: %@", completed.path);
        } else {
            candidate.status = CandFailed;
            candidate.progress = 0;
            candidate.errorText = error.localizedDescription ?: @"下载未完成";
            mlog(@"下载失败: %@", candidate.errorText);
        }
        notify_list_changed();
    }
}
@end

// ───────────────────────── 列表 UI ─────────────────────────
static NSArray<MuseCandidate *> *cand_snapshot(void) {
    [gLock lock];
    NSArray *a = [gCands copy];
    [gLock unlock];
    return a;
}

static NSString *muse_diagnostic_report(void);

@interface MuseListVC : UITableViewController
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation MuseListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"暮色下载";
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    UIBarButtonItem *selAll = [[UIBarButtonItem alloc] initWithTitle:@"全选"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self action:@selector(selAll)];
    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                              style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItems = @[close, selAll];
    UIBarButtonItem *download =
        [[UIBarButtonItem alloc] initWithTitle:@"下载选中" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(downloadSelected)];
    UIBarButtonItem *diagnostics =
        [[UIBarButtonItem alloc] initWithTitle:@"诊断" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(showDiagnostics)];
    self.navigationItem.rightBarButtonItems = @[download, diagnostics];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:@"MuseListChanged" object:nil];
    [self updateEmptyHint];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:self.onClose];
}

- (void)showDiagnostics {
    NSString *report = muse_diagnostic_report();
    for (MuseCandidate *candidate in cand_snapshot()) {
        if (candidate.status == CandRunning)
            report = [report stringByAppendingFormat:@"\n下载 %.0f%%，%.0f KB/s，%lu路",
                      candidate.progress * 100, candidate.bytesPerSecond / 1024, (unsigned long)candidate.connections];
        if (candidate.errorText.length) {
            report = [report stringByAppendingFormat:@"\n下载错误 %@", candidate.errorText];
            break;
        }
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MuseHook 诊断"
                                                                 message:report
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = report;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
        [self updateEmptyHint];
    });
}

- (void)updateEmptyHint {
    if (cand_snapshot().count == 0) {
        UILabel *l = [[UILabel alloc] initWithFrame:self.tableView.bounds];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor colorWithWhite:0.6 alpha:1];
        l.font = [UIFont systemFontOfSize:14];
        l.text = [NSString stringWithFormat:@"还没有候选。\n\n播放视频后重新打开列表。\n点右上角「诊断」可查看或复制抓取状态。\n\n%@", muse_diagnostic_report()];
        self.tableView.backgroundView = l;
    } else {
        self.tableView.backgroundView = nil;
    }
}

- (void)selAll {
    NSArray<MuseCandidate *> *snap = cand_snapshot();
    BOOL all = YES;
    for (MuseCandidate *c in snap) if (!c.selected) { all = NO; break; }
    for (MuseCandidate *c in snap) c.selected = !all;
    [self.tableView reloadData];
}

- (void)downloadSelected {
    __block NSInteger n = 0;
    for (MuseCandidate *c in cand_snapshot()) {
        if (c.selected && c.status != CandRunning && c.status != CandDone) {
            c.selected = NO;
            c.status = CandRunning;
            c.progress = 0;
            n++;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[MuseDl shared] downloadCandidate:c];
            });
        }
    }
    if (n == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没选中"
                                                                  message:@"先勾选要下载的条目"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)cand_snapshot().count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)idx {
    static NSString *cid = @"c";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSArray<MuseCandidate *> *snap = cand_snapshot();
    if (idx.row >= (NSInteger)snap.count) return cell;
    MuseCandidate *c = snap[idx.row];
    cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    cell.textLabel.text = c.title;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    NSString *state = @"";
    switch (c.status) {
        case CandIdle:    state = @"待选"; break;
        case CandRunning: {
            NSString *speed = c.bytesPerSecond >= 1024 * 1024
                ? [NSString stringWithFormat:@"%.1f MB/s", c.bytesPerSecond / (1024 * 1024)]
                : [NSString stringWithFormat:@"%.0f KB/s", c.bytesPerSecond / 1024];
            state = [NSString stringWithFormat:@"下载中 %.0f%% %@ %lu路", c.progress * 100, speed, (unsigned long)c.connections];
            break;
        }
        case CandDone:    state = @"✅ 已完成"; break;
        case CandFailed:  state = @"❌ 失败（可重试）"; break;
    }
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@  ·  %@",
                                 [df stringFromDate:c.time], state, c.url.lastPathComponent];
    cell.accessoryType = c.selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    if (c.status == CandRunning) {
        UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        pv.frame = CGRectMake(0, 0, 90, 4);
        pv.progress = c.progress;
        cell.accessoryView = pv;
    } else {
        cell.accessoryView = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)idx {
    [tv deselectRowAtIndexPath:idx animated:YES];
    NSArray<MuseCandidate *> *snap = cand_snapshot();
    if (idx.row >= (NSInteger)snap.count) return;
    MuseCandidate *c = snap[idx.row];
    if (c.status == CandFailed) {
        c.status = CandRunning; c.progress = 0;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[MuseDl shared] downloadCandidate:c];
        });
    } else {
        c.selected = !c.selected;
    }
    [tv reloadRowsAtIndexPaths:@[idx] withRowAnimation:UITableViewRowAnimationNone];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)idx {
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"移出列表"
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        NSArray<MuseCandidate *> *snap = cand_snapshot();
        if (idx.row < (NSInteger)snap.count) {
            MuseCandidate *c = snap[idx.row];
            [gLock lock]; [gCands removeObject:c]; [gSeen removeObjectForKey:c.url]; [gLock unlock];
        }
        [tv deleteRowsAtIndexPaths:@[idx] withRowAnimation:UITableViewRowAnimationAutomatic];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

// ───────────────────────── 悬浮球 + 窗口 ─────────────────────────
@interface MuseUI : NSObject
@property (nonatomic, weak) UIWindow *win;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, weak) UINavigationController *listController;
@property (nonatomic, assign) NSInteger retry;
@end

@implementation MuseUI

+ (instancetype)shared {
    static MuseUI *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MuseUI new]; });
    return s;
}

- (void)setup {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (self.ball.window) return;
            UIWindow *host = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]] ||
                    scene.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (window.hidden || window.alpha <= 0 ||
                        window.windowLevel != UIWindowLevelNormal ||
                        !window.rootViewController) continue;
                    if (!host || window.isKeyWindow) host = window;
                    if (window.isKeyWindow) break;
                }
                if (host) break;
            }
            if (!host) {
                if (self.retry < 8) {
                    self.retry++;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{ [self setup]; });
                } else {
                    mlog(@"等待应用主窗口超时");
                }
                return;
            }
            self.win = host;

            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(0, 0, 56, 56);
            b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                 UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin |
                                 UIViewAutoresizingFlexibleBottomMargin;
            b.layer.cornerRadius = 28;
            b.layer.masksToBounds = YES;
            b.backgroundColor = [UIColor colorWithRed:0.49 green:0.30 blue:1.0 alpha:0.92];
            [b setTitle:@"0" forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
            [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            b.layer.borderWidth = 1;
            b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
            [b addTarget:self action:@selector(openList) forControlEvents:UIControlEventTouchUpInside];

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
            [b addGestureRecognizer:pan];

            CGSize sz = host.bounds.size;
            b.center = CGPointMake(sz.width - 46, sz.height * 0.42);
            [host addSubview:b];
            self.ball = b;

            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshBadge)
                                                         name:@"MuseBadgeChanged" object:nil];
            mlog(@"悬浮球已挂到应用主窗口");
        } @catch (NSException *e) {
            mlog(@"UI 创建失败: %@", e);
        }
    });
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint p = [g translationInView:v.superview];
    CGRect area = UIEdgeInsetsInsetRect(self.win.bounds, self.win.safeAreaInsets);
    CGFloat halfWidth = CGRectGetWidth(v.bounds) / 2;
    CGFloat halfHeight = CGRectGetHeight(v.bounds) / 2;
    v.center = CGPointMake(
        MIN(CGRectGetMaxX(area) - halfWidth, MAX(CGRectGetMinX(area) + halfWidth, v.center.x + p.x)),
        MIN(CGRectGetMaxY(area) - halfHeight, MAX(CGRectGetMinY(area) + halfHeight, v.center.y + p.y)));
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)refreshBadge {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *t = gUnseen > 0 ? [NSString stringWithFormat:@"%ld", (long)gUnseen] : @"0";
        [self.ball setTitle:t forState:UIControlStateNormal];
        self.ball.backgroundColor = gUnseen > 0
            ? [UIColor colorWithRed:1.0 green:0.35 blue:0.30 alpha:0.95]
            : [UIColor colorWithRed:0.49 green:0.30 blue:1.0 alpha:0.85];
    });
}

- (void)openList {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.listController || !self.ball.window) return;
        UIViewController *presenter = self.ball.window.rootViewController;
        while (presenter.presentedViewController) {
            presenter = presenter.presentedViewController;
        }
        if (!presenter.view.window || presenter.isBeingPresented || presenter.isBeingDismissed) return;
        gUnseen = 0;
        [self refreshBadge];
        MuseListVC *vc = [MuseListVC new];
        __weak MuseUI *weakSelf = self;
        vc.onClose = ^{
            MuseUI *ui = weakSelf;
            ui.listController = nil;
            ui.ball.hidden = NO;
            [ui.ball.superview bringSubviewToFront:ui.ball];
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        self.listController = nav;
        self.ball.hidden = YES;
        [presenter presentViewController:nav animated:YES completion:nil];
    });
}

@end

// ───────────────────────── 播放器抓取 ─────────────────────────
static dispatch_queue_t gMediaCaptureQueue;
static _Atomic(NSUInteger) gMediaHooksInstalled;
static _Atomic(NSUInteger) gMediaCallsObserved;
static _Atomic(NSUInteger) gMediaURLsObserved;
static NSString *gMediaLastEvent;
static NSString *gMediaLastAddress;
static IMP gBetterCallOriginal;
static IMP gFSPrepareOriginal;
static IMP gFSPlayOriginal;
static IMP gAVReplaceOriginal;
static IMP gAVPlayOriginal;

static void muse_record_player_call(NSString *event) {
    atomic_fetch_add(&gMediaCallsObserved, 1);
    if (gMediaCaptureQueue)
        dispatch_async(gMediaCaptureQueue, ^{ gMediaLastEvent = event; });
}

static id muse_object_property(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char *type = method_copyReturnType(method);
    BOOL objectResult = type && type[0] == '@';
    free(type);
    if (!objectResult) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSDictionary *muse_media_headers(id value) {
    if (![value isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (id key in value) {
        id field = value[key];
        if ([key isKindOfClass:[NSString class]] && [field isKindOfClass:[NSString class]] &&
            [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound &&
            [field rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound) {
            headers[key] = field;
        }
    }
    return headers.count ? [headers copy] : nil;
}

static void muse_record_media(id value, NSString *title, NSDictionary *headers, NSString *origin) {
    if (!gReady || !gMediaCaptureQueue) return;
    NSString *url = [value isKindOfClass:[NSURL class]] ? [value absoluteString] : value;
    if (![url isKindOfClass:[NSString class]] || !url.length || url.length > 8192) return;
    NSURLComponents *parts = [NSURLComponents componentsWithString:url];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!parts.host.length || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return;
    NSString *extension = parts.path.pathExtension.lowercaseString;
    if ([@[@"mp3", @"aac", @"wav", @"m4a", @"ogg"] containsObject:extension]) return;
    NSString *capturedURL = [url copy];
    NSString *capturedTitle = [title copy];
    NSDictionary *capturedHeaders = [headers copy];
    atomic_fetch_add(&gMediaURLsObserved, 1);
    dispatch_async(gMediaCaptureQueue, ^{
        @autoreleasepool {
            gMediaLastEvent = origin;
            gMediaLastAddress = [NSString stringWithFormat:@"%@%@", parts.host, parts.percentEncodedPath ?: @""];
            add_candidate(capturedURL, capturedTitle, capturedHeaders);
        }
    });
}

static void muse_collect_media(id object, NSString *title, NSDictionary *headers, NSUInteger depth) {
    if (depth > 12) return;
    if ([object isKindOfClass:[NSDictionary class]]) {
        id ownTitle = object[@"title"] ?: object[@"name"];
        NSString *matchingTitle = [ownTitle isKindOfClass:[NSString class]] ? ownTitle : title;
        NSDictionary *matchingHeaders = muse_media_headers(object[@"headers"] ?: object[@"httpHeaders"]) ?: headers;
        for (id key in object) {
            id value = object[key];
            NSString *name = [key isKindOfClass:[NSString class]] ? [key lowercaseString] : @"";
            if ([@[@"uri", @"url", @"videourl", @"source", @"src"] containsObject:name]) {
                muse_record_media(value, matchingTitle, matchingHeaders, @"BetterPlayer 数据源");
            }
            if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]])
                muse_collect_media(value, matchingTitle, matchingHeaders, depth + 1);
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in object) muse_collect_media(value, title, headers, depth + 1);
    }
}

static void muse_better_call(id object, SEL selector, id call, id result) {
    @try {
        NSString *method = muse_object_property(call, NSSelectorFromString(@"method"));
        NSString *lower = method.lowercaseString;
        muse_record_player_call([NSString stringWithFormat:@"BetterPlayer %@", method ?: @"未知方法"]);
        if ([lower containsString:@"datasource"] || [lower isEqualToString:@"create"]) {
            id arguments = muse_object_property(call, NSSelectorFromString(@"arguments"));
            muse_collect_media(arguments, nil, nil, 0);
        }
    } @catch (__unused NSException *exception) {}
    ((void (*)(id, SEL, id, id))gBetterCallOriginal)(object, selector, call, result);
}

static void muse_fs_prepare(id object, SEL selector) {
    @try {
        muse_record_player_call(@"FSPlayer 准备播放");
        muse_record_media(muse_object_property(object, NSSelectorFromString(@"contentURL")), nil, nil, @"FSPlayer 准备播放");
    } @catch (__unused NSException *exception) {}
    ((void (*)(id, SEL))gFSPrepareOriginal)(object, selector);
}

static void muse_fs_play(id object, SEL selector) {
    @try {
        muse_record_player_call(@"FSPlayer 播放");
        muse_record_media(muse_object_property(object, NSSelectorFromString(@"contentURL")), nil, nil, @"FSPlayer 播放");
    } @catch (__unused NSException *exception) {}
    ((void (*)(id, SEL))gFSPlayOriginal)(object, selector);
}

static void muse_capture_av_item(id item, NSString *origin) {
    id asset = muse_object_property(item, NSSelectorFromString(@"asset"));
    id url = muse_object_property(asset, NSSelectorFromString(@"URL"));
    muse_record_media(url, nil, nil, origin);
}

static void muse_av_replace(id object, SEL selector, id item) {
    @try {
        muse_record_player_call(@"AVPlayer 更换数据源");
        muse_capture_av_item(item, @"AVPlayer 更换数据源");
    } @catch (__unused NSException *exception) {}
    ((void (*)(id, SEL, id))gAVReplaceOriginal)(object, selector, item);
}

static void muse_av_play(id object, SEL selector) {
    @try {
        muse_record_player_call(@"AVPlayer 播放");
        id item = muse_object_property(object, NSSelectorFromString(@"currentItem"));
        muse_capture_av_item(item, @"AVPlayer 播放");
    } @catch (__unused NSException *exception) {}
    ((void (*)(id, SEL))gAVPlayOriginal)(object, selector);
}

static BOOL muse_install_media_hook(NSString *name, NSString *methodName, unsigned int arguments,
                                    char resultType, IMP replacement, IMP *original) {
    if (*original) return YES;
    Class cls = NSClassFromString(name);
    SEL selector = NSSelectorFromString(methodName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != arguments) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && type[0] == resultType;
    free(type);
    for (unsigned int index = 2; valid && index < arguments; index++) {
        char *argument = method_copyArgumentType(method, index);
        valid = argument && argument[0] == '@';
        free(argument);
    }
    if (!valid) return NO;
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return YES;
}

static void muse_media_install_hooks(NSUInteger retry) {
    NSUInteger installed = 0;
    installed += muse_install_media_hook(@"_TtC18better_player_plus18BetterPlayerPlugin", @"handleMethodCall:result:",
                                        4, 'v', (IMP)muse_better_call, &gBetterCallOriginal);
    installed += muse_install_media_hook(@"FSPlayer", @"prepareToPlay",
                                        2, 'v', (IMP)muse_fs_prepare, &gFSPrepareOriginal);
    installed += muse_install_media_hook(@"FSPlayer", @"play", 2, 'v', (IMP)muse_fs_play, &gFSPlayOriginal);
    installed += muse_install_media_hook(@"AVPlayer", @"replaceCurrentItemWithPlayerItem:",
                                        3, 'v', (IMP)muse_av_replace, &gAVReplaceOriginal);
    installed += muse_install_media_hook(@"AVPlayer", @"play", 2, 'v', (IMP)muse_av_play, &gAVPlayOriginal);
    atomic_store(&gMediaHooksInstalled, installed);
    if (installed < 5 && retry < 5)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            muse_media_install_hooks(retry + 1);
        });
}

static void muse_media_capture_start(void) {
    gMediaCaptureQueue = dispatch_queue_create("MuseHook.media", DISPATCH_QUEUE_SERIAL);
    muse_media_install_hooks(0);
}

static NSString *muse_diagnostic_report(void) {
    __block NSString *event = nil;
    __block NSString *address = nil;
    if (gMediaCaptureQueue) {
        dispatch_sync(gMediaCaptureQueue, ^{
            event = gMediaLastEvent;
            address = gMediaLastAddress;
        });
    }
    NSString *logPath = gLogPath ?: [out_dir() stringByAppendingPathComponent:@"hook.log"];
    return [NSString stringWithFormat:
        @"MuseHook 播放器抓取版 · 分块续传\n观察点 %lu/5\n播放器调用 %lu\n播放地址 %lu\n最近入口 %@\n最近地址 %@\n日志 %@",
        (unsigned long)atomic_load(&gMediaHooksInstalled),
        (unsigned long)atomic_load(&gMediaCallsObserved),
        (unsigned long)atomic_load(&gMediaURLsObserved),
        event ?: @"等待播放", address ?: @"等待播放", logPath];
}

// ───────────────────────── 入口 ─────────────────────────
// constructor 里只做一件事：把初始化丢到主队列延后执行。
// 不建对象、不碰文件、不碰 UIKit —— 上一版就是在这里崩的。
static void muse_bootstrap(void) {
    @try {
        // 紧急开关：/var/mobile/Media/暮色下载/disable 存在 = 完全不工作（救命用）
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Media/暮色下载/disable"]) {
            return;
        }
        gLock = [NSLock new];
        gCands = [NSMutableArray array];
        gSeen = [NSMutableDictionary dictionary];
        gUnseen = 0;
        (void)out_dir();
        muse_media_capture_start();
        mlog(@"MuseHook 已注入（播放器抓取版）· 输出: %@", out_dir());
        gReady = YES;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { [[MuseUI shared] setup]; }
            @catch (NSException *e) { mlog(@"UI 失败: %@", e); }
        });
    } @catch (NSException *e) {
        gReady = NO;
    }
}

__attribute__((constructor))
static void muse_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        muse_bootstrap();
    });
}
