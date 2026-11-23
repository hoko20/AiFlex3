#import "FLEXAiFlexFrida.h"
#import "FLEXDoKitCrashMonitor.h"

#import <execinfo.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>

#ifndef GX_NO_GUM
#include "frida-gum.h"
#endif

// 本文件按 frida-gum 17.27.4 的真实头文件书写。几个与旧版本不同、容易踩的点：
//   * 没有 GumModuleDetails：gum_process_enumerate_modules 的回调直接给 GumModule *。
//   * 没有 gum_version_string：引擎版本只能由构建时的 devkit 决定，这里不做谎报。
//   * 没有 gum_memory_enumerate_ranges，用的是 gum_process_enumerate_ranges。
//   * GumExportDetails / GumImportDetails 的 type 是枚举（不是字符串），
//     GumImportDetails.module 是 const gchar *（不是 GumModule *）。
//   * GumThreadDetails.cpu_context 是值不是指针，state 也是枚举。
//   * gum_module_load 需要第二个 GError ** 参数；gum_module_get_range 返回
//     const GumMemoryRange *（不再有 size 输出参数）。
//   * gum 自带 gum_memory_scan + GumMatchPattern，特征码扫描不需要自己实现匹配。

#pragma mark - 常量

#define GXMaxBacktraceDepth 96

static const NSUInteger GXDefaultLimit      = 200;
static const NSUInteger GXMaxLimit          = 2000;
static const NSUInteger GXDefaultReadBytes  = 256;
static const NSUInteger GXMaxReadBytes      = 65536;
static const NSUInteger GXMaxHexBytes       = 4096;
static const NSUInteger GXDefaultScanBytes  = 32 * 1024 * 1024;
static const NSUInteger GXMaxScanBytes      = 256 * 1024 * 1024;
static const NSUInteger GXDefaultMatches    = 20;
static const NSUInteger GXMaxMatches        = 100;
static const double     GXScanBudget        = 4.0;
static const size_t     GXMaxSingleRegion   = 64 * 1024 * 1024;

static NSString * const GXErrorUnavailable =
    @"Frida 引擎未编入当前构建（frida-gum devkit 缺失）。请在 CI 中拉取 frida-gum 后重新打包。";

#pragma mark - 参数工具

static NSString *GXStringArg(NSDictionary *arguments, NSString *key) {
    id value = arguments[key];
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value length] ? value : nil;
    }
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSUInteger GXIntArg(NSDictionary *arguments, NSString *key, NSUInteger fallback, NSUInteger minimum, NSUInteger maximum) {
    id value = arguments[key];
    long long parsed = (long long)fallback;
    if ([value isKindOfClass:NSNumber.class]) {
        parsed = [(NSNumber *)value longLongValue];
    } else if ([value isKindOfClass:NSString.class]) {
        parsed = [(NSString *)value longLongValue];
    }
    if (parsed < (long long)minimum) parsed = (long long)minimum;
    if (parsed > (long long)maximum) parsed = (long long)maximum;
    return (NSUInteger)parsed;
}

// 地址一律按字符串传：JSON number 是 double，超过 2^53 会丢精度，
// 而 arm64 的真实地址经常在 0x7ff... 与 0x1... 之间跳。
static BOOL GXParseAddress(NSString *text, uint64_t *out) {
    if (!text.length) return NO;
    const char *raw = text.UTF8String;
    if (!raw || !*raw) return NO;
    while (*raw == ' ') raw++;
    char *end = NULL;
    unsigned long long value = strtoull(raw, &end, 0);
    if (end == raw) return NO;
    if (out) *out = (uint64_t)value;
    return YES;
}

static NSString *GXProtectionString(uint32_t protection) {
    char text[4] = { '-', '-', '-', 0 };
    if (protection & 1) text[0] = 'r';
    if (protection & 2) text[1] = 'w';
    if (protection & 4) text[2] = 'x';
    return [NSString stringWithUTF8String:text];
}

static NSString *GXBaseName(const char *path) {
    if (!path) return @"";
    const char *slash = strrchr(path, '/');
    const char *name = slash ? slash + 1 : path;
    return [NSString stringWithUTF8String:name] ?: @"";
}

static NSString *GXStringFromCString(const char *text) {
    if (!text) return @"";
    return [NSString stringWithUTF8String:text] ?: @"";
}

#pragma mark - 引擎初始化

static BOOL GXEnsureEngine(void) {
#ifdef GX_NO_GUM
    return NO;
#else
    static BOOL ready = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // gum_init_embedded 只能调一次：内部锁与调度线程重复初始化会直接崩。
        gum_init_embedded();
        ready = YES;
    });
    return ready;
#endif
}

#pragma mark - 回调（只在 gum 分支编译）

#ifndef GX_NO_GUM

static gboolean GXCollectModule(GumModule *module, gpointer user_data) {
    NSMutableArray *out = (__bridge NSMutableArray *)user_data;
    if (!module) return TRUE;
    const GumMemoryRange *range = gum_module_get_range(module);
    [out addObject:@{
        @"name": GXStringFromCString(gum_module_get_name(module)),
        @"path": GXStringFromCString(gum_module_get_path(module)),
        @"version": GXStringFromCString(gum_module_get_version(module)),
        @"base": [NSString stringWithFormat:@"0x%llx",
                 (unsigned long long)(range ? range->base_address : 0)],
        @"size": @(range ? range->size : 0),
    }];
    return TRUE;
}

static NSString *GXExportTypeString(GumExportType type) {
    switch (type) {
        case GUM_EXPORT_FUNCTION: return @"function";
        case GUM_EXPORT_VARIABLE: return @"variable";
        default: return @"unknown";
    }
}

static NSString *GXImportTypeString(GumImportType type) {
    switch (type) {
        case GUM_IMPORT_FUNCTION: return @"function";
        case GUM_IMPORT_VARIABLE: return @"variable";
        default: return @"unknown";
    }
}

static NSString *GXThreadStateString(GumThreadState state) {
    switch (state) {
        case GUM_THREAD_RUNNING: return @"running";
        case GUM_THREAD_STOPPED: return @"stopped";
        case GUM_THREAD_WAITING: return @"waiting";
        case GUM_THREAD_UNINTERRUPTIBLE: return @"uninterruptible";
        case GUM_THREAD_HALTED: return @"halted";
        default: return @"unknown";
    }
}

static gboolean GXCollectExport(const GumExportDetails *details, gpointer user_data) {
    NSMutableArray *out = (__bridge NSMutableArray *)user_data;
    if (!details) return TRUE;
    [out addObject:@{
        @"name": GXStringFromCString(details->name),
        @"type": GXExportTypeString(details->type),
        @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)details->address],
    }];
    return TRUE;
}

static gboolean GXCollectImport(const GumImportDetails *details, gpointer user_data) {
    NSMutableArray *out = (__bridge NSMutableArray *)user_data;
    if (!details) return TRUE;
    [out addObject:@{
        @"name": GXStringFromCString(details->name),
        @"type": GXImportTypeString(details->type),
        @"fromModule": GXStringFromCString(details->module),
        @"slot": [NSString stringWithFormat:@"0x%llx", (unsigned long long)details->slot],
    }];
    return TRUE;
}

static gboolean GXCollectThread(const GumThreadDetails *details, gpointer user_data) {
    NSMutableArray *out = (__bridge NSMutableArray *)user_data;
    if (!details) return TRUE;
    // cpu_context 是值类型，寄存器内容属于敏感数据，这里刻意不读。
    [out addObject:@{
        @"id": @(details->id),
        @"name": GXStringFromCString(details->name),
        @"state": GXThreadStateString(details->state),
    }];
    return TRUE;
}

typedef struct {
    void *ranges;       // __bridge NSMutableArray *
    void *filter;       // __bridge NSString *
    NSUInteger limit;
    NSUInteger total;
} GXRangeContext;

static gboolean GXCollectRangeEntry(const GumRangeDetails *details, gpointer user_data) {
    GXRangeContext *ctx = (GXRangeContext *)user_data;
    if (!details || !details->range) return TRUE;
    ctx->total++;
    NSMutableArray *ranges = (__bridge NSMutableArray *)ctx->ranges;
    if (ranges.count >= ctx->limit) return TRUE;

    NSString *protection = GXProtectionString(details->protection);
    NSString *filter = (__bridge NSString *)ctx->filter;
    if (filter.length &&
        [protection rangeOfString:filter options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return TRUE;
    }

    GumAddress base = details->range->base_address;
    gsize size = details->range->size;
    [ranges addObject:@{
        @"start": [NSString stringWithFormat:@"0x%llx", (unsigned long long)base],
        @"end": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(base + size)],
        @"size": @(size),
        @"protection": protection,
    }];
    return TRUE;
}

typedef struct {
    GumMatchPattern *pattern;
    void *matches;          // __bridge NSMutableArray *
    BOOL hasModuleRange;
    GumAddress moduleBase;
    GumAddress moduleEnd;
    NSUInteger limit;
    NSUInteger scanned;
    NSUInteger maxBytes;
    double deadline;
    BOOL exhausted;
} GXScanContext;

static gboolean GXScanMatch(GumAddress address, gsize size, gpointer user_data) {
    GXScanContext *ctx = (GXScanContext *)user_data;
    if (ctx->exhausted) return FALSE;
    NSMutableArray *matches = (__bridge NSMutableArray *)ctx->matches;
    [matches addObject:@{
        @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
        @"length": @(size),
    }];
    if (matches.count >= ctx->limit) { ctx->exhausted = YES; return FALSE; }
    if (CFAbsoluteTimeGetCurrent() > ctx->deadline) { ctx->exhausted = YES; return FALSE; }
    return TRUE;
}

static gboolean GXScanRange(const GumRangeDetails *details, gpointer user_data) {
    GXScanContext *ctx = (GXScanContext *)user_data;
    if (!details || !details->range || ctx->exhausted) return FALSE;
    if (CFAbsoluteTimeGetCurrent() > ctx->deadline) { ctx->exhausted = YES; return FALSE; }

    uint32_t protection = details->protection;
    // 白名单式过滤：必须可读、跳过可执行段（代码段噪音大且更易出问题）。
    if (!(protection & GUM_PAGE_READ)) return TRUE;
    if (protection & GUM_PAGE_EXECUTE) return TRUE;

    GumAddress base = details->range->base_address;
    gsize size = details->range->size;
    if (size == 0 || size > GXMaxSingleRegion) return TRUE;

    if (ctx->hasModuleRange) {
        if (base + size <= ctx->moduleBase || base >= ctx->moduleEnd) return TRUE;
        if (base < ctx->moduleBase) {
            size -= (gsize)(ctx->moduleBase - base);
            base = ctx->moduleBase;
        }
        if (base + size > ctx->moduleEnd) size = (gsize)(ctx->moduleEnd - base);
        if (size == 0) return TRUE;
    }
    if (ctx->scanned >= ctx->maxBytes) { ctx->exhausted = YES; return FALSE; }

    // 整段确认可读，避免扫到 guard page 触发 SIGBUS。
    if (!gum_memory_is_readable((gconstpointer)(uintptr_t)base, size)) return TRUE;

    GumMemoryRange range = { base, size };
    gum_memory_scan(&range, ctx->pattern, GXScanMatch, ctx);

    ctx->scanned += size;
    return TRUE;
}

#endif // GX_NO_GUM

#pragma mark - 类

@interface FLEXAiFlexFrida ()
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FLEXAiFlexFrida

+ (instancetype)sharedEngine {
    static FLEXAiFlexFrida *engine = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[self alloc] init]; });
    return engine;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.hoko20.aiflex3.frida", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}

+ (BOOL)engineAvailable {
    return GXEnsureEngine();
}

+ (NSString *)engineVersion {
#ifndef GX_NO_GUM
    if (!GXEnsureEngine()) return nil;
    // 17.x 的 devkit 不再导出 gum_version_string，版本由构建时拉取的 devkit 决定；
    // 这里不做谎报，具体 tag 记录在 .github/workflows/build.yml 的运行日志里。
    return @"embedded-devkit";
#else
    return nil;
#endif
}

+ (NSArray<NSString *> *)supportedOperations {
    return @[@"status", @"modules", @"exports", @"imports", @"resolve", @"threads",
             @"backtrace", @"memory_ranges", @"read_mem", @"scan", @"crash_log"];
}

#pragma mark - 分发

- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *, NSString *))completion {
    if (!completion) return;
    if (![operation isKindOfClass:NSString.class] || !operation.length) {
        completion(nil, @"缺少 operation");
        return;
    }

    NSDictionary *wire = [arguments isKindOfClass:NSDictionary.class] ? arguments : @{};

    // backtrace 必须在主线程取栈，否则拿到的是引擎队列自己的调用栈，毫无意义。
    // crash_log 读的是 DoKit 的可变数组，也放主线程，避免并发修改。
    BOOL onMain = [operation isEqualToString:@"backtrace"] || [operation isEqualToString:@"crash_log"];
    __weak typeof(self) weakSelf = self;

    void (^work)(void) = ^{
        NSString *error = nil;
        NSDictionary *result = nil;
        @try {
            result = [weakSelf run:operation arguments:wire error:&error];
        } @catch (NSException *exception) {
            error = [NSString stringWithFormat:@"Frida 引擎异常（%@: %@）", exception.name, exception.reason];
        }
        completion(result, error);
    };

    if (onMain) dispatch_async(dispatch_get_main_queue(), work);
    else dispatch_async(_queue, work);
}

- (NSDictionary *)run:(NSString *)operation arguments:(NSDictionary *)arguments error:(NSString **)error {
    if ([operation isEqualToString:@"status"])    return [self opStatus];
    if ([operation isEqualToString:@"backtrace"]) return [self opBacktrace:arguments error:error];
    if ([operation isEqualToString:@"crash_log"]) return [self opCrashLog:arguments error:error];

    // 以下全部依赖 gum。
    if (!GXEnsureEngine()) { *error = GXErrorUnavailable; return nil; }

#ifndef GX_NO_GUM
    if ([operation isEqualToString:@"modules"])       return [self opModules:arguments error:error];
    if ([operation isEqualToString:@"exports"])       return [self opExports:arguments error:error];
    if ([operation isEqualToString:@"imports"])       return [self opImports:arguments error:error];
    if ([operation isEqualToString:@"resolve"])       return [self opResolve:arguments error:error];
    if ([operation isEqualToString:@"threads"])       return [self opThreads:arguments error:error];
    if ([operation isEqualToString:@"memory_ranges"]) return [self opMemoryRanges:arguments error:error];
    if ([operation isEqualToString:@"read_mem"])      return [self opReadMemory:arguments error:error];
    if ([operation isEqualToString:@"scan"])          return [self opScan:arguments error:error];
#endif

    *error = [@"不支持的 Frida operation：" stringByAppendingString:operation];
    return nil;
}

#pragma mark - status（不依赖 gum）

- (NSDictionary *)opStatus {
    return @{
        @"engine": @"frida-gum",
        @"available": @([FLEXAiFlexFrida engineAvailable]),
        @"version": [FLEXAiFlexFrida engineVersion] ?: @"unavailable",
        @"readOnly": @YES,
        @"operations": [FLEXAiFlexFrida supportedOperations],
        @"writeCapabilities": @[],
        @"note": @"本组只做只读：模块/符号/线程/内存区间/内存读/特征扫描/回调栈/崩溃记录。"
                 @"不提供 inline hook、内存写入、代码补丁与 Stalker——写类能力需要独立的备份、"
                 @"自检与回滚机制，不应和只读能力共用同一个授权开关。",
    };
}

#pragma mark - backtrace（不依赖 gum）

- (NSDictionary *)opBacktrace:(NSDictionary *)arguments error:(NSString **)error {
    NSUInteger depth = GXIntArg(arguments, @"depth", 32, 1, GXMaxBacktraceDepth);
    void *frames[GXMaxBacktraceDepth];
    int captured = backtrace(frames, (int)depth);
    if (captured <= 0) {
        *error = @"当前线程取栈失败（可选：depth 1-96）";
        return nil;
    }

    NSMutableArray *list = [NSMutableArray arrayWithCapacity:(NSUInteger)captured];
    for (int index = 0; index < captured; index++) {
        uintptr_t address = (uintptr_t)frames[index];
        Dl_info info;
        memset(&info, 0, sizeof(info));
        NSMutableDictionary *entry = [@{
            @"index": @(index),
            @"address": [NSString stringWithFormat:@"0x%lx", (unsigned long)address],
        } mutableCopy];
        if (dladdr((void *)address, &info)) {
            entry[@"image"] = GXBaseName(info.dli_fname);
            if (info.dli_sname && info.dli_saddr) {
                entry[@"symbol"] = [NSString stringWithUTF8String:info.dli_sname] ?: @"";
                entry[@"offset"] = [NSString stringWithFormat:@"0x%lx",
                                    (unsigned long)(address - (uintptr_t)info.dli_saddr)];
            } else {
                entry[@"offset"] = [NSString stringWithFormat:@"0x%lx",
                                    (unsigned long)(address - (uintptr_t)info.dli_fbase)];
            }
        }
        [list addObject:entry];
    }

    return @{@"thread": [NSThread isMainThread] ? @"main" : @"other",
             @"count": @(captured),
             @"frames": list};
}

#pragma mark - crash_log（复用 DoKit 已捕获的数据，不重复注册 signal handler）

- (NSDictionary *)opCrashLog:(NSDictionary *)arguments error:(NSString **)error {
    NSUInteger limit = GXIntArg(arguments, @"limit", 10, 1, 50);
    FLEXDoKitCrashMonitor *monitor = [FLEXDoKitCrashMonitor sharedInstance];
    NSArray<FLEXDoKitCrashInfo *> *logs = monitor.crashLogs;

    NSMutableArray *entries = [NSMutableArray array];
    NSInteger total = (NSInteger)logs.count;
    NSInteger start = MAX(0, total - (NSInteger)limit);
    for (NSInteger index = total - 1; index >= start; index--) {
        FLEXDoKitCrashInfo *info = logs[(NSUInteger)index];
        NSMutableDictionary *entry = [@{
            @"reason": info.reason ?: @"",
            @"timestamp": @(info.timestamp ? [info.timestamp timeIntervalSince1970] : 0),
            @"callStack": info.callStack ?: @[],
        } mutableCopy];
        entry[@"kind"] = (info.type == FLEXDoKitCrashTypeSignal) ? @"signal" : @"exception";
        [entries addObject:entry];
    }

    return @{@"count": @(entries.count),
             @"totalStored": @(total),
             @"note": @"信号崩溃由 FLEXDoKitCrashMonitor 在崩溃瞬间落盘裸帧、下次启动时符号化回捞；"
                      @"崩溃当次进程已不存在，因此记录在下一次启动后才可见。本 operation 只读已有记录，"
                      @"不会额外注册 signal handler。",
             @"entries": entries};
}

#ifndef GX_NO_GUM

#pragma mark - modules

- (NSDictionary *)opModules:(NSDictionary *)arguments error:(NSString **)error {
    NSString *filter = GXStringArg(arguments, @"filter");
    NSUInteger limit = GXIntArg(arguments, @"limit", GXDefaultLimit, 1, GXMaxLimit);

    NSMutableArray *all = [NSMutableArray array];
    gum_process_enumerate_modules(GXCollectModule, (__bridge gpointer)all);

    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *entry in all) {
        if (filter.length) {
            BOOL hit = [entry[@"name"] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [entry[@"path"] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!hit) continue;
        }
        [filtered addObject:entry];
        if (filtered.count >= limit) break;
    }

    return @{@"total": @(all.count),
             @"count": @(filtered.count),
             @"truncated": @(filtered.count < all.count),
             @"modules": filtered};
}

#pragma mark - exports / imports

- (GumModule *)loadModuleNamed:(NSString *)name error:(NSString **)error {
    GError *glibError = NULL;
    GumModule *module = gum_module_load(name.UTF8String, &glibError);
    if (!module) {
        NSString *reason = glibError ? [NSString stringWithUTF8String:glibError->message] : nil;
        if (glibError) g_error_free(glibError);
        *error = reason.length
            ? [NSString stringWithFormat:@"加载模块失败：%@（%@）", name, reason]
            : [NSString stringWithFormat:@"找不到模块：%@（用 modules 的 filter 确认准确名称）", name];
        return NULL;
    }
    return module;
}

- (NSDictionary *)opExports:(NSDictionary *)arguments error:(NSString **)error {
    NSString *moduleName = GXStringArg(arguments, @"module");
    if (!moduleName.length) { *error = @"exports 需要 module 参数（模块名或完整路径）"; return nil; }
    NSString *query = GXStringArg(arguments, @"query");
    NSUInteger limit = GXIntArg(arguments, @"limit", GXDefaultLimit, 1, GXMaxLimit);

    GumModule *module = [self loadModuleNamed:moduleName error:error];
    if (!module) return nil;

    NSMutableArray *all = [NSMutableArray array];
    gum_module_enumerate_exports(module, GXCollectExport, (__bridge gpointer)all);

    const GumMemoryRange *range = gum_module_get_range(module);
    GumAddress moduleBase = range ? range->base_address : 0;
    gsize moduleSize = range ? range->size : 0;
    g_object_unref(module);

    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *entry in all) {
        if (query.length &&
            [entry[@"name"] rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [filtered addObject:entry];
        if (filtered.count >= limit) break;
    }

    return @{@"module": moduleName,
             @"base": [NSString stringWithFormat:@"0x%llx", (unsigned long long)moduleBase],
             @"size": @(moduleSize),
             @"total": @(all.count),
             @"count": @(filtered.count),
             @"truncated": @(filtered.count < all.count),
             @"exports": filtered};
}

- (NSDictionary *)opImports:(NSDictionary *)arguments error:(NSString **)error {
    NSString *moduleName = GXStringArg(arguments, @"module");
    if (!moduleName.length) { *error = @"imports 需要 module 参数（模块名或完整路径）"; return nil; }
    NSString *query = GXStringArg(arguments, @"query");
    NSUInteger limit = GXIntArg(arguments, @"limit", GXDefaultLimit, 1, GXMaxLimit);

    GumModule *module = [self loadModuleNamed:moduleName error:error];
    if (!module) return nil;

    NSMutableArray *all = [NSMutableArray array];
    gum_module_enumerate_imports(module, GXCollectImport, (__bridge gpointer)all);
    g_object_unref(module);

    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *entry in all) {
        if (query.length) {
            NSString *name = entry[@"name"] ?: @"";
            NSString *from = entry[@"fromModule"] ?: @"";
            BOOL hit = [name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [from rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!hit) continue;
        }
        [filtered addObject:entry];
        if (filtered.count >= limit) break;
    }

    return @{@"module": moduleName,
             @"total": @(all.count),
             @"count": @(filtered.count),
             @"truncated": @(filtered.count < all.count),
             @"imports": filtered};
}

#pragma mark - resolve

- (NSDictionary *)opResolve:(NSDictionary *)arguments error:(NSString **)error {
    NSString *addressText = GXStringArg(arguments, @"address");
    NSString *moduleName = GXStringArg(arguments, @"module");
    NSString *symbolName = GXStringArg(arguments, @"name");

    if (addressText.length) {
        uint64_t address = 0;
        if (!GXParseAddress(addressText, &address)) {
            *error = [NSString stringWithFormat:@"address 解析失败：%@（示例：0x104a2b000）", addressText];
            return nil;
        }
        NSMutableDictionary *result = [@{
            @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
        } mutableCopy];

        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr((void *)(uintptr_t)address, &info)) {
            result[@"image"] = GXBaseName(info.dli_fname);
            result[@"imagePath"] = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"";
            result[@"imageOffset"] = [NSString stringWithFormat:@"0x%llx",
                                      (unsigned long long)(address - (uintptr_t)info.dli_fbase)];
            if (info.dli_sname && info.dli_saddr) {
                result[@"symbol"] = [NSString stringWithUTF8String:info.dli_sname] ?: @"";
                result[@"symbolOffset"] = [NSString stringWithFormat:@"0x%llx",
                                           (unsigned long long)(address - (uintptr_t)info.dli_saddr)];
            }
        } else {
            result[@"image"] = @"";
            result[@"note"] = @"该地址不在任何已加载镜像内，可能是堆/栈地址或未映射区域。";
        }

        // 补一条 gum 视角的归属（dladdr 只认符号，gum 认整个模块范围）
        GumModule *owner = gum_process_find_module_by_address((GumAddress)address);
        if (owner) {
            const GumMemoryRange *range = gum_module_get_range(owner);
            result[@"gumModule"] = GXStringFromCString(gum_module_get_name(owner));
            if (range) {
                result[@"gumModuleBase"] = [NSString stringWithFormat:@"0x%llx",
                                            (unsigned long long)range->base_address];
            }
            g_object_unref(owner);
        }
        return result;
    }

    if (moduleName.length && symbolName.length) {
        GumModule *module = [self loadModuleNamed:moduleName error:error];
        if (!module) return nil;

        GumAddress exported = gum_module_find_export_by_name(module, symbolName.UTF8String);
        GumAddress symbol = exported ? exported : gum_module_find_symbol_by_name(module, symbolName.UTF8String);

        const GumMemoryRange *range = gum_module_get_range(module);
        GumAddress moduleBase = range ? range->base_address : 0;
        g_object_unref(module);

        if (!symbol) {
            *error = [NSString stringWithFormat:@"模块 %@ 中没有符号 %@（可用 exports 的 query 模糊查）", moduleName, symbolName];
            return nil;
        }
        return @{@"module": moduleName,
                 @"name": symbolName,
                 @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)symbol],
                 @"offset": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(symbol - moduleBase)],
                 @"moduleBase": [NSString stringWithFormat:@"0x%llx", (unsigned long long)moduleBase],
                 @"kind": exported ? @"export" : @"symbol"};
    }

    *error = @"resolve 需要 address，或 module + name";
    return nil;
}

#pragma mark - threads

- (NSDictionary *)opThreads:(NSDictionary *)arguments error:(NSString **)error {
    NSUInteger limit = GXIntArg(arguments, @"limit", 256, 1, 4096);
    NSString *query = GXStringArg(arguments, @"query");

    NSMutableArray *all = [NSMutableArray array];
    gum_process_enumerate_threads(GXCollectThread, (__bridge gpointer)all);

    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *entry in all) {
        if (query.length) {
            NSString *name = entry[@"name"] ?: @"";
            if (!name.length || [name rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [filtered addObject:entry];
        if (filtered.count >= limit) break;
    }

    return @{@"total": @(all.count),
             @"count": @(filtered.count),
             @"note": @"只读线程名与状态；不读寄存器上下文，也不提供 suspend/resume。",
             @"threads": filtered};
}

#pragma mark - memory_ranges

- (NSDictionary *)opMemoryRanges:(NSDictionary *)arguments error:(NSString **)error {
    NSUInteger limit = GXIntArg(arguments, @"limit", GXDefaultLimit, 1, GXMaxLimit);
    NSString *filter = GXStringArg(arguments, @"filter");   // 例如 "r-x" / "rw" / "rx"

    NSMutableArray *ranges = [NSMutableArray array];
    GXRangeContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.ranges = (__bridge void *)ranges;
    ctx.filter = (__bridge void *)filter;
    ctx.limit = limit;
    ctx.total = 0;

    gum_process_enumerate_ranges((GumPageProtection)0, GXCollectRangeEntry, &ctx);

    return @{@"count": @(ranges.count),
             @"total": @(ctx.total),
             @"truncated": @(ranges.count < ctx.total),
             @"ranges": ranges};
}

#pragma mark - read_mem

- (NSDictionary *)opReadMemory:(NSDictionary *)arguments error:(NSString **)error {
    NSString *addressText = GXStringArg(arguments, @"address");
    uint64_t address = 0;
    if (!addressText.length || !GXParseAddress(addressText, &address)) {
        *error = @"read_mem 需要 address（字符串，示例 0x104a2b000）";
        return nil;
    }
    NSUInteger length = GXIntArg(arguments, @"length", GXDefaultReadBytes, 1, GXMaxReadBytes);
    NSString *format = GXStringArg(arguments, @"format") ?: @"hex";
    if (![@[@"hex", @"utf8", @"u32", @"u64", @"ptr"] containsObject:format]) {
        *error = [NSString stringWithFormat:@"format 只支持 hex/utf8/u32/u64/ptr，收到 %@", format];
        return nil;
    }

    NSUInteger effective = length;
    if ([format isEqualToString:@"hex"] && effective > GXMaxHexBytes) effective = GXMaxHexBytes;

    // 逐页确认可读，遇到不可读立即停止并标记截断——绝不「先读再判断」。
    NSUInteger readable = 0;
    while (readable < effective) {
        uint64_t cursor = address + readable;
        gconstpointer pointer = (gconstpointer)(uintptr_t)cursor;
        if (!gum_memory_is_readable(pointer, 1)) break;
        NSUInteger pageLeft = (NSUInteger)(4096 - (cursor & 0xFFF));
        NSUInteger chunk = MIN(effective - readable, pageLeft);
        if (!gum_memory_is_readable(pointer, (gsize)chunk)) chunk = 1;
        readable += chunk;
    }

    if (readable == 0) {
        GumPageProtection protection = 0;
        NSString *protectionText = gum_memory_query_protection((gconstpointer)(uintptr_t)address, &protection)
            ? GXProtectionString(protection)
            : @"unmapped";
        *error = [NSString stringWithFormat:@"地址 %@ 不可读（protection=%@）", addressText, protectionText];
        return nil;
    }

    const uint8_t *buffer = (const uint8_t *)(uintptr_t)address;
    NSMutableDictionary *result = [@{
        @"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
        @"requested": @(length),
        @"read": @(readable),
        @"truncated": @(readable < length),
        @"format": format,
    } mutableCopy];

    if ([format isEqualToString:@"hex"]) {
        NSMutableString *hex = [NSMutableString stringWithCapacity:readable * 3];
        for (NSUInteger index = 0; index < readable; index++) {
            [hex appendFormat:@"%02X", buffer[index]];
            if (index + 1 < readable) [hex appendString:((index & 15) == 15) ? @"\n" : @" "];
        }
        result[@"data"] = hex;
    } else if ([format isEqualToString:@"utf8"]) {
        NSData *data = [NSData dataWithBytes:buffer length:readable];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) {
            NSMutableString *escaped = [NSMutableString stringWithCapacity:readable];
            for (NSUInteger index = 0; index < readable; index++) {
                uint8_t byte = buffer[index];
                if ((byte >= 0x20 && byte < 0x7F) || byte == '\n' || byte == '\t') {
                    [escaped appendFormat:@"%c", byte];
                } else {
                    [escaped appendFormat:@"\\x%02X", byte];
                }
            }
            text = escaped;
            result[@"encodingFallback"] = @"binary-escaped";
        }
        result[@"data"] = text;
    } else if ([format isEqualToString:@"u32"]) {
        NSUInteger count = readable / 4;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger index = 0; index < count; index++) {
            uint32_t value = 0;
            memcpy(&value, buffer + index * 4, 4);
            [values addObject:@(value)];
        }
        result[@"data"] = values;
        result[@"count"] = @(count);
        result[@"endianness"] = @"little";
    } else {
        NSUInteger unit = [format isEqualToString:@"ptr"] ? sizeof(void *) : 8;
        NSUInteger count = readable / unit;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger index = 0; index < count; index++) {
            uint64_t value = 0;
            memcpy(&value, buffer + index * unit, unit);
            [values addObject:[NSString stringWithFormat:@"0x%llx", (unsigned long long)value]];
        }
        result[@"data"] = values;
        result[@"count"] = @(count);
        result[@"endianness"] = @"little";
    }

    return result;
}

#pragma mark - scan

- (NSDictionary *)opScan:(NSDictionary *)arguments error:(NSString **)error {
    NSString *patternText = GXStringArg(arguments, @"pattern");
    if (!patternText.length) {
        *error = @"scan 需要 pattern（十六进制，?? 为通配，示例 \"48 8B ?? ?? 89\"）";
        return nil;
    }

    // 先自己做一遍语法校验，再把合法 pattern 交给 gum：避免把畸形输入喂进解析器。
    NSMutableString *compact = [NSMutableString string];
    for (NSUInteger index = 0; index < patternText.length; index++) {
        unichar ch = [patternText characterAtIndex:index];
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '-') continue;
        [compact appendFormat:@"%C", ch];
    }
    if (compact.length == 0 || (compact.length % 2) != 0 || compact.length > 1024) {
        *error = @"pattern 长度必须是偶数（每字节两位十六进制），最多 512 字节";
        return nil;
    }
    BOOL hasConcreteByte = NO;
    for (NSUInteger index = 0; index < compact.length; index += 2) {
        unichar high = [compact characterAtIndex:index];
        unichar low = [compact characterAtIndex:index + 1];
        if (high == '?' && low == '?') continue;
        BOOL highValid = (high >= '0' && high <= '9') || (high >= 'a' && high <= 'f') || (high >= 'A' && high <= 'F');
        BOOL lowValid = (low >= '0' && low <= '9') || (low >= 'a' && low <= 'f') || (low >= 'A' && low <= 'F');
        if (!highValid || !lowValid) {
            *error = @"pattern 含非法字符（只接受 0-9 a-f A-F 与 ?? 通配）";
            return nil;
        }
        hasConcreteByte = YES;
    }
    if (!hasConcreteByte) {
        *error = @"pattern 不能全是通配，至少需要一个确定字节";
        return nil;
    }

    GumMatchPattern *pattern = gum_match_pattern_new_from_string(patternText.UTF8String);
    if (!pattern) {
        *error = @"gum 拒绝了该 pattern（请检查格式）";
        return nil;
    }

    NSUInteger limit = GXIntArg(arguments, @"limit", GXDefaultMatches, 1, GXMaxMatches);
    NSUInteger maxBytes = GXIntArg(arguments, @"max_bytes", GXDefaultScanBytes, 4096, GXMaxScanBytes);
    NSString *moduleName = GXStringArg(arguments, @"module");

    NSMutableArray *matches = [NSMutableArray array];
    GXScanContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.pattern = pattern;
    ctx.matches = (__bridge void *)matches;
    ctx.limit = limit;
    ctx.maxBytes = maxBytes;
    ctx.deadline = CFAbsoluteTimeGetCurrent() + GXScanBudget;

    GumModule *module = nil;
    if (moduleName.length) {
        module = [self loadModuleNamed:moduleName error:error];
        if (!module) {
            gum_match_pattern_unref(pattern);
            return nil;
        }
        const GumMemoryRange *range = gum_module_get_range(module);
        if (range) {
            ctx.hasModuleRange = YES;
            ctx.moduleBase = range->base_address;
            ctx.moduleEnd = range->base_address + range->size;
        }
    }

    gum_process_enumerate_ranges((GumPageProtection)0, GXScanRange, &ctx);
    if (module) g_object_unref(module);
    gum_match_pattern_unref(pattern);

    return @{@"pattern": patternText,
             @"module": moduleName ?: @"",
             @"scanned": @(ctx.scanned),
             @"budgetBytes": @(maxBytes),
             @"timeBudgetSeconds": @(GXScanBudget),
             @"truncated": @(ctx.exhausted),
             @"count": @(matches.count),
             @"matches": matches,
             @"note": @"只扫可读且不可执行的页，单段上限 64 MB、总预算 4 秒；命中只给地址与长度，"
                      @"看内容另用 read_mem。"};
}

#endif // GX_NO_GUM

@end
