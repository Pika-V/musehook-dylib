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
#include <math.h>
#include <stdint.h>
#include <limits.h>
#include <arpa/inet.h>
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>

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

// ───────────────────────── One 检查 ─────────────────────────
static NSString *gOneCheckResult;
static BOOL gOneCheckRunning;

static NSString *muse_one_token(NSUserDefaults *defaults, NSString *name) {
    id value = [defaults objectForKey:[@"flutter." stringByAppendingString:name]];
    if (![value isKindOfClass:NSString.class]) value = [defaults objectForKey:name];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *token = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([token hasPrefix:@"Bearer "]) token = [token substringFromIndex:7];
    return token.length ? token : nil;
}

static NSDictionary *muse_one_payload(NSString *token) {
    if (!token.length || token.length > 16384) return nil;
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-."];
    if (parts.count != 3 || ![parts[0] length] || ![parts[1] length] || ![parts[2] length] ||
        [token rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    NSString *base64 = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (base64.length % 4) base64 = [base64 stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *muse_one_date(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss ZZZZZ";
    return [formatter stringFromDate:date];
}

static NSString *muse_one_token_state(NSString *token, NSDate *now) {
    if (!token.length) return @"未获取";
    NSDictionary *payload = muse_one_payload(token);
    if (!payload) return @"格式无效";
    id exp = payload[@"exp"];
    NSString *state = @"未标明有效期";
    if ([exp isKindOfClass:NSNumber.class] && isfinite([exp doubleValue]) && [exp doubleValue] > 0) {
        NSDate *expires = [NSDate dateWithTimeIntervalSince1970:[exp doubleValue]];
        state = [NSString stringWithFormat:@"%@（%@）",
                 [expires compare:now] != NSOrderedDescending ? @"已过期" : @"本地有效期未过",
                 muse_one_date(expires)];
    }
    BOOL hasUUID = [payload[@"uuid"] isKindOfClass:NSString.class] && [payload[@"uuid"] length] > 0;
    return [state stringByAppendingFormat:@"；UUID %@", hasUUID ? @"存在" : @"缺失"];
}

static NSString *muse_one_local_report(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *now = [NSDate date];
    return [NSString stringWithFormat:@"One 检查\n手机时间 %@\n登录凭证 %@\n游客凭证 %@\n%@",
            muse_one_date(now), muse_one_token_state(muse_one_token(defaults, @"token_one"), now),
            muse_one_token_state(muse_one_token(defaults, @"token_one_visitor"), now),
            gOneCheckResult ?: @"点击「检查 One」获取服务器原因"];
}

static NSString *muse_one_md5(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char bytes[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *result = [NSMutableString stringWithCapacity:32];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) [result appendFormat:@"%02x", bytes[index]];
    return result;
}

static NSMutableURLRequest *muse_one_probe_request_for_uuid(NSString *token, NSString *timestamp, NSString *uuid) {
    if (!muse_one_payload(token) || !uuid.length || ![[NSUUID alloc] initWithUUIDString:uuid])
        return nil;
    NSString *inner = muse_one_md5([NSString stringWithFormat:@"0.0.0.0.3.%@..%@", timestamp, uuid]);
    NSString *sign = muse_one_md5([inner stringByAppendingString:@"m4n2hjPeYWkD6tFpqKF^3HO^h24P@idT"]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://917api.4c86d03.com/v2.5/navigation/getDemandTagList"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSData data];
    request.timeoutInterval = 16;
    request.allHTTPHeaderFields = @{@"User-Agent": @"Dart/3.12 (dart:io)", @"ip": @"0.0.0.0",
        @"uuid": uuid, @"Content-Type": @"application/x-www-form-urlencoded", @"timestamp": timestamp,
        @"platform": @"3", @"token": token, @"sign": sign, @"user-key": @"", @"app-version": @"2.6.4"};
    return request;
}

static NSMutableURLRequest *muse_one_probe_request(NSString *token, NSString *timestamp) {
    NSDictionary *payload = muse_one_payload(token);
    NSString *uuid = [payload[@"uuid"] isKindOfClass:NSString.class] ? payload[@"uuid"] : nil;
    return muse_one_probe_request_for_uuid(token, timestamp, uuid);
}

static NSString *muse_one_safe_message(NSString *message) {
    if (![message isKindOfClass:NSString.class]) return @"";
    NSString *safe = message;
    for (NSString *pattern in @[@"eyJ[A-Za-z0-9_-]*(?:\\.[A-Za-z0-9_-]*){0,2}",
                                @"(?i)Bearer\\s+[^\\s\\\"'<>]+",
                                @"(?i)(?:token|uuid|password|secret)\\s*[:=]\\s*[^\\s,;\\\"'<>]+",
                                @"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                @"[A-Za-z0-9_+/%=-]{48,}"]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        safe = [regex stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0, safe.length)
                                         withTemplate:@"[已隐藏凭证]"];
    }
    safe = [[safe componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    return safe.length > 180 ? [[safe substringToIndex:180] stringByAppendingString:@"…"] : safe;
}

static NSDictionary *muse_one_response_json(NSData *data) {
    if (!data.length || data.length > 1024 * 1024) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
    if ([object isKindOfClass:NSDictionary.class]) return object;
    NSString *encoded = [object isKindOfClass:NSString.class] ? object :
        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    encoded = [encoded stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!encoded.length) return nil;
    NSData *cipher = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!cipher.length || cipher.length % kCCBlockSizeAES128) return nil;
    NSMutableData *plain = [NSMutableData dataWithLength:cipher.length + kCCBlockSizeAES128];
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        "l*bv%Ziq000Biaog", kCCKeySizeAES128, "8597506002939249",
        cipher.bytes, cipher.length, plain.mutableBytes, plain.length, &written);
    if (status != kCCSuccess) return nil;
    plain.length = written;
    object = [NSJSONSerialization JSONObjectWithData:plain options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

@interface MuseOneProbeDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation MuseOneProbeDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSURL *url = request.URL;
    BOOL sameOrigin = [url.scheme.lowercaseString isEqualToString:@"https"] &&
        [url.host.lowercaseString isEqualToString:@"917api.4c86d03.com"] && (!url.port || url.port.integerValue == 443);
    completionHandler(sameOrigin ? request : nil);
}
@end

static void muse_one_check_next(NSArray<NSDictionary *> *tokens, NSUInteger index, NSMutableArray<NSString *> *reports,
                                void (^completion)(NSString *)) {
    if (index >= tokens.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([reports componentsJoinedByString:@"\n"]);
        });
        return;
    }
    NSDictionary *entry = tokens[index];
    NSString *timestamp = [NSString stringWithFormat:@"%.0f", floor([NSDate date].timeIntervalSince1970)];
    NSMutableURLRequest *request = muse_one_probe_request(entry[@"token"], timestamp);
    if (!request) {
        [reports addObject:[entry[@"name"] stringByAppendingString:@"：无法读取凭证 UUID"]];
        muse_one_check_next(tokens, index + 1, reports, completion);
        return;
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 16;
    configuration.timeoutIntervalForResource = 20;
    configuration.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[MuseOneProbeDelegate new] delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *result;
        if (error) {
            result = [NSString stringWithFormat:@"%@：网络错误 %ld %@", entry[@"name"], (long)error.code,
                      muse_one_safe_message(error.localizedDescription)];
        } else {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            NSDictionary *json = muse_one_response_json(data);
            NSString *message = muse_one_safe_message(json[@"message"] ?: json[@"msg"]);
            id code = [json[@"code"] isKindOfClass:NSNumber.class] ? json[@"code"] : nil;
            BOOL success = status == 200 && [code integerValue] == 200;
            result = [NSString stringWithFormat:@"%@：HTTP %ld%@%@%@", entry[@"name"], (long)status,
                      code ? [NSString stringWithFormat:@"，业务码 %@", code] : @"",
                      success ? @"，分类接口可用" : @"",
                      message.length ? [@"，" stringByAppendingString:message] : (json ? @"" : @"，无法解析响应正文")];
        }
        [session finishTasksAndInvalidate];
        [reports addObject:result];
        muse_one_check_next(tokens, index + 1, reports, completion);
    }];
    [task resume];
}

static void muse_one_run_check(void (^completion)(NSString *)) {
    NSMutableArray<NSDictionary *> *tokens = [NSMutableArray new];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *login = muse_one_token(defaults, @"token_one");
    NSString *visitor = muse_one_token(defaults, @"token_one_visitor");
    if (login.length) [tokens addObject:@{@"name": @"登录凭证检测", @"token": login}];
    if (visitor.length && ![visitor isEqualToString:login]) [tokens addObject:@{@"name": @"游客凭证检测", @"token": visitor}];
    NSMutableArray<NSString *> *reports = [NSMutableArray arrayWithObject:
        @"检测接口 917api.4c86d03.com；请求包含空 user-key；证书正常验证"];
    if (!tokens.count) [reports addObject:@"未获取 One 凭证，请先在暮色首页等待后再检查"];
    muse_one_check_next(tokens, 0, reports, completion);
}

// ───────────────────────── One 修复包 ─────────────────────────
// This key has the same length and Dart hash as token_one_visitor.
// Canonical table slots, object lengths and cached hashes remain valid.
static NSString *const kOneCacheAlias = @"token_one_p0zP3K5";
static NSString *gOneFixResult;
static NSURL *gOneFixIPA;
static BOOL gOneFixRunning;

static NSError *muse_one_fix_error(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MuseHook.OneFix" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
static uint32_t muse_one_u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint32_t muse_one_be32(const uint8_t *p) {
    return (uint32_t)p[3] | (uint32_t)p[2] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[0] << 24;
}
static uint64_t muse_one_u64(const uint8_t *p) {
    return (uint64_t)muse_one_u32(p) | (uint64_t)muse_one_u32(p + 4) << 32;
}
static uint64_t muse_one_be64(const uint8_t *p) {
    return (uint64_t)muse_one_be32(p + 4) | (uint64_t)muse_one_be32(p) << 32;
}
static void muse_one_put_be32(uint8_t *p, uint32_t n) {
    for (NSUInteger i = 0; i < 4; i++) p[i] = (uint8_t)(n >> (24 - i * 8));
}
static BOOL muse_one_bounds(NSUInteger offset, NSUInteger size, NSUInteger total) {
    return offset <= total && size <= total - offset;
}
static uint32_t muse_one_dart_hash(NSString *text) {
    uint32_t h = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        h += [text characterAtIndex:i]; h += h << 10; h ^= h >> 6;
    }
    h += h << 3; h ^= h >> 11; h += h << 15; h &= 0x3fffffff;
    return h ? h : 1;
}
static NSArray<NSValue *> *muse_one_slices(NSData *data, NSError **error) {
    const uint8_t *b = data.bytes;
    NSMutableArray<NSValue *> *slices = [NSMutableArray new];
    if (data.length >= 32 && muse_one_u32(b) == 0xfeedfacf) {
        [slices addObject:[NSValue valueWithRange:NSMakeRange(0, data.length)]];
    } else if (data.length >= 8 && (muse_one_be32(b) == 0xcafebabe || muse_one_be32(b) == 0xcafebabf)) {
        BOOL wide = muse_one_be32(b) == 0xcafebabf;
        uint32_t count = muse_one_be32(b + 4);
        NSUInteger width = wide ? 32 : 20;
        if (!count || count > 16 || !muse_one_bounds(8, count * width, data.length)) goto invalid;
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *arch = b + 8 + i * width;
            uint64_t offset = wide ? muse_one_be64(arch + 8) : muse_one_be32(arch + 8);
            uint64_t size = wide ? muse_one_be64(arch + 16) : muse_one_be32(arch + 12);
            if (!muse_one_bounds((NSUInteger)offset, (NSUInteger)size, data.length) || size < 32 ||
                muse_one_u32(b + offset) != 0xfeedfacf) goto invalid;
            [slices addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)size)]];
        }
    } else goto invalid;
    return slices;
invalid:
    if (error) *error = muse_one_fix_error(201, @"无法识别安装包中的 Mach-O 文件");
    return nil;
}
static NSDictionary *muse_one_framework_profile(NSData *data, NSError **error) {
    NSArray<NSValue *> *slices = muse_one_slices(data, error);
    if (!slices) return nil;
    const uint8_t *b = data.bytes;
    NSMutableArray<NSValue *> *keys = [NSMutableArray new], *suffixes = [NSMutableArray new], *uuids = [NSMutableArray new];
    NSString *fixedUUID;
    BOOL already = NO, versionSeen = NO, oneSeen = NO;
    NSUInteger chosen = 0;
    for (NSValue *value in slices) {
        NSRange slice = value.rangeValue;
        const uint8_t *header = b + slice.location;
        if (muse_one_u32(header + 4) != 0x0100000c) continue;
        chosen++;
        uint32_t count = muse_one_u32(header + 16), bytes = muse_one_u32(header + 20);
        if (count > 1024 || !muse_one_bounds(32, bytes, slice.length)) goto invalid;
        NSUInteger command = slice.location + 32, end = command + bytes;
        for (uint32_t c = 0; c < count; c++) {
            if (!muse_one_bounds(command, 8, end)) goto invalid;
            uint32_t type = muse_one_u32(b + command), size = muse_one_u32(b + command + 4);
            if (size < 8 || !muse_one_bounds(command, size, end)) goto invalid;
            if (type == 0x19) {
                if (size < 72) goto invalid;
                uint32_t sections = muse_one_u32(b + command + 64);
                if (sections > (size - 72) / 80) goto invalid;
                for (uint32_t s = 0; s < sections; s++) {
                    const uint8_t *section = b + command + 72 + s * 80;
                    if (strncmp((const char *)section, "__const", 16) ||
                        strncmp((const char *)section + 16, "__TEXT", 16)) continue;
                    uint64_t sectionSize = muse_one_u64(section + 40);
                    NSUInteger start = slice.location + muse_one_u32(section + 48);
                    if (sectionSize > 16 * 1024 * 1024 ||
                        !muse_one_bounds(start, (NSUInteger)sectionSize, slice.location + slice.length)) goto invalid;
                    NSData *part = [data subdataWithRange:NSMakeRange(start, (NSUInteger)sectionSize)];
                    NSData *hash = [@"ace654289f5abc240509fc941453ebc5" dataUsingEncoding:NSASCIIStringEncoding];
                    if ([part rangeOfData:hash options:0 range:NSMakeRange(0, part.length)].location != NSNotFound) versionSeen = YES;
                    for (NSUInteger pos = 0; pos + 16 <= part.length; pos += 16) {
                        const uint8_t *object = b + start + pos;
                        if (((muse_one_u32(object) >> 12) & 0xfffff) != 94) continue;
                        uint64_t smi = muse_one_u64(object + 8), length = smi / 2;
                        if ((smi & 1) || length > 100 || !muse_one_bounds(pos + 16, (NSUInteger)length, part.length)) continue;
                        NSString *text = [[NSString alloc] initWithBytes:object + 16 length:(NSUInteger)length encoding:NSASCIIStringEncoding];
                        if ([text isEqualToString:@"OneInterceptor"]) oneSeen = YES;
                        if ([text isEqualToString:@"token_one_visitor"] || [text isEqualToString:kOneCacheAlias]) {
                            if ((muse_one_u32(object) & 2) == 0 || muse_one_u32(object + 4) != muse_one_dart_hash(text)) goto invalid;
                            [keys addObject:[NSValue valueWithRange:NSMakeRange(start + pos + 16, (NSUInteger)length)]];
                            already = [text isEqualToString:kOneCacheAlias];
                        }
                        if (length == 38 && [text hasPrefix:@".."] && [[NSUUID alloc] initWithUUIDString:[text substringFromIndex:2]]) {
                            fixedUUID = [text substringFromIndex:2];
                            [suffixes addObject:[NSValue valueWithRange:NSMakeRange(start + pos + 16, 38)]];
                        }
                        if (length == 36 && [[NSUUID alloc] initWithUUIDString:text])
                            [uuids addObject:[NSValue valueWithRange:NSMakeRange(start + pos + 16, 36)]];
                    }
                }
            }
            command += size;
        }
        if (command != end) goto invalid;
    }
    if (chosen != 1 || !versionSeen || !oneSeen || keys.count != 1 || suffixes.count != 1 ||
        muse_one_dart_hash(kOneCacheAlias) != muse_one_dart_hash(@"token_one_visitor")) goto invalid;
    NSUInteger matches = 0;
    for (NSValue *value in uuids) {
        NSString *uuid = [[NSString alloc] initWithBytes:b + value.rangeValue.location length:36 encoding:NSASCIIStringEncoding];
        if ([uuid isEqualToString:fixedUUID]) matches++;
    }
    if (matches != 1) goto invalid;
    return @{@"key": keys.firstObject, @"uuid": fixedUUID, @"already": @(already)};
invalid:
    if (error) *error = muse_one_fix_error(202, @"当前 App 的 One 快照布局不匹配，已停止生成补丁");
    return nil;
}
static NSData *muse_one_patch_framework(NSData *data, NSError **error) {
    NSDictionary *profile = muse_one_framework_profile(data, error);
    if (!profile) return nil;
    if ([profile[@"already"] boolValue]) return data;
    NSRange range = [profile[@"key"] rangeValue];
    NSData *alias = [kOneCacheAlias dataUsingEncoding:NSASCIIStringEncoding];
    if (range.length != alias.length || muse_one_dart_hash(@"token_one_visitor") != muse_one_dart_hash(kOneCacheAlias)) return nil;
    NSMutableData *patched = [data mutableCopy];
    [patched replaceBytesInRange:range withBytes:alias.bytes length:alias.length];
    return patched; // Only 17 text bytes change; hashes, tags, gaps and UUIDs are retained.
}

// An unindexed CMS blob cannot trigger TrollStore's fake-root "already signed" path.
// Entitlement blobs and their offsets are preserved for normal recursive re-signing.
static NSData *muse_one_prepare_resign(NSData *data, NSError **error) {
    NSArray<NSValue *> *slices = muse_one_slices(data, error);
    if (!slices) return nil;
    NSMutableData *copy = [data mutableCopy];
    uint8_t *b = copy.mutableBytes;
    for (NSValue *value in slices) {
        NSRange slice = value.rangeValue;
        uint32_t count = muse_one_u32(b + slice.location + 16), bytes = muse_one_u32(b + slice.location + 20);
        if (count > 1024 || !muse_one_bounds(32, bytes, slice.length)) goto invalid;
        NSUInteger command = slice.location + 32, end = command + bytes;
        for (uint32_t c = 0; c < count; c++) {
            if (!muse_one_bounds(command, 8, end)) goto invalid;
            uint32_t type = muse_one_u32(b + command), size = muse_one_u32(b + command + 4);
            if (size < 8 || !muse_one_bounds(command, size, end)) goto invalid;
            if (type == 0x1d) {
                if (size < 16) goto invalid;
                NSUInteger signature = slice.location + muse_one_u32(b + command + 8);
                NSUInteger capacity = muse_one_u32(b + command + 12);
                if (!muse_one_bounds(signature, capacity, slice.location + slice.length) || capacity < 12 ||
                    muse_one_be32(b + signature) != 0xfade0cc0) goto invalid;
                uint32_t length = muse_one_be32(b + signature + 4), entries = muse_one_be32(b + signature + 8);
                if (length > capacity || length < 12 || entries > (length - 12) / 8) goto invalid;
                NSMutableArray<NSDictionary *> *kept = [NSMutableArray new];
                for (uint32_t i = 0; i < entries; i++) {
                    const uint8_t *index = b + signature + 12 + i * 8;
                    uint32_t slot = muse_one_be32(index), offset = muse_one_be32(index + 4);
                    if (!muse_one_bounds(offset, 8, length)) goto invalid;
                    uint32_t blobLength = muse_one_be32(b + signature + offset + 4);
                    if (blobLength < 8 || !muse_one_bounds(offset, blobLength, length)) goto invalid;
                    if (slot == 0x10000) continue;
                    if (muse_one_be32(b + signature + offset) == 0xfade0c02 && blobLength >= 16)
                        muse_one_put_be32(b + signature + offset + 12, muse_one_be32(b + signature + offset + 12) | 2);
                    [kept addObject:@{@"slot": @(slot), @"offset": @(offset)}];
                }
                muse_one_put_be32(b + signature + 8, (uint32_t)kept.count);
                for (NSUInteger i = 0; i < kept.count; i++) {
                    muse_one_put_be32(b + signature + 12 + i * 8, [kept[i][@"slot"] unsignedIntValue]);
                    muse_one_put_be32(b + signature + 16 + i * 8, [kept[i][@"offset"] unsignedIntValue]);
                }
            }
            command += size;
        }
        if (command != end) goto invalid;
    }
    return copy;
invalid:
    if (error) *error = muse_one_fix_error(203, @"无法保留当前 App 的签名权限，已停止导出");
    return nil;
}
static BOOL muse_one_zip_u16(FILE *file, uint16_t n) {
    const uint8_t b[] = {(uint8_t)n, (uint8_t)(n >> 8)};
    return fwrite(b, 1, sizeof(b), file) == sizeof(b);
}
static BOOL muse_one_zip_u32(FILE *file, uint32_t n) {
    return muse_one_zip_u16(file, (uint16_t)n) && muse_one_zip_u16(file, (uint16_t)(n >> 16));
}
static uint32_t muse_one_crc(uint32_t crc, const uint8_t *bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t n = i;
            for (uint32_t bit = 0; bit < 8; bit++) n = (n >> 1) ^ ((n & 1) ? 0xedb88320 : 0);
            table[i] = n;
        }
    });
    for (size_t i = 0; i < length; i++) crc = table[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    return crc;
}
static BOOL muse_one_zip_tree(NSURL *root, NSURL *archive, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *files = [NSMutableArray new];
    __block NSError *enumerationFailure;
    NSDirectoryEnumerator *iterator = [fm enumeratorAtURL:root includingPropertiesForKeys:nil options:0
        errorHandler:^BOOL(NSURL *url, NSError *failure) { enumerationFailure = failure; return NO; }];
    for (NSURL *url in iterator) [files addObject:url];
    if (enumerationFailure) { if (error) *error = enumerationFailure; return NO; }
    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path]; }];
    if (files.count > 65535) {
        if (error) *error = muse_one_fix_error(204, @"安装包文件数量超出 ZIP 格式限制");
        return NO;
    }
    FILE *out = fopen(archive.path.fileSystemRepresentation, "wb");
    if (!out) { if (error) *error = muse_one_fix_error(205, @"无法创建修复安装包"); return NO; }
    NSMutableArray<NSDictionary *> *directory = [NSMutableArray new];
    BOOL success = NO;
    @try {
        uint8_t buffer[65536];
        for (NSURL *url in files) {
            NSDictionary *attributes = [fm attributesOfItemAtPath:url.path error:error];
            if (!attributes) goto done;
            NSString *kind = attributes[NSFileType];
            BOOL isDirectory = [kind isEqualToString:NSFileTypeDirectory], isLink = [kind isEqualToString:NSFileTypeSymbolicLink];
            if (!isDirectory && !isLink && ![kind isEqualToString:NSFileTypeRegular]) goto done;
            NSString *prefix = [root.path stringByAppendingString:@"/"];
            if (![url.path hasPrefix:prefix]) goto done;
            NSString *relative = [url.path substringFromIndex:prefix.length];
            if (isDirectory) relative = [relative stringByAppendingString:@"/"];
            NSData *name = [relative dataUsingEncoding:NSUTF8StringEncoding];
            if (!name.length || name.length > 65535) goto done;
            NSData *link = nil;
            uint64_t length = isDirectory ? 0 : [attributes[NSFileSize] unsignedLongLongValue];
            uint32_t crc = 0xffffffff;
            FILE *input = NULL;
            if (isLink) {
                NSString *target = [fm destinationOfSymbolicLinkAtPath:url.path error:error];
                if (!target) goto done;
                link = [target dataUsingEncoding:NSUTF8StringEncoding];
                length = link.length; crc = muse_one_crc(crc, link.bytes, link.length);
            } else if (!isDirectory) {
                input = fopen(url.path.fileSystemRepresentation, "rb");
                if (!input) goto done;
                size_t amount; uint64_t read = 0;
                while ((amount = fread(buffer, 1, sizeof(buffer), input))) { crc = muse_one_crc(crc, buffer, amount); read += amount; }
                BOOL valid = !ferror(input) && read == length; fclose(input);
                if (!valid) goto done;
            }
            crc ^= 0xffffffff;
            long long position = ftello(out);
            if (length > UINT32_MAX || position < 0 || (uint64_t)position > UINT32_MAX) goto done;
            uint32_t mode = [attributes[NSFilePosixPermissions] unsignedIntValue] |
                (isDirectory ? 0040000 : (isLink ? 0120000 : 0100000));
            if (!muse_one_zip_u32(out, 0x04034b50) || !muse_one_zip_u16(out, 20) ||
                !muse_one_zip_u16(out, 0x0800) || !muse_one_zip_u16(out, 0) ||
                !muse_one_zip_u16(out, 0) || !muse_one_zip_u16(out, 0x5d7c) ||
                !muse_one_zip_u32(out, crc) || !muse_one_zip_u32(out, (uint32_t)length) ||
                !muse_one_zip_u32(out, (uint32_t)length) || !muse_one_zip_u16(out, (uint16_t)name.length) ||
                !muse_one_zip_u16(out, 0) || fwrite(name.bytes, 1, name.length, out) != name.length) goto done;
            if (isLink) {
                if (fwrite(link.bytes, 1, link.length, out) != link.length) goto done;
            } else if (!isDirectory) {
                input = fopen(url.path.fileSystemRepresentation, "rb");
                if (!input) goto done;
                uint64_t written = 0; size_t amount; BOOL copied = YES;
                while ((amount = fread(buffer, 1, sizeof(buffer), input))) {
                    if (fwrite(buffer, 1, amount, out) != amount) { copied = NO; break; }
                    written += amount;
                }
                BOOL valid = copied && !ferror(input) && written == length; fclose(input);
                if (!valid) goto done;
            }
            [directory addObject:@{@"name": name, @"crc": @(crc), @"size": @(length), @"offset": @(position), @"mode": @(mode)}];
        }
        long long central = ftello(out);
        if (central < 0 || (uint64_t)central > UINT32_MAX) goto done;
        for (NSDictionary *item in directory) {
            NSData *name = item[@"name"];
            if (!muse_one_zip_u32(out, 0x02014b50) || !muse_one_zip_u16(out, 0x0314) ||
                !muse_one_zip_u16(out, 20) || !muse_one_zip_u16(out, 0x0800) ||
                !muse_one_zip_u16(out, 0) || !muse_one_zip_u16(out, 0) ||
                !muse_one_zip_u16(out, 0x5d7c) || !muse_one_zip_u32(out, [item[@"crc"] unsignedIntValue]) ||
                !muse_one_zip_u32(out, [item[@"size"] unsignedIntValue]) || !muse_one_zip_u32(out, [item[@"size"] unsignedIntValue]) ||
                !muse_one_zip_u16(out, (uint16_t)name.length) || !muse_one_zip_u16(out, 0) ||
                !muse_one_zip_u16(out, 0) || !muse_one_zip_u16(out, 0) || !muse_one_zip_u16(out, 0) ||
                !muse_one_zip_u32(out, [item[@"mode"] unsignedIntValue] << 16) ||
                !muse_one_zip_u32(out, [item[@"offset"] unsignedIntValue]) ||
                fwrite(name.bytes, 1, name.length, out) != name.length) goto done;
        }
        long long finish = ftello(out);
        if (finish < central || (uint64_t)(finish - central) > UINT32_MAX) goto done;
        success = muse_one_zip_u32(out, 0x06054b50) && muse_one_zip_u16(out, 0) && muse_one_zip_u16(out, 0) &&
            muse_one_zip_u16(out, (uint16_t)directory.count) && muse_one_zip_u16(out, (uint16_t)directory.count) &&
            muse_one_zip_u32(out, (uint32_t)(finish - central)) && muse_one_zip_u32(out, (uint32_t)central) && muse_one_zip_u16(out, 0);
done:
        if (fflush(out)) success = NO;
    } @catch (NSException *exception) { success = NO; }
    if (fclose(out)) success = NO;
    if (!success && error && !*error) *error = muse_one_fix_error(206, @"修复包写入未完成");
    return success;
}
static void muse_one_fix_validate(NSString *token, NSString *uuid, void (^completion)(BOOL, NSString *)) {
    NSString *timestamp = [NSString stringWithFormat:@"%.0f", floor([NSDate date].timeIntervalSince1970)];
    NSMutableURLRequest *request = muse_one_probe_request_for_uuid(token, timestamp, uuid);
    if (!request) { completion(NO, @"登录凭证无法用于校验"); return; }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 16; configuration.timeoutIntervalForResource = 20; configuration.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[MuseOneProbeDelegate new] delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = muse_one_response_json(data);
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        BOOL success = !error && status == 200 && [json[@"code"] isKindOfClass:NSNumber.class] && [json[@"code"] integerValue] == 200;
        NSString *message = error ? muse_one_safe_message(error.localizedDescription) :
            [NSString stringWithFormat:@"HTTP %ld，%@ %@", (long)status,
                [json[@"code"] isKindOfClass:NSNumber.class] ? [NSString stringWithFormat:@"业务码 %@", json[@"code"]] : @"无法解析响应",
                muse_one_safe_message(json[@"message"] ?: json[@"msg"])];
        [session finishTasksAndInvalidate]; completion(success, message);
    }];
    [task resume];
}
static void muse_one_generate_fix(void (^completion)(NSURL *, NSString *, NSError *)) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *executable = [bundle objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if (![bundle.bundleIdentifier isEqualToString:@"com.look.avbox"] ||
        ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:@"1.0.4"] ||
        ![executable isKindOfClass:NSString.class] || !executable.length || ![executable.lastPathComponent isEqualToString:executable]) {
        completion(nil, nil, muse_one_fix_error(207, @"此修复仅适用于暮色 1.0.4")); return;
    }
    NSString *token = muse_one_token(NSUserDefaults.standardUserDefaults, @"token_one");
    NSDictionary *payload = muse_one_payload(token);
    if (![payload[@"exp"] isKindOfClass:NSNumber.class] ||
        !isfinite([payload[@"exp"] doubleValue]) ||
        [payload[@"exp"] doubleValue] <= [NSDate date].timeIntervalSince1970) {
        completion(nil, nil, muse_one_fix_error(208, @"当前登录凭证已失效，请先在暮色首页更新后重试")); return;
    }
    NSString *frameworkRelative = @"Frameworks/App.framework/App";
    NSError *readError = nil;
    NSData *framework = [NSData dataWithContentsOfFile:[bundle.bundlePath stringByAppendingPathComponent:frameworkRelative]
                                              options:NSDataReadingMappedIfSafe error:&readError];
    NSDictionary *profile = framework ? muse_one_framework_profile(framework, &readError) : nil;
    if (!profile) { completion(nil, nil, readError ?: muse_one_fix_error(202, @"无法识别当前 One 快照")); return; }
    muse_one_fix_validate(token, profile[@"uuid"], ^(BOOL valid, NSString *verification) {
        if (!valid) {
            completion(nil, nil, muse_one_fix_error(209, [@"App 原签名配合登录凭证未通过验证，已停止生成修复包。"
                stringByAppendingString:verification ?: @""])); return;
        }
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setObject:token forKey:[@"flutter." stringByAppendingString:kOneCacheAlias]];
        if (![defaults synchronize]) { completion(nil, nil, muse_one_fix_error(210, @"修复凭证未能保存，已停止生成安装包")); return; }
        if ([profile[@"already"] boolValue]) { completion(nil, @"One 凭证已更新，强退并重新打开暮色后生效", nil); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSFileManager *fm = NSFileManager.defaultManager;
                NSURL *stage = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                    [@"muse-one-export-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
                NSURL *tree = [stage URLByAppendingPathComponent:@"tree" isDirectory:YES];
                NSURL *payloadFolder = [tree URLByAppendingPathComponent:@"Payload" isDirectory:YES];
                NSURL *copiedBundle = [payloadFolder URLByAppendingPathComponent:bundle.bundleURL.lastPathComponent isDirectory:YES];
                NSError *error = nil;
                BOOL ok = [fm createDirectoryAtURL:payloadFolder withIntermediateDirectories:YES attributes:nil error:&error] &&
                    [fm copyItemAtURL:bundle.bundleURL toURL:copiedBundle error:&error];
                NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSURL *folder = [NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"暮色One修复"] isDirectory:YES];
                NSURL *backup = [folder URLByAppendingPathComponent:@"暮色1.0.4-修复前备份.ipa"];
                NSURL *backupTemporary = [stage URLByAppendingPathComponent:@"original.ipa.partial"];
                if (ok) ok = [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error] &&
                    muse_one_zip_tree(tree, backupTemporary, &error);
                if (ok) {
                    if ([fm fileExistsAtPath:backup.path])
                        ok = [fm replaceItemAtURL:backup withItemAtURL:backupTemporary backupItemName:nil options:0 resultingItemURL:nil error:&error];
                    else ok = [fm moveItemAtURL:backupTemporary toURL:backup error:&error];
                }
                if (ok) {
                    NSData *patched = muse_one_patch_framework(framework, &error);
                    NSURL *file = [copiedBundle URLByAppendingPathComponent:frameworkRelative];
                    ok = patched && [patched writeToURL:file options:NSDataWritingAtomic error:&error] &&
                        [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:file.path error:&error];
                }
                if (ok) {
                    NSURL *main = [copiedBundle URLByAppendingPathComponent:executable];
                    NSData *bytes = [NSData dataWithContentsOfURL:main options:0 error:&error];
                    NSData *unsignedMain = bytes ? muse_one_prepare_resign(bytes, &error) : nil;
                    ok = unsignedMain && [unsignedMain writeToURL:main options:NSDataWritingAtomic error:&error] &&
                        [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:main.path error:&error];
                }
                if (ok) {
                    NSURL *infoURL = [copiedBundle URLByAppendingPathComponent:@"Info.plist"];
                    NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfURL:infoURL] mutableCopy];
                    if (!info) { error = muse_one_fix_error(211, @"无法保留 App 信息"); ok = NO; }
                    else {
                        [info removeObjectForKey:@"TSPreAppliedExploitType"]; [info removeObjectForKey:@"TSBundlePreSigned"];
                        ok = [info writeToURL:infoURL error:&error];
                    }
                }
                NSURL *destination = [folder URLByAppendingPathComponent:@"暮色1.0.4-One修复.ipa"];
                NSURL *temporary = [stage URLByAppendingPathComponent:@"One修复.ipa.partial"];
                if (ok) ok = [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error] &&
                    muse_one_zip_tree(tree, temporary, &error);
                if (ok) {
                    if ([fm fileExistsAtPath:destination.path])
                        ok = [fm replaceItemAtURL:destination withItemAtURL:temporary backupItemName:nil options:0 resultingItemURL:nil error:&error];
                    else ok = [fm moveItemAtURL:temporary toURL:destination error:&error];
                }
                if (ok) [fm removeItemAtURL:stage error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(ok ? destination : nil, ok ? @"原签名验证成功，One 修复安装包已生成" : nil,
                               ok ? nil : (error ?: muse_one_fix_error(212, @"生成修复包失败")));
                });
            }
        });
    });
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
@property (atomic, copy) NSString *outputPath;
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

static NSString *muse_video_basename(NSString *value) {
    for (NSUInteger depth = 0; depth < 3 && value.length; depth++) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:value];
        NSString *component = parts.percentEncodedPath.lastPathComponent;
        component = component.stringByRemovingPercentEncoding ?: component;
        NSString *extension = component.pathExtension.lowercaseString;
        if ([@[@"mp4", @"m4v", @"mov", @"m3u8", @"mkv", @"flv", @"webm", @"ts"] containsObject:extension]) {
            NSString *name = component.stringByDeletingPathExtension;
            if (name.length && ![@[@"index", @"master", @"playlist", @"manifest", @"main", @"list", @"start", @"prog_index", @"chunklist"]
                                containsObject:name.lowercaseString]) return name;
        }
        NSString *nested = nil;
        for (NSURLQueryItem *item in parts.queryItems) {
            if ([item.name.lowercaseString isEqualToString:@"url"]) { nested = item.value; break; }
        }
        if ([nested isEqualToString:value]) break;
        value = nested;
    }
    return nil;
}

static NSString *muse_display_title(NSString *title) {
    NSString *value = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return nil;
    static NSRegularExpression *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        placeholder = [NSRegularExpression regularExpressionWithPattern:@"^候选\\s*[0-9]+$"
                                                                 options:0 error:NULL];
    });
    if ([placeholder firstMatchInString:value options:0 range:NSMakeRange(0, value.length)]) return nil;
    return value;
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
            NSURL *url = muse_hls_url(candidate.url, nil);
            if (!url) @throw [NSException exceptionWithName:@"MuseDownload" reason:@"播放地址无效" userInfo:nil];
            MuseDownloadJob *probe = [self probeURL:url candidate:candidate];
            NSString *name = muse_display_title(candidate.title) ?: muse_video_basename(candidate.url) ?:
                             muse_video_basename(probe.response.URL.absoluteString) ?: candidate.title;
            NSString *safe = [[name componentsSeparatedByCharactersInSet:
                              [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r"]]
                             componentsJoinedByString:@"_"];
            if (!safe.length || [safe isEqualToString:@"."] || [safe isEqualToString:@".."]) safe = @"MuseVideo";
            if (safe.length > 60) safe = [safe substringWithRange:[safe rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 60)]];
            if ([safe lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) safe = @"MuseVideo";
            mlog(@"保存命名 标题[%@] 名称[%@] 模块标题[%@]",
                 candidate.title, safe, muse_display_title(candidate.title) ?: @"未获得");
            NSURL *directory = [NSURL fileURLWithPath:out_dir() isDirectory:YES];
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error])
                @throw [NSException exceptionWithName:@"MuseDownload" reason:error.localizedDescription userInfo:nil];
            NSURL *temporaryDirectory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
            working = [temporaryDirectory URLByAppendingPathComponent:[@"MuseHook-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
            if (![NSFileManager.defaultManager createDirectoryAtURL:working withIntermediateDirectories:NO attributes:nil error:&error])
                @throw [NSException exceptionWithName:@"MuseDownload" reason:error.localizedDescription userInfo:nil];
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
            candidate.outputPath = completed.path;
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
        report = [report stringByAppendingFormat:@"\n候选标题 %@\n保存路径 %@",
                  candidate.title, candidate.outputPath ?: @"尚未完成下载"];
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
    [alert addAction:[UIAlertAction actionWithTitle:@"检查 One" style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *action) {
        [self performSelector:@selector(checkOne) withObject:nil afterDelay:0.35];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"修复 One" style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *action) {
        [self performSelector:@selector(repairOne) withObject:nil afterDelay:0.35];
    }]];
    if (gOneFixIPA && [NSFileManager.defaultManager fileExistsAtPath:gOneFixIPA.path]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"分享修复安装包" style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
            [self performSelector:@selector(shareOneFix) withObject:nil afterDelay:0.35];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkOne {
    if (gOneCheckRunning || gOneFixRunning) return;
    gOneCheckRunning = YES;
    gOneCheckResult = @"正在检查服务器…";
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"正在检查 One"
        message:@"分别检查登录和游客凭证，最多约 40 秒。" preferredStyle:UIAlertControllerStyleAlert];
    [progress addAction:[UIAlertAction actionWithTitle:@"后台检查" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:progress animated:YES completion:nil];
    __weak MuseListVC *weakSelf = self;
    muse_one_run_check(^(NSString *result) {
        gOneCheckRunning = NO;
        gOneCheckResult = result;
        mlog(@"%@", muse_one_local_report());
        MuseListVC *strongSelf = weakSelf;
        if (strongSelf.presentedViewController == progress) {
            [progress dismissViewControllerAnimated:YES completion:^{ [strongSelf showDiagnostics]; }];
        }
    });
}

- (void)shareOneFix {
    if (!gOneFixIPA) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[gOneFixIPA] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)repairOne {
    if (gOneFixRunning || gOneCheckRunning) return;
    gOneFixRunning = YES;
    gOneFixResult = @"正在验证原 App 签名并准备修复包…";
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"正在修复 One"
        message:@"请保持已验证可用的网络。验证通过后会生成备份及修复安装包。"
        preferredStyle:UIAlertControllerStyleAlert];
    [progress addAction:[UIAlertAction actionWithTitle:@"后台生成" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:progress animated:YES completion:nil];
    __weak MuseListVC *weakSelf = self;
    muse_one_generate_fix(^(NSURL *ipa, NSString *message, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gOneFixRunning = NO;
            gOneFixIPA = ipa;
            gOneFixResult = error ? muse_one_safe_message(error.localizedDescription) :
                (ipa ? [NSString stringWithFormat:@"%@\n修复包 %@\n备份在同一目录", message, ipa.path] : message);
            mlog(@"One 修复：%@", gOneFixResult);
            MuseListVC *strongSelf = weakSelf;
            if (strongSelf.presentedViewController == progress)
                [progress dismissViewControllerAnimated:YES completion:^{ [strongSelf showDiagnostics]; }];
        });
    });
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
    NSString *report = [NSString stringWithFormat:
        @"MuseHook One 修复包生成版 2026.11.28\n观察点 %lu/5\n播放器调用 %lu\n播放地址 %lu\n最近入口 %@\n最近地址 %@\n日志 %@",
        (unsigned long)atomic_load(&gMediaHooksInstalled),
        (unsigned long)atomic_load(&gMediaCallsObserved),
        (unsigned long)atomic_load(&gMediaURLsObserved),
        event ?: @"等待播放", address ?: @"等待播放", logPath];
    return [report stringByAppendingFormat:@"\n\n%@\n\nOne 修复\n%@", muse_one_local_report(),
            gOneFixResult ?: @"点击「修复 One」验证并生成安装包"];
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
