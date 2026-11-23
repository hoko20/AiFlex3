#import "FLEXAiFlexMCPServer.h"
#import "FLEXAiFlexRuntime.h"
#import "FLEXAiFlex3ViewController.h"
#import "FLEXManager+Private.h"
#import <Network/Network.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

static NSString *const DXMCPServiceKey=@"FLEXAiFlexMCP.enabled";
static NSString *const DXMCPPortKey=@"FLEXAiFlexMCP.port";
static NSString *const DXMCPHostKey=@"FLEXAiFlexMCP.host";
static NSString *const DXMCPTokenKey=@"FLEXAiFlexMCP.token";
static NSString *const DXMCPAuthKey=@"FLEXAiFlexMCP.requireToken";
static NSString *const DXMCPGroupPrefix=@"FLEXAiFlexMCP.group.";
static NSString *const DXMCPVersion=@"2025-06-18";
// Persist grants immediately: a token lazily generated at first copy must not
// be lost if the host app is killed shortly after, or copied credentials 401.
static void Sync(void){[NSUserDefaults.standardUserDefaults synchronize];}

static NSDictionary *HTTPJSON(NSInteger status,NSDictionary *json,NSDictionary *headers){
 NSData *data=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
 NSMutableDictionary *response=[@{@"status":@(status),@"headers":headers?:@{},@"body":data?:NSData.data} mutableCopy];
 return response;
}
static NSDictionary *RPC(id identifier,NSDictionary *result){
 return @{@"jsonrpc":@"2.0",@"id":identifier?:NSNull.null,@"result":result?:@{}};
}
static NSDictionary *RPCError(id identifier,NSInteger code,NSString *message){
 return @{@"jsonrpc":@"2.0",@"id":identifier?:NSNull.null,@"error":@{@"code":@(code),@"message":message?:@"请求无效"}};
}
static NSString *JSONText(id object){
 NSData *data=[NSJSONSerialization dataWithJSONObject:object?:@{} options:0 error:nil];
 NSString *text=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
 if(text.length>256000)text=[[text substringToIndex:256000] stringByAppendingString:@"\n…（结果过长已截断，请缩小查询范围）"];
 return text?:@"{}";
}
static NSDictionary *TextContent(id object,BOOL failed){
 NSMutableDictionary *result=[@{@"content":@[@{@"type":@"text",@"text":JSONText(object)}]} mutableCopy];
 if(failed)result[@"isError"]=@YES;
 return result;
}
static NSDictionary *ToolError(NSString *message){return TextContent(@{@"error":message?:@"工具执行失败"},YES);}
static NSDictionary *FlexContent(NSDictionary *result){
 NSMutableDictionary *text=[result mutableCopy];
 NSString *image=[text[@"imageBase64"] isKindOfClass:NSString.class]?text[@"imageBase64"]:nil;
 NSString *mime=[text[@"mime"] isKindOfClass:NSString.class]?text[@"mime"]:@"";
 [text removeObjectForKey:@"imageBase64"];
 NSMutableArray *content=[NSMutableArray arrayWithObject:@{@"type":@"text",@"text":JSONText(text)}];
 if([mime isEqual:@"image/jpeg"]&&image.length&&image.length<400000)[content addObject:@{@"type":@"image",@"data":image,@"mimeType":mime}];
 return @{@"content":content};
}
static NSDictionary *StringField(void){return @{@"type":@"string"};}
static NSDictionary *ArrayField(void){return @{@"type":@"array"};}
static NSDictionary *IntegerField(void){return @{@"type":@"integer"};}
static NSDictionary *NumberField(void){return @{@"type":@"number"};}
static NSDictionary *BooleanField(void){return @{@"type":@"boolean"};}
static NSDictionary *EnumField(NSArray *values){return @{@"type":@"string",@"enum":values};}
static NSDictionary *Tool(NSString *name,NSString *group,NSString *description,NSDictionary *properties,NSArray *required){
 return @{@"name":name,@"group":group,@"description":description,@"schema":@{@"type":@"object",@"properties":properties?:@{},@"required":required?:@[],@"additionalProperties":@NO}};
}
static NSArray<NSString *> *ReadOperations(void){return @[@"capabilities",@"current",@"report",@"screen_elements",@"screen_texts",@"find_text",@"wait_for",@"hit_test",@"view_tree",@"controller_stack",@"app_info",@"device_info",@"object_info",@"object_properties",@"find_instances",@"class_search",@"class_info",@"runtime_images",@"network_list",@"network_search",@"cookies_list",@"sandbox_list",@"defaults_keys",@"select_object",@"gesture_capabilities",@"tool_catalog",@"chat_status",@"snapshot"];}
static NSArray<NSString *> *SensitiveOperations(void){return @[@"class_header",@"flex_ui_state",@"network_detail",@"network_export",@"sandbox_read",@"sandbox_grep",@"defaults_get",@"keychain_list",@"capture_screen"];}
static NSArray<NSString *> *ControlOperations(void){return @[@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool",@"select_row",@"set_search",@"flex_scroll",@"input_text",@"set_control_value",@"activate_control",@"tap_text",@"scroll_to_text",@"highlight_element",@"scroll_view",@"set_view",@"set_network_recording",@"undo",@"invoke_method",@"gesture"];}
static BOOL GroupEnabled(NSString *group){
 if([group isEqual:@"read"])return YES;
 if([group isEqual:@"sensitive"])return [FLEXAiFlexMCPServer sensitiveEnabled];
 if([group isEqual:@"control"])return [FLEXAiFlexMCPServer controlEnabled];
 if([group isEqual:@"script"])return [FLEXAiFlexMCPServer scriptEnabled];
 if([group isEqual:@"tracing"])return [FLEXAiFlexMCPServer tracingEnabled];
 return NO;
}
// Window operations belong to FLEXAiFlex3ViewController; everything else is
// executed by FLEXAiFlexRuntime.
static BOOL WindowOperation(NSString *operation){
 static NSSet *operations;static dispatch_once_t once;
 dispatch_once(&once,^{operations=[NSSet setWithArray:@[@"chat_status",@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool"]];});
 return [operations containsObject:operation];
}
static NSString *Instructions(void){
 return @"你通过 AiFlex3 直连当前注入的 App。先调用 aiflex_read(operation=capabilities)、current 和 report，核对 bundleID、当前页面、选中对象与可用操作；连接配置存在不代表目标在线。选中对象为空不妨碍用 screen_elements / view_tree 自主观察，不要只凭最后点选的控件猜界面。\n需要操作目标页面时，若 FLEX 覆盖层可见，先调用 aiflex_control(operation=minimize_chat, surface=target)，再读 screen_elements 和截图；截图用 aiflex_sensitive(operation=capture_screen)；返回截图不代表模型一定收到图像。\n只使用真实返回的 id/frame/窗口坐标，导航后重新读取，不连续重试过期 id。activate_control 的支持范围以返回为准，不支持时可在 gesture_capabilities 确认后端可用并获授权后使用 gesture。需要触发业务方法或已存在的 Hook 时，可用 aiflex_control(operation=invoke_method, selector=..., arguments=[...])；传 id 指定实时对象，或传 class 调用类方法，不传则用当前选中对象。返回对象时会给出 returnId，可继续用 aiflex_read(operation=object_info, id=returnId) 读取实例数据，或用 invoke_method(id=returnId) 调实例方法。需要查找当前界面里某个类的已有实例，用 aiflex_read(operation=find_instances, class=...)，返回的 id 同样可继续使用；非界面对象不做堆扫描。参数仅支持字符串、数字、布尔、null、数组和字典，最多 8 个；调用会执行真实副作用，是否触发 Hook 取决于目标实现，调用后重新读取现场。delivered、dispatched、scrolled 不是业务成功证明，操作后核对 controllerPath、控件文字/位置、contentOffset 和新截图；滚动 delta=0 要报告未滚动。切页前记录恢复路径，结束后 restore_chat。\n稳定 Hook 证据：object_info + view_tree + class_info；头文件用 aiflex_sensitive(operation=class_header) 的 name/start_line/line_count 分页。区分当前对象、交互父容器、业务祖先、最近 responder controller 和声明所属镜像；hookEvidence 的声明候选、executionObserved、stabilityVerified 分开解释，未观测执行不能称为已验证生命周期。\nset_view / undo 仅作临时现场验证，需授权并复查；持久修改要写进工程并构建，不能用临时隐藏冒充插件功能。\n定位文字用 aiflex_read(operation=find_text, query=...) 或 screen_texts；点击文字用 aiflex_control(operation=tap_text, query=...)；读实例字段值用 object_properties；日志搜索用 aiflex_sensitive(operation=sandbox_grep, path=..., query=...)；对比操作前后用 aiflex_read(operation=snapshot, action=save/diff)。脚本仅在手机端开启「脚本执行」后用 aiflex_script(operation=run_js, code=...)，只影响 WKWebView。方法追踪仅在开启「方法追踪」后用 aiflex_trace(operation=start/stop/read/clear, class=..., selector=...)，它替换方法实现并记录调用，可能崩溃或卡顿，10 分钟自动停止，不要对高频方法开启。需要等待页面变化时用 aiflex_read(operation=wait_for, condition=text_exists, query=..., timeout=...)，不要空转重复读取；列表内容在屏幕外时用 aiflex_control(operation=scroll_to_text, query=...)；点不动先查 aiflex_read(operation=controller_stack) 确认是否有模态遮挡；环境信息用 app_info / device_info；view_tree 支持 class_filter、text_filter、max_depth、interactive_only、include_hidden。\n日志：先 sandbox_list 取真实相对路径和大小，再 aiflex_sensitive(operation=sandbox_read, path=...)，默认 128 KiB、limit 最高 524288；优先 tail=true 读末尾，tail 不与 offset 同传；续读用 next_offset，检查 has_more、totalBytes、modifiedAt。网络详情、defaults、文件和钥匙串元数据只在授权范围内读取，不复述秘密。报告工具失败、空结果、未测项和真实截图状态，不凭配置声称功能正常。";
}
static NSArray<NSDictionary *> *Tools(void){ static NSArray *tools;static dispatch_once_t once;
 dispatch_once(&once,^{
  NSDictionary *read=@{@"operation":EnumField(ReadOperations()),@"id":StringField(),@"query":StringField(),@"name":StringField(),@"class":StringField(),@"limit":IntegerField(),@"path":StringField(),@"offset":IntegerField(),@"x":NumberField(),@"y":NumberField(),@"host":StringField(),@"method":StringField(),@"status":IntegerField(),@"exact":BooleanField(),@"action":EnumField(@[@"save",@"diff",@"clear"]),@"condition":EnumField(@[@"text_exists",@"text_gone",@"element_exists",@"element_gone",@"controller",@"network"]),@"timeout":NumberField(),@"max_depth":IntegerField(),@"class_filter":StringField(),@"text_filter":StringField(),@"interactive_only":BooleanField(),@"include_hidden":BooleanField()};
  NSDictionary *sensitive=@{@"operation":EnumField(SensitiveOperations()),@"surface":EnumField(@[@"target",@"flex"]),@"name":StringField(),@"start_line":IntegerField(),@"line_count":IntegerField(),@"id":StringField(),@"path":StringField(),@"query":StringField(),@"case_sensitive":BooleanField(),@"rect":StringField(),@"key":StringField(),@"offset":IntegerField(),@"limit":IntegerField(),@"tail":BooleanField()};
  NSDictionary *control=@{@"operation":EnumField(ControlOperations()),@"surface":EnumField(@[@"target",@"flex"]),@"tool_id":StringField(),@"query":StringField(),@"exact":BooleanField(),@"section":IntegerField(),@"row":IntegerField(),@"kind":EnumField(@[@"tap",@"double_tap",@"long_press",@"swipe",@"drag",@"pinch",@"rotate"]),@"x":NumberField(),@"y":NumberField(),@"end_x":NumberField(),@"end_y":NumberField(),@"duration":NumberField(),@"start_radius":NumberField(),@"end_radius":NumberField(),@"radius":NumberField(),@"angle":NumberField(),@"text":StringField(),@"replace":BooleanField(),@"value":NumberField(),@"index":IntegerField(),@"id":StringField(),@"direction":EnumField(@[@"up",@"down",@"left",@"right"]),@"pages":NumberField(),@"max_pages":IntegerField(),@"container":StringField(),@"hidden":BooleanField(),@"alpha":NumberField(),@"enabled":BooleanField(),@"selector":StringField(),@"arguments":ArrayField(),@"class":StringField()};
  NSDictionary *script=@{@"operation":EnumField(@[@"run_js"]),@"code":StringField(),@"id":StringField()};
  NSDictionary *trace=@{@"operation":EnumField(@[@"start",@"stop",@"read",@"clear"]),@"class":StringField(),@"selector":StringField()};
  tools=@[
   Tool(@"aiflex_status",@"read",@"Report this injected app, the MCP endpoint, listening state and enabled tool groups.",@{},@[]),
   Tool(@"aiflex_read",@"read",@"Read runtime facts from this app through FLEX: capabilities, current object, report text, screen elements/texts, text search, hit test, view tree, object info/properties, instances, class search/info, loaded images, network metadata/search, cookies metadata, sandbox listing, defaults keys and screen snapshots. Live IDs expire after navigation or tree refresh; requery instead of reusing stale ids.",read,@[@"operation"]),
   Tool(@"aiflex_sensitive",@"sensitive",@"Read sensitive app content with the phone-side sensitive grant: class header, FLEX UI state, network detail/export, text grep in sandbox files, UTF-8 sandbox file, defaults value, Keychain metadata (never secret values) and an app JPEG screenshot (optional rect crop).",sensitive,@[@"operation"]),
   Tool(@"aiflex_control",@"control",@"Control this app with the phone-side control grant: minimize/restore panel, open tools, navigate, select rows, search, scroll, input text, set values, activate buttons, tap by text, highlight a view, change hidden/alpha, toggle network recording, undo, invoke a method and deliver real gestures. Delivered input is not proof the action succeeded; requery afterwards.",control,@[@"operation"]),
   Tool(@"aiflex_script",@"script",@"Run JavaScript inside the current page's WKWebView/UIWebView with the phone-side script grant. This changes web page state and is isolated from the native process; it is not a hooking tool.",script,@[@"operation",@"code"]),
   Tool(@"aiflex_trace",@"tracing",@"Experimental method tracing with the phone-side tracing grant: replace an instance method's implementation and record calls (up to 3 object arguments, void/object return) in a 500-event ring buffer. High risk: may change app behavior, crash, or slow high-frequency methods. Active hooks auto-stop after 10 minutes.",trace,@[@"operation"])
  ];
 });return tools;
}
static NSDictionary *ToolNamed(NSString *name){
 for(NSDictionary *tool in Tools())if([tool[@"name"] isEqual:name])return tool;
 return nil;
}
// JSON true/false 落到 NSNumber，但和 1/0 不是一回事：只按 NSNumber 判断会让
// boolean 参数接受 1、让 integer 参数接受 true 或 1.5（被 integerValue 悄悄截断）。
// NSJSONSerialization 给布尔值的是 __NSCFBoolean，这是唯一可靠的区分点；
// 不要用 CFGetTypeID 去猜，对非 toll-free 对象属于未定义行为。
static BOOL BooleanValue(id value){
 if(![value isKindOfClass:NSNumber.class])return NO;
 if([NSStringFromClass([value class]) isEqual:@"__NSCFBoolean"])return YES;
 const char *type=[(NSNumber *)value objCType];
 return type&&(type[0]=='c'||type[0]=='B')&&[NSStringFromClass([value class]) containsString:@"Boolean"];
}
static BOOL TypeMatches(NSString *type,id value){
 if([type isEqual:@"string"])return [value isKindOfClass:NSString.class];
 if([type isEqual:@"array"])return [value isKindOfClass:NSArray.class];
 if(![value isKindOfClass:NSNumber.class])return NO;
 if(BooleanValue(value))return [type isEqual:@"boolean"];
 if([type isEqual:@"boolean"])return NO;
 if([type isEqual:@"integer"]){double number=[value doubleValue];return isfinite(number)&&number==floor(number);}
 return YES;
}
static BOOL Same(NSString *left,NSString *right){
 const char *a=left.UTF8String,*b=right.UTF8String;
 if(!a||!b)return NO;
 size_t length=strlen(a);
 if(length!=strlen(b))return NO;
 unsigned char diff=0;
 for(size_t i=0;i<length;i++)diff|=(unsigned char)(a[i]^b[i]);
 return diff==0;
}
static NSString *RandomToken(void){
 unsigned char bytes[32];if(SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess)arc4random_buf(bytes,sizeof(bytes));
 NSMutableString *token=[NSMutableString stringWithCapacity:64];
 for(NSUInteger i=0;i<sizeof(bytes);i++)[token appendFormat:@"%02x",bytes[i]];
 return token;
}
static NSString *LocalIPv4(void){
 struct ifaddrs *interfaces=NULL;NSString *address=@"127.0.0.1";
 if(getifaddrs(&interfaces)!=0)return address;
 for(struct ifaddrs *cursor=interfaces;cursor;cursor=cursor->ifa_next){
  if(!cursor->ifa_addr||cursor->ifa_addr->sa_family!=AF_INET||(cursor->ifa_flags&IFF_LOOPBACK))continue;
  NSString *name=cursor->ifa_name?[NSString stringWithUTF8String:cursor->ifa_name]:@"";
  if(![name hasPrefix:@"en"])continue;
  char buffer[INET_ADDRSTRLEN];inet_ntop(AF_INET,&((struct sockaddr_in*)cursor->ifa_addr)->sin_addr,buffer,sizeof(buffer));
  address=[NSString stringWithUTF8String:buffer];break;
 }
 freeifaddrs(interfaces);return address;
}

@interface FLEXAiFlexMCPServer ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) nw_listener_t listener;
@property(nonatomic) NSMutableSet *connections;
@property(atomic) BOOL running;
@property(atomic,copy) NSString *lastError;
@property(atomic,copy) NSString *portNotice; // 端口被占自动顺延后的说明，成功后仍保留给面板展示
@property(nonatomic) FLEXAiFlexRuntime *runtime;
@property(nonatomic) NSUInteger generation;   // isolates stale listener callbacks after stop/restart
@property(nonatomic) NSUInteger startAttempt; // bounded backoff for failed binds
@property(nonatomic) NSUInteger portFallbackHops; // how many ports we auto-skipped
@property(nonatomic) NSInteger lastBindError; // errno of the last failed bind (0 = unknown)
@property(nonatomic) BOOL rebinding;              // 内部重建中：端口冲突先等待旧 socket 释放，别急着顺延
@property(nonatomic) BOOL inBackground;           // 宿主是否在后台：后台会被系统挂起，监听随之中断
@property(nonatomic) UIBackgroundTaskIdentifier lease; // 进后台时的短时租约，只为让在途请求收尾
@property(nonatomic) NSMutableSet<NSValue *> *busy; // 有请求正在执行的连接：看门狗不能收线
- (void)accept:(nw_connection_t)connection;
- (void)armWatchdog:(nw_connection_t)connection;
- (void)markBusy:(nw_connection_t)connection busy:(BOOL)busy;
- (BOOL)isBusy:(nw_connection_t)connection;
- (void)beginListening;
- (void)restart;
- (void)beginBackgroundLease;
- (void)endBackgroundLease;
+ (NSString *)bindFailureText:(NSInteger)code port:(NSUInteger)port;
- (void)read:(nw_connection_t)connection buffer:(NSMutableData *)buffer;
- (void)process:(nw_connection_t)connection buffer:(NSMutableData *)buffer;
- (void)handle:(NSDictionary *)request connection:(nw_connection_t)connection;
- (void)mcp:(NSDictionary *)body connection:(nw_connection_t)connection;
- (NSArray<NSDictionary *> *)schemas;
- (void)sendResponse:(NSDictionary *)response connection:(nw_connection_t)connection;
- (void)call:(NSString *)name arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *result))completion;
- (void)respond:(nw_connection_t)connection status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body;
- (void)close:(nw_connection_t)connection;
- (void)retryStartForGeneration:(NSUInteger)generation;
@end
@implementation FLEXAiFlexMCPServer
+ (instancetype)shared{
 static FLEXAiFlexMCPServer *server;static dispatch_once_t once;
 dispatch_once(&once,^{server=[FLEXAiFlexMCPServer new];});
 return server;
}
+ (BOOL)isEnabled{return [NSUserDefaults.standardUserDefaults boolForKey:DXMCPServiceKey];}
+ (void)setEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:DXMCPServiceKey];Sync();}
+ (NSUInteger)port{
 NSUInteger port=[NSUserDefaults.standardUserDefaults integerForKey:DXMCPPortKey];
 return port>=1024&&port<=65535?port:8790;
}
+ (void)setPort:(NSUInteger)port{if(port<1024||port>65535)return;[NSUserDefaults.standardUserDefaults setInteger:port forKey:DXMCPPortKey];Sync();}
+ (NSString *)endpointHost{
 NSString *host=[NSUserDefaults.standardUserDefaults stringForKey:DXMCPHostKey];
 host=[host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 return host.length?host:@"127.0.0.1";
}
+ (BOOL)setEndpointHost:(NSString *)host{
 NSString *value=[host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 // Accept a full URL pasted by the user and keep only the host component.
 if([value containsString:@"://"]){NSURL *url=[NSURL URLWithString:value];value=url.host?:value;}
 // Strip an optional port or path suffix so endpoint can re-append the configured port.
 NSURLComponents *parts=[NSURLComponents componentsWithString:[@"http://" stringByAppendingString:value]];
 if(parts.host.length)value=parts.host;
 if(!value.length||value.length>253)return NO;
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.:[]-"];
 if([value rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound)return NO;
 [NSUserDefaults.standardUserDefaults setObject:value forKey:DXMCPHostKey];Sync();
 return YES;
}
+ (BOOL)authRequired{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:DXMCPAuthKey];
 return stored?[stored boolValue]:YES;
}
+ (void)setAuthRequired:(BOOL)required{[NSUserDefaults.standardUserDefaults setBool:required forKey:DXMCPAuthKey];Sync();}
+ (NSString *)token{
 NSString *token=[NSUserDefaults.standardUserDefaults stringForKey:DXMCPTokenKey];
 if(!token.length){token=RandomToken();[NSUserDefaults.standardUserDefaults setObject:token forKey:DXMCPTokenKey];Sync();}
 return token;
}
+ (BOOL)setToken:(NSString *)token{
 NSString *value=[token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
 if(value.length<6||value.length>64)return NO;
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
 if([value rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound)return NO;
 [NSUserDefaults.standardUserDefaults setObject:value forKey:DXMCPTokenKey];
 // 自填的授权码必须立刻落盘：面板复制后马上杀进程也不会丢，否则下次 401。
 Sync();
 return YES;
}
+ (NSString *)rotateToken{
 NSString *token=RandomToken();[NSUserDefaults.standardUserDefaults setObject:token forKey:DXMCPTokenKey];Sync();return token;
}
+ (BOOL)sensitiveEnabled{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"sensitive"]];
 return stored?[stored boolValue]:NO;
}
+ (void)setSensitiveEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"sensitive"]];Sync();}
+ (BOOL)controlEnabled{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"control"]];
 return stored?[stored boolValue]:NO;
}
+ (void)setControlEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"control"]];Sync();}
+ (BOOL)scriptEnabled{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"script"]];
 return stored?[stored boolValue]:NO;
}
+ (void)setScriptEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"script"]];Sync();}
+ (BOOL)tracingEnabled{
 id stored=[NSUserDefaults.standardUserDefaults objectForKey:[DXMCPGroupPrefix stringByAppendingString:@"tracing"]];
 return stored?[stored boolValue]:NO;
}
+ (void)setTracingEnabled:(BOOL)enabled{[NSUserDefaults.standardUserDefaults setBool:enabled forKey:[DXMCPGroupPrefix stringByAppendingString:@"tracing"]];Sync();}
+ (NSString *)localAddress{return LocalIPv4();}
+ (NSString *)endpoint{return [NSString stringWithFormat:@"http://%@:%lu/mcp",[self endpointHost],(unsigned long)[self port]];}
+ (NSString *)status{
 FLEXAiFlexMCPServer *server=[self shared];
 if(![self isEnabled])return @"未开启";
 if(server.running)return server.inBackground?@"运行中 · 后台可能暂停":@"运行中";
 if(server.lastError.length)return server.lastError;
 return @"正在启动";
}
+ (NSString *)portNotice{return [self shared].portNotice;}
- (instancetype)init{
 if((self=[super init])){_queue=dispatch_queue_create("flex.aiflex.mcp",DISPATCH_QUEUE_SERIAL);_connections=[NSMutableSet new];_busy=[NSMutableSet new];_lease=UIBackgroundTaskInvalid;}
 return self;
}
- (void)start{
 dispatch_async(self.queue,^{
  // 外部重启意味着"重新开始"：清掉上一次的失败计数。
  // 之前这里没清零，一次瞬时端口冲突就会把计数顶到上限，
  // 之后无论怎么点重启都直接判定"持续无法监听"，永远不会再试。
  self.startAttempt=0;
  self.portFallbackHops=0;
  self.lastBindError=0;
  self.portNotice=nil;
  self.rebinding=YES;
  [self beginListening];
 });
}

// 强制重建监听。系统把宿主挂起时 socket 会被回收，但 nw_listener 不一定回调
// cancelled，running 可能仍停在 YES；此时只调 start 会被 running 挡住，
// 表现就是面板显示"运行中"却始终连不上。回前台必须走这条路径。
- (void)restart{
 dispatch_async(self.queue,^{
  if(![FLEXAiFlexMCPServer isEnabled])return;
  self.running=NO;
  if(self.listener){nw_listener_cancel(self.listener);self.listener=nil;}
  // 挂起期间留下的半死连接一并清掉，否则重连会复用到已失效的 socket。
  for(nw_connection_t connection in self.connections.allObjects)nw_connection_cancel(connection);
  [self.connections removeAllObjects];
  self.generation++;
  self.startAttempt=0;
  self.portFallbackHops=0;
  self.lastBindError=0;
  self.rebinding=YES;
  [self beginListening];
 });
}

// 进后台时向系统借一小段时间（通常 30 秒左右），让在途请求能收尾；
// 借不到长期保活是系统限制，不是服务本身的问题。
- (void)beginBackgroundLease{
 if(self.lease!=UIBackgroundTaskInvalid)return;
 __weak typeof(self) weak=self;
 self.lease=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"AiFlex3 MCP"
   expirationHandler:^{ [weak endBackgroundLease]; }];
}

- (void)endBackgroundLease{
 if(self.lease==UIBackgroundTaskInvalid)return;
 UIBackgroundTaskIdentifier lease=self.lease;
 self.lease=UIBackgroundTaskInvalid;
 [UIApplication.sharedApplication endBackgroundTask:lease];
}

// 必须在 queue 上调用。
- (void)beginListening{
 if(self.running)return;
 self.lastError=@"";
 if(self.listener){nw_listener_cancel(self.listener);self.listener=nil;}
 // Bump generation so callbacks from any prior/cancelled listener are ignored.
 self.generation++;
 NSUInteger generation=self.generation;
 NSUInteger port=[FLEXAiFlexMCPServer port];
 nw_parameters_t parameters=nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,NW_PARAMETERS_DEFAULT_CONFIGURATION);
 nw_listener_t listener=nw_listener_create_with_port([NSString stringWithFormat:@"%lu",(unsigned long)port].UTF8String,parameters);
 if(!listener){
  self.lastBindError=ENOMEM;
  self.lastError=[NSString stringWithFormat:@"端口 %lu 无法创建监听器",(unsigned long)port];
  [self retryStartForGeneration:generation];return;
 }
 nw_listener_set_queue(listener,self.queue);
 __weak typeof(self) weak=self;
 nw_listener_set_new_connection_handler(listener,^(nw_connection_t connection){[weak accept:connection];});
 nw_listener_set_state_changed_handler(listener,^(nw_listener_state_t state,nw_error_t error){
  FLEXAiFlexMCPServer *server=weak;if(!server)return;
  if(server.generation!=generation)return; // stale callback: ignore
  if(state==nw_listener_state_ready){
   server.running=YES;server.lastError=@"";server.startAttempt=0;server.portFallbackHops=0;server.lastBindError=0;server.rebinding=NO;
  }else if(state==nw_listener_state_failed){
   server.running=NO;
   // 绑定失败的真实原因在 nw_error 里：EADDRINUSE 说明端口被占，
   // 其它码才可能是权限或参数问题。带上码值，面板就不用再猜。
   NSInteger code=0;
   if(error&&nw_error_get_error_domain(error)==nw_error_domain_posix)code=(NSInteger)nw_error_get_error_code(error);
   server.lastBindError=code;
   server.lastError=[FLEXAiFlexMCPServer bindFailureText:code port:port];
   [server retryStartForGeneration:generation];
  }else if(state==nw_listener_state_cancelled){
   if(server.generation==generation)server.running=NO;
  }
 });
 self.listener=listener;
 nw_listener_start(listener);
}

+ (NSString *)bindFailureText:(NSInteger)code port:(NSUInteger)port{
 switch(code){
  case EADDRINUSE: return [NSString stringWithFormat:@"端口 %lu 已被占用",(unsigned long)port];
  case EACCES: return [NSString stringWithFormat:@"端口 %lu 被系统拒绝（无监听权限）",(unsigned long)port];
  default: break;
 }
 if(code)return [NSString stringWithFormat:@"端口 %lu 无法监听（errno %ld）",(unsigned long)port,(long)code];
 return [NSString stringWithFormat:@"端口 %lu 无法监听",(unsigned long)port];
}

// Bounded retry for a failed bind (e.g. port still held by an old listener during restart).
- (void)retryStartForGeneration:(NSUInteger)generation{
 // 端口明确被占用时，等待重试没有意义（占用方不会自己让开），
 // 直接顺延；只有 errno 不明或权限类错误才退避重试。
 BOOL occupied=(self.lastBindError==EADDRINUSE);
 // 但内部重建（回前台/手动重启）是例外：旧 listener 的 socket 往往还没释放，
 // 这时判"端口被占"会把端口莫名顺延成 8791，App 侧存的地址就对不上了。
 // 内部重建先在同一端口上多等几拍，等旧 socket 释放。
 if(occupied&&self.rebinding&&self.startAttempt<6){
  NSUInteger attempt=++self.startAttempt;
  __weak typeof(self) weak=self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*attempt*NSEC_PER_SEC)),self.queue,^{
   FLEXAiFlexMCPServer *server=weak;if(!server||server.generation!=generation||server.running)return;
   if(server.listener){nw_listener_cancel(server.listener);server.listener=nil;}
   [server beginListening];
  });
  return;
 }
 if(!occupied&&self.startAttempt<4){
  NSUInteger attempt=++self.startAttempt;
  __weak typeof(self) weak=self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*attempt*NSEC_PER_SEC)),self.queue,^{
   FLEXAiFlexMCPServer *server=weak;if(!server||server.generation!=generation||server.running)return;
   if(server.listener){nw_listener_cancel(server.listener);server.listener=nil;}
   [server beginListening];
  });
  return;
 }
 // 顺延到后面的端口，并把配置写回，面板上的访问地址会跟着变成新端口，
 // 不用用户手动去设置里改。
 if((occupied||self.lastBindError==0)&&self.portFallbackHops<10){
  // 内部重建的等待机会已经用尽，说明端口是真的被别的进程占着，转顺延。
  self.rebinding=NO;
  NSUInteger current=[FLEXAiFlexMCPServer port];
  NSUInteger next=current+1;
  if(next>=1024&&next<=65535){
   self.portFallbackHops++;
   self.startAttempt=0;
   [NSUserDefaults.standardUserDefaults setInteger:next forKey:DXMCPPortKey];
   Sync();
   self.portNotice=[NSString stringWithFormat:@"端口 %lu 被占用，已自动改用 %lu",
                    (unsigned long)current,(unsigned long)next];
   self.lastError=self.portNotice;
   __weak typeof(self) weak=self;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),self.queue,^{
    FLEXAiFlexMCPServer *server=weak;if(!server||server.generation!=generation||server.running)return;
    [server beginListening];
   });
   return;
  }
 }
 self.lastError=[NSString stringWithFormat:@"端口 %lu 持续无法监听，请在设置中更换端口",
                 (unsigned long)[FLEXAiFlexMCPServer port]];
}
- (void)stop{
 dispatch_async(self.queue,^{
  self.generation++; // invalidate in-flight listener callbacks
  if(self.listener){nw_listener_cancel(self.listener);self.listener=nil;}
  for(nw_connection_t connection in self.connections.allObjects)nw_connection_cancel(connection);
  [self.connections removeAllObjects];self.running=NO;
  [self endBackgroundLease];
 });
}
// 100.64/10 是运营商级 NAT 与 Tailscale 一类的常用段，出现在手机上很常见；
// 只认 10/8、172.16/12、192.168/16 会把这类局域网直连判成"公网"而拒掉。
static BOOL PrivateIPv4(uint32_t host){
 if((host>>24)==127||(host>>24)==10)return YES;
 if((host&0xFFF00000)==0xAC100000)return YES;
 if((host&0xFFFF0000)==0xC0A80000)return YES;
 if((host&0xFFFF0000)==0xA9FE0000)return YES;
 if((host&0xFFC00000)==0x64400000)return YES;
 return NO;
}
// Keep the endpoint private to this device or its LAN. IPv6 must be handled too:
// a client that resolves "localhost" connects from ::1, and an IPv4-only check
// used to cancel that socket before any byte was read — the client only saw a
// silent close, which is indistinguishable from a crash.
- (BOOL)privateConnection:(nw_connection_t)connection{
 nw_endpoint_t endpoint=nw_connection_copy_endpoint(connection);
 const struct sockaddr *address=nw_endpoint_get_address(endpoint);
 if(!address){
  nw_path_t path=nw_connection_copy_current_path(connection);
  nw_endpoint_t remote=path?nw_path_copy_effective_remote_endpoint(path):nil;
  address=remote?nw_endpoint_get_address(remote):NULL;
 }
 if(!address)return NO;
 if(address->sa_family==AF_INET)return PrivateIPv4(ntohl(((const struct sockaddr_in *)address)->sin_addr.s_addr));
 if(address->sa_family==AF_INET6){
  const struct in6_addr *six=&((const struct sockaddr_in6 *)address)->sin6_addr;
  if(IN6_IS_ADDR_LOOPBACK(six)||IN6_IS_ADDR_LINKLOCAL(six))return YES;
  if((six->s6_addr[0]&0xFE)==0xFC)return YES; // fc00::/7 unique local
  if(IN6_IS_ADDR_V4MAPPED(six)){
   uint32_t host=((uint32_t)six->s6_addr[12]<<24)|((uint32_t)six->s6_addr[13]<<16)|((uint32_t)six->s6_addr[14]<<8)|(uint32_t)six->s6_addr[15];
   return PrivateIPv4(host);
  }
  return NO;
 }
 return NO;
}
- (void)markBusy:(nw_connection_t)connection busy:(BOOL)busy{
 NSValue *key=[NSValue valueWithPointer:(__bridge const void *)connection];
 if(busy)[self.busy addObject:key];else[self.busy removeObject:key];
}
- (BOOL)isBusy:(nw_connection_t)connection{return [self.busy containsObject:[NSValue valueWithPointer:(__bridge const void *)connection]];}
// 空闲连接 180 秒后收线，防止死连接占满 8 个槽位；但只要这一条连接上还有请求在跑
// （wait_for、sandbox_grep、导出、截图都可能超过 60 秒），就只续航而不收线——
// 收线会丢掉已经算完的结果，客户端只能看到连接中断。
- (void)armWatchdog:(nw_connection_t)connection{
 __weak typeof(self) weak=self;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(180*NSEC_PER_SEC)),self.queue,^{
  FLEXAiFlexMCPServer *server=weak;if(!server)return;
  if(![server.connections containsObject:connection])return;
  if([server isBusy:connection]){[server armWatchdog:connection];return;}
  [server close:connection];
 });
}
- (void)accept:(nw_connection_t)connection{
 if(![self privateConnection:connection]){
  // 静默 cancel 时客户端只看到"对端关闭"，分不清是地址问题还是服务没起来。
  // 这里先起来再回 403，把原因写进响应体。
  nw_connection_set_queue(connection,self.queue);
  __weak typeof(self) weak=self;
  nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error){
   if(state==nw_connection_state_failed||state==nw_connection_state_cancelled)[weak close:connection];
  });
  nw_connection_start(connection);
  [self respond:connection status:403 headers:@{} body:[@"仅接受本机或局域网地址：请使用 AiFlex3 面板上的实际局域网地址，不要经过公网转发或反向代理。" dataUsingEncoding:NSUTF8StringEncoding]];
  return;
 }
 if(self.connections.count>=8){nw_connection_cancel(connection);return;}
 [self.connections addObject:connection];
 __weak typeof(self) weak=self;
 nw_connection_set_queue(connection,self.queue);
 nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error){
  if(state==nw_connection_state_failed||state==nw_connection_state_cancelled)[weak close:connection];
 });
 nw_connection_start(connection);
 [self armWatchdog:connection];
 [self read:connection buffer:[NSMutableData data]];
}
- (void)read:(nw_connection_t)connection buffer:(NSMutableData *)buffer{
 __weak typeof(self) weak=self;
 nw_connection_receive(connection,1,65536,^(dispatch_data_t content,nw_content_context_t context,bool complete,nw_error_t error){
  FLEXAiFlexMCPServer *server=weak;if(!server)return;
  if(error){[server close:connection];return;}
  if(content)[buffer appendData:(NSData *)content];
  [server process:connection buffer:buffer];
 });
}
- (void)process:(nw_connection_t)connection buffer:(NSMutableData *)buffer{
 NSData *marker=[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
 NSRange range=[buffer rangeOfData:marker options:0 range:NSMakeRange(0,buffer.length)];
 if(range.location==NSNotFound){
  if(buffer.length>16384){[self respond:connection status:431 headers:@{} body:[@"请求头过大" dataUsingEncoding:NSUTF8StringEncoding]];return;}
  [self read:connection buffer:buffer];return;
 }
 NSData *head=[buffer subdataWithRange:NSMakeRange(0,range.location)];
 NSString *text=[[NSString alloc]initWithData:head encoding:NSUTF8StringEncoding];
 NSArray *lines=[text componentsSeparatedByString:@"\r\n"];
 NSArray *requestLine=lines.count?[lines[0] componentsSeparatedByString:@" "]:@[];
 if(requestLine.count<2){[self respond:connection status:400 headers:@{} body:[@"请求格式无效" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 NSMutableDictionary *headers=[NSMutableDictionary new];
 for(NSUInteger i=1;i<lines.count;i++){
  NSRange colon=[lines[i] rangeOfString:@":"];
  if(colon.location==NSNotFound)continue;
  NSString *key=[[lines[i] substringToIndex:colon.location] lowercaseString];
  NSString *value=[[lines[i] substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if(key.length)headers[key]=value;
 }
 NSUInteger length=[headers[@"content-length"] integerValue];
 if(length>2*1024*1024){[self respond:connection status:413 headers:@{} body:[@"请求体过大" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 NSUInteger start=NSMaxRange(range);
 if(buffer.length<start+length){[self read:connection buffer:buffer];return;}
 NSData *body=[buffer subdataWithRange:NSMakeRange(start,length)];
 NSString *peer=@"";
 nw_endpoint_t endpoint=nw_connection_copy_endpoint(connection);
 const struct sockaddr *address=nw_endpoint_get_address(endpoint);
 if(address&&address->sa_family==AF_INET){char text[INET_ADDRSTRLEN];inet_ntop(AF_INET,&((const struct sockaddr_in *)address)->sin_addr,text,sizeof(text));peer=[NSString stringWithUTF8String:text]?:@"";}
 [self handle:@{@"method":requestLine[0],@"path":requestLine[1],@"headers":headers,@"body":body,@"peer":peer} connection:connection];
}
- (void)handle:(NSDictionary *)request connection:(nw_connection_t)connection{
 NSString *method=request[@"method"];NSString *path=request[@"path"];
 // /mcp?trace=1 这类带查询串的地址是合法的：只按全等比较会直接 404，
 // 客户端拿到的现象是"工具列表拉不到"，看不出是路径判定太严。
 NSRange query=[path rangeOfString:@"?"];
 if(query.location!=NSNotFound)path=[path substringToIndex:query.location];
 if(![path isEqual:@"/mcp"]){[self respond:connection status:404 headers:@{} body:[@"Not Found" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 if([method isEqual:@"DELETE"]){[self respond:connection status:204 headers:@{} body:NSData.data];return;}
 if(![method isEqual:@"POST"]){[self respond:connection status:405 headers:@{} body:[@"Method Not Allowed" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 if([FLEXAiFlexMCPServer authRequired]){
  NSString *authorization=request[@"headers"][@"authorization"];
  NSString *token=[authorization.lowercaseString hasPrefix:@"bearer "]?[authorization substringFromIndex:7]:nil;
  if(!token.length||!Same(token,[FLEXAiFlexMCPServer token])){[self respond:connection status:401 headers:@{@"WWW-Authenticate":@"Bearer realm=\"AiFlex3 MCP\""} body:[@"Unauthorized" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 }
 id body=[NSJSONSerialization JSONObjectWithData:request[@"body"]?:NSData.data options:0 error:nil];
 if(![body isKindOfClass:NSDictionary.class]){[self respond:connection status:400 headers:@{} body:[@"JSON 解析失败" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 [self mcp:body connection:connection];
}
- (void)mcp:(NSDictionary *)body connection:(nw_connection_t)connection{
 id identifier=body[@"id"];NSString *method=body[@"method"];NSDictionary *params=[body[@"params"] isKindOfClass:NSDictionary.class]?body[@"params"]:@{};
 if(![method isKindOfClass:NSString.class]){[self respond:connection status:400 headers:@{} body:[@"JSON-RPC 请求无效" dataUsingEncoding:NSUTF8StringEncoding]];return;}
 if(!identifier){[self respond:connection status:202 headers:@{} body:NSData.data];return;}
 if([method isEqual:@"initialize"]){
  NSString *requested=params[@"protocolVersion"];
  NSString *version=[requested isKindOfClass:NSString.class]&&[@[@"2025-06-18",@"2025-03-26",@"2024-11-05"] containsObject:requested]?requested:DXMCPVersion;
  NSString *appVersion=[NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]?NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]:@"dev";
  NSDictionary *response=HTTPJSON(200,RPC(identifier,@{@"protocolVersion":version,@"capabilities":@{@"tools":@{@"listChanged":@NO}},@"serverInfo":@{@"name":@"AiFlex3",@"version":appVersion},@"instructions":Instructions()}),@{@"Mcp-Session-Id":NSUUID.UUID.UUIDString});
  [self sendResponse:response connection:connection];return;
 }
 if([method isEqual:@"ping"]){[self sendResponse:HTTPJSON(200,RPC(identifier,@{}),nil) connection:connection];return;}
 if([method isEqual:@"tools/list"]){[self sendResponse:HTTPJSON(200,RPC(identifier,@{@"tools":[self schemas]}),nil) connection:connection];return;}
 if([method isEqual:@"tools/call"]){
  NSString *name=params[@"name"];id arguments=params[@"arguments"]?:@{};
  if(![name isKindOfClass:NSString.class]||![arguments isKindOfClass:NSDictionary.class]){[self sendResponse:HTTPJSON(200,RPCError(identifier,-32602,@"tools/call 缺少 name 或 arguments"),nil) connection:connection];return;}
  [self markBusy:connection busy:YES];
  [self call:name arguments:arguments completion:^(NSDictionary *result){
   [self markBusy:connection busy:NO];
   [self sendResponse:HTTPJSON(200,RPC(identifier,result),nil) connection:connection];
  }];return;
 }
 [self sendResponse:HTTPJSON(200,RPCError(identifier,-32601,[@"未实现的方法：" stringByAppendingString:method]),nil) connection:connection];
}
- (void)sendResponse:(NSDictionary *)response connection:(nw_connection_t)connection{
 [self respond:connection status:[response[@"status"] integerValue] headers:response[@"headers"] body:response[@"body"]];
}
- (NSArray<NSDictionary *> *)schemas{
 NSMutableArray *list=[NSMutableArray new];
 for(NSDictionary *tool in Tools()){
  NSString *group=tool[@"group"];BOOL enabled=GroupEnabled(group);
  if(!enabled)continue;
  NSMutableDictionary *entry=[@{@"name":tool[@"name"],@"description":tool[@"description"],@"inputSchema":tool[@"schema"]} mutableCopy];
  if([group isEqual:@"read"])entry[@"annotations"]=@{@"readOnlyHint":@YES,@"destructiveHint":@NO};
  [list addObject:entry];
 }
 return list;
}
- (void)call:(NSString *)name arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion{
 NSDictionary *tool=ToolNamed(name);
 NSString *group=tool[@"group"];
 BOOL enabled=tool&&GroupEnabled(group);
 if(!enabled){completion(ToolError(@"工具不存在或已在 FLEX 设置中关闭"));return;}
 if([name isEqual:@"aiflex_status"]){
  NSString *bundle=NSBundle.mainBundle.bundleIdentifier?:@"";
  NSDictionary *status=@{@"bundleID":bundle,@"endpoint":[FLEXAiFlexMCPServer endpoint],@"state":[FLEXAiFlexMCPServer status],@"groups":@{@"read":@YES,@"sensitive":@([FLEXAiFlexMCPServer sensitiveEnabled]),@"control":@([FLEXAiFlexMCPServer controlEnabled]),@"script":@([FLEXAiFlexMCPServer scriptEnabled]),@"tracing":@([FLEXAiFlexMCPServer tracingEnabled])},@"server":@"AiFlex3 in-app",@"build":[NSString stringWithFormat:@"%@ (%@)",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"unknown",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"-"],@"selectedObject":([FLEXAiFlexRuntime sharedRuntime].selectedObject?NSStringFromClass([[FLEXAiFlexRuntime sharedRuntime].selectedObject class]):@"未选中")};
  completion(TextContent(status,NO));return;
 }
 NSDictionary *properties=tool[@"schema"][@"properties"];
 for(id key in arguments){
  if(![key isKindOfClass:NSString.class]){completion(ToolError(@"参数名无效"));return;}
  NSDictionary *property=properties[key];
  if(!property){completion(ToolError([@"未注册参数：" stringByAppendingString:key]));return;}
  if(!TypeMatches(property[@"type"],arguments[key])){completion(ToolError([@"参数类型有误：" stringByAppendingString:key]));return;}
  if(property[@"enum"]&&![property[@"enum"] containsObject:arguments[key]]){completion(ToolError([@"参数取值无效：" stringByAppendingString:key]));return;}
 }
 for(NSString *key in tool[@"schema"][@"required"])if(![arguments objectForKey:key]){completion(ToolError([@"缺少参数：" stringByAppendingString:key]));return;}
 NSString *operation=arguments[@"operation"];
 if(![operation isKindOfClass:NSString.class]||!operation.length){completion(ToolError(@"缺少 operation"));return;}
 NSMutableDictionary *wire=[arguments mutableCopy];[wire removeObjectForKey:@"operation"];
 if([name isEqual:@"aiflex_script"]){
  dispatch_async(dispatch_get_main_queue(),^{
   [[FLEXAiFlexRuntime sharedRuntime] runJavaScript:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 if([name isEqual:@"aiflex_trace"]){
  dispatch_async(dispatch_get_main_queue(),^{
   NSString *traceError=nil;NSDictionary *traceResult=nil;
   @try{traceResult=[[FLEXAiFlexRuntime sharedRuntime] traceOperation:operation arguments:wire error:&traceError];}
   @catch(NSException *exception){traceError=[NSString stringWithFormat:@"方法追踪异常（%@），请先 stop 再重试",exception.name];}
   dispatch_async(self.queue,^{completion(traceError.length?ToolError(traceError):FlexContent(traceResult));});
  });
  return;
 }
 if([operation isEqual:@"wait_for"]){
  dispatch_async(dispatch_get_main_queue(),^{
   [[FLEXAiFlexRuntime sharedRuntime] waitFor:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 if([operation isEqual:@"scroll_to_text"]){
  dispatch_async(dispatch_get_main_queue(),^{
   [[FLEXAiFlexRuntime sharedRuntime] scrollToText:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 if([operation isEqual:@"tap_text"]){
  dispatch_async(dispatch_get_main_queue(),^{
   [[FLEXAiFlexRuntime sharedRuntime] performTapText:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 if(WindowOperation(operation)){
  dispatch_async(dispatch_get_main_queue(),^{
   // 窗口操作只属于 AiFlex3 面板：面板自己持有 minimize/restore/open_tool/返回/关闭，
   // 以及 chat_status（面板可见性 + FLEX 覆盖层状态）。
   FLEXAiFlex3ViewController *panel=[FLEXAiFlex3ViewController aiFlex3CurrentPanel];
   if(!panel){
    if([operation isEqual:@"chat_status"]){
     NSDictionary *state=@{@"chatVisible":@NO,@"minimized":@NO,@"connected":@NO,@"taskRunning":@NO,@"stopped":@NO,@"sessionID":@"",@"flexVisible":@(!FLEXManager.sharedManager.isHidden),@"targetReady":@(FLEXManager.sharedManager.isHidden),@"statusVisible":@NO,@"activity":@"",@"uiTransitioning":@NO};
     dispatch_async(self.queue,^{completion(TextContent(state,NO));});
     return;
    }
    dispatch_async(self.queue,^{completion(ToolError(@"请先打开 AiFlex3 面板（FLEX 工具栏 AiFlex3 按钮）后再使用窗口控制"));});
    return;
   }
   [panel performWindowOperation:operation arguments:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];
  });
  return;
 }
 dispatch_async(dispatch_get_main_queue(),^{
  FLEXAiFlexRuntime *runtime=self.runtime;
  if(!runtime){runtime=[FLEXAiFlexRuntime sharedRuntime];self.runtime=runtime;}
  if([operation isEqual:@"gesture"]){
   [runtime performGesture:wire completion:^(NSDictionary *result,NSString *error){
    dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
   }];return;
  }
  NSString *error=nil;
  NSDictionary *result=nil;
  @try{result=[runtime execute:operation arguments:wire error:&error];}
  @catch(NSException *exception){error=[NSString stringWithFormat:@"FLEX 操作异常（%@）；请重新查询页面",exception.name];}
  dispatch_async(self.queue,^{completion(error.length?ToolError(error):FlexContent(result));});
 });
}
// 状态行里的原因短语原来只有 200/202/204/401 是真值，其余全部写成 "Error"，
// 抓包和日志里看不出是 403、404 还是 413。
static NSString *ReasonPhrase(NSInteger status){
 switch(status){
  case 200:return @"OK";
  case 202:return @"Accepted";
  case 204:return @"No Content";
  case 400:return @"Bad Request";
  case 401:return @"Unauthorized";
  case 403:return @"Forbidden";
  case 404:return @"Not Found";
  case 405:return @"Method Not Allowed";
  case 413:return @"Content Too Large";
  case 431:return @"Request Header Fields Too Large";
  default:return status>=500?@"Server Error":@"Error";
 }
}
- (void)respond:(nw_connection_t)connection status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body{
 NSMutableString *head=[NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n",(long)status,ReasonPhrase(status),(unsigned long)body.length];
 for(NSString *key in headers)[head appendFormat:@"%@: %@\r\n",key,headers[key]];
 [head appendString:@"\r\n"];
 NSMutableData *message=[head dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
 [message appendData:body];
 // The destructor block keeps the backing NSData alive until dispatch_data is
 // released; DISPATCH_DATA_DESTRUCTOR_DEFAULT would not retain the buffer.
 NSData *payload=[message copy];
 dispatch_data_t data=dispatch_data_create(payload.bytes,payload.length,self.queue,^{ (void)payload; });
 __weak typeof(self) weak=self;
 nw_connection_send(connection,data,NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,true,^(nw_error_t error){[weak close:connection];});
}
- (void)close:(nw_connection_t)connection{
 [self markBusy:connection busy:NO];
 [self.connections removeObject:connection];nw_connection_cancel(connection);
}
@end
__attribute__((constructor)) static void FLEXAiFlexMCPBoot(void){
 if(![FLEXAiFlexMCPServer isEnabled])return;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[[FLEXAiFlexMCPServer shared] start];});
 // 回到前台时监听常常已经被系统回收（socket 被挂起时断开），但 running 未必变 NO。
 // 所以这里不看 running，直接强制重建一次，避免"面板显示运行中却连不上"。
 [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                 object:nil
                                                  queue:NSOperationQueue.mainQueue
                                             usingBlock:^(__unused NSNotification *note){
  FLEXAiFlexMCPServer *server=[FLEXAiFlexMCPServer shared];
  server.inBackground=NO;
  [server endBackgroundLease];
  if(![FLEXAiFlexMCPServer isEnabled])return;
  [server restart];
 }];
 // 进后台借一小段执行时间给在途请求收尾；借不到就交给系统挂起，回前台再重建。
 [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                 object:nil
                                                  queue:NSOperationQueue.mainQueue
                                             usingBlock:^(__unused NSNotification *note){
  FLEXAiFlexMCPServer *server=[FLEXAiFlexMCPServer shared];
  server.inBackground=YES;
  [server beginBackgroundLease];
 }];
 [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                 object:nil
                                                  queue:NSOperationQueue.mainQueue
                                             usingBlock:^(__unused NSNotification *note){
  FLEXAiFlexMCPServer *server=[FLEXAiFlexMCPServer shared];
  if(![FLEXAiFlexMCPServer isEnabled]||server.running)return;
  [server restart];
 }];
}
