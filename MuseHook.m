//
//  MuseHook.m — 暮色 手动选择式下载 dylib（TrollFools 注入）
//
//  与上一版的区别：**不再自动下载**。
//    · 播放时只把抓到的 .m3u8 记成「候选」，不产生任何下载流量
//    · 暮色界面右侧浮出一个悬浮球，角标 = 新候选数
//    · 点悬浮球 → 原生列表，勾选 → 点「下载选中」才真正下
//
//  原理：接口是明文 http://IP:6868，Flutter(dart:io) 走 BSD socket，
//        dylib 观察 socket 的读写入口，重组 HTTP 和本机播放代理中的播放地址。
//        UI 把悬浮球加到应用现有主窗口，列表由现有控制器弹出。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSDate *time;
@property (nonatomic, assign) BOOL selected;
@property (nonatomic, assign) CandStatus status;
@property (nonatomic, assign) double progress;   // 0~1
@property (nonatomic, assign) BOOL isFmp4;
@end

@implementation MuseCandidate
@end

// 全局表
static NSMutableArray<MuseCandidate *> *gCands;   // 最新在前
static NSMutableDictionary<NSString *, NSNumber *> *gSeen;
static NSLock *gLock;
static NSInteger gUnseen = 0;                     // 角标
static _Atomic(BOOL) gReady = NO;

static void notify_list_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MuseListChanged" object:nil];
    });
}

static MuseCandidate *add_candidate(NSString *url, NSString *title) {
    if (url.length < 8) return nil;
    [gLock lock];
    if (gSeen[url]) { [gLock unlock]; return nil; }
    gSeen[url] = @YES;
    MuseCandidate *c = [MuseCandidate new];
    c.url = url;
    c.title = title.length ? title : [NSString stringWithFormat:@"候选 %lu", (unsigned long)(gCands.count + 1)];
    c.time = [NSDate date];
    c.selected = NO;
    c.status = CandIdle;
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
@interface MuseDl : NSObject
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *keyCache;
@property (nonatomic, strong) NSLock *keyLock;
@end

@implementation MuseDl

+ (instancetype)shared {
    static MuseDl *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MuseDl new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.HTTPMaximumConnectionsPerHost = 6;
        cfg.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                           @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            @"Accept": @"*/*",
        };
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _keyCache = [NSMutableDictionary dictionary];
        _keyLock = [NSLock new];
    }
    return self;
}

- (NSData *)syncGet:(NSString *)url range:(NSString *)range {
    __block NSData *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    if (range) [req setValue:range forHTTPHeaderField:@"Range"];
    NSURLSessionDataTask *t = [_session dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            if (!e) result = d;
            dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC));
    return result;
}

- (NSString *)syncGetText:(NSString *)url {
    NSData *d = [self syncGet:url range:nil];
    if (!d) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?:
           [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
}

- (NSData *)aes128:(NSData *)data key:(NSData *)key iv:(NSData *)iv {
    if (key.length != 16) return data;
    if (iv.length != 16) iv = [NSMutableData dataWithLength:16];
    size_t outLen = data.length + 32;
    NSMutableData *out = [NSMutableData dataWithLength:outLen];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, 0,
                                 key.bytes, key.length, iv.bytes,
                                 data.bytes, data.length,
                                 out.mutableBytes, outLen, &moved);
    if (st != kCCSuccess) return data;
    out.length = moved;
    const uint8_t *b = out.bytes;
    if (moved > 0) {
        uint8_t p = b[moved - 1];
        if (p >= 1 && p <= 16 && moved >= p) {
            BOOL ok = YES;
            for (size_t i = moved - p; i < moved; i++) if (b[i] != p) { ok = NO; break; }
            if (ok) out.length = moved - p;
        }
    }
    return out;
}

/// 下载一个候选（后台线程调用），进度通过 candidate.progress 回传
- (void)downloadCandidate:(MuseCandidate *)cand {
    @autoreleasepool {
        @try {
            NSString *url = cand.url;
            mlog(@"⬇️ 开始下载: %@", cand.title);

            NSString *text = [self syncGetText:url];
            if (text.length == 0) {
                cand.status = CandFailed;
                notify_list_changed();
                mlog(@"playlist 拉取失败: %@", url);
                return;
            }

            NSString *base = url;
            if ([text containsString:@"#EXT-X-STREAM-INF"]) {
                NSArray *lines = [text componentsSeparatedByString:@"\n"];
                NSString *best = nil; NSInteger bestBw = -1;
                for (NSUInteger i = 0; i < lines.count; i++) {
                    NSString *l = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (![l hasPrefix:@"#EXT-X-STREAM-INF"]) continue;
                    NSInteger bw = 0;
                    NSRange rb = [l rangeOfString:@"BANDWIDTH="];
                    if (rb.location != NSNotFound) bw = [[l substringFromIndex:rb.location + rb.length] integerValue];
                    for (NSUInteger j = i + 1; j < lines.count; j++) {
                        NSString *n = [lines[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        if (n.length == 0 || [n hasPrefix:@"#"]) continue;
                        if (bw > bestBw) { bestBw = bw; best = n; }
                        break;
                    }
                }
                if (best) {
                    base = [NSURL URLWithString:best relativeToURL:[NSURL URLWithString:url]].absoluteString;
                    text = [self syncGetText:base] ?: text;
                }
            }

            NSMutableArray<NSDictionary *> *segs = [NSMutableArray array];
            NSDictionary *curKey = nil;
            NSDictionary *initSeg = nil;
            NSInteger pendLen = -1; long long curOff = 0, lastEnd = 0;

            for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
                NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (l.length == 0) continue;
                if ([l hasPrefix:@"#EXT-X-KEY"]) {
                    if ([l containsString:@"AES-128"]) {
                        NSRange ru = [l rangeOfString:@"URI=\""];
                        NSRange ri = [l rangeOfString:@"IV=0x"];
                        NSString *ku = nil, *ivs = nil;
                        if (ru.location != NSNotFound) {
                            NSString *rest = [l substringFromIndex:ru.location + ru.length];
                            NSRange q = [rest rangeOfString:@"\""];
                            if (q.location != NSNotFound) ku = [rest substringToIndex:q.location];
                        }
                        if (ri.location != NSNotFound) {
                            NSString *rest = [l substringFromIndex:ri.location + ri.length];
                            NSMutableString *hex = [NSMutableString string];
                            for (NSUInteger k = 0; k < rest.length; k++) {
                                unichar ch = [rest characterAtIndex:k];
                                if (isxdigit(ch)) [hex appendFormat:@"%C", ch]; else break;
                            }
                            ivs = hex;
                        }
                        curKey = ku ? @{@"uri": [NSURL URLWithString:ku relativeToURL:[NSURL URLWithString:base]].absoluteString,
                                        @"iv": ivs ?: @""} : nil;
                    } else {
                        curKey = nil;
                    }
                } else if ([l hasPrefix:@"#EXT-X-MAP"]) {
                    NSRange ru = [l rangeOfString:@"URI=\""];
                    NSRange rb = [l rangeOfString:@"BYTERANGE=\""];
                    if (ru.location != NSNotFound) {
                        NSString *rest = [l substringFromIndex:ru.location + ru.length];
                        NSRange q = [rest rangeOfString:@"\""];
                        if (q.location != NSNotFound) {
                            NSString *u = [rest substringToIndex:q.location];
                            NSMutableDictionary *d = [@{@"u": [NSURL URLWithString:u relativeToURL:[NSURL URLWithString:base]].absoluteString,
                                                        @"init": @YES} mutableCopy];
                            if (rb.location != NSNotFound) {
                                NSString *r2 = [l substringFromIndex:rb.location + rb.length];
                                NSRange q2 = [r2 rangeOfString:@"\""];
                                if (q2.location != NSNotFound) {
                                    NSArray *pp = [[r2 substringToIndex:q2.location] componentsSeparatedByString:@"@"];
                                    long long ln = [pp[0] longLongValue];
                                    long long st = pp.count > 1 ? [pp[1] longLongValue] : 0;
                                    d[@"range"] = [NSString stringWithFormat:@"bytes=%lld-%lld", st, st + ln - 1];
                                    d[@"fmp4"] = @YES;
                                }
                            }
                            initSeg = d;
                        }
                    }
                } else if ([l hasPrefix:@"#EXT-X-BYTERANGE"]) {
                    NSString *rest = [l substringFromIndex:[l rangeOfString:@":"].location + 1];
                    NSArray *pp = [rest componentsSeparatedByString:@"@"];
                    pendLen = [pp[0] integerValue];
                    curOff = pp.count > 1 ? [pp[1] longLongValue] : lastEnd;
                } else if (![l hasPrefix:@"#"]) {
                    NSMutableDictionary *d = [@{@"u": [NSURL URLWithString:l relativeToURL:[NSURL URLWithString:base]].absoluteString} mutableCopy];
                    if (curKey) d[@"key"] = curKey;
                    if (pendLen >= 0) {
                        d[@"range"] = [NSString stringWithFormat:@"bytes=%lld-%lld", curOff, curOff + pendLen - 1];
                        d[@"fmp4"] = @YES;
                        lastEnd = curOff + pendLen;
                        pendLen = -1;
                    }
                    [segs addObject:d];
                }
            }
            if (segs.count == 0) {
                cand.status = CandFailed;
                notify_list_changed();
                mlog(@"没解析到分片: %@", url);
                return;
            }

            cand.isFmp4 = (initSeg != nil) || ([[segs.firstObject objectForKey:@"fmp4"] boolValue]);
            NSString *safe = [[cand.title componentsSeparatedByCharactersInSet:
                               [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r"]]
                              componentsJoinedByString:@"_"];
            NSString *dir = [out_dir() stringByAppendingPathComponent:safe];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

            NSMutableArray *pieces = [NSMutableArray array];
            if (initSeg) [pieces addObject:initSeg];
            [pieces addObjectsFromArray:segs];
            NSInteger total = pieces.count;

            __block NSInteger done = 0;
            NSMutableArray *bufs = [NSMutableArray array];
            for (NSInteger i = 0; i < total; i++) [bufs addObject:[NSNull null]];
            NSLock *lk = [NSLock new];

            dispatch_semaphore_t limit = dispatch_semaphore_create(6);
            dispatch_group_t grp = dispatch_group_create();
            for (NSInteger i = 0; i < total; i++) {
                dispatch_group_async(grp, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    dispatch_semaphore_wait(limit, DISPATCH_TIME_FOREVER);
                    @autoreleasepool {
                        NSDictionary *d = pieces[i];
                        NSData *data = nil;
                        for (int a = 0; a < 3 && !data; a++) data = [self syncGet:d[@"u"] range:d[@"range"]];
                        NSDictionary *k = d[@"key"];
                        if (data && k) {
                            NSString *kuri = k[@"uri"];
                            [self.keyLock lock];
                            NSData *kb = self.keyCache[kuri];
                            [self.keyLock unlock];
                            if (!kb) {
                                kb = [self syncGet:kuri range:nil];
                                if (kb) {
                                    [self.keyLock lock];
                                    self.keyCache[kuri] = kb;
                                    [self.keyLock unlock];
                                }
                            }
                            NSMutableData *iv = [NSMutableData dataWithLength:16];
                            NSString *ivs = k[@"iv"];
                            if (ivs.length >= 32) {
                                for (int n = 0; n < 16; n++) {
                                    unsigned int byte = 0;
                                    sscanf([[ivs substringWithRange:NSMakeRange(n * 2, 2)] UTF8String], "%02x", &byte);
                                    ((uint8_t *)iv.mutableBytes)[n] = byte;
                                }
                            } else {
                                uint32_t seq = htonl((uint32_t)(i - (initSeg ? 1 : 0)));
                                memcpy((uint8_t *)iv.mutableBytes + 12, &seq, 4);
                            }
                            data = [self aes128:data key:kb iv:iv];
                        }
                        [lk lock];
                        if (data) bufs[i] = data;
                        done++;
                        cand.progress = total > 0 ? (double)done / total : 0;
                        BOOL tick = (done % 5 == 0) || done == total;
                        [lk unlock];
                        if (tick) notify_list_changed();
                        dispatch_semaphore_signal(limit);
                    }
                });
            }
            dispatch_group_wait(grp, dispatch_time(DISPATCH_TIME_NOW, 7200ull * NSEC_PER_SEC));

            NSMutableData *merged = [NSMutableData data];
            for (id b in bufs) if ([b isKindOfClass:[NSData class]]) [merged appendData:b];
            if (merged.length == 0) {
                cand.status = CandFailed;
                cand.progress = 0;
                notify_list_changed();
                mlog(@"❌ 全部失败: %@", cand.title);
                return;
            }
            NSString *out = [dir stringByAppendingPathComponent:
                             [safe stringByAppendingString:cand.isFmp4 ? @".mp4" : @".ts"]];
            [merged writeToFile:out atomically:YES];
            cand.status = CandDone;
            cand.progress = 1;
            notify_list_changed();
            mlog(@"✅ 完成: %@ (%lu KB)", out, (unsigned long)(merged.length / 1024));
        } @catch (NSException *e) {
            cand.status = CandFailed;
            notify_list_changed();
            mlog(@"异常: %@", e);
        }
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
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"下载选中" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(downloadSelected)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:@"MuseListChanged" object:nil];
    [self updateEmptyHint];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:self.onClose];
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
        l.text = @"还没有候选。\n\n回暮色播任意视频几秒，\n这里就会出现可下载的条目，\n勾选后点右上角「下载选中」。";
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
        case CandRunning: state = [NSString stringWithFormat:@"下载中 %.0f%%", c.progress * 100]; break;
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
            [gLock lock]; [gCands removeObject:c]; [gLock unlock];
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

// ───────────────────────── 流量抓取 ─────────────────────────
// HTTP capture state is owned by the caller's serial capture queue.
#include <zlib.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static const NSUInteger kCaptureHeaderLimit = 64 * 1024;
static const NSUInteger kCaptureBodyLimit = 2 * 1024 * 1024;
static const NSUInteger kCaptureDecodedLimit = 4 * 1024 * 1024;
static const NSUInteger kCaptureRawTextLimit = 256 * 1024;
static const NSUInteger kCaptureConnectionLimit = 32;
static const NSUInteger kCaptureRequestLimit = 8;
static const NSUInteger kCaptureMemoryLimit = 8 * 1024 * 1024;
static NSUInteger gCaptureHttpMessages = 0;

typedef NS_ENUM(NSUInteger, MuseCaptureBodyMode) {
    MuseCaptureHeaders,
    MuseCaptureLengthBody,
    MuseCaptureChunkedBody,
    MuseCaptureCloseBody
};

@interface MuseCaptureStream : NSObject {
@public
    NSMutableData *buffer;
    NSMutableData *body;
    NSDictionary<NSString *, NSString *> *headers;
    NSString *url;
    MuseCaptureBodyMode mode;
    NSUInteger remaining;
    NSUInteger chunkRemaining;
    BOOL needsChunkCRLF;
    BOOL trailers;
    BOOL discardBody;
    BOOL unframed;
}
@end

@implementation MuseCaptureStream
- (instancetype)init {
    if ((self = [super init])) {
        buffer = [NSMutableData data];
        body = [NSMutableData data];
    }
    return self;
}
@end

@interface MuseCaptureConnection : NSObject {
@public
    MuseCaptureStream *reading;
    MuseCaptureStream *writing;
    NSMutableArray<NSDictionary *> *readingRequests;
    NSMutableArray<NSDictionary *> *writingRequests;
    NSUInteger lastUse;
}
@end

@implementation MuseCaptureConnection
- (instancetype)init {
    if ((self = [super init])) {
        reading = [MuseCaptureStream new];
        writing = [MuseCaptureStream new];
        readingRequests = [NSMutableArray array];
        writingRequests = [NSMutableArray array];
    }
    return self;
}
@end

static NSMutableDictionary<NSNumber *, MuseCaptureConnection *> *gCaptureConnections;
static NSUInteger gCaptureUseSequence;

static NSRange muse_capture_find(NSData *data, const char *needle, NSUInteger length) {
    return [data rangeOfData:[NSData dataWithBytes:needle length:length]
                    options:0 range:NSMakeRange(0, data.length)];
}

static void muse_capture_consume(NSMutableData *data, NSUInteger length) {
    [data replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
}

static BOOL muse_capture_http_prefix(NSData *data) {
    static const char *prefixes[] = {
        "HTTP/1.", "GET ", "POST ", "HEAD ", "PUT ", "PATCH ",
        "DELETE ", "OPTIONS ", "CONNECT ", "TRACE "
    };
    for (NSUInteger i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        NSUInteger length = MIN(data.length, strlen(prefixes[i]));
        if (length && memcmp(data.bytes, prefixes[i], length) == 0) return YES;
    }
    return NO;
}

static BOOL muse_capture_text_prefix(NSData *data) {
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length &&
           (bytes[offset] == ' ' || bytes[offset] == '\r' ||
            bytes[offset] == '\n' || bytes[offset] == '\t')) offset++;
    if (offset == data.length) return YES;
    unsigned char first = bytes[offset];
    if (first == '{' || first == '[' || first == '"' || first == '<' || first == '#') return YES;
    static const char *prefixes[] = {"http://", "https://"};
    for (NSUInteger i = 0; i < 2; i++) {
        NSUInteger length = MIN(data.length - offset, strlen(prefixes[i]));
        if (strncasecmp((const char *)bytes + offset, prefixes[i], length) == 0) return YES;
    }
    return NO;
}

static BOOL muse_capture_valid_url(NSString *value) {
    if (value.length == 0 || value.length > 8192) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    NSString *scheme = parts.scheme.lowercaseString;
    return parts.host.length && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]);
}

static BOOL muse_capture_hls_url(NSString *value) {
    if (!muse_capture_valid_url(value)) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    NSString *filename = [parts.path.lastPathComponent componentsSeparatedByString:@";"].firstObject;
    return [filename.pathExtension.lowercaseString isEqualToString:@"m3u8"];
}

static NSString *muse_capture_inner_url(NSString *value) {
    if (!muse_capture_valid_url(value)) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    NSString *host = parts.host.lowercaseString;
    BOOL loopback = [host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"] ||
                    [host isEqualToString:@"::1"] || [host isEqualToString:@"[::1]"];
    if (!loopback || ![parts.path isEqualToString:@"/parse"]) return nil;
    for (NSURLQueryItem *item in parts.queryItems) {
        // queryItems decodes the outer query once and preserves literal '+'.
        if ([item.name isEqualToString:@"url"] && muse_capture_valid_url(item.value)) return item.value;
    }
    return nil;
}

static void muse_capture_url(NSString *value, NSString *title) {
    if (muse_capture_hls_url(value)) add_candidate(value, title);
    NSString *inner = muse_capture_inner_url(value);
    if (muse_capture_hls_url(inner)) add_candidate(inner, title);
}

static NSString *muse_capture_decode_json_string(NSString *token) {
    id decoded = [NSJSONSerialization JSONObjectWithData:[token dataUsingEncoding:NSUTF8StringEncoding]
                                                options:NSJSONReadingFragmentsAllowed error:NULL];
    return [decoded isKindOfClass:[NSString class]] ? decoded : nil;
}

static BOOL muse_capture_inside_quote(NSString *text, NSUInteger location) {
    BOOL quoted = NO;
    BOOL escaped = NO;
    for (NSUInteger index = 0; index < location; index++) {
        unichar character = [text characterAtIndex:index];
        if (escaped) escaped = NO;
        else if (character == '\\') escaped = YES;
        else if (character == '"') quoted = !quoted;
    }
    return quoted;
}

static void muse_capture_scan_text(NSString *text, NSString *title, BOOL complete) {
    if (!text.length) return;
    static NSRegularExpression *quoted;
    static NSRegularExpression *plainURLs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        quoted = [NSRegularExpression regularExpressionWithPattern:@"\"(?:[^\"\\\\]|\\\\.)*\""
                                                           options:0 error:NULL];
        plainURLs = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>\\\\]+"
                                                              options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    for (NSTextCheckingResult *match in [quoted matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        NSString *decoded = muse_capture_decode_json_string([text substringWithRange:match.range]);
        if (decoded) muse_capture_url(decoded, title);
    }
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    for (NSTextCheckingResult *match in [plainURLs matchesInString:normalized options:0
                                                           range:NSMakeRange(0, normalized.length)]) {
        if (muse_capture_inside_quote(normalized, match.range.location)) continue;
        if (NSMaxRange(match.range) < normalized.length &&
            [normalized characterAtIndex:NSMaxRange(match.range)] == '\\') continue;
        // A URL reaching a live buffer's end may still be receiving its signature.
        if (!complete && NSMaxRange(match.range) == normalized.length) continue;
        muse_capture_url([normalized substringWithRange:match.range], title);
    }
}

static void muse_capture_walk_json(id object, NSString *title, NSUInteger depth) {
    if (depth > 32) return;
    if ([object isKindOfClass:[NSDictionary class]]) {
        id ownTitle = object[@"title"];
        NSString *matchingTitle = [ownTitle isKindOfClass:[NSString class]] ? ownTitle : title;
        for (id value in [object allValues]) muse_capture_walk_json(value, matchingTitle, depth + 1);
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id value in object) muse_capture_walk_json(value, title, depth + 1);
    } else if ([object isKindOfClass:[NSString class]]) {
        muse_capture_url(object, title);
        muse_capture_scan_text(object, title, YES);
    }
}

static NSData *muse_capture_inflate(NSData *input, int windowBits) {
    if (!input.length || input.length > kCaptureBodyLimit) return nil;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    if (inflateInit2(&stream, windowBits) != Z_OK) return nil;
    NSMutableData *output = [NSMutableData data];
    unsigned char chunk[16384];
    int status = Z_OK;
    while (status == Z_OK) {
        stream.next_out = chunk;
        stream.avail_out = sizeof(chunk);
        status = inflate(&stream, Z_NO_FLUSH);
        NSUInteger produced = sizeof(chunk) - stream.avail_out;
        if (produced > kCaptureDecodedLimit - output.length) {
            status = Z_MEM_ERROR;
            break;
        }
        [output appendBytes:chunk length:produced];
        if (status == Z_OK && produced == 0 && stream.avail_in == 0) {
            status = Z_DATA_ERROR;
            break;
        }
    }
    inflateEnd(&stream);
    return status == Z_STREAM_END ? output : nil;
}

static NSData *muse_capture_decode_body(NSData *body, NSString *encoding) {
    NSString *name = [[encoding lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length || [name isEqualToString:@"identity"]) return body;
    if ([name isEqualToString:@"gzip"] || [name isEqualToString:@"x-gzip"]) return muse_capture_inflate(body, 15 + 16);
    if ([name isEqualToString:@"deflate"]) {
        NSData *decoded = muse_capture_inflate(body, 15);
        return decoded ?: muse_capture_inflate(body, -15);
    }
    return nil;
}

static void muse_capture_scan_body(NSData *encodedBody, NSDictionary *headers, NSString *requestURL) {
    NSData *decodedBody = muse_capture_decode_body(encodedBody, headers[@"content-encoding"]);
    if (!decodedBody.length) return;
    id json = [NSJSONSerialization JSONObjectWithData:decodedBody options:NSJSONReadingFragmentsAllowed error:NULL];
    if (json) {
        muse_capture_walk_json(json, nil, 0);
        return;
    }
    NSString *text = [[NSString alloc] initWithData:decodedBody encoding:NSUTF8StringEncoding];
    if (!text) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"#EXTM3U"] && muse_capture_valid_url(requestURL)) {
        NSString *inner = muse_capture_inner_url(requestURL);
        // An extensionless parse/topicId endpoint is accepted only after this HLS response.
        add_candidate(muse_capture_hls_url(inner) ? inner : requestURL, nil);
    }
    muse_capture_scan_text(text, nil, YES);
}

static void muse_capture_reset_message(MuseCaptureStream *stream) {
    stream->body.length = 0;
    stream->headers = nil;
    stream->url = nil;
    stream->mode = MuseCaptureHeaders;
    stream->remaining = 0;
    stream->chunkRemaining = 0;
    stream->needsChunkCRLF = NO;
    stream->trailers = NO;
    stream->discardBody = NO;
    stream->unframed = NO;
}

static void muse_capture_finish_message(MuseCaptureStream *stream) {
    if (!stream->discardBody) muse_capture_scan_body(stream->body, stream->headers, stream->url);
    gCaptureHttpMessages++;
    muse_capture_reset_message(stream);
}

static void muse_capture_append_body(MuseCaptureStream *stream, const void *bytes, NSUInteger length) {
    if (stream->discardBody) return;
    if (length > kCaptureBodyLimit - stream->body.length) {
        stream->body.length = 0;
        stream->discardBody = YES;
        return;
    }
    [stream->body appendBytes:bytes length:length];
}

static BOOL muse_capture_unsigned(NSString *value, int base, NSUInteger *result) {
    if (!value.length) return NO;
    const char *start = value.UTF8String;
    if (!start || *start == '-' || *start == '+') return NO;
    errno = 0;
    char *end = NULL;
    unsigned long long number = strtoull(start, &end, base);
    if (errno || !end || end == start || *end || number > NSUIntegerMax) return NO;
    *result = (NSUInteger)number;
    return YES;
}

static BOOL muse_capture_begin_message(MuseCaptureConnection *connection, MuseCaptureStream *stream, BOOL reading) {
    NSRange end = muse_capture_find(stream->buffer, "\r\n\r\n", 4);
    if (end.location == NSNotFound) return NO;
    NSData *headerData = [stream->buffer subdataWithRange:NSMakeRange(0, end.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSISOLatin1StringEncoding];
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *parts = [[lines.firstObject componentsSeparatedByString:@" "]
                                filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (parts.count < 2) {
        stream->buffer.length = 0;
        return NO;
    }
    NSMutableDictionary *parsedHeaders = [NSMutableDictionary dictionary];
    for (NSUInteger index = 1; index < lines.count; index++) {
        NSRange colon = [lines[index] rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[lines[index] substringToIndex:colon.location] lowercaseString];
        NSString *value = [[lines[index] substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        parsedHeaders[name] = value;
    }
    muse_capture_consume(stream->buffer, NSMaxRange(end));
    stream->headers = parsedHeaders;
    BOOL response = [parts[0] hasPrefix:@"HTTP/1."];
    BOOL noBody = NO;
    if (response) {
        NSInteger status = [parts[1] integerValue];
        NSMutableArray *requests = reading ? connection->readingRequests : connection->writingRequests;
        NSDictionary *request = requests.firstObject;
        stream->url = request[@"url"];
        BOOL informational = status >= 100 && status < 200;
        noBody = informational || status == 204 || status == 304 || [request[@"method"] isEqualToString:@"HEAD"] ||
                 ([request[@"method"] isEqualToString:@"CONNECT"] && status >= 200 && status < 300);
        if (!informational && requests.count) [requests removeObjectAtIndex:0];
        NSString *location = parsedHeaders[@"location"];
        if (location.length) {
            NSURL *base = stream->url.length ? [NSURL URLWithString:stream->url] : nil;
            NSString *redirect = [NSURL URLWithString:location relativeToURL:base].absoluteString;
            muse_capture_url(redirect, nil);
        }
    } else {
        NSString *target = parts[1];
        NSString *host = parsedHeaders[@"host"];
        if (muse_capture_valid_url(target)) stream->url = target;
        else if ([target hasPrefix:@"/"] && host.length) stream->url = [NSString stringWithFormat:@"http://%@%@", host, target];
        if (!muse_capture_valid_url(stream->url)) stream->url = nil;
        NSMutableArray *requests = reading ? connection->writingRequests : connection->readingRequests;
        if (requests.count >= kCaptureRequestLimit) [requests removeObjectAtIndex:0];
        [requests addObject:@{@"url": stream->url ?: @"", @"method": parts[0]}];
        muse_capture_url(stream->url, nil);
    }
    NSString *transfer = [parsedHeaders[@"transfer-encoding"] lowercaseString];
    NSUInteger length = 0;
    if (noBody) {
        muse_capture_finish_message(stream);
    } else if (transfer.length && [transfer rangeOfString:@"chunked"].location != NSNotFound) {
        stream->mode = MuseCaptureChunkedBody;
    } else if (parsedHeaders[@"content-length"]) {
        if (!muse_capture_unsigned(parsedHeaders[@"content-length"], 10, &length)) {
            stream->buffer.length = 0;
            muse_capture_reset_message(stream);
            return NO;
        }
        stream->remaining = length;
        stream->mode = MuseCaptureLengthBody;
        if (!length) muse_capture_finish_message(stream);
    } else if (response) {
        stream->mode = MuseCaptureCloseBody;
    } else {
        muse_capture_finish_message(stream);
    }
    return YES;
}

static void muse_capture_raw_text(MuseCaptureStream *stream, BOOL complete) {
    NSString *text = [[NSString alloc] initWithData:stream->buffer encoding:NSUTF8StringEncoding];
    if (!text) return;
    id json = [NSJSONSerialization JSONObjectWithData:stream->buffer options:NSJSONReadingFragmentsAllowed error:NULL];
    if (json) {
        muse_capture_walk_json(json, nil, 0);
        stream->buffer.length = 0;
        stream->unframed = NO;
    } else {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!complete && ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["])) return;
        muse_capture_scan_text(text, nil, complete);
    }
}

static void muse_capture_process(MuseCaptureConnection *connection, MuseCaptureStream *stream, BOOL reading) {
    while (stream->buffer.length) {
        if (stream->mode == MuseCaptureHeaders) {
            if (stream->unframed || !muse_capture_http_prefix(stream->buffer)) {
                if (!stream->unframed && !muse_capture_text_prefix(stream->buffer)) {
                    stream->buffer.length = 0;
                    return;
                }
                stream->unframed = YES;
                muse_capture_raw_text(stream, NO);
                if (stream->buffer.length > kCaptureRawTextLimit) {
                    muse_capture_consume(stream->buffer, stream->buffer.length - 8192);
                }
                return;
            }
            NSRange headerEnd = muse_capture_find(stream->buffer, "\r\n\r\n", 4);
            if (headerEnd.location == NSNotFound) {
                if (stream->buffer.length > kCaptureHeaderLimit) stream->buffer.length = 0;
                return;
            }
            if (NSMaxRange(headerEnd) > kCaptureHeaderLimit) {
                stream->buffer.length = 0;
                return;
            }
            if (!muse_capture_begin_message(connection, stream, reading)) return;
        } else if (stream->mode == MuseCaptureLengthBody) {
            NSUInteger count = MIN(stream->remaining, stream->buffer.length);
            muse_capture_append_body(stream, stream->buffer.bytes, count);
            muse_capture_consume(stream->buffer, count);
            stream->remaining -= count;
            if (!stream->remaining) muse_capture_finish_message(stream);
        } else if (stream->mode == MuseCaptureCloseBody) {
            muse_capture_append_body(stream, stream->buffer.bytes, stream->buffer.length);
            stream->buffer.length = 0;
        } else if (stream->trailers) {
            if (stream->buffer.length >= 2 && memcmp(stream->buffer.bytes, "\r\n", 2) == 0) {
                muse_capture_consume(stream->buffer, 2);
                muse_capture_finish_message(stream);
                continue;
            }
            NSRange end = muse_capture_find(stream->buffer, "\r\n\r\n", 4);
            if (end.location == NSNotFound) {
                if (stream->buffer.length > kCaptureHeaderLimit) {
                    stream->buffer.length = 0;
                    muse_capture_reset_message(stream);
                }
                return;
            }
            muse_capture_consume(stream->buffer, NSMaxRange(end));
            muse_capture_finish_message(stream);
        } else if (stream->needsChunkCRLF) {
            if (stream->buffer.length < 2) return;
            if (memcmp(stream->buffer.bytes, "\r\n", 2) != 0) {
                stream->buffer.length = 0;
                muse_capture_reset_message(stream);
                return;
            }
            muse_capture_consume(stream->buffer, 2);
            stream->needsChunkCRLF = NO;
        } else if (stream->chunkRemaining) {
            NSUInteger count = MIN(stream->chunkRemaining, stream->buffer.length);
            muse_capture_append_body(stream, stream->buffer.bytes, count);
            muse_capture_consume(stream->buffer, count);
            stream->chunkRemaining -= count;
            if (!stream->chunkRemaining) stream->needsChunkCRLF = YES;
        } else {
            NSRange end = muse_capture_find(stream->buffer, "\r\n", 2);
            if (end.location == NSNotFound) {
                if (stream->buffer.length > 4096) {
                    stream->buffer.length = 0;
                    muse_capture_reset_message(stream);
                }
                return;
            }
            NSString *line = [[NSString alloc] initWithData:[stream->buffer subdataWithRange:NSMakeRange(0, end.location)]
                                                  encoding:NSASCIIStringEncoding];
            NSString *size = [[line componentsSeparatedByString:@";"].firstObject
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSUInteger chunkSize = 0;
            if (!muse_capture_unsigned(size, 16, &chunkSize)) {
                stream->buffer.length = 0;
                muse_capture_reset_message(stream);
                return;
            }
            muse_capture_consume(stream->buffer, NSMaxRange(end));
            stream->chunkRemaining = chunkSize;
            if (!chunkSize) stream->trailers = YES;
        }
    }
}

static NSUInteger muse_capture_memory(MuseCaptureConnection *connection) {
    return connection->reading->buffer.length + connection->reading->body.length +
           connection->writing->buffer.length + connection->writing->body.length;
}

static void muse_capture_trim(NSNumber *keepKey) {
    NSUInteger bytes = 0;
    for (MuseCaptureConnection *connection in gCaptureConnections.allValues) bytes += muse_capture_memory(connection);
    while (gCaptureConnections.count > kCaptureConnectionLimit || bytes > kCaptureMemoryLimit) {
        NSNumber *oldestKey = nil;
        NSUInteger oldestUse = NSUIntegerMax;
        for (NSNumber *key in gCaptureConnections) {
            MuseCaptureConnection *connection = gCaptureConnections[key];
            if (![key isEqual:keepKey] && connection->lastUse < oldestUse) {
                oldestKey = key;
                oldestUse = connection->lastUse;
            }
        }
        if (!oldestKey) break;
        bytes -= muse_capture_memory(gCaptureConnections[oldestKey]);
        [gCaptureConnections removeObjectForKey:oldestKey];
    }
}

static void muse_capture_feed(int fd, NSData *data, BOOL reading) {
    if (fd < 0 || !data.length) return;
    @autoreleasepool {
        if (!gCaptureConnections) gCaptureConnections = [NSMutableDictionary dictionary];
        NSNumber *key = @(fd);
        MuseCaptureConnection *connection = gCaptureConnections[key];
        if (!connection) {
            connection = [MuseCaptureConnection new];
            gCaptureConnections[key] = connection;
        }
        connection->lastUse = ++gCaptureUseSequence;
        MuseCaptureStream *stream = reading ? connection->reading : connection->writing;
        const unsigned char *bytes = data.bytes;
        for (NSUInteger offset = 0; offset < data.length;) {
            NSUInteger count = MIN((NSUInteger)16384, data.length - offset);
            NSData *piece = [NSData dataWithBytesNoCopy:(void *)(bytes + offset) length:count freeWhenDone:NO];
            if (stream->mode != MuseCaptureHeaders || stream->buffer.length ||
                muse_capture_http_prefix(piece) || muse_capture_text_prefix(piece)) {
                [stream->buffer appendBytes:bytes + offset length:count];
                muse_capture_process(connection, stream, reading);
            }
            offset += count;
        }
        muse_capture_trim(key);
    }
}

static void muse_capture_close(int fd) {
    @autoreleasepool {
        NSNumber *key = @(fd);
        MuseCaptureConnection *connection = gCaptureConnections[key];
        if (!connection) return;
        for (MuseCaptureStream *stream in @[connection->reading, connection->writing]) {
            if (stream->mode == MuseCaptureCloseBody) muse_capture_finish_message(stream);
            else if (stream->unframed) muse_capture_raw_text(stream, YES);
        }
        [gCaptureConnections removeObjectForKey:key];
    }
}

// ───────────────────────── 网络调用 ─────────────────────────
enum {
    MuseIoRead, MuseIoWrite, MuseIoRecv, MuseIoRecvFrom,
    MuseIoRecvMsg, MuseIoSend, MuseIoSendTo, MuseIoSendMsg, MuseIoCount
};
static _Atomic(unsigned long long) gCaptureIoCalls[MuseIoCount];
static _Atomic(size_t) gCaptureQueuedBytes;
static __thread unsigned int gCaptureDepth;
static dispatch_queue_t gCaptureQueue;
static dispatch_source_t gCaptureTimer;
static const size_t kCaptureQueueBudget = 8 * 1024 * 1024;

static void muse_capture_vectors(int fd, const struct iovec *vectors, size_t count,
                                 size_t length, BOOL reading) {
    if (!length || length > kCaptureQueueBudget || !vectors || !gCaptureQueue) return;
    int type = 0;
    socklen_t typeLength = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeLength) != 0 || type != SOCK_STREAM) return;
    size_t queued = atomic_fetch_add(&gCaptureQueuedBytes, length);
    if (queued > kCaptureQueueBudget - length) {
        atomic_fetch_sub(&gCaptureQueuedBytes, length);
        return;
    }
    @try {
        @autoreleasepool {
            NSMutableData *data = [NSMutableData dataWithCapacity:length];
            size_t remaining = length;
            for (size_t i = 0; i < count && remaining; i++) {
                size_t part = MIN(vectors[i].iov_len, remaining);
                if (part) [data appendBytes:vectors[i].iov_base length:part];
                remaining -= part;
            }
            if (remaining) {
                atomic_fetch_sub(&gCaptureQueuedBytes, length);
                return;
            }
            dispatch_async(gCaptureQueue, ^{
                @autoreleasepool {
                    gCaptureDepth++;
                    @try {
                        muse_capture_feed(fd, data, reading);
                    } @catch (NSException *exception) {
                        muse_capture_close(fd);
                        mlog(@"抓取解析异常: %@", exception.name);
                    } @finally {
                        gCaptureDepth--;
                        atomic_fetch_sub(&gCaptureQueuedBytes, length);
                    }
                }
            });
        }
    } @catch (__unused NSException *exception) {
        atomic_fetch_sub(&gCaptureQueuedBytes, length);
    }
}

static void muse_capture_bytes(int fd, const void *bytes, size_t length, BOOL reading) {
    struct iovec vector = { .iov_base = (void *)bytes, .iov_len = length };
    muse_capture_vectors(fd, &vector, 1, length, reading);
}

static void muse_capture_start(void) {
    gCaptureQueue = dispatch_queue_create("MuseHook.capture", DISPATCH_QUEUE_SERIAL);
    gCaptureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gCaptureQueue);
    dispatch_source_set_timer(gCaptureTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gCaptureTimer, ^{
        @autoreleasepool {
            gCaptureDepth++;
            [gLock lock];
            NSUInteger candidates = gCands.count;
            [gLock unlock];
            mlog(@"网络抓取 read=%llu write=%llu recv=%llu recvfrom=%llu recvmsg=%llu "
                  "send=%llu sendto=%llu sendmsg=%llu HTTP=%lu 候选=%lu",
                 atomic_load(&gCaptureIoCalls[MuseIoRead]), atomic_load(&gCaptureIoCalls[MuseIoWrite]),
                 atomic_load(&gCaptureIoCalls[MuseIoRecv]), atomic_load(&gCaptureIoCalls[MuseIoRecvFrom]),
                 atomic_load(&gCaptureIoCalls[MuseIoRecvMsg]), atomic_load(&gCaptureIoCalls[MuseIoSend]),
                 atomic_load(&gCaptureIoCalls[MuseIoSendTo]), atomic_load(&gCaptureIoCalls[MuseIoSendMsg]),
                 (unsigned long)gCaptureHttpMessages, (unsigned long)candidates);
            gCaptureDepth--;
        }
    });
    dispatch_resume(gCaptureTimer);
}

// 同一 dylib 内的原始符号调用由 dyld 保留，深度计数处理 libSystem 内部的嵌套调用。
static ssize_t my_read(int fd, void *buffer, size_t length) {
    if (!gReady) return read(fd, buffer, length);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = read(fd, buffer, length);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoRead], 1);
        if (result > 0) muse_capture_bytes(fd, buffer, (size_t)result, YES);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_write(int fd, const void *buffer, size_t length) {
    if (!gReady) return write(fd, buffer, length);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = write(fd, buffer, length);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoWrite], 1);
        if (result > 0) muse_capture_bytes(fd, buffer, (size_t)result, NO);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_recv(int fd, void *buffer, size_t length, int flags) {
    if (!gReady) return recv(fd, buffer, length, flags);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = recv(fd, buffer, length, flags);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoRecv], 1);
        if (result > 0 && !(flags & MSG_PEEK)) muse_capture_bytes(fd, buffer, (size_t)result, YES);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_recvfrom(int fd, void *buffer, size_t length, int flags,
                           struct sockaddr *address, socklen_t *addressLength) {
    if (!gReady) return recvfrom(fd, buffer, length, flags, address, addressLength);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = recvfrom(fd, buffer, length, flags, address, addressLength);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoRecvFrom], 1);
        if (result > 0 && !(flags & MSG_PEEK)) muse_capture_bytes(fd, buffer, (size_t)result, YES);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_recvmsg(int fd, struct msghdr *message, int flags) {
    if (!gReady) return recvmsg(fd, message, flags);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = recvmsg(fd, message, flags);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoRecvMsg], 1);
        if (result > 0 && !(flags & MSG_PEEK))
            muse_capture_vectors(fd, message->msg_iov, (size_t)message->msg_iovlen, (size_t)result, YES);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_send(int fd, const void *buffer, size_t length, int flags) {
    if (!gReady) return send(fd, buffer, length, flags);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = send(fd, buffer, length, flags);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoSend], 1);
        if (result > 0) muse_capture_bytes(fd, buffer, (size_t)result, NO);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_sendto(int fd, const void *buffer, size_t length, int flags,
                         const struct sockaddr *address, socklen_t addressLength) {
    if (!gReady) return sendto(fd, buffer, length, flags, address, addressLength);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = sendto(fd, buffer, length, flags, address, addressLength);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoSendTo], 1);
        if (result > 0) muse_capture_bytes(fd, buffer, (size_t)result, NO);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static ssize_t my_sendmsg(int fd, const struct msghdr *message, int flags) {
    if (!gReady) return sendmsg(fd, message, flags);
    BOOL outer = ++gCaptureDepth == 1;
    ssize_t result = sendmsg(fd, message, flags);
    int savedErrno = errno;
    if (outer) {
        atomic_fetch_add(&gCaptureIoCalls[MuseIoSendMsg], 1);
        if (result > 0)
            muse_capture_vectors(fd, message->msg_iov, (size_t)message->msg_iovlen, (size_t)result, NO);
    }
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

static int my_close(int fd) {
    if (!gReady) return close(fd);
    BOOL outer = ++gCaptureDepth == 1;
    int result = close(fd);
    int savedErrno = errno;
    if (outer && result == 0 && gCaptureQueue)
        dispatch_async(gCaptureQueue, ^{
            @autoreleasepool {
                gCaptureDepth++;
                @try { muse_capture_close(fd); }
                @catch (__unused NSException *exception) {}
                gCaptureDepth--;
            }
        });
    gCaptureDepth--;
    errno = savedErrno;
    return result;
}

#define DYLD_INTERPOSE(_replacement, _replacee)                                   \
    __attribute__((used)) static struct {                                         \
        const void *replacement;                                                  \
        const void *replacee;                                                     \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {     \
        (const void *)(unsigned long)&_replacement,                               \
        (const void *)(unsigned long)&_replacee};

DYLD_INTERPOSE(my_read, read)
DYLD_INTERPOSE(my_write, write)
DYLD_INTERPOSE(my_recv, recv)
DYLD_INTERPOSE(my_recvfrom, recvfrom)
DYLD_INTERPOSE(my_recvmsg, recvmsg)
DYLD_INTERPOSE(my_send, send)
DYLD_INTERPOSE(my_sendto, sendto)
DYLD_INTERPOSE(my_sendmsg, sendmsg)
DYLD_INTERPOSE(my_close, close)

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
        muse_capture_start();
        mlog(@"MuseHook 已注入（网络抓取更新）· 输出: %@", out_dir());
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
