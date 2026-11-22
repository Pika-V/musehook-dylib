//
//  MuseHook.m — 暮色 手动选择式下载 dylib（TrollFools 注入）
//
//  与上一版的区别：**不再自动下载**。
//    · 播放时只把抓到的 .m3u8 记成「候选」，不产生任何下载流量
//    · 暮色界面右侧浮出一个悬浮球，角标 = 新候选数
//    · 点悬浮球 → 原生列表，勾选 → 点「下载选中」才真正下
//
//  原理：接口是明文 http://IP:6868，Flutter(dart:io) 走 BSD socket，
//        dylib 用 dyld __interpose 挂 send/write/recv/read，从响应体里捡 m3u8。
//        UI 用 UIKit 自己建 window（Flutter 的渲染层之上），不需要改 App 本体。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <sys/socket.h>
#include <unistd.h>
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
static BOOL gReady = NO;

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
@end

@implementation MuseListVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"暮色下载";
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(selAll)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"下载选中" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(downloadSelected)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:@"MuseListChanged" object:nil];
    [self updateEmptyHint];
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
@property (nonatomic, strong) UIWindow *win;
@property (nonatomic, strong) UIButton *ball;
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
            UIWindow *w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            w.windowLevel = UIWindowLevelAlert + 100;
            w.backgroundColor = UIColor.clearColor;      // 关键：否则整屏盖黑
            if (@available(iOS 13.0, *)) {
                for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                    if ([sc isKindOfClass:[UIWindowScene class]]) { w.windowScene = (UIWindowScene *)sc; break; }
                }
                if (w.windowScene == nil) {                   // 场景还没就绪，2 秒后重试（最多 8 次）
                    if (self.retry < 8) {
                        self.retry++;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{ [self setup]; });
                    } else {
                        mlog(@"拿不到 windowScene，跳过悬浮球（可用列表接口直接调）");
                    }
                    return;
                }
            }
            UIViewController *root = [UIViewController new];
            root.view.backgroundColor = UIColor.clearColor;
            w.rootViewController = root;
            w.hidden = NO;
            self.win = w;

            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(0, 0, 56, 56);
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

            CGSize sz = UIScreen.mainScreen.bounds.size;
            b.center = CGPointMake(sz.width - 46, sz.height * 0.42);
            [root.view addSubview:b];
            self.ball = b;

            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshBadge)
                                                         name:@"MuseBadgeChanged" object:nil];
            mlog(@"悬浮球已创建");
        } @catch (NSException *e) {
            mlog(@"UI 创建失败: %@", e);
        }
    });
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint p = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + p.x, v.center.y + p.y);
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
        gUnseen = 0;
        [self refreshBadge];
        MuseListVC *vc = [MuseListVC new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.barStyle = UIBarStyleBlack;
        UIViewController *root = self.win.rootViewController;
        if (root.presentedViewController) [root dismissViewControllerAnimated:NO completion:nil];
        [root presentViewController:nav animated:YES completion:nil];
    });
}

@end

// ───────────────────────── 流量抓取 ─────────────────────────
static ssize_t (*orig_send)(int, const void *, size_t, int);
static ssize_t (*orig_recv)(int, void *, size_t, int);
static ssize_t (*orig_write)(int, const void *, size_t);
static ssize_t (*orig_read)(int, void *, size_t);
static NSString *gLastTitle = nil;   // 从 JSON 里顺手捞的标题

static BOOL is_socket(int fd) {
    int type = 0; socklen_t len = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) != 0) return NO;
    return (type == SOCK_STREAM || type == SOCK_DGRAM);
}

static NSString *peek_title(NSString *s) {
    NSRange r = [s rangeOfString:@"\"title\""];
    if (r.location == NSNotFound) return nil;
    NSString *rest = [s substringFromIndex:r.location + r.length];
    NSRange colon = [rest rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    rest = [rest substringFromIndex:colon.location + 1];
    NSRange q1 = [rest rangeOfString:@"\""];
    if (q1.location == NSNotFound) return nil;
    rest = [rest substringFromIndex:q1.location + 1];
    NSRange q2 = [rest rangeOfString:@"\""];
    if (q2.location == NSNotFound) return nil;
    NSString *t = [rest substringToIndex:q2.location];
    if (t.length > 40) t = [t substringToIndex:40];
    return t.length ? t : nil;
}

static void scan_buf(const char *buf, size_t n) {
    if (!gReady || n == 0) return;
    if (strnstr(buf, "m3u8", n) == NULL && strnstr(buf, "title", n) == NULL) return;
    @autoreleasepool {
        NSString *s = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithBytes:buf length:n encoding:NSISOLatin1StringEncoding];
        if (!s) return;
        NSString *t = peek_title(s);
        if (t) gLastTitle = t;

        static NSRegularExpression *re;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            re = [NSRegularExpression regularExpressionWithPattern:
                  @"https?://[^\\s\"'<>\\\\]{6,300}?\\.m3u8[^\\s\"'<>\\\\]*"
                                                          options:NSRegularExpressionCaseInsensitive error:nil];
        });
        for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
            NSString *u = [s substringWithRange:m.range];
            u = [u stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            add_candidate(u, gLastTitle);
        }
    }
}

static ssize_t my_send(int fd, const void *buf, size_t len, int flags) {
    if (!orig_send) orig_send = dlsym(RTLD_NEXT, "send");
    if (is_socket(fd)) scan_buf((const char *)buf, len);
    return orig_send(fd, buf, len, flags);
}

static ssize_t my_recv(int fd, void *buf, size_t len, int flags) {
    if (!orig_recv) orig_recv = dlsym(RTLD_NEXT, "recv");
    ssize_t n = orig_recv(fd, buf, len, flags);
    if (n > 0 && is_socket(fd)) scan_buf((const char *)buf, (size_t)n);
    return n;
}

static ssize_t my_write(int fd, const void *buf, size_t len) {
    if (!orig_write) orig_write = dlsym(RTLD_NEXT, "write");
    if (is_socket(fd)) scan_buf((const char *)buf, len);
    return orig_write(fd, buf, len);
}

static ssize_t my_read(int fd, void *buf, size_t len) {
    if (!orig_read) orig_read = dlsym(RTLD_NEXT, "read");
    ssize_t n = orig_read(fd, buf, len);
    if (n > 0 && is_socket(fd)) scan_buf((const char *)buf, (size_t)n);
    return n;
}

#define DYLD_INTERPOSE(_replacement, _replacee)                                   \
    __attribute__((used)) static struct {                                         \
        const void *replacement;                                                  \
        const void *replacee;                                                     \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {   \
        (const void *)(unsigned long)&_replacement,                               \
        (const void *)(unsigned long)&_replacee};

DYLD_INTERPOSE(my_send, send)
DYLD_INTERPOSE(my_recv, recv)
DYLD_INTERPOSE(my_write, write)
DYLD_INTERPOSE(my_read, read)

// ───────────────────────── 入口 ─────────────────────────
__attribute__((constructor))
static void muse_init(void) {
    gLock = [NSLock new];
    gCands = [NSMutableArray array];
    gSeen = [NSMutableDictionary dictionary];
    gUnseen = 0;
    (void)out_dir();
    gReady = YES;
    mlog(@"MuseHook 已注入（手动选择模式）· 输出: %@", out_dir());

    // App 启动完成后再建 UI，避免和 Flutter 抢窗口
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[MuseUI shared] setup];
    });
}
