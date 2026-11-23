#import "FLEXDoKitCrashMonitor.h"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <signal.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>
#import <fcntl.h>

// 崩溃采集的两条硬规则（改动前务必读完）：
//
// 1) 信号上下文里只能用「异步信号安全」的函数。alloc / NSThread / dispatch_async /
//    @try 全都不安全：崩溃往往就发生在堆元数据被写坏的时候，handler 再分配一次
//    内存会二次崩溃，进程直接变成崩溃循环（本文件旧实现就是这样）。
//    因此信号路径只做三件事：backtrace() 拿原始帧、write() 落盘、转发上一个 handler。
//
// 2) 绝不接管 SIGPIPE。iOS 上 socket 对端断开就会产生 SIGPIPE，这是日常事件。
//    旧实现把它当崩溃处理并 raise()，等于「MCP 客户端断一次连接，宿主 App 就死一次」。
//    SIGPIPE 必须保持 SIG_IGN，让 write()/send() 正常返回 EPIPE。

#define FLEXCrashAltStackSize (64 * 1024)
#define FLEXCrashMaxFrames    96
#define FLEXCrashRawPath      @"FLEXDoKitCrashFrames.bin"

static char gFlexCrashAltStack[FLEXCrashAltStackSize] __attribute__((aligned(16)));
static struct sigaction gFlexPrevActions[NSIG];
static volatile sig_atomic_t gFlexCrashHandling = 0;
static volatile sig_atomic_t gFlexCrashFD = -1;

static const int gFlexCrashSignals[] = { SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP };
static const size_t gFlexCrashSignalCount = sizeof(gFlexCrashSignals) / sizeof(gFlexCrashSignals[0]);

static NSString *FLEXCrashDocumentsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        path = paths.count ? paths[0] : NSTemporaryDirectory();
    });
    return path;
}

static NSString *FLEXCrashRawFilePath(void) {
    return [FLEXCrashDocumentsPath() stringByAppendingPathComponent:FLEXCrashRawPath];
}

#pragma mark - 信号处理（异步信号安全区）

static void FLEXCrashForwardToPrevious(int sig, siginfo_t *info, void *uap) {
    struct sigaction *prev = &gFlexPrevActions[sig];
    if ((prev->sa_flags & SA_SIGINFO) != 0 && prev->sa_sigaction != NULL) {
        prev->sa_sigaction(sig, info, uap);
        return;
    }
    if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN && prev->sa_handler != NULL) {
        prev->sa_handler(sig);
        return;
    }
    // 上一个 handler 是默认行为：还原本进程的默认处置并重抛，
    // 让系统 Crash Reporter 正常生成 .ips，否则会丢失系统级崩溃报告。
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    raise(sig);
}

static void FLEXCrashSignalHandler(int sig, siginfo_t *info, void *uap) {
    // 递归进入说明「处理崩溃时又崩了」。此时再写盘没有意义，直接交给系统，
    // 避免 handler 之间反复弹跳把进程挂死在半死状态。
    if (gFlexCrashHandling) {
        FLEXCrashForwardToPrevious(sig, info, uap);
        return;
    }
    gFlexCrashHandling = 1;

    int fd = (int)gFlexCrashFD;
    if (fd >= 0) {
        // 头部：magic + signal + 帧数，随后是裸指针数组。符号化推迟到下次启动做，
        // 因为 dladdr/snprintf 都可能触碰堆。
        void *frames[FLEXCrashMaxFrames];
        int count = backtrace(frames, FLEXCrashMaxFrames);
        if (count < 0) count = 0;
        char header[32];
        int hlen = snprintf(header, sizeof(header), "FLEX%08X%08X\n", (unsigned)sig, (unsigned)count);
        if (hlen > 0) {
            ssize_t ignored = write(fd, header, (size_t)hlen);
            (void)ignored;
            if (count > 0) {
                ignored = write(fd, frames, (size_t)count * sizeof(void *));
                (void)ignored;
            }
            fsync(fd);
        }
        close(fd);
        gFlexCrashFD = -1;
    }

    gFlexCrashHandling = 0;
    FLEXCrashForwardToPrevious(sig, info, uap);
}

#pragma mark - 上一轮信号记录的回捞

// 上一次进程被信号杀死前落盘的裸帧，在这里符号化。这段在主线程、有完整 ObjC 环境，
// 可以随意分配。
static NSDictionary *FLEXCrashReapRawRecord(void) {
    NSString *path = FLEXCrashRawFilePath();
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

    const char *bytes = data.bytes;
    const char *newline = memchr(bytes, '\n', MIN(data.length, (NSUInteger)64));
    if (!newline || strncmp(bytes, "FLEX", 4) != 0) return nil;

    unsigned int signalNumber = 0, frameCount = 0;
    if (sscanf(bytes + 4, "%8X%8X", &signalNumber, &frameCount) != 2) return nil;
    if (frameCount > FLEXCrashMaxFrames) frameCount = FLEXCrashMaxFrames;

    NSUInteger headerLength = (NSUInteger)(newline - bytes) + 1;
    NSUInteger available = headerLength <= data.length ? data.length - headerLength : 0;
    NSUInteger maxFrames = available / sizeof(void *);
    if (frameCount > maxFrames) frameCount = (unsigned int)maxFrames;
    if (frameCount == 0) return nil;

    NSMutableArray<NSString *> *symbols = [NSMutableArray arrayWithCapacity:frameCount];
    const uintptr_t *frames = (const uintptr_t *)(bytes + headerLength);
    for (unsigned int index = 0; index < frameCount; index++) {
        uintptr_t address = frames[index];
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (address && dladdr((void *)address, &info)) {
            const char *image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
            const char *imageName = image ? image + 1 : (info.dli_fname ? info.dli_fname : "?");
            if (info.dli_sname && info.dli_saddr) {
                [symbols addObject:[NSString stringWithFormat:@"%u  %s  %s + %ld",
                                    index, imageName, info.dli_sname,
                                    (long)(address - (uintptr_t)info.dli_saddr)]];
            } else {
                [symbols addObject:[NSString stringWithFormat:@"%u  %s + 0x%lx",
                                    index, imageName,
                                    (unsigned long)(address - (uintptr_t)info.dli_fbase)]];
            }
        } else {
            [symbols addObject:[NSString stringWithFormat:@"%u  0x%lx", index, (unsigned long)address]];
        }
    }

    return @{@"signal": @(signalNumber), @"callStack": symbols};
}

#pragma mark -

@implementation FLEXDoKitCrashInfo

- (NSDictionary *)dictionaryRepresentation {
    return @{
        @"type": @(self.type),
        @"reason": self.reason ?: @"",
        @"callStack": self.callStack ?: @[],
        @"timestamp": @([self.timestamp timeIntervalSince1970]),
        @"deviceInfo": self.deviceInfo ?: @{}
    };
}

@end

@interface FLEXDoKitCrashMonitor ()
@property (nonatomic, strong) NSMutableArray<FLEXDoKitCrashInfo *> *mutableCrashLogs;
@property (nonatomic, assign) BOOL isMonitoring;
@property (nonatomic, assign) NSUncaughtExceptionHandler *previousExceptionHandler;
@end

static void flexDoKitExceptionHandler(NSException *exception);

@implementation FLEXDoKitCrashMonitor

+ (instancetype)sharedInstance {
    static FLEXDoKitCrashMonitor *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableCrashLogs = [NSMutableArray new];
        _isMonitoring = NO;
        [self loadCrashLogsFromDisk];
        // 回捞要读 UIDevice / NSBundle，必须在主线程做；非主线程首次触碰单例时延后执行。
        if ([NSThread isMainThread]) {
            [self reapPendingSignalCrash];
        } else {
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reapPendingSignalCrash]; });
        }
    }
    return self;
}

- (NSMutableArray<FLEXDoKitCrashInfo *> *)crashLogs {
    return self.mutableCrashLogs;
}

#pragma mark - 崩溃监控

- (void)startCrashMonitoring {
    if (self.isMonitoring) return;
    self.isMonitoring = YES;

    // SIGPIPE 显式忽略：它是 socket 断连的正常现象，不是崩溃。
    signal(SIGPIPE, SIG_IGN);

    // 备用信号栈：栈溢出类崩溃（SIGSEGV on stack guard）时，原栈已经没有空间跑 handler，
    // 必须切到独立栈，否则 handler 根本不执行，崩溃记录直接丢失。
    stack_t altStack;
    memset(&altStack, 0, sizeof(altStack));
    altStack.ss_sp = gFlexCrashAltStack;
    altStack.ss_size = sizeof(gFlexCrashAltStack);
    altStack.ss_flags = 0;
    sigaltstack(&altStack, NULL);

    int fd = open([FLEXCrashRawFilePath() fileSystemRepresentation],
                  O_WRONLY | O_CREAT | O_TRUNC, 0600);
    gFlexCrashFD = fd;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = FLEXCrashSignalHandler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (size_t index = 0; index < gFlexCrashSignalCount; index++) {
        int sig = gFlexCrashSignals[index];
        sigaction(sig, NULL, &gFlexPrevActions[sig]);
        sigaction(sig, &action, NULL);
    }
    gFlexCrashHandling = 0;

    self.previousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&flexDoKitExceptionHandler);

    NSLog(@"[AiFlex3] 崩溃监控已启动（SIGPIPE 保持忽略）");
}

- (void)stopCrashMonitoring {
    if (!self.isMonitoring) return;
    self.isMonitoring = NO;

    // 逐个还原本进程接管前的处置，而不是笼统地设 SIG_DFL，
    // 避免把其它组件（如系统库自己）注册的 handler 一并抹掉。
    for (size_t index = 0; index < gFlexCrashSignalCount; index++) {
        int sig = gFlexCrashSignals[index];
        sigaction(sig, &gFlexPrevActions[sig], NULL);
    }
    signal(SIGPIPE, SIG_IGN);

    if (gFlexCrashFD >= 0) {
        close((int)gFlexCrashFD);
        gFlexCrashFD = -1;
    }
    [[NSFileManager defaultManager] removeItemAtPath:FLEXCrashRawFilePath() error:NULL];

    NSSetUncaughtExceptionHandler(self.previousExceptionHandler);

    NSLog(@"[AiFlex3] 崩溃监控已停止");
}

#pragma mark - 崩溃处理

// ObjC 异常不是信号上下文，可以正常分配内存；但它同样必须转发，
// 否则会顶掉后来的监控组件（Crashlytics / Bugly 之类）。
static void flexDoKitExceptionHandler(NSException *exception) {
    NSArray *callStack = [exception callStackSymbols];

    FLEXDoKitCrashInfo *crashInfo = [[FLEXDoKitCrashInfo alloc] init];
    crashInfo.type = FLEXDoKitCrashTypeException;
    crashInfo.reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];
    crashInfo.callStack = callStack;
    crashInfo.timestamp = [NSDate date];
    crashInfo.deviceInfo = [[FLEXDoKitCrashMonitor sharedInstance] getDeviceInfo];

    [[FLEXDoKitCrashMonitor sharedInstance] saveCrashInfo:crashInfo];

    FLEXDoKitCrashMonitor *monitor = [FLEXDoKitCrashMonitor sharedInstance];
    if (monitor.previousExceptionHandler) {
        monitor.previousExceptionHandler(exception);
    }
}

- (void)reapPendingSignalCrash {
    NSDictionary *record = FLEXCrashReapRawRecord();
    if (!record) return;

    unsigned int signalNumber = [record[@"signal"] unsignedIntValue];
    FLEXDoKitCrashInfo *crashInfo = [[FLEXDoKitCrashInfo alloc] init];
    crashInfo.type = FLEXDoKitCrashTypeSignal;
    crashInfo.reason = [NSString stringWithFormat:@"Signal %u（上次进程崩溃，启动时回捞）", signalNumber];
    crashInfo.callStack = record[@"callStack"];
    crashInfo.timestamp = [NSDate date];
    crashInfo.deviceInfo = [self getDeviceInfo];
    [self saveCrashInfo:crashInfo];
}

- (void)saveCrashInfo:(FLEXDoKitCrashInfo *)crashInfo {
    [self.mutableCrashLogs addObject:crashInfo];

    if (self.mutableCrashLogs.count > 100) {
        [self.mutableCrashLogs removeObjectAtIndex:0];
    }

    [self saveCrashLogsToDisk];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"FLEXDoKitCrashDetected" object:crashInfo];
    });
}

- (NSDictionary *)getDeviceInfo {
    struct utsname systemInfo;
    uname(&systemInfo);

    return @{
        @"device": [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"unknown",
        @"system": [NSString stringWithFormat:@"%@ %@", [UIDevice currentDevice].systemName, [UIDevice currentDevice].systemVersion],
        @"app_version": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"Unknown",
        @"build": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"Unknown",
        @"memory": [self getMemoryInfo],
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
}

- (NSDictionary *)getMemoryInfo {
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;

    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
    if (result == KERN_SUCCESS) {
        return @{
            @"used": @(info.resident_size),
            @"virtual": @(info.virtual_size)
        };
    }

    return @{};
}

#pragma mark - 数据持久化

- (void)saveCrashLogsToDisk {
    NSArray *crashData = [self.mutableCrashLogs valueForKey:@"dictionaryRepresentation"];
    NSString *filePath = [self crashLogsFilePath];
    // writeToFile 对非 plist 类型会静默失败，先校验一次再写。
    if (![NSPropertyListSerialization propertyList:crashData isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        NSLog(@"[AiFlex3] 崩溃日志包含不可序列化字段，跳过本次落盘");
        return;
    }
    [crashData writeToFile:filePath atomically:YES];
}

- (void)loadCrashLogsFromDisk {
    NSString *filePath = [self crashLogsFilePath];
    NSArray *crashData = [NSArray arrayWithContentsOfFile:filePath];
    if (![crashData isKindOfClass:[NSArray class]]) return;

    for (NSDictionary *crashDict in crashData) {
        if (![crashDict isKindOfClass:[NSDictionary class]]) continue;
        FLEXDoKitCrashInfo *crashInfo = [[FLEXDoKitCrashInfo alloc] init];
        crashInfo.type = (FLEXDoKitCrashType)[crashDict[@"type"] unsignedIntegerValue];
        crashInfo.reason = [crashDict[@"reason"] isKindOfClass:[NSString class]] ? crashDict[@"reason"] : @"";
        crashInfo.callStack = [crashDict[@"callStack"] isKindOfClass:[NSArray class]] ? crashDict[@"callStack"] : @[];
        crashInfo.timestamp = [NSDate dateWithTimeIntervalSince1970:[crashDict[@"timestamp"] doubleValue]];
        crashInfo.deviceInfo = [crashDict[@"deviceInfo"] isKindOfClass:[NSDictionary class]] ? crashDict[@"deviceInfo"] : @{};
        [self.mutableCrashLogs addObject:crashInfo];
    }
}

- (NSString *)crashLogsFilePath {
    return [FLEXCrashDocumentsPath() stringByAppendingPathComponent:@"FLEXDoKitCrashLogs.plist"];
}

#pragma mark - 崩溃日志管理

- (void)clearCrashLogs {
    [self.mutableCrashLogs removeAllObjects];
    [self saveCrashLogsToDisk];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FLEXDoKitCrashLogsCleared" object:nil];
}

- (NSString *)exportCrashLogsAsString {
    NSMutableString *exportString = [NSMutableString string];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    for (FLEXDoKitCrashInfo *crashInfo in self.mutableCrashLogs) {
        [exportString appendFormat:@"=== 崩溃日志 ===\n"];
        [exportString appendFormat:@"时间: %@\n", [formatter stringFromDate:crashInfo.timestamp]];
        [exportString appendFormat:@"类型: %@\n", [self stringForCrashType:crashInfo.type]];
        [exportString appendFormat:@"原因: %@\n", crashInfo.reason];
        [exportString appendFormat:@"设备信息: %@\n", crashInfo.deviceInfo];
        [exportString appendFormat:@"调用栈:\n"];

        for (NSString *symbol in crashInfo.callStack) {
            [exportString appendFormat:@"  %@\n", symbol];
        }

        [exportString appendString:@"\n\n"];
    }

    return [exportString copy];
}

- (NSString *)stringForCrashType:(FLEXDoKitCrashType)type {
    switch (type) {
        case FLEXDoKitCrashTypeSignal:
            return @"信号崩溃";
        case FLEXDoKitCrashTypeException:
            return @"异常崩溃";
        case FLEXDoKitCrashTypeKVO:
            return @"KVO崩溃";
        case FLEXDoKitCrashTypeUnrecognizedSelector:
            return @"未识别选择器";
        default:
            return @"未知类型";
    }
}

@end
