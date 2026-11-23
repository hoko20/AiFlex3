#import <Foundation/Foundation.h>

// AiFlex3 的 AArch64 反汇编 / 控制流分析引擎（MCP 适配层）。
//
// 它包装仓库里已有的 x/Disassembler/UCDisassembler（973 行，capstone 5.0.1 后端），
// 把那套「函数边界识别 + 基本块 CFG + 交叉引用 + 符号化」的能力暴露成 MCP operation。
//
// 设计边界（不要越过）：
//   * 只做「读」：读代码页、反汇编、建 CFG、查符号。不写内存、不改指令、不装 hook。
//   * capstone 的 csh 是全局单例，UCDisassembler 内部已用 g_disasmQueue 串行化
//     cs_disasm。本引擎再加一层专属串行队列，保证「MCP 侧不会有两个反汇编同时跑」，
//     也避免长扫描把 CPU 打满。
//   * 输入规模一律设硬上限：反汇编区间、函数数量、返回条数。capstone 反汇编是同步
//     阻塞调用，没有中断点，所以「限时」只能靠「限输入」实现，不能靠 dispatch 超时。
//   * 所有输出都做分页，默认 200 条指令，最大 2000 条；超出部分给 nextOffset。
@interface FLEXAiFlexDisasm : NSObject

+ (instancetype)sharedEngine;

/// capstone 是否初始化成功。失败时引擎降级为十六进制 dump。
+ (BOOL)engineAvailable;

/// 引擎名（含 capstone 主版本号）；不可用时返回降级标识。
+ (NSString *)engineVersion;

/// 支持的 operation 名称，供 capabilities / status 汇总。
+ (NSArray<NSString *> *)supportedOperations;

/// 统一入口。completion 在引擎的串行队列上回调，调用方自行切换队列。
- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *result, NSString *error))completion;

@end
