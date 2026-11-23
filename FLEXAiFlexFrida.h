#import <Foundation/Foundation.h>

// AiFlex3 的 Frida 只读引擎。
//
// 设计边界（不要越过）：
//   * 只做「读」：模块/符号/线程/内存区间/内存读/特征扫描/回调栈/崩溃记录。
//   * 不做任何写操作：不改代码页、不装 inline hook、不替换方法实现。
//     写类能力（hook / patch / Stalker）需要独立的备份、自检与回滚机制，
//     不应和这组只读能力混在同一个授权开关下。
//   * 所有 gum 调用都在专属串行队列上执行，不占用主线程。
//   * 编译时未提供 frida-gum（GX_NO_GUM）时，引擎降级为「仅 backtrace / crash_log /
//     status 可用」，其余 operation 返回明确错误，绝不静默失败。
@interface FLEXAiFlexFrida : NSObject

+ (instancetype)sharedEngine;

/// gum 是否被编译进当前产物并成功初始化。
+ (BOOL)engineAvailable;

/// gum 版本串；未编译进产物时返回 nil。
+ (NSString *)engineVersion;

/// 支持的 operation 名称，供 capabilities / status 汇总。
+ (NSArray<NSString *> *)supportedOperations;

/// 统一入口。completion 在引擎的串行队列上回调，调用方自行切换队列。
- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *result, NSString *error))completion;

@end
