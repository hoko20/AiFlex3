//
//  FLEXAiFlexHook.h
//  FLEX++
//
//  代码改写引擎：inline hook（Interceptor）+ 字节补丁（patch）+ 还原。
//
//  定位：这是本插件里唯一能改变宿主 App 运行时行为的组。它不是一个
//  「试试看」的接口，而是围绕「可回滚」构造的：
//
//    * 每条 hook / patch 都有唯一 id 与完整的原始状态快照；
//    * 还原按快照逐字节写回，不靠调用方记参数；
//    * 引擎自检（selftest）在真正动手前验证整条链路，失败即整组拒绝；
//    * 目标三重校验（对齐 / 可执行页 / 非自身代码）在写入前完成。
//
//  能力来自 frida-gum 17.27.4：
//    - gum_interceptor_attach / detach   —— trampoline 式的函数入口拦截，
//      指令重定位、页权限切换、原子替换都由 gum 处理，不需要自己搬运指令；
//    - gum_make_call_listener            —— 回调式监听器，无需实现 GObject 子类；
//    - gum_memory_patch_code             —— 受控的代码页写入，内部处理 mprotect
//      与指令缓存刷新，比手写 vm_protect + sys_icache_invalidate 更稳。
//
//  构建降级：没有 frida-gum devkit 时（GX_NO_GUM），本引擎整体不可用，
//  aiflex_hook 工具不出现在 tools/list，其余工具不受影响。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FLEXAiFlexHook : NSObject

+ (instancetype)sharedEngine;

/// 编译期是否编入了 gum 后端。和运行期可用性不是一回事：
/// 编入了但初始化失败也会返回 NO，具体原因看 status。
+ (BOOL)engineAvailable;

/// operation 列表，供 MCP schema 与 capabilities 复用。
+ (NSArray<NSString *> *)supportedOperations;

/// 所有 operation 统一入口。completion 恒定在主线程之外的回调队列执行。
- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;

/// 进程退出前尽力把仍然生效的 hook 摘掉、patch 还原。
/// 不是必需的（进程结束后 trampoline 与内存补丁都会消失），但在
/// 「注入到长驻进程 + 用户忘记 unhook」的场景下能少留一份残局。
- (void)teardownSynchronously;

/// 按单调时钟区间取事件快照，供网络引擎做「请求 ↔ 原生调用」时间对齐。
/// 与 events operation 的区别：这个是同步的、按时间过滤而不是按 seq 游标，
/// 因为网络侧拿到的是时间戳而不是事件序号。时间单位是纳秒，和
/// clock_gettime(CLOCK_MONOTONIC) 一致。未编入 gum 时返回空数组。
+ (NSArray<NSDictionary *> *)snapshotEventsFrom:(uint64_t)startNs
                                             to:(uint64_t)endNs
                                          limit:(NSUInteger)limit;

@end

NS_ASSUME_NONNULL_END
