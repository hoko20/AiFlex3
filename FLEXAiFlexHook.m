//
//  FLEXAiFlexHook.m
//  FLEX++
//
//  本文件按 frida-gum 17.27.4 的真实头文件书写。几个与旧版本不同、实测确认过的点：
//    * gum_interceptor_attach 是 4 参数，第四参是 const GumAttachOptions *，
//      旧版是 3 参数；options 里 listener_function_data 就是回调里的 user_data。
//    * 用 gum_make_call_listener(on_enter, on_leave, data, destroy) 构造监听器，
//      不需要 G_DEFINE_TYPE 去实现 GumInvocationListener 接口。
//    * GumAttachReturn / GumReplaceReturn 是带负值的枚举，0 为 OK。
//    * gum_memory_patch_code 内部完成 mprotect 与指令缓存刷新，
//      不要自己再调 vm_protect + sys_icache_invalidate（会覆盖掉 gum 的页状态记录）。
//    * gum_init_embedded 全进程只能调一次。这里不自己初始化，复用 FLEXAiFlexFrida
//      的 dispatch_once，否则两处各调一次会重复初始化内部锁与调度线程，直接崩。
//

#import "FLEXAiFlexHook.h"
#import "FLEXAiFlexFrida.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <time.h>
#import <errno.h>
#import <unistd.h>

#ifndef GX_NO_GUM
#include "frida-gum.h"
#endif

#pragma mark - 常量

// 环形缓冲容量。每条 hook 事件 56 字节，4096 条约 224 KB BSS——
// 不占可执行文件体积，只在首次触碰时映射。宁可多留也不要在高频函数上丢事件。
#define HXEventCapacity 4096
#define HXMaxArgs 4

static const NSUInteger HXDefaultEventLimit = 100;
static const NSUInteger HXMaxEventLimit     = 1000;
static const NSUInteger HXMaxPatchBytes     = 64;
static const NSUInteger HXMaxHooks          = 32;
static const NSUInteger HXMaxPatches        = 64;
static const double     HXSelftestBudget    = 3.0;

static NSString * const HXErrorUnavailable =
    @"代码改写引擎未编入当前构建（frida-gum devkit 缺失）。请在 CI 中拉取 frida-gum 后重新打包。";

static NSString * const HXAuditDirectoryName = @"AiFlex3Hooks";
static NSString * const HXAuditFileName      = @"audit.log";

#pragma mark - 参数工具

static NSString *HXStringArg(NSDictionary *arguments, NSString *key) {
    id value = arguments[key];
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSUInteger HXIntArg(NSDictionary *arguments, NSString *key, NSUInteger fallback,
                           NSUInteger minimum, NSUInteger maximum) {
    id value = arguments[key];
    long long parsed = (long long)fallback;
    if ([value isKindOfClass:NSNumber.class]) {
        parsed = [(NSNumber *)value longLongValue];
    } else if ([value isKindOfClass:NSString.class]) {
        parsed = strtoll([(NSString *)value UTF8String], NULL, 0);
    } else {
        return fallback;
    }
    if (parsed < (long long)minimum) parsed = (long long)minimum;
    if (parsed > (long long)maximum) parsed = (long long)maximum;
    return (NSUInteger)parsed;
}

static BOOL HXBoolArg(NSDictionary *arguments, NSString *key, BOOL fallback) {
    id value = arguments[key];
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:NSString.class]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqual:@"true"] || [lower isEqual:@"1"] || [lower isEqual:@"yes"]) return YES;
        if ([lower isEqual:@"false"] || [lower isEqual:@"0"] || [lower isEqual:@"no"]) return NO;
    }
    return fallback;
}

/// 地址一律按字符串解析。JSON number 是 double，arm64 真实地址超过 2^53 会丢精度，
/// 这类错误的表现是「hook 成功但打在错误的地址上」，比直接报错危险得多。
static BOOL HXParseAddress(NSString *text, uint64_t *out) {
    if (![text isKindOfClass:NSString.class] || !text.length) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!trimmed.length) return NO;
    const char *utf8 = trimmed.UTF8String;
    if (!utf8) return NO;
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(utf8, &end, 0);
    if (errno != 0 || end == utf8) return NO;
    while (end && (*end == ' ' || *end == '\t')) end++;
    if (end && *end != '\0') return NO;
    *out = (uint64_t)value;
    return YES;
}

static NSString *HXHex(uint64_t value) {
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value];
}

/// "fd 7b bf a9" / "fd7bbfa9" / "FD 7B BF A9" 都能解析。
static NSData *HXParseHexBytes(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return nil;
    NSMutableData *data = [NSMutableData data];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@" \t,:-_"];
    NSArray<NSString *> *tokens = [text componentsSeparatedByCharactersInSet:separators];
    BOOL sawToken = NO;
    for (NSString *token in tokens) {
        if (!token.length) continue;
        if (token.length % 2 != 0 || token.length > 64) return nil;
        sawToken = YES;
        for (NSUInteger i = 0; i < token.length; i += 2) {
            NSString *pair = [token substringWithRange:NSMakeRange(i, 2)];
            unsigned int byte = 0;
            if (![[NSScanner scannerWithString:pair] scanHexInt:&byte]) return nil;
            uint8_t value = (uint8_t)(byte & 0xFF);
            [data appendBytes:&value length:1];
        }
    }
    return sawToken ? data : nil;
}

static NSString *HXHexBytes(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || !length) return @"";
    NSMutableString *text = [NSMutableString stringWithCapacity:length * 3];
    for (NSUInteger i = 0; i < length; i++) {
        if (i) [text appendString:@" "];
        [text appendFormat:@"%02x", bytes[i]];
    }
    return text;
}

#pragma mark - 时间

static double HXMonotonicSeconds(void) {
    // clock_gettime 在 iOS 上是 vDSO 实现，没有系统调用开销。
    // listener 里每个事件都要取一次时间，用这个而不是 NSDate。
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

#pragma mark - 环形事件缓冲

// 全部为纯 C 结构。listener 运行在被 hook 函数的调用线程上，可能是高频路径，
// 因此这里刻意不使用 ObjC、不 malloc、不加锁——只用原子操作和固定数组。
typedef struct {
    uint64_t seq;        // 写入完成标记，release 语义；读者据此判断槽位是否有效
    uint64_t ts;         // 单调时钟，秒
    uint64_t args[HXMaxArgs];
    uint64_t ret;
    uint32_t hookId;
    uint32_t threadId;
    uint16_t depth;
    uint16_t phase;      // 0 = enter, 1 = leave
    uint16_t argCount;
    uint16_t reserved;
} HXEvent;

typedef struct {
    uint32_t hookId;
    uint8_t recordArgs;
    uint8_t retired;
    uint8_t reserved[2];
    uint64_t target;
    uint64_t calls;
} HXHookSlot;

#ifndef GX_NO_GUM

static HXEvent gHXEvents[HXEventCapacity];
static uint64_t gHXWriteIndex = 0;

static void HXRecordEnter(GumInvocationContext *context, gpointer user_data) {
    HXHookSlot *slot = (HXHookSlot *)user_data;
    if (!slot || slot->retired) return;
    __atomic_fetch_add(&slot->calls, 1ULL, __ATOMIC_RELAXED);
    if (!slot->recordArgs) return;

    uint64_t index = __atomic_fetch_add(&gHXWriteIndex, 1ULL, __ATOMIC_RELAXED);
    HXEvent *event = &gHXEvents[index % HXEventCapacity];
    // 先写数据，最后 release 写 seq。读者只有看到 seq 匹配才认为数据完整，
    // 这样「正在被覆盖的槽位」会被读者自动跳过，不需要读写锁。
    event->ts = (uint64_t)(HXMonotonicSeconds() * 1e9);
    for (guint i = 0; i < HXMaxArgs; i++) {
        event->args[i] = (uint64_t)(uintptr_t)gum_invocation_context_get_nth_argument(context, i);
    }
    event->ret = 0;
    event->hookId = slot->hookId;
    event->threadId = gum_invocation_context_get_thread_id(context);
    event->depth = (uint16_t)MIN(gum_invocation_context_get_depth(context), (guint)0xFFFF);
    event->phase = 0;
    event->argCount = HXMaxArgs;
    event->reserved = 0;
    __atomic_store_n(&event->seq, index + 1, __ATOMIC_RELEASE);
}

static void HXRecordLeave(GumInvocationContext *context, gpointer user_data) {
    HXHookSlot *slot = (HXHookSlot *)user_data;
    if (!slot || slot->retired || !slot->recordArgs) return;

    uint64_t index = __atomic_fetch_add(&gHXWriteIndex, 1ULL, __ATOMIC_RELAXED);
    HXEvent *event = &gHXEvents[index % HXEventCapacity];
    event->ts = (uint64_t)(HXMonotonicSeconds() * 1e9);
    for (guint i = 0; i < HXMaxArgs; i++) event->args[i] = 0;
    event->ret = (uint64_t)(uintptr_t)gum_invocation_context_get_return_value(context);
    event->hookId = slot->hookId;
    event->threadId = gum_invocation_context_get_thread_id(context);
    event->depth = (uint16_t)MIN(gum_invocation_context_get_depth(context), (guint)0xFFFF);
    event->phase = 1;
    event->argCount = 0;
    event->reserved = 0;
    __atomic_store_n(&event->seq, index + 1, __ATOMIC_RELEASE);
}

typedef struct {
    const uint8_t *bytes;
    size_t length;
} HXPatchPayload;

static void HXPatchApply(gpointer mem, gpointer user_data) {
    HXPatchPayload *payload = (HXPatchPayload *)user_data;
    if (!mem || !payload || !payload->bytes) return;
    memcpy(mem, payload->bytes, payload->length);
}

#endif /* GX_NO_GUM */

#pragma mark - 指针解释

/// 只在「读取事件」这一步做，绝不在 listener 里做。
/// 判据全部是「先确认可读，再解引用」，任何一步不满足就放弃，不做猜测性解引用。
static NSDictionary *HXDescribePointer(uint64_t value) {
    NSMutableDictionary *hint = [NSMutableDictionary dictionary];
    hint[@"hex"] = HXHex(value);
    if (value == 0) {
        hint[@"kind"] = @"null";
        return hint;
    }
    if (value < 0x1000) {
        hint[@"kind"] = @"small";
        hint[@"value"] = @((long long)value);
        return hint;
    }
#ifdef GX_NO_GUM
    hint[@"kind"] = @"raw";
    return hint;
#else
    if (!gum_memory_is_readable((gconstpointer)(uintptr_t)value, 1)) {
        hint[@"kind"] = @"raw";
        return hint;
    }

    // 代码地址：dladdr 能给出最近的导出符号。stripped 内部函数返回空，属正常。
    Dl_info info;
    if (dladdr((const void *)(uintptr_t)value, &info) != 0 && info.dli_fname) {
        if (info.dli_sname && info.dli_sname[0]) {
            hint[@"kind"] = @"symbol";
            hint[@"symbol"] = @(info.dli_sname);
            hint[@"image"] = @(info.dli_fname);
            return hint;
        }
        if (info.dli_fbase && (uint64_t)(uintptr_t)info.dli_fbase == value) {
            hint[@"kind"] = @"image";
            hint[@"image"] = @(info.dli_fname);
            return hint;
        }
    }

    // C 字符串：逐字节读，遇 0 或不可读立即停。只有全部是可打印 ASCII 且长度达标才认。
    if (gum_memory_is_readable((gconstpointer)(uintptr_t)value, 16)) {
        char buffer[201];
        size_t length = 0;
        BOOL printable = YES;
        while (length < 200) {
            if (!gum_memory_is_readable((gconstpointer)(uintptr_t)(value + length), 1)) {
                printable = NO;
                break;
            }
            char c = ((const char *)(uintptr_t)value)[length];
            if (c == 0) break;
            unsigned char uc = (unsigned char)c;
            if (uc < 0x20 || uc > 0x7E) {
                printable = NO;
                break;
            }
            buffer[length++] = c;
        }
        if (printable && length >= 4) {
            buffer[length] = 0;
            hint[@"kind"] = @"string";
            hint[@"str"] = @(buffer);
            return hint;
        }
    }

    // ObjC 实例：只做「isa 落在可读内存」这一层判断，不 deref isa 之外的东西，
    // 也不调 object_getClass——对伪造指针调 runtime 函数会直接段错误。
    if (gum_memory_is_readable((gconstpointer)(uintptr_t)value, sizeof(void *))) {
        uint64_t isa = *(const uint64_t *)(uintptr_t)value;
        if (isa >= 0x100000000ULL && (isa & 7) == 0 &&
            gum_memory_is_readable((gconstpointer)(uintptr_t)isa, 8)) {
            hint[@"kind"] = @"object?";
            hint[@"isa"] = HXHex(isa);
            return hint;
        }
    }

    hint[@"kind"] = @"data";
    return hint;
#endif
}

#pragma mark - 引擎

@implementation FLEXAiFlexHook {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_hooks;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_patches;
    NSMutableArray<NSValue *> *_retiredSlots;
    NSUInteger _nextHookId;
    NSUInteger _nextPatchId;
    BOOL _selfTestPassed;
    NSString *_selfTestDetail;
}

+ (instancetype)sharedEngine {
    static FLEXAiFlexHook *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [[FLEXAiFlexHook alloc] init];
    });
    return engine;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("com.hoko20.aiflex3.hook", DISPATCH_QUEUE_SERIAL);
    _hooks = [NSMutableDictionary dictionary];
    _patches = [NSMutableDictionary dictionary];
    _retiredSlots = [NSMutableArray array];
    _nextHookId = 1;
    _nextPatchId = 1;
    _selfTestPassed = NO;
    _selfTestDetail = @"未执行";
    return self;
}

+ (BOOL)engineAvailable {
#ifdef GX_NO_GUM
    return NO;
#else
    return [FLEXAiFlexFrida ensureGumInitialized];
#endif
}

+ (NSArray<NSString *> *)supportedOperations {
    return @[@"status", @"list", @"hook", @"unhook", @"events", @"clear",
             @"patch", @"restore", @"selftest"];
}

#pragma mark - 审计日志

- (NSString *)auditDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) return nil;
    NSString *directory = [paths.firstObject stringByAppendingPathComponent:HXAuditDirectoryName];
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) {
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];
    }
    return directory;
}

/// 只写不读。这个日志是给人看的审计记录，不参与任何自动还原流程——
/// 原因见 restore 的实现注释：跨进程按旧偏移还原比不还原更危险。
- (void)appendAudit:(NSDictionary *)entry {
    NSString *directory = [self auditDirectory];
    if (!directory) return;
    NSMutableDictionary *row = [entry mutableCopy];
    row[@"at"] = [NSISO8601DateFormatter stringFromDate:NSDate.date
                                                timeZone:nil
                                           formatOptions:NSISO8601DateFormatWithInternetDateTime];
    NSData *data = [NSJSONSerialization dataWithJSONObject:row
                                                   options:NSJSONWritingWithoutEscapingSlashes
                                                     error:NULL];
    if (!data) return;
    NSString *path = [directory stringByAppendingPathComponent:HXAuditFileName];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [data writeToFile:path atomically:YES];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - 目标解析

/// 三级回退：显式地址 → 模块+导出名 → 类+方法名。
/// 类方法自动查 metaclass，因为 class_getInstanceMethod 对类方法返回 nil，
/// 这是逆向时最容易漏的一步。
- (uint64_t)resolveTarget:(NSDictionary *)arguments error:(NSString **)error {
    NSString *addressText = HXStringArg(arguments, @"address");
    if (addressText.length) {
        uint64_t address = 0;
        if (!HXParseAddress(addressText, &address)) {
            if (error) *error = @"address 不是合法整数，请传十进制或 0x 前缀的字符串";
            return 0;
        }
        if (address == 0) {
            if (error) *error = @"address 不能为 0";
            return 0;
        }
        return address;
    }

    NSString *className = HXStringArg(arguments, @"class");
    NSString *selectorName = HXStringArg(arguments, @"selector");
    if (className.length && selectorName.length) {
#ifdef GX_NO_GUM
        if (error) *error = HXErrorUnavailable;
        return 0;
#else
        Class cls = NSClassFromString(className);
        if (!cls) {
            if (error) *error = [@"找不到类：" stringByAppendingString:className];
            return 0;
        }
        BOOL isMeta = HXBoolArg(arguments, @"meta", NO);
        SEL selector = NSSelectorFromString(selectorName);
        Method method = isMeta ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
        if (!method) {
            if (error) {
                *error = [NSString stringWithFormat:@"类 %@ 中不存在%@方法 %@",
                          className, isMeta ? @"类" : @"实例", selectorName];
            }
            return 0;
        }
        IMP imp = method_getImplementation(method);
        if (!imp) {
            if (error) *error = @"方法实现为空";
            return 0;
        }
        return (uint64_t)(uintptr_t)imp;
#endif
    }

    NSString *moduleName = HXStringArg(arguments, @"module");
    NSString *symbolName = HXStringArg(arguments, @"name");
    if (symbolName.length) {
#ifdef GX_NO_GUM
        if (error) *error = HXErrorUnavailable;
        return 0;
#else
        if (moduleName.length) {
            GError *gumError = NULL;
            GumModule *module = gum_module_load(moduleName.UTF8String, &gumError);
            if (!module) {
                if (error) {
                    *error = [NSString stringWithFormat:@"加载模块失败：%@（%@）",
                              moduleName, gumError ? @(gumError->message) : @"未知原因"];
                }
                if (gumError) g_clear_error(&gumError);
                return 0;
            }
            GumAddress address = gum_module_find_export_by_name(module, symbolName.UTF8String);
            g_object_unref(module);
            if (address == 0) {
                if (error) *error = [NSString stringWithFormat:@"模块 %@ 没有导出符号 %@", moduleName, symbolName];
                return 0;
            }
            return (uint64_t)address;
        }
        GumAddress address = gum_module_find_global_export_by_name(symbolName.UTF8String);
        if (address == 0) {
            if (error) *error = [NSString stringWithFormat:@"全局导出里找不到 %@", symbolName];
            return 0;
        }
        return (uint64_t)address;
#endif
    }

    if (error) *error = @"需要 address，或者 class + selector，或者 name（可带 module）";
    return 0;
}

/// 是否落在本插件自己的镜像里。改自己的代码等于把分析工具本身打死，
/// 而且它没法自我还原——必须在写入前拒绝。
#ifndef GX_NO_GUM
static BOOL HXIsOwnImage(uint64_t address) {
    Dl_info info;
    if (dladdr((const void *)(uintptr_t)address, &info) == 0 || !info.dli_fname) return NO;
    NSString *path = @(info.dli_fname);
    if (!path.length) return NO;
    return [path containsString:@"FLEX++"] || [path containsString:@"AiFlex3"] ||
           [path containsString:@"FLEX.dylib"];
}

/// 三重校验：对齐 / 可执行页 / 非自身镜像，外加可读长度。
/// 少任何一项都会让「参数写错」变成「进程崩溃」，而不是一条错误消息。
static NSString *HXValidateExecutableTarget(uint64_t address, size_t needBytes) {
    if (address < 0x100000000ULL) {
        return @"地址低于 0x100000000，不是有效的用户态代码地址（检查是否有漏传的偏移）";
    }
    if ((address & 3) != 0) {
        return @"地址未按 4 字节对齐，AArch64 指令必须 4 对齐";
    }
    GumPageProtection protection = GUM_PAGE_NO_ACCESS;
    if (!gum_memory_query_protection((gconstpointer)(uintptr_t)address, &protection)) {
        return @"地址不在任何已映射区间内";
    }
    if (!(protection & GUM_PAGE_EXECUTE)) {
        return @"目标不在可执行页，改写后一旦被取指就会崩溃";
    }
    if (HXIsOwnImage(address)) {
        return @"拒绝改写 AiFlex3 自身代码";
    }
    if (needBytes && !gum_memory_is_readable((gconstpointer)(uintptr_t)address, (gsize)needBytes)) {
        return [NSString stringWithFormat:@"目标可读长度不足 %zu 字节", needBytes];
    }
    return nil;
}
#endif

#pragma mark - 自检

/// 用 getpid 做端到端自检：它一定存在、无参数、无副作用、调用频率极低。
/// 关键是「attach 后真的调一次，确认 listener 被触发，再 detach 确认计数不再增长」——
/// 只检查 attach 返回 0 是不够的，trampoline 可能挂着但回调没接上。
- (NSDictionary *)runSelfTest {
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
#ifdef GX_NO_GUM
    report[@"ok"] = @NO;
    report[@"reason"] = HXErrorUnavailable;
    return report;
#else
    if (![FLEXAiFlexFrida ensureGumInitialized]) {
        report[@"ok"] = @NO;
        report[@"reason"] = @"gum 引擎初始化失败";
        return report;
    }
    double started = HXMonotonicSeconds();
    GumAddress target = gum_module_find_global_export_by_name("getpid");
    if (target == 0) {
        report[@"ok"] = @NO;
        report[@"reason"] = @"找不到 getpid，无法自检";
        return report;
    }
    report[@"target"] = HXHex((uint64_t)target);
    report[@"targetName"] = @"getpid";

    GumInterceptor *interceptor = gum_interceptor_obtain();
    HXHookSlot *slot = calloc(1, sizeof(HXHookSlot));
    if (!slot) {
        report[@"ok"] = @NO;
        report[@"reason"] = @"内存不足";
        return report;
    }
    slot->hookId = 0;
    slot->recordArgs = 1;
    slot->target = (uint64_t)target;

    GumInvocationListener *listener = gum_make_call_listener(HXRecordEnter, HXRecordLeave, slot, NULL);
    if (!listener) {
        free(slot);
        report[@"ok"] = @NO;
        report[@"reason"] = @"监听器创建失败";
        return report;
    }

    GumAttachOptions options = { 0, };
    GumAttachReturn attached = gum_interceptor_attach(interceptor, (gpointer)(uintptr_t)target, listener, &options);
    report[@"attach"] = @(attached);
    if (attached != GUM_ATTACH_OK) {
        g_object_unref(listener);
        free(slot);
        report[@"ok"] = @NO;
        report[@"reason"] = [NSString stringWithFormat:@"attach 失败（GumAttachReturn %d）：目标可能已被其他 hook 占用，或指令无法重定位", (int)attached];
        return report;
    }

    // 真的调三次，确认回调链路通。
    for (int i = 0; i < 3; i++) (void)getpid();
    uint64_t observed = __atomic_load_n(&slot->calls, __ATOMIC_RELAXED);
    report[@"observedCalls"] = @(observed);

    gum_interceptor_detach(interceptor, listener);
    g_object_unref(listener);

    (void)getpid();
    uint64_t afterDetach = __atomic_load_n(&slot->calls, __ATOMIC_RELAXED);
    report[@"callsAfterDetach"] = @(afterDetach);

    // slot 不立即释放：detach 之后仍可能有在途调用处在老的 trampoline 上。
    // 几十字节的滞后释放比 use-after-free 划算。
    [self->_retiredSlots addObject:[NSValue valueWithPointer:slot]];

    BOOL observedOK = observed >= 3;
    BOOL detachOK = afterDetach == observed;
    report[@"detach"] = @(detachOK);
    report[@"ok"] = @(observedOK && detachOK);
    if (!observedOK) report[@"reason"] = @"attach 成功但回调未被触发，trampoline 未生效";
    else if (!detachOK) report[@"reason"] = @"detach 后仍收到回调，监听器未摘干净";
    report[@"elapsedMs"] = @((HXMonotonicSeconds() - started) * 1000.0);
    return report;
#endif
}

#pragma mark - operation: status

- (NSDictionary *)opStatus {
    BOOL available = [FLEXAiFlexHook engineAvailable];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"available"] = @(available);
    result[@"engine"] = available ? @"frida-gum Interceptor" : @"unavailable";
    result[@"operations"] = [FLEXAiFlexHook supportedOperations];
    result[@"limits"] = @{
        @"maxHooks": @(HXMaxHooks),
        @"maxPatches": @(HXMaxPatches),
        @"maxPatchBytes": @(HXMaxPatchBytes),
        @"maxArgs": @(HXMaxArgs),
        @"eventCapacity": @(HXEventCapacity),
        @"eventLimit": @(HXMaxEventLimit),
        @"selftestBudgetSeconds": @(HXSelftestBudget),
    };
    result[@"activeHooks"] = @(_hooks.count);
    result[@"activePatches"] = @(_patches.count);
    result[@"selfTest"] = @{ @"passed": @(_selfTestPassed), @"detail": _selfTestDetail ?: @"未执行" };
    result[@"capabilities"] = @{
        @"inlineHook": @(available),
        @"bytePatch": @(available),
        @"restore": @(available),
        @"argumentCapture": @(available),
        @"returnCapture": @(available),
        @"automaticPersistentRestore": @NO,
    };
    result[@"notes"] = @[
        @"hook 用 trampoline 改写目标入口，指令重定位、页权限和原子替换由 gum 完成。",
        @"patch 只写 4 字节对齐的整指令，写到一半不会留下跨指令的残片。",
        @"还原只对当前进程有效：进程结束后 trampoline 与内存补丁都会消失。",
        @"不做跨进程注入、不做 Stalker 指令级追踪、不跑 GumJS 脚本。",
    ];
    return result;
}

#pragma mark - operation: list

- (NSDictionary *)opList {
    NSMutableArray *hooks = [NSMutableArray array];
    NSArray<NSNumber *> *hookIds = [_hooks.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *key in hookIds) {
        NSMutableDictionary *record = _hooks[key];
        // 对外只给 address 字符串。target 是内部用的 NSNumber(uint64)，
        // 客户端多半按 double 解析，超过 2^53 会静默丢精度。
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = record[@"id"];
        row[@"address"] = record[@"address"];
        row[@"label"] = record[@"label"];
        row[@"image"] = record[@"image"];
        row[@"imageOffset"] = record[@"imageOffset"];
        row[@"recordArgs"] = record[@"recordArgs"];
        HXHookSlot *slot = (HXHookSlot *)((NSValue *)record[@"slot"]).pointerValue;
        row[@"calls"] = @(slot ? (uint64_t)__atomic_load_n(&slot->calls, __ATOMIC_RELAXED) : 0);
        [hooks addObject:row];
    }

    NSMutableArray *patches = [NSMutableArray array];
    NSArray<NSNumber *> *patchIds = [_patches.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *key in patchIds) {
        NSDictionary *record = _patches[key];
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"id"] = record[@"id"];
        row[@"address"] = record[@"address"];
        row[@"label"] = record[@"label"];
        row[@"length"] = record[@"length"];
        row[@"original"] = record[@"original"];
        row[@"patched"] = record[@"patched"];
        row[@"image"] = record[@"image"];
        row[@"imageOffset"] = record[@"imageOffset"];
        [patches addObject:row];
    }

    return @{
        @"hooks": hooks,
        @"patches": patches,
        @"hookCount": @(hooks.count),
        @"patchCount": @(patches.count),
    };
}

#pragma mark - operation: hook

- (NSDictionary *)opHook:(NSDictionary *)arguments error:(NSString **)error {
#ifdef GX_NO_GUM
    if (error) *error = HXErrorUnavailable;
    return nil;
#else
    if (_hooks.count >= HXMaxHooks) {
        if (error) *error = [NSString stringWithFormat:@"同时最多 %lu 条 hook，请先 unhook", (unsigned long)HXMaxHooks];
        return nil;
    }
    uint64_t target = [self resolveTarget:arguments error:error];
    if (!target) return nil;

    for (NSDictionary *record in _hooks.allValues) {
        if ([record[@"target"] unsignedLongLongValue] == target) {
            if (error) *error = [NSString stringWithFormat:@"该地址已在 hook 中（id %@），先 unhook", record[@"id"]];
            return nil;
        }
    }

    // attach 需要至少一条完整指令的空间；gum 会自己判断能否重定位，
    // 这里只校验 4 字节可读，把明显无效的地址挡在前面。
    NSString *failure = HXValidateExecutableTarget(target, 4);
    if (failure) {
        if (error) *error = failure;
        return nil;
    }

    BOOL recordArgs = HXBoolArg(arguments, @"record_args", YES);
    NSString *label = HXStringArg(arguments, @"label");

    GumInterceptor *interceptor = gum_interceptor_obtain();
    HXHookSlot *slot = calloc(1, sizeof(HXHookSlot));
    if (!slot) {
        if (error) *error = @"内存不足";
        return nil;
    }
    NSUInteger identifier = _nextHookId++;
    slot->hookId = (uint32_t)identifier;
    slot->recordArgs = recordArgs ? 1 : 0;
    slot->target = target;

    GumInvocationListener *listener = gum_make_call_listener(HXRecordEnter, HXRecordLeave, slot, NULL);
    if (!listener) {
        free(slot);
        if (error) *error = @"监听器创建失败";
        return nil;
    }

    GumAttachOptions options = { 0, };
    options.listener_function_data = slot;
    GumAttachReturn attached = gum_interceptor_attach(interceptor, (gpointer)(uintptr_t)target, listener, &options);
    if (attached != GUM_ATTACH_OK) {
        g_object_unref(listener);
        free(slot);
        if (error) {
            NSString *reason = @"未知原因";
            switch (attached) {
                case GUM_ATTACH_INVALID_INSTRUCTION: reason = @"目标入口指令无法安全重定位（函数太短或首条就是跳转）"; break;
                case GUM_ATTACH_ALREADY_ATTACHED:    reason = @"该地址已被其他 interceptor 占用"; break;
                case GUM_ATTACH_POLICY_VIOLATION:    reason = @"被策略拒绝（可能是硬件断点/代码签名策略）"; break;
                case GUM_ATTACH_WRONG_TYPE:          reason = @"地址类型不符（可能指向数据而非代码）"; break;
                case GUM_ATTACH_WRONG_SIGNATURE:     reason = @"函数签名不匹配"; break;
                default: reason = @"未知原因"; break;
            }
            *error = [NSString stringWithFormat:@"attach 失败：%@（GumAttachReturn %d）", reason, (int)attached];
        }
        return nil;
    }

    // 记录用于还原与审计的上下文。module + offset 一起存，方便人看；
    // 但还原只用内存里的 listener，不依赖这两个字段。
    NSString *image = @"";
    uint64_t imageOffset = 0;
    Dl_info info;
    if (dladdr((const void *)(uintptr_t)target, &info) != 0) {
        if (info.dli_fname) image = @(info.dli_fname);
        if (info.dli_fbase) imageOffset = target - (uint64_t)(uintptr_t)info.dli_fbase;
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"id"] = @(identifier);
    record[@"target"] = @(target);
    record[@"address"] = HXHex(target);
    record[@"label"] = label ?: @"";
    record[@"recordArgs"] = @(recordArgs);
    record[@"image"] = image;
    record[@"imageOffset"] = HXHex(imageOffset);
    record[@"attachedAt"] = @(HXMonotonicSeconds());
    record[@"calls"] = @0;
    record[@"listener"] = [NSValue valueWithPointer:listener];
    record[@"slot"] = [NSValue valueWithPointer:slot];
    _hooks[@(identifier)] = record;

    [self appendAudit:@{ @"action": @"hook", @"id": @(identifier), @"target": HXHex(target),
                         @"image": image, @"offset": HXHex(imageOffset), @"label": label ?: @"" }];

    return @{
        @"id": @(identifier),
        @"attached": @YES,
        @"address": HXHex(target),
        @"image": image,
        @"imageOffset": HXHex(imageOffset),
        @"recordArgs": @(recordArgs),
        @"note": recordArgs
            ? @"已开始记录 x0-x3 与返回值。参数按通用寄存器原样抓取，不做类型推断——浮点参数在 d0-d3，这里取不到。"
            : @"只计数不记录参数（record_args=false），高频函数建议这样开。",
    };
#endif
}

#pragma mark - operation: unhook

- (NSDictionary *)opUnhook:(NSDictionary *)arguments error:(NSString **)error {
#ifdef GX_NO_GUM
    if (error) *error = HXErrorUnavailable;
    return nil;
#else
    BOOL all = HXBoolArg(arguments, @"all", NO);
    NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
    if (all) {
        [targets addObjectsFromArray:_hooks.allKeys];
    } else {
        NSUInteger identifier = HXIntArg(arguments, @"id", 0, 0, 1000000);
        if (!identifier || !_hooks[@(identifier)]) {
            if (error) *error = @"需要 id，或者传 all=true 全部摘掉";
            return nil;
        }
        [targets addObject:@(identifier)];
    }
    if (!targets.count) {
        return @{ @"detached": @0, @"note": @"当前没有 hook" };
    }

    GumInterceptor *interceptor = gum_interceptor_obtain();
    NSMutableArray *detached = [NSMutableArray array];
    for (NSNumber *key in targets) {
        NSMutableDictionary *record = _hooks[key];
        GumInvocationListener *listener = (GumInvocationListener *)((NSValue *)record[@"listener"]).pointerValue;
        HXHookSlot *slot = (HXHookSlot *)((NSValue *)record[@"slot"]).pointerValue;
        if (listener) {
            gum_interceptor_detach(interceptor, listener);
            g_object_unref(listener);
        }
        if (slot) {
            slot->retired = 1;
            // 不 free：detach 之后仍可能有在途调用走在老 trampoline 上。
            [_retiredSlots addObject:[NSValue valueWithPointer:slot]];
        }
        [detached addObject:@{ @"id": key,
                               @"address": record[@"address"] ?: @"",
                               @"calls": @(slot ? (uint64_t)__atomic_load_n(&slot->calls, __ATOMIC_RELAXED) : 0) }];
        [_hooks removeObjectForKey:key];
        [self appendAudit:@{ @"action": @"unhook", @"id": key, @"target": record[@"address"] ?: @"" }];
    }
    return @{ @"detached": @(detached.count), @"items": detached };
#endif
}

#pragma mark - operation: events

- (NSDictionary *)opEvents:(NSDictionary *)arguments {
#ifdef GX_NO_GUM
    return @{ @"events": @[], @"count": @0, @"total": @0,
              @"note": HXErrorUnavailable };
#else
    NSUInteger limit = HXIntArg(arguments, @"limit", HXDefaultEventLimit, 1, HXMaxEventLimit);
    NSUInteger filterId = HXIntArg(arguments, @"id", 0, 0, 1000000);
    uint64_t since = 0;
    NSString *sinceText = HXStringArg(arguments, @"since");
    if (sinceText.length) HXParseAddress(sinceText, &since);
    BOOL wantsEnter = YES, wantsLeave = YES;
    NSString *phase = HXStringArg(arguments, @"phase");
    if ([phase isEqual:@"enter"]) wantsLeave = NO;
    else if ([phase isEqual:@"leave"]) wantsEnter = NO;

    uint64_t writeIndex = __atomic_load_n(&gHXWriteIndex, __ATOMIC_ACQUIRE);
    uint64_t oldest = writeIndex > HXEventCapacity ? writeIndex - HXEventCapacity : 0;
    if (since + 1 > oldest) oldest = since + 1;

    NSMutableArray *events = [NSMutableArray array];
    // 从新到旧扫，凑够 limit 就停；再翻转成时间正序返回。
    for (uint64_t index = writeIndex; index > oldest && events.count < limit; index--) {
        HXEvent *event = &gHXEvents[(index - 1) % HXEventCapacity];
        if (__atomic_load_n(&event->seq, __ATOMIC_ACQUIRE) != index) continue;
        if (event->phase == 0 && !wantsEnter) continue;
        if (event->phase == 1 && !wantsLeave) continue;
        if (filterId && event->hookId != filterId) continue;

        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"seq"] = @(event->seq);
        row[@"id"] = @(event->hookId);
        row[@"phase"] = event->phase == 0 ? @"enter" : @"leave";
        row[@"thread"] = @(event->threadId);
        row[@"depth"] = @(event->depth);
        double nowNs = HXMonotonicSeconds() * 1e9;
        row[@"ageMs"] = @((nowNs - (double)event->ts) / 1e6);
        if (event->phase == 0) {
            NSMutableArray *args = [NSMutableArray array];
            for (guint i = 0; i < HXMaxArgs; i++) {
                [args addObject:HXDescribePointer(event->args[i])];
            }
            row[@"args"] = args;
        } else {
            row[@"return"] = HXDescribePointer(event->ret);
        }
        [events insertObject:row atIndex:0];
    }

    uint64_t nextSince = events.count ? [events.lastObject[@"seq"] unsignedLongLongValue] : since;
    return @{
        @"events": events,
        @"count": @(events.count),
        @"writeIndex": @(writeIndex),
        @"nextSince": [NSString stringWithFormat:@"%llu", (unsigned long long)nextSince],
        // 最早还留着的序号。小于它的记录已被环形缓冲覆盖，拉不回来了。
        @"earliestSeq": [NSString stringWithFormat:@"%llu", (unsigned long long)(oldest + 1)],
        @"capacity": @(HXEventCapacity),
    };
#endif
}

#pragma mark - operation: clear

- (NSDictionary *)opClear:(NSDictionary *)arguments {
#ifdef GX_NO_GUM
    return @{ @"cleared": @YES, @"note": HXErrorUnavailable };
#else
    // 不清 seq，只把 since 游标推到当前写入位置：老的槽位会被后续写入自然覆盖，
    // 而正在被读的快照不会突然失效。
    uint64_t writeIndex = __atomic_load_n(&gHXWriteIndex, __ATOMIC_ACQUIRE);
    BOOL alsoResetCounters = HXBoolArg(arguments, @"reset_counters", NO);
    if (alsoResetCounters) {
        for (NSDictionary *record in _hooks.allValues) {
            HXHookSlot *slot = (HXHookSlot *)((NSValue *)record[@"slot"]).pointerValue;
            if (slot) __atomic_store_n(&slot->calls, 0, __ATOMIC_RELAXED);
        }
    }
    return @{ @"cleared": @YES, @"writeIndex": @(writeIndex),
              @"resetCounters": @(alsoResetCounters),
              @"note": @"清空只影响后续拉取；已有事件会被新写入逐步覆盖。" };
#endif
}

#pragma mark - operation: patch

- (NSDictionary *)opPatch:(NSDictionary *)arguments error:(NSString **)error {
#ifdef GX_NO_GUM
    if (error) *error = HXErrorUnavailable;
    return nil;
#else
    if (_patches.count >= HXMaxPatches) {
        if (error) *error = [NSString stringWithFormat:@"同时最多 %lu 处补丁，请先 restore", (unsigned long)HXMaxPatches];
        return nil;
    }
    uint64_t target = [self resolveTarget:arguments error:error];
    if (!target) return nil;

    NSString *bytesText = HXStringArg(arguments, @"bytes");
    NSData *bytes = HXParseHexBytes(bytesText);
    if (!bytes.length) {
        if (error) *error = @"bytes 需要十六进制字节串，例如 \"1f 20 03 d5\"（NOP）";
        return nil;
    }
    if (bytes.length > HXMaxPatchBytes) {
        if (error) *error = [NSString stringWithFormat:@"单次最多写 %lu 字节", (unsigned long)HXMaxPatchBytes];
        return nil;
    }
    // 写非整指令会在指令中间留下半条编码，取指时是随机指令流。
    // 要求 4 的整数倍，是这条工具唯一强硬的形式约束。
    if (bytes.length % 4 != 0) {
        if (error) *error = [NSString stringWithFormat:@"长度必须是 4 的整数倍（当前 %lu 字节），否则会写出半条指令", (unsigned long)bytes.length];
        return nil;
    }

    for (NSDictionary *record in _patches.allValues) {
        uint64_t start = [record[@"target"] unsignedLongLongValue];
        NSUInteger length = [record[@"length"] unsignedIntegerValue];
        if (target < start + length && start < target + bytes.length) {
            if (error) *error = [NSString stringWithFormat:@"与已有补丁（id %@）区间重叠，先 restore", record[@"id"]];
            return nil;
        }
    }
    for (NSDictionary *record in _hooks.allValues) {
        if ([record[@"target"] unsignedLongLongValue] == target) {
            if (error) *error = @"该地址正在被 hook，改写入口字节会破坏 trampoline，先 unhook";
            return nil;
        }
    }

    NSString *failure = HXValidateExecutableTarget(target, bytes.length);
    if (failure) {
        if (error) *error = failure;
        return nil;
    }

    // 备份原始字节。备份失败就绝不能往下写——没有原始字节就没有还原。
    NSMutableData *original = [NSMutableData dataWithLength:bytes.length];
    gsize read = 0;
    uint8_t *buffer = gum_memory_read((gconstpointer)(uintptr_t)target, (gsize)bytes.length, &read);
    if (buffer && read == bytes.length) {
        [original setData:[NSData dataWithBytes:buffer length:read]];
    }
    if (buffer) g_free(buffer);
    if (original.length != bytes.length) {
        if (error) *error = @"读取原始字节失败，拒绝写入（没有备份就无法还原）";
        return nil;
    }

    HXPatchPayload payload = { (const uint8_t *)bytes.bytes, (size_t)bytes.length };
    if (!gum_memory_patch_code((gpointer)(uintptr_t)target, (gsize)bytes.length, HXPatchApply, &payload)) {
        if (error) *error = @"写入代码页失败：目标页可能不可写且无法写时复制（系统共享页常见）";
        return nil;
    }

    // 读回验证。gum 应该已经刷新了指令缓存，但读到的不等于写入的就是失败的写入。
    gsize verifyRead = 0;
    uint8_t *verify = gum_memory_read((gconstpointer)(uintptr_t)target, (gsize)bytes.length, &verifyRead);
    BOOL verified = verify && verifyRead == bytes.length && memcmp(verify, bytes.bytes, bytes.length) == 0;
    if (verify) g_free(verify);
    if (!verified) {
        // 已经写进去了但读回不一致，立刻用备份回滚，不留半成品。
        HXPatchPayload rollback = { (const uint8_t *)original.bytes, (size_t)original.length };
        gum_memory_patch_code((gpointer)(uintptr_t)target, (gsize)original.length, HXPatchApply, &rollback);
        if (error) *error = @"写入后读回不一致，已自动回滚到原始字节";
        return nil;
    }

    NSUInteger identifier = _nextPatchId++;
    NSString *image = @"";
    uint64_t imageOffset = 0;
    Dl_info info;
    if (dladdr((const void *)(uintptr_t)target, &info) != 0) {
        if (info.dli_fname) image = @(info.dli_fname);
        if (info.dli_fbase) imageOffset = target - (uint64_t)(uintptr_t)info.dli_fbase;
    }
    NSString *originalText = HXHexBytes((const uint8_t *)original.bytes, original.length);

    _patches[@(identifier)] = [@{
        @"id": @(identifier),
        @"target": @(target),
        @"address": HXHex(target),
        @"length": @(bytes.length),
        @"original": originalText,
        @"patched": HXHexBytes((const uint8_t *)bytes.bytes, bytes.length),
        @"image": image,
        @"imageOffset": HXHex(imageOffset),
        @"label": HXStringArg(arguments, @"label") ?: @"",
    } mutableCopy];

    [self appendAudit:@{ @"action": @"patch", @"id": @(identifier), @"target": HXHex(target),
                         @"original": originalText, @"patched": HXHexBytes((const uint8_t *)bytes.bytes, bytes.length) }];

    return @{
        @"id": @(identifier),
        @"written": @YES,
        @"address": HXHex(target),
        @"length": @(bytes.length),
        @"original": originalText,
        @"patched": HXHexBytes((const uint8_t *)bytes.bytes, bytes.length),
        @"verified": @YES,
        @"note": @"原始字节已备份，可用 restore(id) 写回。还原只对当前进程有效。",
    };
#endif
}

#pragma mark - operation: restore

- (NSDictionary *)opRestore:(NSDictionary *)arguments error:(NSString **)error {
#ifdef GX_NO_GUM
    if (error) *error = HXErrorUnavailable;
    return nil;
#else
    BOOL all = HXBoolArg(arguments, @"all", NO);
    NSMutableArray<NSNumber *> *targets = [NSMutableArray array];
    if (all) {
        [targets addObjectsFromArray:_patches.allKeys];
    } else {
        NSUInteger identifier = HXIntArg(arguments, @"id", 0, 0, 1000000);
        if (!identifier || !_patches[@(identifier)]) {
            if (error) *error = @"需要 id，或者传 all=true 全部还原";
            return nil;
        }
        [targets addObject:@(identifier)];
    }
    if (!targets.count) return @{ @"restored": @0, @"note": @"当前没有补丁" };

    NSMutableArray *restored = [NSMutableArray array];
    NSMutableArray *failed = [NSMutableArray array];
    for (NSNumber *key in targets) {
        NSDictionary *record = _patches[key];
        uint64_t target = [record[@"target"] unsignedLongLongValue];
        NSData *original = HXParseHexBytes(record[@"original"]);
        if (!original.length) {
            [failed addObject:@{ @"id": key, @"reason": @"备份字节损坏" }];
            continue;
        }
        HXPatchPayload payload = { (const uint8_t *)original.bytes, (size_t)original.length };
        if (!gum_memory_patch_code((gpointer)(uintptr_t)target, (gsize)original.length, HXPatchApply, &payload)) {
            [failed addObject:@{ @"id": key, @"reason": @"写回失败，目标页不可写" }];
            continue;
        }
        gsize verifyRead = 0;
        uint8_t *verify = gum_memory_read((gconstpointer)(uintptr_t)target, (gsize)original.length, &verifyRead);
        BOOL ok = verify && verifyRead == original.length && memcmp(verify, original.bytes, original.length) == 0;
        if (verify) g_free(verify);
        if (!ok) {
            [failed addObject:@{ @"id": key, @"reason": @"写回后读回不一致" }];
            continue;
        }
        [restored addObject:@{ @"id": key, @"address": record[@"address"] ?: @"",
                               @"original": record[@"original"] ?: @"" }];
        [_patches removeObjectForKey:key];
        [self appendAudit:@{ @"action": @"restore", @"id": key, @"target": record[@"address"] ?: @"" }];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"restored"] = @(restored.count);
    result[@"items"] = restored;
    if (failed.count) result[@"failed"] = failed;
    return result;
#endif
}

#pragma mark - 分发

- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *_Nullable, NSString *_Nullable))completion {
    if (![operation isKindOfClass:NSString.class] || ![arguments isKindOfClass:NSDictionary.class]) {
        arguments = @{};
    }
    // 所有 gum 调用走同一条串行队列：Interceptor 的 attach/detach 会改写代码页并
    // 维护自己的内部表，并发进入没有意义且会互相看到中间态。
    dispatch_async(_queue, ^{
        NSDictionary *result = nil;
        NSString *error = nil;
        NSString *name = operation ?: @"";

        if ([name isEqual:@"status"]) {
            result = [self opStatus];
        } else if ([name isEqual:@"list"]) {
            result = [self opList];
        } else if ([name isEqual:@"hook"]) {
            result = [self opHook:arguments error:&error];
        } else if ([name isEqual:@"unhook"]) {
            result = [self opUnhook:arguments error:&error];
        } else if ([name isEqual:@"events"]) {
            result = [self opEvents:arguments];
        } else if ([name isEqual:@"clear"]) {
            result = [self opClear:arguments];
        } else if ([name isEqual:@"patch"]) {
            result = [self opPatch:arguments error:&error];
        } else if ([name isEqual:@"restore"]) {
            result = [self opRestore:arguments error:&error];
        } else if ([name isEqual:@"selftest"]) {
            NSDictionary *report = [self runSelfTest];
            self->_selfTestPassed = [report[@"ok"] boolValue];
            self->_selfTestDetail = [report[@"reason"] copy] ?: @"通过";
            result = report;
        } else {
            error = [NSString stringWithFormat:@"未知 operation：%@（支持 %@）",
                     name, [[FLEXAiFlexHook supportedOperations] componentsJoinedByString:@", "]];
        }

        // hook 的调用计数在 C 层原子递增，这里同步回记录里，供 list 展示。
        if ([name isEqual:@"list"] || [name isEqual:@"status"]) {
            for (NSNumber *key in self->_hooks.allKeys) {
                NSMutableDictionary *record = self->_hooks[key];
                HXHookSlot *slot = (HXHookSlot *)((NSValue *)record[@"slot"]).pointerValue;
                if (slot) record[@"calls"] = @((uint64_t)__atomic_load_n(&slot->calls, __ATOMIC_RELAXED));
            }
        }

        completion(error ? nil : result, error);
    });
}

- (void)teardownSynchronously {
#ifdef GX_NO_GUM
    return;
#else
    dispatch_sync(_queue, ^{
        GumInterceptor *interceptor = gum_interceptor_obtain();
        for (NSNumber *key in self->_hooks.allKeys) {
            NSDictionary *record = self->_hooks[key];
            GumInvocationListener *listener = (GumInvocationListener *)((NSValue *)record[@"listener"]).pointerValue;
            if (listener) {
                gum_interceptor_detach(interceptor, listener);
                g_object_unref(listener);
            }
        }
        [self->_hooks removeAllObjects];
        for (NSNumber *key in self->_patches.allKeys) {
            NSDictionary *record = self->_patches[key];
            NSData *original = HXParseHexBytes(record[@"original"]);
            if (!original.length) continue;
            HXPatchPayload payload = { (const uint8_t *)original.bytes, (size_t)original.length };
            gum_memory_patch_code((gpointer)(uintptr_t)[record[@"target"] unsignedLongLongValue],
                                  (gsize)original.length, HXPatchApply, &payload);
        }
        [self->_patches removeAllObjects];
    });
#endif
}

@end
