#import "UCDecryptTool.h"
#import "DatabaseManager.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>

NSString *const UCDecryptAutoStartDefaultsKey = @"AiFlex3DecryptAutoStart";
NSString *const UCDecryptAutoStartEnvironmentKey = @"AIFLEX3_DECRYPT_AUTOSTART";

#ifdef __cplusplus
extern "C" {
#endif

void RegisterCryptoHooks(void);
void RegisterStreamingHashHooks(void);
void RegisterOpenSSLHooks(void);
void RegisterSSLHooks(void);
void ssl2_kill(void);
void ssl3_kill(void);
void RegisterURLResponseHooks(void);
void RegisterURLInterceptHooks(void);
void IZXShowDecryptPanelNow(void);

NSString *CurrentBundleID(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown.bundle";
}

NSString *HexStringFromBytes(const void *bytes, size_t length) {
    if (!bytes || length == 0) return @"";
    const uint8_t *p = (const uint8_t *)bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) {
        [s appendFormat:@"%02x", p[i]];
    }
    return s;
}

#ifdef __cplusplus
}
#endif

/// hook 是否已经装进当前进程。installDecryptHooksIfNeeded 的 dispatch_once 无法反查，
/// 单独用一个静态标志给 UI 和日志用。
static BOOL gUCDecryptHooksInstalled = NO;

@interface UCDecryptTool ()
+ (void)scheduleDeferredDecryptHooksInstallIfAllowed;
+ (void)scheduleDeferredDecryptHooksInstall;
@end

@implementation UCDecryptTool

#pragma mark - 自动安装开关

+ (BOOL)decryptAutoStartEnabled {
    // 环境变量优先：方便 launchctl setenv 一次性覆盖，不用改 App 的 plist。
    NSString *raw = [NSProcessInfo processInfo].environment[UCDecryptAutoStartEnvironmentKey];
    if (raw.length > 0) {
        NSString *v = [raw lowercaseString];
        if ([v isEqualToString:@"1"] || [v isEqualToString:@"yes"] ||
            [v isEqualToString:@"true"] || [v isEqualToString:@"on"]) {
            return YES;
        }
        if ([v isEqualToString:@"0"] || [v isEqualToString:@"no"] ||
            [v isEqualToString:@"false"] || [v isEqualToString:@"off"]) {
            return NO;
        }
        // 其它值视为未设置，继续看 NSUserDefaults。
    }
    // boolForKey: 对缺失的 key 返回 NO —— 正好就是「默认关闭」。
    return [[NSUserDefaults standardUserDefaults] boolForKey:UCDecryptAutoStartDefaultsKey];
}

+ (void)setDecryptAutoStartEnabled:(BOOL)enabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:UCDecryptAutoStartDefaultsKey];
    [defaults synchronize];

    NSLog(@"[AiFlex3][Decrypt] %@ = %@", UCDecryptAutoStartDefaultsKey, enabled ? @"YES" : @"NO");

    // 打开时就地装一次，省得用户为了生效去重启目标 App。
    // dispatch_once 保护，重复调用无副作用；装 hook 是重活，扔后台队列，
    // 和 CapturePanelViewController.viewDidLoad 的做法保持一致。
    if (enabled) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self installDecryptHooksIfNeeded];
        });
    }
    // 关闭不卸载：fishhook 已改的符号表指针无法安全回滚，
    // 真要彻底停掉只能重启进程。这点在设置项的说明里写清楚。
}

+ (BOOL)decryptHooksInstalled {
    return gUCDecryptHooksInstalled;
}

#pragma mark - 安装

+ (void)load {
    // +load 阶段不去碰 NSUserDefaults（此时 cfprefsd 未必就绪），
    // 统一挪到主队列，判断和排期一起做。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scheduleDeferredDecryptHooksInstallIfAllowed];
    });
}

+ (void)scheduleDeferredDecryptHooksInstallIfAllowed {
    if (![self decryptAutoStartEnabled]) {
        NSLog(@"[AiFlex3][Decrypt] %@ 未开启，跳过自动安装（点 FLEX 工具栏「抓取」，"
              @"或在「抓取 → 功能设置 → 启动时自动安装」里打开）",
              UCDecryptAutoStartDefaultsKey);
        return;
    }
    [self scheduleDeferredDecryptHooksInstall];
}

+ (void)scheduleDeferredDecryptHooksInstall {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __block BOOL didScheduleInstall = NO;
            __block id launchObserver = nil;
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

            void (^scheduleInstall)(void) = ^{
                if (didScheduleInstall) return;
                didScheduleInstall = YES;
                if (launchObserver) {
                    [center removeObserver:launchObserver];
                    launchObserver = nil;
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self installDecryptHooksIfNeeded];
                });
            };

            launchObserver = [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                 object:nil
                                                  queue:NSOperationQueue.mainQueue
                                             usingBlock:^(__unused NSNotification *note) {
                scheduleInstall();
            }];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                scheduleInstall();
            });
        });
    });
}

+ (void)installDecryptHooksIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            [[DatabaseManager sharedManager] createTables];
            [[DatabaseManager sharedManager] insertLogText:[NSString stringWithFormat:@"Decrypt feature loaded for %@", CurrentBundleID()]];
            RegisterCryptoHooks();
            RegisterStreamingHashHooks();
            RegisterOpenSSLHooks();
            RegisterSSLHooks();
            RegisterURLResponseHooks();
            RegisterURLInterceptHooks();
            ssl2_kill();
            ssl3_kill();
            gUCDecryptHooksInstalled = YES;
        }
    });
}

#pragma mark - 入口

+ (void)presentDecryptPanelFromViewController:(UIViewController *)viewController {
    // 点「抓取」= 明确表达了抓取意图，此时安装与自动开关无关。
    [self installDecryptHooksIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{
        IZXShowDecryptPanelNow();
    });
}

@end
