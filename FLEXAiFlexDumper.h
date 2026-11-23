#import <Foundation/Foundation.h>

// AiFlex3 的二进制脱壳引擎（Mach-O 内存导出）。
//
// iOS 上 App Store 分发的 Mach-O 是可执行段被 FairPlay 加密的（LC_ENCRYPTION_INFO_64
// 里 cryptid == 1）。磁盘上的那份永远是密文；内核在页错误时按页解密后映射进内存，
// 所以内存里的可执行段就是明文。本引擎做的事就是：按 segment 表把内存里的明文搬到
// 一个新文件里，并把 cryptid 改成 0，得到一份可以直接丢进 IDA / Hopper / Ghidra 的二进制。
//
// 设计边界（不要越过）：
//   * 纯读：只读已加载镜像的内存 + 写一个新文件。不改运行时代码、不做 hook、不 patch。
//   * 逐页读，失败页填零并记入 failedBytes。绝不假设整段连续可读——
//     有反 dump 检测的实现会把部分页设成 PROT_NONE，整段 memcpy 就是 SIGBUS。
//   * 输出目录固定 Documents/AiFlex3Dump/，这样沙盒读取（sandbox_list / sandbox_read）
//     可以直接取走，不需要额外的传输通道。
//   * 单文件上限 512 MiB，且写入前检查可用磁盘空间，绝不把设备写满。
@interface FLEXAiFlexDumper : NSObject

+ (instancetype)sharedEngine;

/// 是否能够导出（Mach-O 解析与 vm_read 都可用；正常情况下恒为 YES）。
+ (BOOL)engineAvailable;

/// 支持的 operation 名称，供 capabilities / status 汇总。
+ (NSArray<NSString *> *)supportedOperations;

/// 统一入口。completion 在引擎的串行队列上回调，调用方自行切换队列。
- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *result, NSString *error))completion;

@end
