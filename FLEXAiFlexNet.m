//
//  FLEXAiFlexNet.m
//  FLEX++
//

#import "FLEXAiFlexNet.h"
#import "FLEXAiFlexHook.h"
#import "flex_fishhook.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <time.h>
#import <errno.h>

#import <sys/socket.h>
#import <netinet/in.h>
#import <netdb.h>
#import <arpa/inet.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <Security/Security.h>
#import <os/lock.h>
#import <os/log.h>

#pragma mark - 常量

// 记录条数。400 条足够覆盖一次完整业务流程（登录 → 拉列表 → 上报），
// 再多会挤占宿主内存而不增加可观测性——FLEX 自己只留 50 条。
static const NSUInteger NXCapacity = 400;
// 单条 body 落库上限。超出部分截断并标 truncated，绝不假装完整。
static const NSUInteger NXBodyStoreMax = 64 * 1024;
// 返回给 AI 的单条 body 上限。存储比返回宽，因为重放需要完整 body。
static const NSUInteger NXBodyReturnMax = 32 * 1024;
// body 全局预算。超预算时从最旧的记录开始释放 body，头信息保留。
static const NSUInteger NXBodyBudget = 24 * 1024 * 1024;
// TLS 流重组缓冲上限（每连接每方向）。
static const NSUInteger NXStreamMax = 256 * 1024;
// 断点最长挂起时间。超时自动放行，避免把调用线程拖死。
static const NSTimeInterval NXHoldTimeout = 15.0;

static NSString *const NXCaptureNSURLKey = @"AiFlex3NetCaptureNSURL";
static NSString *const NXCaptureWSKey = @"AiFlex3NetCaptureWS";
static NSString *const NXCaptureTLSKey = @"AiFlex3NetCaptureTLS";
static NSString *const NXCaptureSocketKey = @"AiFlex3NetCaptureSocket";
static NSString *const NXRulesFile = @"rules.json";

#pragma mark - 小工具

static NSString *NXShort(NSString *text, NSUInteger limit) {
    if (![text isKindOfClass:NSString.class]) return @"";
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"…"];
}

static NSString *NXText(NSData *data, NSUInteger limit) {
    if (!data.length) return @"";
    NSUInteger use = MIN(data.length, limit);
    NSString *text = [[NSString alloc] initWithBytes:data.bytes length:use encoding:NSUTF8StringEncoding];
    if (!text) {
        // 二进制 body：给十六进制前缀，别返回乱码让 AI 误判成文本。
        NSMutableString *hex = [NSMutableString stringWithCapacity:use * 2];
        const uint8_t *bytes = data.bytes;
        for (NSUInteger i = 0; i < MIN(use, 512); i++) [hex appendFormat:@"%02x", bytes[i]];
        return [NSString stringWithFormat:@"<binary %lu bytes> %@", (unsigned long)data.length, hex];
    }
    if (data.length > use) text = [text stringByAppendingString:@"…（已截断）"];
    return text;
}

static id NXString(NSDictionary *arguments, NSString *key) {
    id value = arguments[key];
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSInteger NXInt(NSDictionary *arguments, NSString *key, NSInteger fallback, NSInteger low, NSInteger high) {
    id value = arguments[key];
    NSInteger parsed = fallback;
    if ([value isKindOfClass:NSNumber.class]) parsed = [(NSNumber *)value integerValue];
    else if ([value isKindOfClass:NSString.class]) parsed = strtol([(NSString *)value UTF8String], NULL, 0);
    return (NSInteger)MIN(MAX(parsed, low), high);
}

static BOOL NXBool(NSDictionary *arguments, NSString *key, BOOL fallback) {
    id value = arguments[key];
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:NSString.class]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqual:@"1"] || [lower isEqual:@"true"] || [lower isEqual:@"yes"]) return YES;
        if ([lower isEqual:@"0"] || [lower isEqual:@"false"] || [lower isEqual:@"no"]) return NO;
    }
    return fallback;
}

static BOOL NXDefaultsFlag(NSString *key, BOOL fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (!value) return fallback;
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

// 开关缓存。-1 表示"还没读过"，读一次后写死，只有在 capture operation 里
// 才置回 -1。原因很实际：nx_send 是高频路径，每次进去读 NSUserDefaults
// 要走锁甚至碰磁盘，光这一项就能让目标 App 卡住。
static int32_t gNXCaptureNSURL = -1;
static int32_t gNXCaptureWS = -1;
static int32_t gNXCaptureTLS = -1;
static int32_t gNXCaptureSocket = -1;

static void NXResetCaptureCache(void) {
    __atomic_store_n(&gNXCaptureNSURL, -1, __ATOMIC_RELAXED);
    __atomic_store_n(&gNXCaptureWS, -1, __ATOMIC_RELAXED);
    __atomic_store_n(&gNXCaptureTLS, -1, __ATOMIC_RELAXED);
    __atomic_store_n(&gNXCaptureSocket, -1, __ATOMIC_RELAXED);
}

static BOOL NXCaptureFlag(int32_t *cache, NSString *key, BOOL fallback) {
    int32_t value = __atomic_load_n(cache, __ATOMIC_RELAXED);
    if (value < 0) {
        value = NXDefaultsFlag(key, fallback) ? 1 : 0;
        __atomic_store_n(cache, value, __ATOMIC_RELAXED);
    }
    return value == 1;
}

static uint64_t NXNowNs(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// body 有两种传法：文本走 body，二进制走 body_base64（base64 优先）。
// 空字符串是一个合法值（表示"把 body 清成空"），所以不做长度判断。
static NSData *NXBodyFromArguments(NSDictionary *arguments) {
    NSString *base64 = NXString(arguments, @"body_base64");
    if ([base64 isKindOfClass:NSString.class] && base64.length) {
        return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    }
    id body = arguments[@"body"];
    if ([body isKindOfClass:NSString.class]) return [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
    return nil;
}

#pragma mark - 记录模型

@interface NXRecord : NSObject
@property (nonatomic) uint64_t seq;
@property (nonatomic, copy) NSString *ident;
@property (nonatomic, copy) NSString *layer;       // nsurl / ws / openssl / securetransport / socket
@property (nonatomic, copy) NSString *kind;        // http / ws / tls / connect / dns
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSInteger status;
@property (nonatomic, strong) NSDictionary *requestHeaders;
@property (nonatomic, strong) NSDictionary *responseHeaders;
@property (nonatomic, strong) NSData *requestBody;
@property (nonatomic, strong) NSData *responseBody;
@property (nonatomic) BOOL requestBodyTruncated;
@property (nonatomic) BOOL responseBodyTruncated;
@property (nonatomic) BOOL requestBodyFromStream;
@property (nonatomic, copy) NSString *note;
@property (nonatomic, copy) NSString *error;
@property (nonatomic) NSUInteger requestBytes;
@property (nonatomic) NSUInteger responseBytes;
@property (nonatomic, copy) NSString *rule;
@property (nonatomic, copy) NSString *tlsSource;
@property (nonatomic, copy) NSString *sni;
@property (nonatomic) NSTimeInterval startedAt;    // 墙钟，给报告用
@property (nonatomic) uint64_t startedNs;          // 单调钟，给 correlate 用
@property (nonatomic) uint64_t endedNs;
@property (nonatomic) BOOL finished;
@end

@implementation NXRecord
@end

#pragma mark - 断点挂起槽

@interface NXPending : NSObject
@property (nonatomic, copy) NSString *ident;
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, copy) NSString *ruleId;
@property (nonatomic) uint64_t createdAtNs;
@property (nonatomic, copy) NSString *decision;    // forward / modify / drop
@property (nonatomic, strong) NSURLRequest *modifiedRequest;
@property (nonatomic) BOOL resolved;
@end

@implementation NXPending
@end

#pragma mark - 引擎

@interface FLEXAiFlexNet () {
    os_unfair_lock _lock;
    NSMutableArray<NXRecord *> *_records;
    uint64_t _seq;
    NSUInteger _bodyBytes;
    NSMutableArray<NSDictionary *> *_rules;
    NSMutableArray<NXPending *> *_pending;
    NSCondition *_holdCondition;
    BOOL _hooksInstalled;
    dispatch_queue_t _queue;
    NSUInteger _droppedRecords;
}
// 内部方法的显式声明。category 里的 swizzle 实现会回调这些方法，
// 不声明的话编译器在 category 里看不到它们（实现都在同一文件后半段）。
- (BOOL)captureNSURL;
- (BOOL)captureWS;
- (BOOL)captureTLS;
- (BOOL)captureSocket;
- (NSDictionary *)firstRuleForRequest:(NSURLRequest *)request;
- (NSURLRequest *)prepareRequest:(NSURLRequest *)request
                           layer:(NSString *)layer
                     requestBody:(NSData *)body
                       recordOut:(NXRecord **)recordOut;
- (NSData *)rewriteResponseData:(NSData *)data
                       response:(NSURLResponse **)responsePtr
                          rule:(NSDictionary *)rule;
- (void)finishRecordIdent:(NSString *)ident
                     data:(NSData *)data
                 response:(NSURLResponse *)response
                    error:(NSError *)error;
- (NXRecord *)recordForIdent:(NSString *)ident;
- (void)markDelegatePathForIdent:(NSString *)ident;
- (void)installURLSessionHooks;
- (void)installWebSocketHooks;
- (void)installTLSHooks;
- (void)installSocketHooks;
- (void)loadRules;
- (void)saveRules;
- (void)recordWebSocketMessage:(id)message outgoing:(BOOL)outgoing url:(NSURL *)url;
- (void)recordTLSData:(NSData *)data
              context:(const void *)context
             outgoing:(BOOL)outgoing
                layer:(NSString *)layer;
- (void)recordSocketEvent:(NSString *)kind
                     host:(NSString *)host
                     note:(NSString *)note;
- (BOOL)resolvePendingIdent:(NSString *)ident
                   decision:(NSString *)decision
                    request:(NSURLRequest *)request
                      error:(NSString **)error;
// 下面这批都是同文件内的分段实现：@implementation 被 C 函数和 category 切成
// 了几段，跨段调用必须先有声明，否则 ARC 无法确定返回类型。
- (NSString *)appendRecord:(NXRecord *)record;
- (NSArray<NXRecord *> *)snapshotRecords;
- (NSDictionary *)rowForRecord:(NXRecord *)record detail:(BOOL)detail;
- (NSDictionary *)harHeaders:(NSDictionary *)headers;
- (NSArray *)harQuery:(NSString *)url;
- (BOOL)rule:(NSDictionary *)rule matches:(NSURLRequest *)request;
- (NSURLRequest *)applyRewrite:(NSDictionary *)set toRequest:(NSURLRequest *)request;
- (NSURLRequest *)holdRequest:(NSURLRequest *)request rule:(NSDictionary *)rule;
- (NXPending *)pendingForIdent:(NSString *)ident;
- (NSString *)rulesDirectory;
- (NSDictionary *)opStatus;
- (NSDictionary *)opList:(NSDictionary *)arguments;
- (NSDictionary *)opDetail:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opExport:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opRules;
- (NSDictionary *)opPending;
- (NSDictionary *)opCorrelate:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opClear;
- (NSDictionary *)opCapture:(NSDictionary *)arguments;
- (NSDictionary *)opRuleAdd:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opRuleRemove:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opRuleClear;
- (NSDictionary *)opRuleToggle:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opDecide:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opReplay:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)opCompose:(NSDictionary *)arguments error:(NSString **)error;
- (NSDictionary *)sendMethod:(NSString *)method
                         url:(NSString *)urlText
                     headers:(NSDictionary *)headers
                        body:(NSData *)body
                     timeout:(NSTimeInterval)timeout
                       error:(NSString **)error;
- (NSDictionary *)performOperation:(NSString *)operation
                         arguments:(NSDictionary *)arguments
                             error:(NSString **)error;
@end

@implementation FLEXAiFlexNet

+ (instancetype)sharedEngine {
    static FLEXAiFlexNet *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [FLEXAiFlexNet new]; });
    return engine;
}

+ (BOOL)engineAvailable { return YES; }

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _records = [NSMutableArray array];
        _rules = [NSMutableArray array];
        _pending = [NSMutableArray array];
        _holdCondition = [NSCondition new];
        _queue = dispatch_queue_create("com.hoko20.aiflex3.net", DISPATCH_QUEUE_SERIAL);
        [self loadRules];
    }
    return self;
}

+ (NSArray<NSString *> *)captureOperations {
    return @[@"status", @"list", @"detail", @"export", @"rules", @"pending", @"correlate", @"clear"];
}

+ (NSArray<NSString *> *)actionOperations {
    return @[@"capture", @"rule_add", @"rule_remove", @"rule_clear", @"rule_toggle",
             @"decide", @"replay", @"compose"];
}

#pragma mark - 采集开关

- (BOOL)captureNSURL { return NXCaptureFlag(&gNXCaptureNSURL, NXCaptureNSURLKey, YES); }
- (BOOL)captureWS { return NXCaptureFlag(&gNXCaptureWS, NXCaptureWSKey, YES); }
- (BOOL)captureTLS { return NXCaptureFlag(&gNXCaptureTLS, NXCaptureTLSKey, NO); }
- (BOOL)captureSocket { return NXCaptureFlag(&gNXCaptureSocket, NXCaptureSocketKey, NO); }

- (NSDictionary *)captureState {
    return @{
        @"nsurl": @([self captureNSURL]),
        @"websocket": @([self captureWS]),
        @"tls": @([self captureTLS]),
        @"socket": @([self captureSocket]),
        @"transparentProxy": @NO,
        @"note": @"tls / socket 默认关闭：两者都要 swizzle 系统 TLS 与 BSD socket，"
                 @"高频 App 上会明显增加开销。需要看自带 TLS 栈（BoringSSL / SecureTransport）"
                 @"或连接级 SNI 时再用 aiflex_net_action(capture, ...) 打开。",
    };
}

#pragma mark - 记录存取

- (NSString *)appendRecord:(NXRecord *)record {
    os_unfair_lock_lock(&_lock);
    _seq += 1;
    record.seq = _seq;
    record.ident = [NSString stringWithFormat:@"n%llu", (unsigned long long)_seq];
    if (!record.startedNs) record.startedNs = NXNowNs();
    if (!record.startedAt) record.startedAt = NSDate.date.timeIntervalSince1970;
    [_records addObject:record];
    if (record.requestBody.length) _bodyBytes += record.requestBody.length;
    if (record.responseBody.length) _bodyBytes += record.responseBody.length;
    while (_records.count > NXCapacity) {
        NXRecord *old = _records.firstObject;
        _bodyBytes -= MIN(_bodyBytes, old.requestBody.length + old.responseBody.length);
        [_records removeObjectAtIndex:0];
        _droppedRecords += 1;
        // 保留头信息比保留 body 更有用：老记录只丢 body，行还在列表里。
        old.requestBody = nil;
        old.responseBody = nil;
    }
    while (_bodyBytes > NXBodyBudget && _records.count > 1) {
        NXRecord *old = _records.firstObject;
        NSUInteger freed = old.requestBody.length + old.responseBody.length;
        old.requestBody = nil;
        old.responseBody = nil;
        _bodyBytes -= MIN(_bodyBytes, freed);
        if (!freed) break;
        old.note = [(old.note ?: @"") stringByAppendingString:@" [body 已释放以控制内存]"];
    }
    NSString *ident = record.ident;
    os_unfair_lock_unlock(&_lock);
    return ident;
}

- (void)finishRecordIdent:(NSString *)ident
                     data:(NSData *)data
                 response:(NSURLResponse *)response
                    error:(NSError *)error {
    if (!ident.length) return;
    os_unfair_lock_lock(&_lock);
    NXRecord *record = nil;
    for (NXRecord *item in _records.reverseObjectEnumerator) {
        if ([item.ident isEqual:ident]) { record = item; break; }
    }
    if (record) {
        record.endedNs = NXNowNs();
        record.finished = YES;
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            record.status = http.statusCode;
            record.responseHeaders = http.allHeaderFields;
        }
        if (data.length) {
            record.responseBytes = data.length;
            if (data.length > NXBodyStoreMax) {
                record.responseBody = [data subdataWithRange:NSMakeRange(0, NXBodyStoreMax)];
                record.responseBodyTruncated = YES;
            } else {
                record.responseBody = data;
            }
            _bodyBytes += record.responseBody.length;
        }
        if (error) record.error = NXShort(error.localizedDescription, 300);
    }
    os_unfair_lock_unlock(&_lock);
}

- (NXRecord *)recordForIdent:(NSString *)ident {
    if (!ident.length) return nil;
    os_unfair_lock_lock(&_lock);
    NXRecord *found = nil;
    for (NXRecord *item in _records.reverseObjectEnumerator) {
        if ([item.ident isEqual:ident]) { found = item; break; }
    }
    os_unfair_lock_unlock(&_lock);
    return found;
}

- (NSArray<NXRecord *> *)snapshotRecords {
    os_unfair_lock_lock(&_lock);
    NSArray *copy = _records.copy;
    os_unfair_lock_unlock(&_lock);
    return copy;
}

#pragma mark - 记录序列化

- (NSDictionary *)rowForRecord:(NXRecord *)record detail:(BOOL)detail {
    NSMutableDictionary *row = [@{
        @"id": record.ident,
        @"layer": record.layer ?: @"",
        @"kind": record.kind ?: @"http",
        @"method": record.method ?: @"",
        @"host": record.host ?: @"",
        @"path": NXShort(record.path ?: @"", 512),
        @"status": @(record.status),
        @"startedAt": @(record.startedAt),
        @"durationMs": @(record.endedNs > record.startedNs ? (double)(record.endedNs - record.startedNs) / 1e6 : 0),
        @"requestBytes": @(record.requestBytes),
        @"responseBytes": @(record.responseBytes),
        @"finished": @(record.finished),
    } mutableCopy];
    if (record.error.length) row[@"error"] = NXShort(record.error, 200);
    if (record.rule.length) row[@"rule"] = record.rule;
    if (record.sni.length) row[@"sni"] = record.sni;
    if (!detail) return row;

    row[@"url"] = NXShort(record.url ?: @"", 2048);
    row[@"requestHeaders"] = record.requestHeaders ?: @{};
    row[@"responseHeaders"] = record.responseHeaders ?: @{};
    row[@"requestContentType"] = record.requestHeaders[@"Content-Type"] ?: record.requestHeaders[@"content-type"] ?: @"";
    row[@"responseContentType"] = record.responseHeaders[@"Content-Type"] ?: record.responseHeaders[@"content-type"] ?: @"";
    row[@"requestBody"] = NXText(record.requestBody, NXBodyReturnMax);
    row[@"responseBody"] = NXText(record.responseBody, NXBodyReturnMax);
    row[@"requestBodyTruncated"] = @(record.requestBodyTruncated);
    row[@"responseBodyTruncated"] = @(record.responseBodyTruncated);
    row[@"requestBodyBytes"] = @(record.requestBody.length);
    row[@"responseBodyBytes"] = @(record.responseBody.length);
    if (record.tlsSource.length) row[@"tlsSource"] = record.tlsSource;
    if (record.note.length) row[@"note"] = record.note;
    if (record.requestBodyFromStream) row[@"requestBodyUnavailable"] = @"HTTPBodyStream（未读取，读流会破坏 App 的请求）";
    // 请求头数量单独给：AI 看到 headers 为 {} 时需要区分"确实没有"
    // 和"这一层拿不到"。
    row[@"requestHeaderCount"] = @(record.requestHeaders.count);
    row[@"responseHeaderCount"] = @(record.responseHeaders.count);
    return row;
}

- (NSDictionary *)harEntryForIdentifier:(NSString *)identifier {
    NXRecord *record = [self recordForIdent:identifier];
    if (!record) return @{};
    NSMutableDictionary *request = [@{
        @"method": record.method ?: @"",
        @"url": record.url ?: @"",
        @"httpVersion": @"HTTP/1.1",
        @"headers": [self harHeaders:record.requestHeaders],
        @"queryString": [self harQuery:record.url],
        @"bodySize": @(record.requestBody.length),
    } mutableCopy];
    if (record.requestBody.length) {
        request[@"postData"] = @{@"mimeType": record.requestHeaders[@"Content-Type"] ?: @"",
                                 @"text": NXText(record.requestBody, NXBodyReturnMax)};
    }
    NSMutableDictionary *response = [@{
        @"status": @(record.status),
        @"statusText": @"",
        @"httpVersion": @"HTTP/1.1",
        @"headers": [self harHeaders:record.responseHeaders],
        @"content": @{@"size": @(record.responseBody.length),
                      @"mimeType": record.responseHeaders[@"Content-Type"] ?: @"",
                      @"text": NXText(record.responseBody, NXBodyReturnMax)},
    } mutableCopy];
    return @{
        @"startedDateTime": [NSDateFormatter.new stringFromDate:[NSDate dateWithTimeIntervalSince1970:record.startedAt]],
        @"time": @(record.endedNs > record.startedNs ? (double)(record.endedNs - record.startedNs) / 1e3 : 0),
        @"request": request,
        @"response": response,
        @"_layer": record.layer ?: @"",
        @"_note": record.note ?: @"",
    };
}

- (NSArray *)harHeaders:(NSDictionary *)headers {
    NSMutableArray *list = [NSMutableArray array];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        [list addObject:@{@"name": [key description], @"value": [value description]}];
    }];
    return list;
}

- (NSArray *)harQuery:(NSString *)url {
    NSMutableArray *list = [NSMutableArray array];
    NSURLComponents *components = [NSURLComponents componentsWithString:url ?: @""];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        [list addObject:@{@"name": item.name ?: @"", @"value": item.value ?: @""}];
    }
    return list;
}

#pragma mark - 规则引擎

// 规则形状：
//   { id, enabled, action: rewrite|hold|drop,
//     match: { host, path, method, url, url_regex },
//     set:   { url, method, headers:{}, remove_headers:[], body, body_base64? } }
// 匹配全部用「包含」语义而不是精确相等：AI 通常只知道路径片段，
// 要求写全 URL 会让规则几乎永远不命中。

- (BOOL)rule:(NSDictionary *)rule matches:(NSURLRequest *)request {
    if (![rule[@"enabled"] boolValue]) return NO;
    NSDictionary *match = rule[@"match"];
    if (![match isKindOfClass:NSDictionary.class] || !match.count) return NO;
    NSString *url = request.URL.absoluteString ?: @"";
    NSString *host = request.URL.host ?: @"";
    NSString *path = request.URL.path ?: @"";

    NSString *hostNeedle = match[@"host"];
    if ([hostNeedle isKindOfClass:NSString.class] && hostNeedle.length &&
        [host rangeOfString:hostNeedle options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;

    NSString *pathNeedle = match[@"path"];
    if ([pathNeedle isKindOfClass:NSString.class] && pathNeedle.length &&
        [path rangeOfString:pathNeedle options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;

    NSString *methodNeedle = match[@"method"];
    if ([methodNeedle isKindOfClass:NSString.class] && methodNeedle.length &&
        ![[request.HTTPMethod ?: @"GET" uppercaseString] isEqual:[methodNeedle uppercaseString]]) return NO;

    NSString *urlNeedle = match[@"url"];
    if ([urlNeedle isKindOfClass:NSString.class] && urlNeedle.length &&
        [url rangeOfString:urlNeedle options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;

    NSString *pattern = match[@"url_regex"];
    if ([pattern isKindOfClass:NSString.class] && pattern.length) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        if (regex && ![regex numberOfMatchesInString:url options:0 range:NSMakeRange(0, url.length)]) return NO;
    }
    return YES;
}

- (NSDictionary *)firstRuleForRequest:(NSURLRequest *)request {
    os_unfair_lock_lock(&_lock);
    NSArray *copy = _rules.copy;
    os_unfair_lock_unlock(&_lock);
    for (NSDictionary *rule in copy) if ([self rule:rule matches:request]) return rule;
    return nil;
}

- (NSURLRequest *)applyRewrite:(NSDictionary *)set toRequest:(NSURLRequest *)request {
    if (![set isKindOfClass:NSDictionary.class] || !set.count) return request;
    NSMutableURLRequest *mutable = [request mutableCopy];
    NSString *url = set[@"url"];
    if ([url isKindOfClass:NSString.class] && url.length) {
        NSURL *newURL = [NSURL URLWithString:url];
        if (newURL) mutable.URL = newURL;
    }
    NSString *method = set[@"method"];
    if ([method isKindOfClass:NSString.class] && method.length) mutable.HTTPMethod = [method uppercaseString];
    NSDictionary *addHeaders = set[@"headers"];
    if ([addHeaders isKindOfClass:NSDictionary.class]) {
        [addHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            [mutable setValue:[value description] forHTTPHeaderField:[key description]];
        }];
    }
    for (NSString *name in [set[@"remove_headers"] isKindOfClass:NSArray.class] ? set[@"remove_headers"] : @[]) {
        if ([name isKindOfClass:NSString.class]) [mutable setValue:nil forHTTPHeaderField:name];
    }
    NSString *bodyBase64 = set[@"body_base64"];
    NSString *bodyText = set[@"body"];
    if ([bodyBase64 isKindOfClass:NSString.class] && bodyBase64.length) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:bodyBase64 options:0];
        if (data) mutable.HTTPBody = data;
    } else if ([bodyText isKindOfClass:NSString.class]) {
        // 显式传空串表示"把 body 清空"，和"没传这个字段"是两件事，
        // 所以这里不做长度判断。
        mutable.HTTPBody = [bodyText dataUsingEncoding:NSUTF8StringEncoding];
    }
    return mutable.copy;
}

#pragma mark - 断点：挂起与决策

// 断点会阻塞调用线程。两条铁律：
//   1. 主线程永不阻塞——很多 App 在建任务的同一个 runloop 里等结果，
//      阻塞主线程等于直接死锁。主线程上命中 hold 时直接放行并标注。
//   2. 一定超时。调用方没有义务配合我们调试，15 秒还没决策就放行。

- (NSURLRequest *)holdRequest:(NSURLRequest *)request rule:(NSDictionary *)rule {
    if (NSThread.isMainThread) {
        [self noteHoldSkipped:rule reason:@"主线程不阻塞，已自动放行"];
        return request;
    }
    NXPending *pending = [NXPending new];
    pending.request = request;
    pending.ruleId = rule[@"id"] ?: @"";
    pending.createdAtNs = NXNowNs();
    pending.ident = [NSString stringWithFormat:@"h%llu", (unsigned long long)pending.createdAtNs];
    os_unfair_lock_lock(&_lock);
    [_pending addObject:pending];
    os_unfair_lock_unlock(&_lock);

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:NXHoldTimeout];
    [_holdCondition lock];
    while (!pending.resolved) {
        if (![_holdCondition waitUntilDate:deadline]) break;
    }
    BOOL resolved = pending.resolved;
    NSString *decision = pending.decision;
    NSURLRequest *modified = pending.modifiedRequest;
    [_holdCondition unlock];

    os_unfair_lock_lock(&_lock);
    [_pending removeObject:pending];
    os_unfair_lock_unlock(&_lock);

    if (!resolved) return request;              // 超时：原样放行
    if ([decision isEqual:@"drop"]) return nil; // 丢弃
    if ([decision isEqual:@"modify"] && modified) return modified;
    return request;
}

- (void)noteHoldSkipped:(NSDictionary *)rule reason:(NSString *)reason {
    NXRecord *record = [NXRecord new];
    record.layer = @"hold";
    record.kind = @"meta";
    record.note = [NSString stringWithFormat:@"规则 %@ 的断点未生效：%@", rule[@"id"] ?: @"?", reason];
    record.finished = YES;
    record.endedNs = NXNowNs();
    [self appendRecord:record];
}

- (BOOL)resolvePendingIdent:(NSString *)ident
                   decision:(NSString *)decision
                    request:(NSURLRequest *)request
                      error:(NSString **)error {
    os_unfair_lock_lock(&_lock);
    NXPending *found = nil;
    for (NXPending *item in _pending) if ([item.ident isEqual:ident]) { found = item; break; }
    os_unfair_lock_unlock(&_lock);
    if (!found) {
        if (error) *error = [NSString stringWithFormat:@"找不到挂起的请求：%@（可能已超时放行）", ident ?: @""];
        return NO;
    }
    [_holdCondition lock];
    found.decision = decision;
    found.modifiedRequest = request;
    found.resolved = YES;
    [_holdCondition broadcast];
    [_holdCondition unlock];
    return YES;
}

#pragma mark - 请求预处理（记录 + 改写 + 断点）

// 所有 hook 入口共用这一条路径，保证规则语义一致：
//   drop  → 返回 nil，调用方拿到 nil 任务
//   hold  → 阻塞等决策
//   rewrite → 换 request
// 无论走哪条，记录都在改写之后建立，所以详情里看到的就是真正发出去的请求。
- (NSURLRequest *)prepareRequest:(NSURLRequest *)request
                           layer:(NSString *)layer
                      requestBody:(NSData *)explicitBody
                       recordOut:(NXRecord **)recordOut {
    if (!request) return nil;
    NSDictionary *rule = [self firstRuleForRequest:request];
    NSString *action = rule[@"action"] ?: @"";
    NSURLRequest *effective = request;

    if (rule && [action isEqual:@"rewrite"]) {
        effective = [self applyRewrite:rule[@"set"] toRequest:request];
    } else if (rule && [action isEqual:@"hold"]) {
        NSURLRequest *held = [self holdRequest:request rule:rule];
        if (!held) {
            NXRecord *dropped = [NXRecord new];
            dropped.layer = layer;
            dropped.kind = @"http";
            dropped.method = request.HTTPMethod ?: @"GET";
            dropped.url = request.URL.absoluteString ?: @"";
            dropped.host = request.URL.host ?: @"";
            dropped.path = request.URL.path ?: @"";
            dropped.requestHeaders = request.allHTTPHeaderFields ?: @{};
            dropped.rule = rule[@"id"];
            dropped.note = @"被规则 drop，请求未发出（调用方会拿到 nil 任务）";
            dropped.finished = YES;
            dropped.error = @"dropped by rule";
            dropped.endedNs = NXNowNs();
            [self appendRecord:dropped];
            if (recordOut) *recordOut = dropped;
            return nil;
        }
        effective = held;
        if (![held isEqual:request]) effective = held;   // 决策为 modify
    } else if (rule && [action isEqual:@"drop"]) {
        NXRecord *dropped = [NXRecord new];
        dropped.layer = layer;
        dropped.kind = @"http";
        dropped.method = request.HTTPMethod ?: @"GET";
        dropped.url = request.URL.absoluteString ?: @"";
        dropped.host = request.URL.host ?: @"";
        dropped.path = request.URL.path ?: @"";
        dropped.requestHeaders = request.allHTTPHeaderFields ?: @{};
        dropped.rule = rule[@"id"];
        dropped.note = @"被规则 drop，请求未发出（调用方会拿到 nil 任务）";
        dropped.finished = YES;
        dropped.error = @"dropped by rule";
        dropped.endedNs = NXNowNs();
        [self appendRecord:dropped];
        if (recordOut) *recordOut = dropped;
        return nil;
    }

    NXRecord *record = [NXRecord new];
    record.layer = layer;
    record.kind = @"http";
    record.method = effective.HTTPMethod ?: @"GET";
    record.url = effective.URL.absoluteString ?: @"";
    record.host = effective.URL.host ?: @"";
    record.path = effective.URL.path ?: @"";
    record.requestHeaders = effective.allHTTPHeaderFields ?: @{};
    if (rule) record.rule = rule[@"id"];

    // body 来源三选一，优先级从高到低：
    //   1. 调用方显式传入（upload 的 fromData，最准）
    //   2. request.HTTPBody（建任务那一刻的快照）
    //   3. HTTPBodyStream —— 流只能被消费一次，这里绝不读它（读掉就等于
    //      把请求体从 App 手里偷走了）。如实标注拿不到，不假装空 body。
    NSData *body = explicitBody ?: effective.HTTPBody;
    if (body.length) {
        if (body.length > NXBodyStoreMax) {
            record.requestBody = [body subdataWithRange:NSMakeRange(0, NXBodyStoreMax)];
            record.requestBodyTruncated = YES;
        } else {
            record.requestBody = body;
        }
        record.requestBytes = body.length;
    } else if (effective.HTTPBodyStream) {
        record.requestBodyFromStream = YES;
        record.note = @"请求体由 HTTPBodyStream 承载，抓不到（读流会破坏 App 的请求）；"
                       @"如需完整 body，改用 App 内其它路径或对该接口做 compose 复现。";
        NSString *length = record.requestHeaders[@"Content-Length"] ?: record.requestHeaders[@"content-length"];
        if (length.length) record.requestBytes = (NSUInteger)length.integerValue;
    } else {
        record.requestBytes = 0;
    }

    // 主动发出的请求同样会被自己的 hook 记录。打标区分，否则 AI 会把
    // 重放流量当成 App 的真实行为去反推业务逻辑。
    if ([NSThread.currentThread.threadDictionary[@"AiFlex3Replay"] boolValue]) {
        record.note = [record.note stringByAppendingString:
                       @" [本条由 aiflex_net_action 的 replay / compose 主动发出，不是 App 自己的请求]"];
    }

    NSString *ident = [self appendRecord:record];
    if (recordOut) *recordOut = record;
    // ident 由 appendRecord 写入，record.ident 已就绪；调用方用 record.ident 关联。
    (void)ident;
    return effective;
}

@end

// swizzle 助手：原方法可能定义在父类上，这时 class_getInstanceMethod 能拿到
// Method，但直接 method_exchangeImplementations 会改错地方，必须先试 addMethod。
static void NXSwizzleInstance(Class cls, SEL original, SEL replacement, BOOL *ok) {
    Method from = class_getInstanceMethod(cls, original);
    Method to = class_getInstanceMethod(cls, replacement);
    if (!from || !to) { if (ok) *ok = NO; return; }
    BOOL added = class_addMethod(cls, original,
                                 method_getImplementation(to),
                                 method_getTypeEncoding(to));
    if (added) {
        class_replaceMethod(cls, replacement,
                            method_getImplementation(from),
                            method_getTypeEncoding(from));
    } else {
        method_exchangeImplementations(from, to);
    }
    if (ok) *ok = YES;
}

@implementation FLEXAiFlexNet

#pragma mark - 安装 hook

- (void)installHooksIfNeeded {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self installURLSessionHooks];
        [self installWebSocketHooks];
        if ([self captureTLS]) [self installTLSHooks];
        if ([self captureSocket]) [self installSocketHooks];
        _hooksInstalled = YES;
    });
}

#pragma mark - 响应改写

// 响应改写只能走 completionHandler 路径——delegate 路径的数据是系统逐块喂给
// delegate 的，中间插一层就得替 App 实现整个 delegate，风险远大于收益。
// 所以这里明确只处理 block 回调的请求，delegate 路径在记录里标注没改。
- (NSData *)rewriteResponseData:(NSData *)data
                       response:(NSURLResponse **)responsePtr
                          rule:(NSDictionary *)rule {
    NSDictionary *set = rule[@"set"];
    if (![set isKindOfClass:NSDictionary.class]) return data;
    id bodyText = set[@"response_body"];
    id bodyBase64 = set[@"response_body_base64"];
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)*responsePtr;
    if (![bodyText isKindOfClass:NSString.class] && ![bodyBase64 isKindOfClass:NSString.class] && !set[@"status"]) return data;

    NSMutableDictionary *headers = [http.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
    NSData *newData = data;
    if ([bodyBase64 isKindOfClass:NSString.class] && [bodyBase64 length]) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:bodyBase64 options:0];
        if (decoded) newData = decoded;
    } else if ([bodyText isKindOfClass:NSString.class]) {
        newData = [bodyText dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (newData != data) {
        // 长度变了必须同步 Content-Length，否则 NSURLSession 的上层解析会错位。
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)newData.length];
        [headers removeObjectForKey:@"Content-Encoding"];   // 原文可能被 gzip 过，改写后不再成立
    }
    NSInteger status = set[@"status"] ? [set[@"status"] integerValue] : http.statusCode;
    NSURL *url = http.URL ?: [NSURL URLWithString:@"about:blank"];
    NSHTTPURLResponse *replaced = [[NSHTTPURLResponse alloc] initWithURL:url
                                                            statusCode:status
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:headers];
    if (replaced) *responsePtr = replaced;
    return newData ?: NSData.data;
}

@end

#pragma mark - NSURLSession hook

@interface NSURLSession (AiFlex3NetHook)
- (NSURLSessionDataTask *)nx_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionDataTask *)nx_dataTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionUploadTask *)nx_uploadTaskWithRequest:(NSURLRequest *)request
                                            fromData:(NSData *)bodyData
                                   completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionUploadTask *)nx_uploadTaskWithRequest:(NSURLRequest *)request
                                            fromFile:(NSURL *)fileURL
                                   completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionDownloadTask *)nx_downloadTaskWithRequest:(NSURLRequest *)request
                                       completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler;
- (NSURLSessionDownloadTask *)nx_downloadTaskWithRequest:(NSURLRequest *)request;
@end

static const void *NXTaskIdentKey = &NXTaskIdentKey;

@implementation NSURLSession (AiFlex3NetHook)

- (NSURLSessionDataTask *)nx_dataTaskWithRequest:(NSURLRequest *)request
                               completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureNSURL) return [self nx_dataTaskWithRequest:request completionHandler:completionHandler];

    NSDictionary *rule = [engine firstRuleForRequest:request];
    NXRecord *record = nil;
    NSURLRequest *effective = [engine prepareRequest:request layer:@"nsurl" requestBody:nil recordOut:&record];
    if (!effective) return nil;   // 被规则 drop

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = nil;
    if (completionHandler) {
        NSString *ident = record.ident;
        wrapped = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *finalData = data;
            NSURLResponse *finalResponse = response;
            if (rule && [rule[@"action"] isEqual:@"rewrite"]) {
                finalData = [engine rewriteResponseData:data response:&finalResponse rule:rule];
            }
            [engine finishRecordIdent:ident data:finalData response:finalResponse error:error];
            completionHandler(finalData, finalResponse, error);
        };
    } else if (record) {
        record.note = [record.note stringByAppendingString:
                       @" 走 delegate 回调路径：本记录只有请求侧，响应体请看 FLEX 自己的网络记录。"];
    }

    NSURLSessionDataTask *task = [self nx_dataTaskWithRequest:effective completionHandler:wrapped];
    if (record.ident) objc_setAssociatedObject(task, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return task;
}

- (NSURLSessionDataTask *)nx_dataTaskWithRequest:(NSURLRequest *)request {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureNSURL) return [self nx_dataTaskWithRequest:request];
    NXRecord *record = nil;
    NSURLRequest *effective = [engine prepareRequest:request layer:@"nsurl" requestBody:nil recordOut:&record];
    if (!effective) return nil;
    NSURLSessionDataTask *task = [self nx_dataTaskWithRequest:effective];
    if (record.ident) objc_setAssociatedObject(task, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return task;
}

- (NSURLSessionUploadTask *)nx_uploadTaskWithRequest:(NSURLRequest *)request
                                            fromData:(NSData *)bodyData
                                   completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureNSURL) return [self nx_uploadTaskWithRequest:request fromData:bodyData completionHandler:completionHandler];

    NSDictionary *rule = [engine firstRuleForRequest:request];
    NXRecord *record = nil;
    // fromData 是最可靠的 body 来源：request.HTTPBody 在 upload 场景里经常是 nil。
    NSURLRequest *effective = [engine prepareRequest:request layer:@"nsurl" requestBody:bodyData recordOut:&record];
    if (!effective) return nil;

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = nil;
    if (completionHandler) {
        NSString *ident = record.ident;
        wrapped = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *finalData = data;
            NSURLResponse *finalResponse = response;
            if (rule && [rule[@"action"] isEqual:@"rewrite"]) {
                finalData = [engine rewriteResponseData:data response:&finalResponse rule:rule];
            }
            [engine finishRecordIdent:ident data:finalData response:finalResponse error:error];
            completionHandler(finalData, finalResponse, error);
        };
    }
    NSURLSessionUploadTask *task = [self nx_uploadTaskWithRequest:effective fromData:bodyData completionHandler:wrapped];
    if (record.ident) objc_setAssociatedObject(task, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return task;
}

- (NSURLSessionUploadTask *)nx_uploadTaskWithRequest:(NSURLRequest *)request
                                            fromFile:(NSURL *)fileURL
                                   completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureNSURL) return [self nx_uploadTaskWithRequest:request fromFile:fileURL completionHandler:completionHandler];

    NSDictionary *rule = [engine firstRuleForRequest:request];
    // 上传文件只读前 64 KiB 做样本：整个文件可能有几百 MB，读进来会直接 OOM。
    NSData *sample = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:fileURL.path ?: @""];
    if (handle) {
        NSData *head = [handle readDataOfLength:NXBodyStoreMax];
        [handle closeFile];
        sample = head;
    }
    NXRecord *record = nil;
    NSURLRequest *effective = [engine prepareRequest:request layer:@"nsurl" requestBody:sample recordOut:&record];
    if (!effective) return nil;
    if (sample && record) {
        unsigned long long total = [[[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path ?: @""
                                                                                    error:nil] fileSize];
        record.requestBytes = (NSUInteger)total;
        if (total > sample.length) record.requestBodyTruncated = YES;
        record.note = [record.note stringByAppendingFormat:
                       @" 上传文件 %@（%llu 字节），body 只保留前 %lu 字节。",
                       fileURL.lastPathComponent ?: @"?", total, (unsigned long)sample.length];
    }

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = nil;
    if (completionHandler) {
        NSString *ident = record.ident;
        wrapped = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSURLResponse *finalResponse = response;
            NSData *finalData = data;
            if (rule && [rule[@"action"] isEqual:@"rewrite"]) {
                finalData = [engine rewriteResponseData:data response:&finalResponse rule:rule];
            }
            [engine finishRecordIdent:ident data:finalData response:finalResponse error:error];
            completionHandler(finalData, finalResponse, error);
        };
    }
    NSURLSessionUploadTask *task = [self nx_uploadTaskWithRequest:effective fromFile:fileURL completionHandler:wrapped];
    if (record.ident) objc_setAssociatedObject(task, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return task;
}

- (NSURLSessionDownloadTask *)nx_downloadTaskWithRequest:(NSURLRequest *)request
                                       completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completionHandler {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureNSURL) return [self nx_downloadTaskWithRequest:request completionHandler:completionHandler];

    NXRecord *record = nil;
    NSURLRequest *effective = [engine prepareRequest:request layer:@"nsurl" requestBody:nil recordOut:&record];
    if (!effective) return nil;

    void (^wrapped)(NSURL *, NSURLResponse *, NSError *) = nil;
    if (completionHandler) {
        NSString *ident = record.ident;
        wrapped = ^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSData *preview = nil;
            if (location.path.length) {
                NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:location.path];
                if (handle) {
                    preview = [handle readDataOfLength:NXBodyStoreMax];
                    [handle closeFile];
                }
            }
            [engine finishRecordIdent:ident data:preview response:response error:error];
            if (preview) {
                NXRecord *saved = [engine recordForIdent:ident];
                if (saved) {
                    saved.note = [saved.note stringByAppendingFormat:
                                  @" 下载任务落地文件 %@，响应体只保留前 %lu 字节预览。",
                                  location.lastPathComponent ?: @"?", (unsigned long)preview.length];
                }
            }
            completionHandler(location, response, error);
        };
    }
    NSURLSessionDownloadTask *task = [self nx_downloadTaskWithRequest:effective completionHandler:wrapped];
    if (record.ident) objc_setAssociatedObject(task, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return task;
}

- (NSURLSessionDownloadTask *)nx_downloadTaskWithRequest:(NSURLRequest *)request {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureNSURL) return [self nx_downloadTaskWithRequest:request];
    NXRecord *record = nil;
    NSURLRequest *effective = [engine prepareRequest:request layer:@"nsurl" requestBody:nil recordOut:&record];
    if (!effective) return nil;
    NSURLSessionDownloadTask *task = [self nx_downloadTaskWithRequest:effective];
    if (record.ident) objc_setAssociatedObject(task, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return task;
}

@end

@interface NSURLSessionTask (AiFlex3NetHook)
- (void)nx_resume;
@end

@implementation NSURLSessionTask (AiFlex3NetHook)

// resume 是最后的兜底：App 可能通过 NSURLSession 的便利方法之外的方式造任务
// （比如从 background session 恢复），那些任务没经过上面的创建方法。
// 已经关联过 ident 的直接放过，不重复记录。
- (void)nx_resume {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    NSString *existing = objc_getAssociatedObject(self, NXTaskIdentKey);
    if (!existing && engine.captureNSURL && self.originalRequest) {
        NXRecord *record = nil;
        [engine prepareRequest:self.originalRequest layer:@"nsurl-delegate" requestBody:nil recordOut:&record];
        if (record) {
            // prepareRequest 已经把记录追加进去了，这里只补一句来源说明。
            [engine markDelegatePathForIdent:record.ident];
            objc_setAssociatedObject(self, NXTaskIdentKey, record.ident, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
    [self nx_resume];
}

@end

@implementation FLEXAiFlexNet

- (void)markDelegatePathForIdent:(NSString *)ident {
    NXRecord *record = [self recordForIdent:ident];
    if (!record) return;
    if ([record.note rangeOfString:@"delegate"].location != NSNotFound) return;
    record.note = [record.note stringByAppendingString:
                   @" 由 resume 兜底记录，只有请求侧；响应体由 FLEX 记录提供。"];
}

- (void)installURLSessionHooks {
    Class session = NSClassFromString(@"NSURLSession");
    BOOL ok = NO;
    NXSwizzleInstance(session, @selector(dataTaskWithRequest:completionHandler:),
                      @selector(nx_dataTaskWithRequest:completionHandler:), &ok);
    NXSwizzleInstance(session, @selector(dataTaskWithRequest:),
                      @selector(nx_dataTaskWithRequest:), &ok);
    NXSwizzleInstance(session, @selector(uploadTaskWithRequest:fromData:completionHandler:),
                      @selector(nx_uploadTaskWithRequest:fromData:completionHandler:), &ok);
    NXSwizzleInstance(session, @selector(uploadTaskWithRequest:fromFile:completionHandler:),
                      @selector(nx_uploadTaskWithRequest:fromFile:completionHandler:), &ok);
    NXSwizzleInstance(session, @selector(downloadTaskWithRequest:completionHandler:),
                      @selector(nx_downloadTaskWithRequest:completionHandler:), &ok);
    NXSwizzleInstance(session, @selector(downloadTaskWithRequest:),
                      @selector(nx_downloadTaskWithRequest:), &ok);
    NXSwizzleInstance(NSClassFromString(@"NSURLSessionTask"), @selector(resume),
                      @selector(nx_resume), &ok);
}

@end

#pragma mark - WebSocket hook

@interface NSURLSessionWebSocketTask (AiFlex3NetHook)
- (void)nx_sendMessage:(id)message completionHandler:(void (^)(NSError *error))completionHandler;
- (void)nx_receiveMessageWithCompletionHandler:(void (^)(id message, NSError *error))completionHandler;
@end

@implementation NSURLSessionWebSocketTask (AiFlex3NetHook)

- (void)nx_sendMessage:(id)message completionHandler:(void (^)(NSError *))completionHandler {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (engine.captureWS) [engine recordWebSocketMessage:message outgoing:YES url:self.originalRequest.URL];
    [self nx_sendMessage:message completionHandler:completionHandler];
}

- (void)nx_receiveMessageWithCompletionHandler:(void (^)(id, NSError *))completionHandler {
    FLEXAiFlexNet *engine = [FLEXAiFlexNet sharedEngine];
    if (!engine.captureWS) {
        [self nx_receiveMessageWithCompletionHandler:completionHandler];
        return;
    }
    NSURL *url = self.originalRequest.URL;
    [self nx_receiveMessageWithCompletionHandler:^(id message, NSError *error) {
        if (message) [engine recordWebSocketMessage:message outgoing:NO url:url];
        if (completionHandler) completionHandler(message, error);
    }];
}

@end

@implementation FLEXAiFlexNet (WebSocketRecord)

- (void)recordWebSocketMessage:(id)message outgoing:(BOOL)outgoing url:(NSURL *)url {
    if (!message) return;
    NXRecord *record = [NXRecord new];
    record.layer = @"ws";
    record.kind = @"ws";
    record.method = outgoing ? @"WS_SEND" : @"WS_RECV";
    record.url = url.absoluteString ?: @"";
    record.host = url.host ?: @"";
    record.path = url.path ?: @"";
    record.requestHeaders = @{@"Upgrade": @"websocket"};

    // NSURLSessionWebSocketMessage 只有两种载荷：data 或 string。
    // 用 KVC 取是为了不把 WebSocket 相关符号拉进编译单元（iOS 15 以下没有这个类，
    // 直接写属性访问会在弱链接时炸）。
    id typeValue = [message valueForKey:@"type"];
    NSInteger type = [typeValue respondsToSelector:@selector(integerValue)] ? [typeValue integerValue] : 0;
    NSData *payload = nil;
    if (type == 0) {
        payload = [message valueForKey:@"data"];
        if (![payload isKindOfClass:NSData.class]) payload = nil;
    } else {
        NSString *text = [message valueForKey:@"string"];
        if ([text isKindOfClass:NSString.class]) payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (payload.length > NXBodyStoreMax) {
        payload = [payload subdataWithRange:NSMakeRange(0, NXBodyStoreMax)];
        record.requestBodyTruncated = YES;
    }
    if (outgoing) {
        record.requestBody = payload;
        record.requestBytes = payload.length;
    } else {
        record.responseBody = payload;
        record.responseBytes = payload.length;
    }
    record.note = @"WebSocket 帧（明文），一个方向一条记录。";
    record.finished = YES;
    record.endedNs = NXNowNs();
    [self appendRecord:record];
}

- (void)installWebSocketHooks {
    Class task = NSClassFromString(@"NSURLSessionWebSocketTask");
    if (!task) return;   // iOS 15 以下没有这个类，静默跳过
    BOOL ok = NO;
    NXSwizzleInstance(task, @selector(sendMessage:completionHandler:),
                      @selector(nx_sendMessage:completionHandler:), &ok);
    NXSwizzleInstance(task, @selector(receiveMessageWithCompletionHandler:),
                      @selector(nx_receiveMessageWithCompletionHandler:), &ok);
}

@end

#pragma mark - TLS fishhook 符号表

// 原始函数指针必须在使用之前定义：installTLSHooks 里要取它们的地址作为
// rebinding 的输出位置。函数实体放在文件末尾，避免这里被上百行 C 代码打断节奏。
typedef int (*NXOpenSSLWriteFn)(void *, const void *, int);
typedef int (*NXOpenSSLWriteExFn)(void *, const void *, size_t, size_t *);
typedef int (*NXOpenSSLReadFn)(void *, void *, int);
typedef int (*NXOpenSSLReadExFn)(void *, void *, size_t, size_t *);
typedef OSStatus (*NXSTWriteFn)(void *, const void *, size_t, size_t *);
typedef OSStatus (*NXSTReadFn)(void *, void *, size_t, size_t *);

static NXOpenSSLWriteFn orig_SSL_write;
static NXOpenSSLWriteExFn orig_SSL_write_ex;
static NXOpenSSLReadFn orig_SSL_read;
static NXOpenSSLReadExFn orig_SSL_read_ex;
static NXSTWriteFn orig_SSLWrite;
static NXSTReadFn orig_SSLRead;

static int nx_SSL_write(void *ssl, const void *buf, int num);
static int nx_SSL_write_ex(void *ssl, const void *buf, size_t num, size_t *written);
static int nx_SSL_read(void *ssl, void *buf, int num);
static int nx_SSL_read_ex(void *ssl, void *buf, size_t num, size_t *readbytes);
static OSStatus nx_SSLWrite(void *ctx, const void *data, size_t len, size_t *written);
static OSStatus nx_SSLRead(void *ctx, void *data, size_t len, size_t *read);

#pragma mark - TLS 明文重组

// 这一层是「自带 TLS 栈 App 的唯一可读入口」。BoringSSL / SecureTransport 解密后
// 的明文都会经过 SSL_write / SSL_read，所以在这里能拿到完整 HTTP 报文。
//
// 但它拿到的是字节流，不是消息：一个 write 可能是半个 header，也可能三条请求粘在
// 一起。所以必须做按连接、按方向的重组，否则记录会碎成一堆无意义的片段。

@interface NXTLSSession : NSObject
@property (nonatomic) uint64_t key;
@property (nonatomic, strong) NSMutableData *incoming;
@property (nonatomic, strong) NSMutableData *outgoing;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *layer;
@end

@implementation NXTLSSession
- (instancetype)init {
    if ((self = [super init])) {
        _incoming = [NSMutableData data];
        _outgoing = [NSMutableData data];
    }
    return self;
}
@end

// 解析结果：一条完整的 HTTP 报文。
@interface NXHTTPMessage : NSObject
@property (nonatomic, copy) NSString *firstLine;
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, strong) NSData *body;
@property (nonatomic) BOOL truncated;
@property (nonatomic) BOOL incomplete;
@property (nonatomic) NSUInteger consumed;
@end

@implementation NXHTTPMessage
@end

// TLS 连接表：key 是 SSL* / SSLContextRef 指针。放这里而不是放进
// category 实现里——C 静态变量只能定义在文件作用域。
static NSMutableDictionary<NSNumber *, NXTLSSession *> *gNXTLSSessions;
static os_unfair_lock gNXTLSLock = OS_UNFAIR_LOCK_INIT;

@implementation FLEXAiFlexNet (TLS)

- (NXTLSSession *)tlsSessionForContext:(const void *)context layer:(NSString *)layer {
    uint64_t key = (uint64_t)(uintptr_t)context;
    if (!key) return nil;
    NSNumber *boxed = @(key);
    if (!gNXTLSSessions) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ gNXTLSSessions = [NSMutableDictionary dictionary]; });
    }
    os_unfair_lock_lock(&gNXTLSLock);
    NXTLSSession *session = gNXTLSSessions[boxed];
    if (!session) {
        // 连接数上限。超过就整体丢弃最旧的一半，避免长时间运行后字典无限增长。
        if (gNXTLSSessions.count > 64) [gNXTLSSessions removeAllObjects];
        session = [NXTLSSession new];
        session.key = key;
        session.layer = layer;
        gNXTLSSessions[boxed] = session;
    }
    os_unfair_lock_unlock(&gNXTLSLock);
    return session;
}

- (NSString *)tlsHostForContext:(const void *)context session:(NXTLSSession *)session {
    if (session.host.length) return session.host;
    NSString *host = nil;
    if ([session.layer isEqual:@"openssl"]) {
        // OpenSSL / BoringSSL 的 SNI 读取。符号可能不存在（部分裁剪版），
        // dlsym 拿不到就放弃，不影响其它字段。
        typedef const char *(*NXGetServerNameFn)(const void *, int);
        static NXGetServerNameFn getServerName;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            getServerName = (NXGetServerNameFn)dlsym(RTLD_DEFAULT, "SSL_get_servername");
            if (!getServerName) getServerName = (NXGetServerNameFn)dlsym(RTLD_DEFAULT, "SSL_get_servername_type");
        });
        if (getServerName) {
            const char *name = getServerName(context, 0);   // TLSEXT_NAMETYPE_host_name = 0
            if (name) host = [NSString stringWithUTF8String:name];
        }
    } else {
        typedef OSStatus (*NXPeerDomainFn)(void *, char *, size_t *);
        static NXPeerDomainFn peerDomain;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ peerDomain = (NXPeerDomainFn)dlsym(RTLD_DEFAULT, "SSLGetPeerDomainName"); });
        if (peerDomain) {
            char buffer[256] = {0};
            size_t length = sizeof(buffer);
            if (peerDomain((void *)context, buffer, &length) == 0 && length) {
                host = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
            }
        }
    }
    session.host = host ?: @"";
    return session.host;
}

// 从字节流里切出一条完整报文。切不出来（数据还不够）就返回 incomplete=YES，
// 并把已消费字节数留在 consumed 里——通常是 0，表示原样等待更多数据。
- (NXHTTPMessage *)nextMessageFrom:(NSData *)stream outgoing:(BOOL)outgoing {
    const uint8_t *bytes = stream.bytes;
    NSUInteger length = stream.length;
    if (length < 5) return nil;

    // 头部结束标记 \r\n\r\n
    NSRange headerEnd = [stream rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                                    options:0
                                      range:NSMakeRange(0, length)];
    if (headerEnd.location == NSNotFound) {
        if (length > 64 * 1024) {
            // 头部超过 64 KiB 仍然没有结束标记，说明这条流不是 HTTP（或者已经被
            // 中间件破坏）。整段丢弃，避免缓冲无限增长。
            NXHTTPMessage *garbage = [NXHTTPMessage new];
            garbage.incomplete = NO;
            garbage.consumed = length;
            garbage.firstLine = @"<非 HTTP 数据，已丢弃>";
            return garbage;
        }
        return nil;
    }

    NSUInteger bodyStart = headerEnd.location + 4;
    NSString *headText = [[NSString alloc] initWithBytes:bytes length:headerEnd.location encoding:NSUTF8StringEncoding];
    if (!headText) {
        NXHTTPMessage *binary = [NXHTTPMessage new];
        binary.consumed = bodyStart;   // 丢掉这段头，继续往下找
        binary.firstLine = @"<非 UTF-8 头>";
        return binary;
    }

    NSArray<NSString *> *lines = [headText componentsSeparatedByString:@"\r\n"];
    NSString *firstLine = lines.firstObject ?: @"";
    // 首行必须是 HTTP 请求行或状态行，否则这不是 HTTP 流量（可能是
    // 自定义二进制协议跑在 TLS 上）。
    BOOL looksHTTP = outgoing
        ? ([firstLine containsString:@" HTTP/1."] || [firstLine hasPrefix:@"GET "] ||
           [firstLine hasPrefix:@"POST "] || [firstLine hasPrefix:@"PUT "] ||
           [firstLine hasPrefix:@"HEAD "] || [firstLine hasPrefix:@"DELETE "] ||
           [firstLine hasPrefix:@"OPTIONS "] || [firstLine hasPrefix:@"PATCH "])
        : [firstLine hasPrefix:@"HTTP/1."];
    if (!looksHTTP) {
        NXHTTPMessage *other = [NXHTTPMessage new];
        other.consumed = bodyStart;
        other.firstLine = NXShort(firstLine, 120);
        return other;
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length) headers[name] = value;
    }

    NSString *transferEncoding = headers[@"Transfer-Encoding"] ?: headers[@"transfer-encoding"] ?: @"";
    NSString *contentLengthText = headers[@"Content-Length"] ?: headers[@"content-length"];
    BOOL chunked = [transferEncoding.lowercaseString containsString:@"chunked"];

    NXHTTPMessage *message = [NXHTTPMessage new];
    message.firstLine = firstLine;
    message.headers = headers;

    if (chunked) {
        NSUInteger cursor = bodyStart;
        NSMutableData *decoded = [NSMutableData data];
        BOOL done = NO;
        while (cursor < length) {
            NSRange lineBreak = [stream rangeOfData:[NSData dataWithBytes:"\r\n" length:2]
                                            options:0
                                              range:NSMakeRange(cursor, length - cursor)];
            if (lineBreak.location == NSNotFound) break;
            NSString *sizeLine = [[NSString alloc] initWithBytes:bytes + cursor
                                                          length:lineBreak.location - cursor
                                                        encoding:NSUTF8StringEncoding];
            // chunk 扩展（;xxx）要切掉，只取十六进制长度
            NSRange semi = [sizeLine rangeOfString:@";"];
            if (semi.location != NSNotFound) sizeLine = [sizeLine substringToIndex:semi.location];
            unsigned long long chunkSize = 0;
            if (![[NSScanner scannerWithString:sizeLine] scanHexLongLong:&chunkSize]) break;
            cursor = lineBreak.location + 2;
            if (chunkSize == 0) {
                // 结束块后面可能跟 trailer，跳过直到空行
                NSRange tail = [stream rangeOfData:[NSData dataWithBytes:"\r\n" length:2]
                                           options:0
                                             range:NSMakeRange(cursor, length - cursor)];
                cursor = tail.location == NSNotFound ? length : tail.location + 2;
                done = YES;
                break;
            }
            if (cursor + chunkSize + 2 > length) break;
            if (decoded.length < NXBodyStoreMax) {
                NSUInteger take = MIN((NSUInteger)chunkSize, NXBodyStoreMax - decoded.length);
                [decoded appendBytes:bytes + cursor length:take];
                if (take < chunkSize) message.truncated = YES;
            } else {
                message.truncated = YES;
            }
            cursor += (NSUInteger)chunkSize + 2;
        }
        if (!done) return nil;   // 还没收完，等下一批
        message.body = decoded;
        message.consumed = cursor;
        return message;
    }

    if (contentLengthText.length) {
        unsigned long long declared = strtoull(contentLengthText.UTF8String, NULL, 10);
        if (bodyStart + declared > length) return nil;   // body 没到齐
        NSUInteger take = (NSUInteger)MIN(declared, (unsigned long long)NXBodyStoreMax);
        message.body = [NSData dataWithBytes:bytes + bodyStart length:take];
        if (take < declared) message.truncated = YES;
        message.consumed = bodyStart + (NSUInteger)declared;
        return message;
    }

    // 没有 Content-Length 也没有 chunked：响应通常是 204/304 或 HEAD，
    // 请求通常是 GET。按 0 长度处理，把剩余部分留给下一条报文。
    message.body = NSData.data;
    message.consumed = bodyStart;
    return message;
}

- (void)recordTLSData:(NSData *)data
              context:(const void *)context
             outgoing:(BOOL)outgoing
                layer:(NSString *)layer {
    if (!data.length) return;
    // hook 装上之后无法卸载（改回来风险更大），所以关掉开关只能在这里短路。
    if (![self captureTLS]) return;
    NXTLSSession *session = [self tlsSessionForContext:context layer:layer];
    if (!session) return;
    NSMutableData *buffer = outgoing ? session.outgoing : session.incoming;
    [buffer appendData:data];
    if (buffer.length > NXStreamMax) {
        // 长时间收不到报文边界（比如下载大文件），只保留尾部，
        // 避免把宿主内存吃光。
        [buffer replaceBytesInRange:NSMakeRange(0, buffer.length - NXStreamMax)
                          withBytes:NULL
                             length:0];
    }

    NSUInteger guard = 0;
    while (buffer.length && guard++ < 64) {
        NXHTTPMessage *message = [self nextMessageFrom:buffer outgoing:outgoing];
        if (!message) break;
        if (!message.consumed) break;
        [buffer replaceBytesInRange:NSMakeRange(0, MIN(message.consumed, buffer.length))
                          withBytes:NULL
                             length:0];
        if (!message.firstLine.length) continue;
        if ([message.firstLine hasPrefix:@"<"]) {
            // 非 HTTP 数据：记一条元数据就够，不逐字节回放。
            NXRecord *raw = [NXRecord new];
            raw.layer = layer;
            raw.kind = @"tls-raw";
            raw.note = [NSString stringWithFormat:@"非 HTTP 的 TLS 明文片段（%@，%lu 字节），未解析。",
                        message.firstLine, (unsigned long)message.consumed];
            raw.host = [self tlsHostForContext:context session:session];
            raw.finished = YES;
            raw.endedNs = NXNowNs();
            [self appendRecord:raw];
            continue;
        }

        NXRecord *record = [NXRecord new];
        record.layer = layer;
        record.kind = @"http";
        record.tlsSource = [layer isEqual:@"openssl"]
            ? @"OpenSSL/BoringSSL SSL_write|SSL_read 解密后明文"
            : @"Apple SecureTransport SSLWrite|SSLRead 解密后明文";
        record.host = [self tlsHostForContext:context session:session];

        if (outgoing) {
            NSArray<NSString *> *parts = [message.firstLine componentsSeparatedByString:@" "];
            record.method = parts.count ? parts[0] : @"GET";
            NSString *path = parts.count > 1 ? parts[1] : @"/";
            record.path = path;
            record.url = record.host.length
                ? [NSString stringWithFormat:@"https://%@%@", record.host, path]
                : path;
            record.requestHeaders = message.headers;
            record.requestBody = message.body;
            record.requestBytes = message.body.length;
            record.requestBodyTruncated = message.truncated;
            record.note = @"TLS 层明文（自带 TLS 栈的 App 只能这样看到参数）。";
        } else {
            NSArray<NSString *> *parts = [message.firstLine componentsSeparatedByString:@" "];
            record.method = record.host.length ? record.method : @"";
            record.status = parts.count > 1 ? parts[1].integerValue : 0;
            record.url = record.host.length ? [NSString stringWithFormat:@"https://%@/", record.host] : @"";
            record.responseHeaders = message.headers;
            record.responseBody = message.body;
            record.responseBytes = message.body.length;
            record.responseBodyTruncated = message.truncated;
            record.finished = YES;
            record.note = @"TLS 层响应明文。请求行在另一条记录里，按 host + 时间顺序配对。";
        }
        record.endedNs = NXNowNs();
        [self appendRecord:record];
    }
}

- (void)installTLSHooks {
    // fishhook 只能改「通过符号指针调用」的引用点。App 自带 dylib 内部的
    // 直接调用绕不过去，所以这里遍历所有已加载镜像逐个 rebind；系统镜像跳过，
    // 改系统库内部调用会造成不可预期的全局影响。
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding bindings[] = {
            {"SSL_write",    (void *)nx_SSL_write,    (void **)&orig_SSL_write},
            {"SSL_write_ex", (void *)nx_SSL_write_ex, (void **)&orig_SSL_write_ex},
            {"SSL_read",     (void *)nx_SSL_read,     (void **)&orig_SSL_read},
            {"SSL_read_ex",  (void *)nx_SSL_read_ex,  (void **)&orig_SSL_read_ex},
            {"SSLWrite",     (void *)nx_SSLWrite,     (void **)&orig_SSLWrite},
            {"SSLRead",      (void *)nx_SSLRead,      (void **)&orig_SSLRead},
        };
        size_t count = sizeof(bindings) / sizeof(bindings[0]);
        uint32_t images = _dyld_image_count();
        for (uint32_t i = 0; i < images; i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name) continue;
            if (strstr(name, "/System/") || strstr(name, "/usr/lib/")) continue;
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header) continue;
            flex_rebind_symbols_image((void *)header, bindings, count);
        }
    });
}

@end

#pragma mark - TLS hook 实现

// 三个约束：
//   1. 先进原函数，再按真实返回值记录。失败时 buf 里的内容根本没发出去，
//      记了就是假数据。
//   2. 每次都要 @autoreleasepool：这些函数可能被高频调用，不建池会把
//      autorelease 对象堆到线程池弹出为止。
//   3. 绝不修改数据、绝不返回值篡改。这一层只读。

static void NXForwardTLS(const void *context, const void *buffer, size_t length,
                         BOOL outgoing, NSString *layer) {
    if (!buffer || !length) return;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:buffer length:MIN(length, NXStreamMax)];
        [[FLEXAiFlexNet sharedEngine] recordTLSData:data
                                            context:context
                                           outgoing:outgoing
                                              layer:layer];
    }
}

static int nx_SSL_write(void *ssl, const void *buf, int num) {
    if (!orig_SSL_write) return -1;
    int written = orig_SSL_write(ssl, buf, num);
    if (written > 0) NXForwardTLS(ssl, buf, (size_t)written, YES, @"openssl");
    return written;
}

static int nx_SSL_write_ex(void *ssl, const void *buf, size_t num, size_t *written) {
    if (!orig_SSL_write_ex) return 0;
    int ok = orig_SSL_write_ex(ssl, buf, num, written);
    if (ok == 1 && written && *written > 0) NXForwardTLS(ssl, buf, *written, YES, @"openssl");
    return ok;
}

static int nx_SSL_read(void *ssl, void *buf, int num) {
    if (!orig_SSL_read) return -1;
    int got = orig_SSL_read(ssl, buf, num);
    if (got > 0) NXForwardTLS(ssl, buf, (size_t)got, NO, @"openssl");
    return got;
}

static int nx_SSL_read_ex(void *ssl, void *buf, size_t num, size_t *readbytes) {
    if (!orig_SSL_read_ex) return 0;
    int ok = orig_SSL_read_ex(ssl, buf, num, readbytes);
    if (ok == 1 && readbytes && *readbytes > 0) NXForwardTLS(ssl, buf, *readbytes, NO, @"openssl");
    return ok;
}

static OSStatus nx_SSLWrite(void *ctx, const void *data, size_t len, size_t *written) {
    if (!orig_SSLWrite) return -1;
    OSStatus status = orig_SSLWrite(ctx, data, len, written);
    if (status == 0 && written && *written > 0) NXForwardTLS(ctx, data, *written, YES, @"securetransport");
    return status;
}

static OSStatus nx_SSLRead(void *ctx, void *data, size_t len, size_t *read) {
    if (!orig_SSLRead) return -1;
    OSStatus status = orig_SSLRead(ctx, data, len, read);
    // SecureTransport 读完最后一段会返回 errSSLWouldBlock，但 read 里已经有数据，
    // 这种情况必须照样记，否则尾部报文会丢。
    if (read && *read > 0) NXForwardTLS(ctx, data, *read, NO, @"securetransport");
    return status;
}

#pragma mark - socket hook

// socket 层不做内容解析：绝大多数流量到这里已经是 TLS 密文，记字节没有意义。
// 这里只解决一个 FLEX 完全看不见的问题——「这个 App 到底连了谁」：
//   getaddrinfo  域名 → IP
//   connect      fd → IP:port
//   send         首次见到 0x16 0x03 时解析 ClientHello 里的 SNI
// 所以 SNI 能在不解密的前提下补上「真实域名」，比只看到 IP 有用得多。

typedef struct {
    int fd;
    char host[256];
    char sni[256];
    BOOL used;
} NXSocketSlot;

static NXSocketSlot gNXSockets[96];
static os_unfair_lock gNXSocketLock = OS_UNFAIR_LOCK_INIT;

static int (*orig_connect)(int, const struct sockaddr *, socklen_t);
static ssize_t (*orig_send)(int, const void *, size_t, int);
static int (*orig_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **);

static NXSocketSlot *NXSocketSlotFor(int fd, BOOL create) {
    os_unfair_lock_lock(&gNXSocketLock);
    NXSocketSlot *slot = NULL;
    for (int i = 0; i < 96; i++) {
        if (gNXSockets[i].used && gNXSockets[i].fd == fd) { slot = &gNXSockets[i]; break; }
    }
    if (!slot && create) {
        for (int i = 0; i < 96; i++) {
            if (!gNXSockets[i].used) {
                memset(&gNXSockets[i], 0, sizeof(NXSocketSlot));
                gNXSockets[i].used = YES;
                gNXSockets[i].fd = fd;
                slot = &gNXSockets[i];
                break;
            }
        }
        if (!slot) {   // 表满：整体清空重来，比逐条 LRU 简单且够用
            memset(gNXSockets, 0, sizeof(gNXSockets));
            gNXSockets[0].used = YES;
            gNXSockets[0].fd = fd;
            slot = &gNXSockets[0];
        }
    }
    os_unfair_lock_unlock(&gNXSocketLock);
    return slot;
}

// TLS ClientHello 的 SNI 扩展解析。结构是固定偏移的：
//   record(5) + handshake header(4) + version(2) + random(32) + session_id(1+n)
//   + cipher_suites(2+n) + compression(1+n) + extensions(2+n)
// 任何一处越界都直接放弃，绝不读越界内存。
static NSString *NXParseSNI(const uint8_t *bytes, size_t length) {
    if (length < 48) return nil;
    if (bytes[0] != 0x16 || bytes[1] != 0x03) return nil;   // 只认 TLS handshake
    if (bytes[5] != 0x01) return nil;                        // 只认 ClientHello
    size_t pos = 9;                                          // 跳过 handshake header
    pos += 2;                                                // client version
    pos += 32;                                               // random
    if (pos >= length) return nil;
    pos += 1 + (size_t)bytes[pos];                           // session id
    if (pos + 2 > length) return nil;
    size_t ciphers = ((size_t)bytes[pos] << 8) | bytes[pos + 1];
    pos += 2 + ciphers;
    if (pos >= length) return nil;
    pos += 1 + (size_t)bytes[pos];                           // compression methods
    if (pos + 2 > length) return nil;
    size_t extTotal = ((size_t)bytes[pos] << 8) | bytes[pos + 1];
    pos += 2;
    size_t extEnd = MIN(pos + extTotal, length);
    while (pos + 4 <= extEnd) {
        uint16_t type = (uint16_t)((bytes[pos] << 8) | bytes[pos + 1]);
        uint16_t extLen = (uint16_t)((bytes[pos + 2] << 8) | bytes[pos + 3]);
        pos += 4;
        if (pos + extLen > extEnd) break;
        if (type == 0x0000 && extLen > 5) {
            size_t cursor = pos + 2;                          // server_name_list length
            if (cursor + 3 <= pos + extLen && bytes[cursor] == 0x00) {
                size_t nameLen = ((size_t)bytes[cursor + 1] << 8) | bytes[cursor + 2];
                cursor += 3;
                if (cursor + nameLen <= pos + extLen) {
                    NSString *name = [[NSString alloc] initWithBytes:bytes + cursor
                                                              length:nameLen
                                                            encoding:NSUTF8StringEncoding];
                    if (name.length) return name;
                }
            }
        }
        pos += extLen;
    }
    return nil;
}

static NSString *NXAddressText(const struct sockaddr *address) {
    if (!address) return @"";
    char buffer[INET6_ADDRSTRLEN] = {0};
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        inet_ntop(AF_INET, &v4->sin_addr, buffer, sizeof(buffer));
        return [NSString stringWithFormat:@"%s:%d", buffer, ntohs(v4->sin_port)];
    }
    if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
        inet_ntop(AF_INET6, &v6->sin6_addr, buffer, sizeof(buffer));
        return [NSString stringWithFormat:@"[%s]:%d", buffer, ntohs(v6->sin6_port)];
    }
    return @"";
}

static int nx_connect(int fd, const struct sockaddr *address, socklen_t length) {
    if (!orig_connect) { errno = ENOSYS; return -1; }
    int result = orig_connect(fd, address, length);
    if ([[FLEXAiFlexNet sharedEngine] captureSocket]) {
        NSString *text = NXAddressText(address);
        if (text.length) {
            NXSocketSlot *slot = NXSocketSlotFor(fd, YES);
            if (slot) {
                snprintf(slot->host, sizeof(slot->host), "%s", text.UTF8String);
            }
            [[FLEXAiFlexNet sharedEngine] recordSocketEvent:(result == 0 ? @"connect" : @"connect-failed")
                                                       host:text
                                                       note:(result == 0 ? @"连接建立" : @"连接失败")];
        }
    }
    return result;
}

// 线程局部快路标：同一条 fd 解析出 SNI 后就不再重复走解析。
static _Thread_local int gNXLastSNIFd = -1;
static _Thread_local BOOL gNXLastSNIDone = NO;

static ssize_t nx_send(int fd, const void *buffer, size_t length, int flags) {
    if (!orig_send) { errno = ENOSYS; return -1; }
    // 高频路径上先做两个字节的判断：不是 TLS 握手就完全不碰锁、不碰引擎。
    // 之前这里无条件查表，普通业务 send 每次都要抢一把 os_unfair_lock。
    if (buffer && length > 48 && !(gNXLastSNIDone && gNXLastSNIFd == fd)) {
        const uint8_t *bytes = buffer;
        if (bytes[0] == 0x16 && bytes[1] == 0x03 && [[FLEXAiFlexNet sharedEngine] captureSocket]) {
            NXSocketSlot *slot = NXSocketSlotFor(fd, NO);
            if (slot && !slot->sni[0]) {
                NSString *sni = NXParseSNI(bytes, length);
                if (sni.length) {
                    snprintf(slot->sni, sizeof(slot->sni), "%s", sni.UTF8String);
                    gNXLastSNIFd = fd;
                    gNXLastSNIDone = YES;
                    [[FLEXAiFlexNet sharedEngine] recordSocketEvent:@"tls-hello"
                                                               host:sni
                                                               note:[NSString stringWithFormat:
                                                                     @"从 ClientHello 解析出 SNI（不解密；对端 %s）",
                                                                     slot->host[0] ? slot->host : "?"]];
                }
            }
        }
    }
    return orig_send(fd, buffer, length, flags);
}

static int nx_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **result) {
    if (!orig_getaddrinfo) return EAI_FAIL;
    int status = orig_getaddrinfo(node, service, hints, result);
    if (status == 0 && node && [[FLEXAiFlexNet sharedEngine] captureSocket]) {
        NSString *host = [NSString stringWithUTF8String:node];
        NSString *address = @"";
        if (result && *result) address = NXAddressText((*result)->ai_addr);
        if (host.length) {
            [[FLEXAiFlexNet sharedEngine] recordSocketEvent:@"dns"
                                                       host:host
                                                       note:[NSString stringWithFormat:@"解析到 %@（service=%@）",
                                                             address.length ? address : @"?",
                                                             service ? [NSString stringWithUTF8String:service] : @"-"]];
        }
    }
    return status;
}

@implementation FLEXAiFlexNet

- (void)installSocketHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding bindings[] = {
            {"connect",     (void *)nx_connect,     (void **)&orig_connect},
            {"send",        (void *)nx_send,        (void **)&orig_send},
            {"getaddrinfo", (void *)nx_getaddrinfo, (void **)&orig_getaddrinfo},
        };
        flex_rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    });
}

- (void)recordSocketEvent:(NSString *)kind host:(NSString *)host note:(NSString *)note {
    NXRecord *record = [NXRecord new];
    record.layer = @"socket";
    record.kind = kind ?: @"socket";
    record.host = host ?: @"";
    record.sni = [kind isEqual:@"tls-hello"] ? host : @"";
    record.note = note ?: @"";
    record.finished = YES;
    record.endedNs = NXNowNs();
    [self appendRecord:record];
}

#pragma mark - 规则持久化

// 规则存 Documents/AiFlex3Net/rules.json。放进 Documents 而不是内存的原因：
// 改包规则通常要跨多次启动调试（「先禁掉这个埋点，再复现一次启动流程」），
// 每次重启都重新配一遍不现实。
- (NSString *)rulesDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [documents stringByAppendingPathComponent:@"AiFlex3Net"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

- (void)loadRules {
    NSString *path = [[self rulesDirectory] stringByAppendingPathComponent:NXRulesFile];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:NSArray.class]) return;
    os_unfair_lock_lock(&_lock);
    [_rules addObjectsFromArray:parsed];
    os_unfair_lock_unlock(&_lock);
}

- (void)saveRules {
    os_unfair_lock_lock(&_lock);
    NSArray *copy = _rules.copy;
    os_unfair_lock_unlock(&_lock);
    NSData *data = [NSJSONSerialization dataWithJSONObject:copy
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    [data writeToFile:[[self rulesDirectory] stringByAppendingPathComponent:NXRulesFile] atomically:YES];
}

#pragma mark - 挂起查询

- (NXPending *)pendingForIdent:(NSString *)ident {
    os_unfair_lock_lock(&_lock);
    NXPending *found = nil;
    for (NXPending *item in _pending) if ([item.ident isEqual:ident]) { found = item; break; }
    os_unfair_lock_unlock(&_lock);
    return found;
}

#pragma mark - 统一入口

- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *, NSString *))completion {
    [self installHooksIfNeeded];
    // replay / compose 会同步等网络返回（最长 20 秒）。它们必须离开串行队列，
    // 否则一次超时会把后面所有记录查询全堵住。
    BOOL blocking = [operation isEqual:@"replay"] || [operation isEqual:@"compose"];
    dispatch_queue_t target = blocking
        ? dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
        : _queue;
    dispatch_async(target, ^{
        NSString *error = nil;
        NSDictionary *result = nil;
        @try {
            result = [self performOperation:operation arguments:arguments ?: @{} error:&error];
        } @catch (NSException *exception) {
            error = [NSString stringWithFormat:@"网络引擎异常（%@）", exception.name];
        }
        completion(error.length ? nil : result, error.length ? error : nil);
    });
}

- (NSDictionary *)performOperation:(NSString *)operation
                         arguments:(NSDictionary *)arguments
                             error:(NSString **)error {
    if ([operation isEqual:@"status"]) return [self opStatus];
    if ([operation isEqual:@"list"]) return [self opList:arguments];
    if ([operation isEqual:@"detail"]) return [self opDetail:arguments error:error];
    if ([operation isEqual:@"export"]) return [self opExport:arguments error:error];
    if ([operation isEqual:@"rules"]) return [self opRules];
    if ([operation isEqual:@"pending"]) return [self opPending];
    if ([operation isEqual:@"correlate"]) return [self opCorrelate:arguments error:error];
    if ([operation isEqual:@"clear"]) return [self opClear];
    if ([operation isEqual:@"capture"]) {
        // target 非法时 opCapture 只回一个 error 键，这里要转成工具级失败，
        // 否则 AI 会把 {"error":...} 当成成功结果继续往下走。
        NSDictionary *captured = [self opCapture:arguments];
        if (captured[@"error"]) {
            if (error) *error = captured[@"error"];
            return nil;
        }
        return captured;
    }
    if ([operation isEqual:@"rule_add"]) return [self opRuleAdd:arguments error:error];
    if ([operation isEqual:@"rule_remove"]) return [self opRuleRemove:arguments error:error];
    if ([operation isEqual:@"rule_clear"]) return [self opRuleClear];
    if ([operation isEqual:@"rule_toggle"]) return [self opRuleToggle:arguments error:error];
    if ([operation isEqual:@"decide"]) return [self opDecide:arguments error:error];
    if ([operation isEqual:@"replay"]) return [self opReplay:arguments error:error];
    if ([operation isEqual:@"compose"]) return [self opCompose:arguments error:error];
    if (error) *error = [NSString stringWithFormat:@"未知 operation：%@", operation ?: @""];
    return nil;
}

#pragma mark - 只读 operation

- (NSDictionary *)opStatus {
    NSArray<NXRecord *> *records = [self snapshotRecords];
    NSMutableDictionary *byLayer = [NSMutableDictionary dictionary];
    for (NXRecord *record in records) {
        NSString *key = record.layer ?: @"?";
        byLayer[key] = @([byLayer[key] integerValue] + 1);
    }
    os_unfair_lock_lock(&_lock);
    NSUInteger ruleCount = _rules.count;
    NSUInteger pendingCount = _pending.count;
    NSUInteger bodyBytes = (NSUInteger)_bodyBytes;
    NSUInteger evicted = _droppedRecords;
    os_unfair_lock_unlock(&_lock);
    return @{
        @"available": @YES,
        @"capture": [self captureState],
        @"records": @(records.count),
        @"capacity": @(NXCapacity),
        @"byLayer": byLayer,
        @"rules": @(ruleCount),
        @"pending": @(pendingCount),
        @"evicted": @(evicted),
        @"bodyBytes": @(bodyBytes),
        @"limits": @{@"records": @(NXCapacity),
                     @"bodyStoreBytes": @(NXBodyStoreMax),
                     @"bodyReturnBytes": @(NXBodyReturnMax),
                     @"bodyBudgetBytes": @(NXBodyBudget),
                     @"holdTimeoutSeconds": @(NXHoldTimeout)},
        @"layers": @[@"nsurl", @"nsurl-delegate", @"ws", @"openssl", @"securetransport", @"socket"],
        @"note": @"nsurl 层能拿到全量请求头与请求体（upload 场景取 fromData）；"
                 @"HTTPBodyStream 的请求体抓不到，记录里会明说，不会假装空。"
                 @"openssl / securetransport 层是自带 TLS 栈 App 的唯一明文入口，默认关闭。"
                 @"socket 层只有连接元数据与 SNI，不解密任何内容。",
    };
}

- (NSDictionary *)opList:(NSDictionary *)arguments {
    NSString *host = NXString(arguments, @"host");
    NSString *method = NXString(arguments, @"method");
    NSString *layer = NXString(arguments, @"layer");
    NSString *kind = NXString(arguments, @"kind");
    NSString *query = NXString(arguments, @"query");
    NSInteger status = NXInt(arguments, @"status", 0, 0, 999);
    NSInteger limit = NXInt(arguments, @"limit", 50, 1, 200);
    BOOL detail = NXBool(arguments, @"detail", NO);

    NSArray<NXRecord *> *records = [self snapshotRecords];
    NSMutableArray *rows = [NSMutableArray array];
    NSInteger matched = 0;
    for (NXRecord *record in records.reverseObjectEnumerator) {
        if (host.length && [record.host rangeOfString:host options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        if (method.length && ![record.method.uppercaseString isEqual:method.uppercaseString]) continue;
        if (layer.length && ![record.layer isEqual:layer]) continue;
        if (kind.length && ![record.kind isEqual:kind]) continue;
        if (status && record.status != status) continue;
        if (query.length) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@", record.url ?: @"", record.path ?: @"", record.host ?: @""];
            if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        matched += 1;
        if (rows.count >= limit) continue;
        [rows addObject:[self rowForRecord:record detail:detail]];
    }
    return @{@"transactions": rows,
             @"count": @(rows.count),
             @"matched": @(matched),
             @"truncated": @(matched > rows.count),
             @"capacity": @(NXCapacity),
             @"capture": [self captureState]};
}

- (NSDictionary *)opDetail:(NSDictionary *)arguments error:(NSString **)error {
    NSString *ident = NXString(arguments, @"id");
    if (!ident.length) { if (error) *error = @"缺少 id"; return nil; }
    NXRecord *record = [self recordForIdent:ident];
    if (!record) {
        if (error) *error = [NSString stringWithFormat:
                             @"找不到记录 %@（可能已被 %lu 条环形缓冲淘汰）",
                             ident, (unsigned long)NXCapacity];
        return nil;
    }
    NSMutableDictionary *row = [[self rowForRecord:record detail:YES] mutableCopy];
    row[@"har"] = [self harEntryForIdentifier:ident];
    return row;
}

- (NSDictionary *)opExport:(NSDictionary *)arguments error:(NSString **)error {
    NSArray<NXRecord *> *records = [self snapshotRecords];
    if (!records.count) { if (error) *error = @"当前没有网络记录可导出"; return nil; }
    NSMutableArray *entries = [NSMutableArray array];
    for (NXRecord *record in records) {
        NSDictionary *entry = [self harEntryForIdentifier:record.ident];
        if (entry.count) [entries addObject:entry];
    }
    NSDictionary *har = @{@"log": @{@"version": @"1.2",
                                    @"creator": @{@"name": @"AiFlex3", @"version": @"3.6.0"},
                                    @"entries": entries}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:har options:0 error:nil];
    NSString *name = [NSString stringWithFormat:@"network-%.0f.har.json", NSDate.date.timeIntervalSince1970 * 1000];
    NSString *path = [[self rulesDirectory] stringByAppendingPathComponent:name];
    if (![data writeToFile:path atomically:YES]) {
        if (error) *error = @"写入导出文件失败";
        return nil;
    }
    return @{@"relativePath": [@"AiFlex3Net/" stringByAppendingString:name],
             @"bytes": @(data.length),
             @"entries": @(entries.count),
             @"note": @"HAR 1.2 风格，可直接拖进 Chrome DevTools / Charles 查看；"
                      @"sequence/websocket 记录在同名字段里，标准 HAR 工具会忽略非 HTTP 条目。"};
}

- (NSDictionary *)opRules {
    os_unfair_lock_lock(&_lock);
    NSArray *copy = _rules.copy;
    os_unfair_lock_unlock(&_lock);
    return @{@"rules": copy,
             @"count": @(copy.count),
             @"capture": [self captureState],
             @"note": @"match 全部用「包含」语义（host / path / method / url / url_regex），"
                      @"不要求写全 URL。action=rewrite 时 set 里的字段覆盖请求，"
                      @"set.response_body / status 会改响应（仅 completionHandler 路径）。"};
}

- (NSDictionary *)opPending {
    os_unfair_lock_lock(&_lock);
    NSArray *copy = _pending.copy;
    os_unfair_lock_unlock(&_lock);
    NSMutableArray *rows = [NSMutableArray array];
    uint64_t now = NXNowNs();
    for (NXPending *item in copy) {
        [rows addObject:@{@"id": item.ident ?: @"",
                          @"rule": item.ruleId ?: @"",
                          @"method": item.request.HTTPMethod ?: @"GET",
                          @"url": item.request.URL.absoluteString ?: @"",
                          @"ageMs": @((now - item.createdAtNs) / 1000000),
                          @"timeoutMs": @(NXHoldTimeout * 1000)}];
    }
    return @{@"pending": rows,
             @"count": @(rows.count),
             @"note": @"命中 hold 规则的请求会阻塞等待决策，最长 15 秒。"
                      @"用 aiflex_net_action(decide, id=..., decision=forward|modify|drop) 放行。"};
}

- (NSDictionary *)opCorrelate:(NSDictionary *)arguments error:(NSString **)error {
    NSString *ident = NXString(arguments, @"id");
    if (!ident.length) { if (error) *error = @"缺少 id"; return nil; }
    NXRecord *anchor = [self recordForIdent:ident];
    if (!anchor) { if (error) *error = [NSString stringWithFormat:@"找不到记录 %@", ident]; return nil; }

    NSInteger windowMs = NXInt(arguments, @"window_ms", 2000, 0, 60000);
    uint64_t windowNs = (uint64_t)windowMs * 1000000ULL;
    uint64_t start = anchor.startedNs > windowNs ? anchor.startedNs - windowNs : 0;
    uint64_t end = (anchor.endedNs ?: anchor.startedNs) + windowNs;

    // 这是本引擎相对于 FLEX 的核心增量：把「一次网络请求」和「同一时间窗内的
    // 原生调用」放在一条时间线上。加密参数到底是哪个函数算出来的，靠这个对。
    NSArray *events = [FLEXAiFlexHook snapshotEventsFrom:start to:end limit:200];

    NSMutableArray *neighbors = [NSMutableArray array];
    for (NXRecord *record in [self snapshotRecords]) {
        if ([record.ident isEqual:ident]) continue;
        if (!record.startedNs || record.startedNs < start || record.startedNs > end) continue;
        [neighbors addObject:@{@"id": record.ident,
                               @"layer": record.layer ?: @"",
                               @"kind": record.kind ?: @"",
                               @"host": record.host ?: @"",
                               @"path": NXShort(record.path ?: @"", 200),
                               @"offsetMs": @((double)((int64_t)record.startedNs - (int64_t)anchor.startedNs) / 1e6)}];
        if (neighbors.count >= 20) break;
    }

    return @{@"anchor": [self rowForRecord:anchor detail:NO],
             @"windowMs": @(windowMs),
             @"hookEvents": events,
             @"hookEventCount": @(events.count),
             @"networkNeighbors": neighbors,
             @"note": events.count
                 ? @"hookEvents 来自 aiflex_hook 的事件环形缓冲，按单调时钟对齐到本记录的时间窗；"
                   @"没有 Hook 事件不等于没有加密调用，只等于当时没挂对应 hook。"
                 : @"时间窗内没有 Hook 事件。若要看加密调用，先用 aiflex_hook 挂上候选函数"
                   @"（如 CCCrypt / CC_SHA256 / 业务加密函数）再重放这条请求。"};
}

- (NSDictionary *)opClear {
    os_unfair_lock_lock(&_lock);
    [_records removeAllObjects];
    _bodyBytes = 0;
    _droppedRecords = 0;
    os_unfair_lock_unlock(&_lock);
    return @{@"cleared": @YES, @"records": @0};
}

#pragma mark - 可写 operation

- (NSDictionary *)opCapture:(NSDictionary *)arguments {
    // target 省略时按 enabled 统一设四个开关；给了 target 只改那一个。
    NSString *target = NXString(arguments, @"target");
    BOOL enabled = NXBool(arguments, @"enabled", YES);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL touchedTLS = NO, touchedSocket = NO;
    if (!target.length || [target isEqual:@"all"]) {
        [defaults setBool:enabled forKey:NXCaptureNSURLKey];
        [defaults setBool:enabled forKey:NXCaptureWSKey];
        [defaults setBool:enabled forKey:NXCaptureTLSKey];
        [defaults setBool:enabled forKey:NXCaptureSocketKey];
        touchedTLS = touchedSocket = enabled;
    } else if ([target isEqual:@"nsurl"]) {
        [defaults setBool:enabled forKey:NXCaptureNSURLKey];
    } else if ([target isEqual:@"websocket"] || [target isEqual:@"ws"]) {
        [defaults setBool:enabled forKey:NXCaptureWSKey];
    } else if ([target isEqual:@"tls"]) {
        [defaults setBool:enabled forKey:NXCaptureTLSKey];
        touchedTLS = enabled;
    } else if ([target isEqual:@"socket"]) {
        [defaults setBool:enabled forKey:NXCaptureSocketKey];
        touchedSocket = enabled;
    } else {
        return @{@"error": [NSString stringWithFormat:@"target 仅支持 all / nsurl / websocket / tls / socket，收到 %@", target]};
    }
    // 缓存必须在这里失效：否则 hook 里读到的还是上一次的开关值，
    // 关掉采集后流量还在被记录，看起来像开关失灵。
    NXResetCaptureCache();
    // swizzle / fishhook 已经装过的直接复用，没装过的现在补装。
    if (touchedTLS) [self installTLSHooks];
    if (touchedSocket) [self installSocketHooks];
    return @{@"capture": [self captureState],
             @"applied": target.length ? target : @"all",
             @"note": touchedTLS || touchedSocket
                 ? @"tls / socket 的 hook 已生效于后续连接；已建立的连接不会补抓。"
                 : @"开关已更新，对后续请求立即生效。"};
}

- (NSDictionary *)opRuleAdd:(NSDictionary *)arguments error:(NSString **)error {
    NSDictionary *match = arguments[@"match"];
    if (![match isKindOfClass:NSDictionary.class] || !match.count) {
        if (error) *error = @"match 不能为空，至少给 host / path / method / url / url_regex 之一";
        return nil;
    }
    NSString *action = NXString(arguments, @"action") ?: @"rewrite";
    if (![@[@"rewrite", @"hold", @"drop"] containsObject:action]) {
        if (error) *error = @"action 仅支持 rewrite / hold / drop";
        return nil;
    }
    NSDictionary *set = [arguments[@"set"] isKindOfClass:NSDictionary.class] ? arguments[@"set"] : @{};
    if ([action isEqual:@"rewrite"] && !set.count) {
        if (error) *error = @"rewrite 规则必须给 set（url / method / headers / body / response_body / status）";
        return nil;
    }

    os_unfair_lock_lock(&_lock);
    NSUInteger next = 1;
    for (NSDictionary *rule in _rules) {
        NSString *ruleId = rule[@"id"];
        if ([ruleId hasPrefix:@"r"]) next = MAX(next, (NSUInteger)ruleId.integerValue + 1);
    }
    NSMutableDictionary *rule = [@{
        @"id": [NSString stringWithFormat:@"r%lu", (unsigned long)next],
        @"enabled": @(NXBool(arguments, @"enabled", YES)),
        @"action": action,
        @"match": match,
        @"set": set,
    } mutableCopy];
    NSString *label = NXString(arguments, @"label");
    if (label.length) rule[@"label"] = label;
    [_rules addObject:rule];
    os_unfair_lock_unlock(&_lock);
    [self saveRules];
    return @{@"rule": rule, @"count": @(_rules.count), @"path": @"AiFlex3Net/rules.json"};
}

- (NSDictionary *)opRuleRemove:(NSDictionary *)arguments error:(NSString **)error {
    NSString *ident = NXString(arguments, @"id");
    if (!ident.length) { if (error) *error = @"缺少 id"; return nil; }
    os_unfair_lock_lock(&_lock);
    NSInteger index = NSNotFound;
    for (NSUInteger i = 0; i < _rules.count; i++) {
        if ([_rules[i][@"id"] isEqual:ident]) { index = (NSInteger)i; break; }
    }
    if (index != NSNotFound) [_rules removeObjectAtIndex:(NSUInteger)index];
    NSUInteger left = _rules.count;
    os_unfair_lock_unlock(&_lock);
    if (index == NSNotFound) { if (error) *error = [NSString stringWithFormat:@"找不到规则 %@", ident]; return nil; }
    [self saveRules];
    return @{@"removed": ident, @"count": @(left)};
}

- (NSDictionary *)opRuleClear {
    os_unfair_lock_lock(&_lock);
    [_rules removeAllObjects];
    os_unfair_lock_unlock(&_lock);
    [self saveRules];
    return @{@"cleared": @YES, @"count": @0};
}

- (NSDictionary *)opRuleToggle:(NSDictionary *)arguments error:(NSString **)error {
    NSString *ident = NXString(arguments, @"id");
    if (!ident.length) { if (error) *error = @"缺少 id"; return nil; }
    BOOL enabled = NXBool(arguments, @"enabled", YES);
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *found = nil;
    for (NSMutableDictionary *rule in _rules) {
        if ([rule[@"id"] isEqual:ident]) { found = rule; break; }
    }
    if (found) found[@"enabled"] = @(enabled);
    os_unfair_lock_unlock(&_lock);
    if (!found) { if (error) *error = [NSString stringWithFormat:@"找不到规则 %@", ident]; return nil; }
    [self saveRules];
    return @{@"rule": found.copy};
}

- (NSDictionary *)opDecide:(NSDictionary *)arguments error:(NSString **)error {
    NSString *ident = NXString(arguments, @"id");
    if (!ident.length) { if (error) *error = @"缺少 id"; return nil; }
    NSString *decision = NXString(arguments, @"decision") ?: @"forward";
    if (![@[@"forward", @"modify", @"drop"] containsObject:decision]) {
        if (error) *error = @"decision 仅支持 forward / modify / drop";
        return nil;
    }
    NSURLRequest *modified = nil;
    if ([decision isEqual:@"modify"]) {
        NXPending *pending = [self pendingForIdent:ident];
        if (!pending) { if (error) *error = @"该请求已超时放行，无法再改"; return nil; }
        NSDictionary *set = [arguments[@"set"] isKindOfClass:NSDictionary.class] ? arguments[@"set"] : @{};
        if (!set.count) { if (error) *error = @"decision=modify 时必须给 set"; return nil; }
        modified = [self applyRewrite:set toRequest:pending.request];
    }
    NSString *failure = nil;
    if (![self resolvePendingIdent:ident decision:decision request:modified error:&failure]) {
        if (error) *error = failure;
        return nil;
    }
    return @{@"id": ident, @"decision": decision, @"modified": @(modified != nil)};
}

#pragma mark - 重放与构造

- (NSDictionary *)sendMethod:(NSString *)method
                         url:(NSString *)urlText
                     headers:(NSDictionary *)headers
                        body:(NSData *)body
                     timeout:(NSTimeInterval)timeout
                       error:(NSString **)error {
    NSURL *url = [NSURL URLWithString:urlText ?: @""];
    if (!url.scheme.length || !url.host.length) {
        if (error) *error = [NSString stringWithFormat:@"url 无效：%@", urlText ?: @""];
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method.length ? method.uppercaseString : @"GET";
    request.timeoutInterval = MAX(1.0, MIN(timeout, 60.0));
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        [request setValue:[value description] forHTTPHeaderField:[key description]];
    }];
    if (body.length) request.HTTPBody = body;

    __block NSData *responseData = nil;
    __block NSURLResponse *response = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    // 打标记让 prepareRequest 知道这条记录是我们自己发的，避免 AI 把
    // 重放流量误当成 App 自己的行为。
    NSThread.currentThread.threadDictionary[@"AiFlex3Replay"] = @YES;
    uint64_t startedNs = NXNowNs();
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            responseData = data;
            response = resp;
            failure = err;
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];
    long waited = dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((request.timeoutInterval + 3) * NSEC_PER_SEC)));
    [NSThread.currentThread.threadDictionary removeObjectForKey:@"AiFlex3Replay"];
    if (waited != 0) {
        [task cancel];
        if (error) *error = [NSString stringWithFormat:@"请求超时（%.0f 秒）", request.timeoutInterval];
        return nil;
    }

    NSMutableDictionary *result = [@{
        @"request": @{@"method": request.HTTPMethod,
                      @"url": url.absoluteString,
                      @"headers": headers ?: @{},
                      @"bodyBytes": @(body.length)},
        @"durationMs": @((NXNowNs() - startedNs) / 1000000),
    } mutableCopy];
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        result[@"status"] = @(http.statusCode);
        result[@"responseHeaders"] = http.allHeaderFields ?: @{};
    }
    result[@"responseBody"] = NXText(responseData, NXBodyReturnMax);
    result[@"responseBodyBytes"] = @(responseData.length);
    result[@"responseBodyTruncated"] = @(responseData.length > NXBodyReturnMax);
    if (failure) result[@"error"] = failure.localizedDescription ?: @"请求失败";
    return result;
}

- (NSDictionary *)opReplay:(NSDictionary *)arguments error:(NSString **)error {
    NSString *ident = NXString(arguments, @"id");
    NXRecord *source = ident.length ? [self recordForIdent:ident] : nil;
    if (ident.length && !source) {
        if (error) *error = [NSString stringWithFormat:@"找不到记录 %@", ident];
        return nil;
    }
    NSString *url = NXString(arguments, @"url") ?: source.url;
    if (!url.length) { if (error) *error = @"没有 id 时必须给 url"; return nil; }
    NSString *method = NXString(arguments, @"method") ?: source.method ?: @"GET";
    NSDictionary *headers = [arguments[@"headers"] isKindOfClass:NSDictionary.class]
        ? arguments[@"headers"]
        : (source.requestHeaders ?: @{});
    NSData *body = NXBodyFromArguments(arguments) ?: source.requestBody;
    NSTimeInterval timeout = [arguments[@"timeout"] doubleValue] > 0 ? [arguments[@"timeout"] doubleValue] : 20;

    NSMutableDictionary *result = [[self sendMethod:method url:url headers:headers body:body timeout:timeout error:error] mutableCopy];
    if (!result) return nil;
    if (source) {
        result[@"replayOf"] = source.ident;
        if (source.requestBodyFromStream) {
            result[@"note"] = @"源记录的请求体来自 HTTPBodyStream，抓不到原文；"
                              @"本次重放发的是空 body。要完整重放请用 compose 显式给 body。";
        }
        if (!headers.count) result[@"headerNote"] = @"源记录没有可用请求头，重放可能被鉴权拦截。";
    }
    return result;
}

- (NSDictionary *)opCompose:(NSDictionary *)arguments error:(NSString **)error {
    NSString *url = NXString(arguments, @"url");
    if (!url.length) { if (error) *error = @"compose 必须给 url"; return nil; }
    NSString *method = NXString(arguments, @"method") ?: @"GET";
    NSDictionary *headers = [arguments[@"headers"] isKindOfClass:NSDictionary.class] ? arguments[@"headers"] : @{};
    NSData *body = NXBodyFromArguments(arguments);
    NSTimeInterval timeout = [arguments[@"timeout"] doubleValue] > 0 ? [arguments[@"timeout"] doubleValue] : 20;
    return [self sendMethod:method url:url headers:headers body:body timeout:timeout error:error];
}

@end
