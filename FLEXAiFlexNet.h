//
//  FLEXAiFlexNet.h
//  FLEX++
//
//  网络抓包与改写引擎。
//
//  定位：FLEX 自带的 FLEXNetworkRecorder 只覆盖 NSURLSession / NSURLConnection
//  一层，拿不到全量请求头、拿不到 HTTPBodyStream、看不到自带 TLS 栈的 App、
//  看不到 WebSocket，更不能改包 / 重放 / 断点 / 构造请求。本引擎补这四类缺口：
//
//    采集层（只观测，不改行为）
//      nsurl        NSURLSession 全家族：data / upload / download / resume 兜底
//      ws           NSURLSessionWebSocketTask 帧（收 / 发）
//      openssl      fishhook SSL_write / SSL_write_ex / SSL_read / SSL_read_ex
//      securetransport  fishhook SSLWrite / SSLRead（Apple 系统 TLS 栈）
//      socket       connect / getaddrinfo / send / recv 的连接元数据 + TLS ClientHello SNI
//
//    改写层（control 组，会改变宿主行为）
//      rewrite      按规则改 URL / method / 请求头 / 请求体 / 响应体
//      hold         请求在发出前挂起，等 AI 决策放行 / 改后放行 / 丢弃
//      replay       把历史请求原样或改后重发
//      compose      从零构造一条请求并取回完整响应
//
//  诚实边界：TLS 之后的密文只有 App 自己调 SSL_read/write 或 SecureTransport
//  才能看到明文；socket 层只给连接元数据与 SNI，绝不解密。看不到的字段一律
//  写进 note，不用空值冒充"没有参数"。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FLEXAiFlexNet : NSObject

+ (instancetype)sharedEngine;

/// 采集引擎是否可用（swizzle 与 fishhook 都编译进来了）。恒为 YES，
/// 保留此方法是为了和 frida / disasm / hook 三组保持一致的调用形状。
+ (BOOL)engineAvailable;

/// aiflex_net 的 operation 列表（sensitive 组，只读）。
+ (NSArray<NSString *> *)captureOperations;

/// aiflex_net_action 的 operation 列表（control 组，会改变行为）。
+ (NSArray<NSString *> *)actionOperations;

/// 统一入口。completion 恒定在引擎自己的串行队列执行，不在主线程。
- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *_Nullable result, NSString *_Nullable error))completion;

/// 幂等安装：重复调用只装一次。由 MCP 服务启动时调用。
- (void)installHooksIfNeeded;

/// 采集开关的当前值，供 status / capabilities 展示。
- (NSDictionary *)captureState;

/// 把一条记录按 HAR 风格导出，供 network_export 复用。内部使用。
- (NSDictionary *)harEntryForIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
