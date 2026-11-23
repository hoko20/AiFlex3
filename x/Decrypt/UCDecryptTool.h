#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 自动安装抓取 hook 的开关键。
///
/// 语义：dylib 注入后要不要**未经用户操作**就把 6 组 fishhook 装进宿主进程。
/// 默认 NO —— 不点「抓取」按钮就完全不碰目标进程。
///
/// 打开方式（任选其一，环境变量优先）：
///   defaults write <宿主 bundleID> AiFlex3DecryptAutoStart -bool YES
///   launchctl setenv AIFLEX3_DECRYPT_AUTOSTART 1
/// 也可在「抓取 → 功能设置 → 启动时自动安装」里改。
FOUNDATION_EXPORT NSString *const UCDecryptAutoStartDefaultsKey;
FOUNDATION_EXPORT NSString *const UCDecryptAutoStartEnvironmentKey;

@interface UCDecryptTool : NSObject

/// 当前是否允许自动安装。环境变量 > NSUserDefaults，都缺省时返回 NO。
+ (BOOL)decryptAutoStartEnabled;

/// 持久化开关到宿主 App 的 NSUserDefaults 并立即 synchronize。
/// 打开时若 hook 尚未安装，会就地安装一次（无需重启进程）；关闭不会卸载已装的 hook。
+ (void)setDecryptAutoStartEnabled:(BOOL)enabled;

/// hook 是否已经装进当前进程。
+ (BOOL)decryptHooksInstalled;

/// 幂等安装。重复调用只生效一次。
+ (void)installDecryptHooksIfNeeded;

+ (void)presentDecryptPanelFromViewController:(nullable UIViewController *)viewController;

@end

NS_ASSUME_NONNULL_END
