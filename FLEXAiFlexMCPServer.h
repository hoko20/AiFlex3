#import <Foundation/Foundation.h>

// Injected-app MCP endpoint. Runs inside the host process and reuses the FLEX
// runtime; it never talks to any external desktop app. The bearer token and
// each tool group are explicit grants stored for that host app.
@interface FLEXAiFlexMCPServer : NSObject
+ (instancetype)shared;
+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;
+ (NSUInteger)port;
+ (void)setPort:(NSUInteger)port;
+ (NSString *)endpointHost;
+ (BOOL)setEndpointHost:(NSString *)host;
+ (NSString *)localAddress;
+ (BOOL)authRequired;
+ (void)setAuthRequired:(BOOL)required;
+ (NSString *)token;
+ (BOOL)setToken:(NSString *)token;
+ (NSString *)rotateToken;
+ (BOOL)sensitiveEnabled;
+ (void)setSensitiveEnabled:(BOOL)enabled;
+ (BOOL)controlEnabled;
+ (void)setControlEnabled:(BOOL)enabled;
+ (BOOL)scriptEnabled;
+ (void)setScriptEnabled:(BOOL)enabled;
+ (BOOL)tracingEnabled;
+ (void)setTracingEnabled:(BOOL)enabled;
// 代码改写组。默认关，且与其余所有组独立：它能让宿主 App 真的改变行为，
// 打开前应在面板上明确看到「会改写运行中的代码」这句话。
+ (BOOL)hookEnabled;
+ (void)setHookEnabled:(BOOL)enabled;
+ (NSString *)endpoint;
+ (NSString *)status;
// 端口被占用并自动顺延时的说明（正常情况为 nil）。
+ (NSString *)portNotice;
- (void)start;
- (void)stop;
@end
