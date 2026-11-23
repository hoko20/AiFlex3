#import "FLEXAiFlexRuntime.h"
#import "FLEXNetworkRecorder.h"
#import "FLEXNetworkObserver.h"
#import "FLEXNetworkTransaction.h"
#import "FLEXKeychain.h"
#import "FLEXUtility.h"
#import "FLEXManager+Private.h"
#import "FLEXGlobalsEntry.h"
#import "FLEXGlobalsViewController.h"
#import "FLEXAiFlexTouchDriver.h"
#import "x/ClassDump/UCClassSearchViewController.h"
#import "x/ClassDump/UCClassDumpTool.h"
#import <objc/runtime.h>
#import <math.h>
#include <string.h>
#import <mach/mach.h>

// Declared locally so the dylib does not hard-link WebKit; the class is looked
// up at runtime and the call is only made when a WKWebView is present.
@interface NSObject (AiFlexJavaScript)
- (void)evaluateJavaScript:(NSString *)javaScriptString completionHandler:(void (^)(id result, NSError *error))completionHandler;
@end

@interface FLEXGlobalsViewController (DXAgentEntries)
+ (FLEXGlobalsEntry *)globalsEntryForRow:(FLEXGlobalsRow)row;
@end

static NSString *DXShort(NSString *text, NSUInteger limit) {
 if (![text isKindOfClass:NSString.class]) return @"";
 return text.length>limit?[text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,limit)]]:text;
}
static NSString *DXClass(id object) { return object?NSStringFromClass([object class]):@"无"; }
static NSString *DXClassImage(Class cls) {const char *path=cls?class_getImageName(cls):NULL;return path?DXShort([NSString stringWithUTF8String:path],512):@"";}
static NSDictionary *DXBody(NSData *body) {
 if (!body.length) return @{@"available":@NO};
 NSUInteger length=MIN(body.length,16384);NSString *text=[[NSString alloc]initWithData:[body subdataWithRange:NSMakeRange(0,length)] encoding:NSUTF8StringEncoding];
 return text?@{@"available":@YES,@"text":text,@"totalBytes":@(body.length),@"truncated":@(body.length>length)}:@{@"available":@YES,@"binary":@YES,@"totalBytes":@(body.length)};
}

@interface FLEXAiFlexRuntime ()
@property NSMapTable<NSString *, id> *views;
@property NSMapTable<UIView *, NSString *> *viewIDs;
@property NSMapTable<NSString *, id> *objects;
@property NSMapTable<id, NSString *> *objectIDs;
@property NSMutableArray<NSDictionary *> *snapshots;
@property NSMutableArray<NSDictionary *> *traceRecords;
@property NSMutableDictionary<NSString *, NSDictionary *> *traceHooks;
@property NSUInteger traceDropped;
@property NSUInteger traceGeneration;
@property NSDictionary *undoState;
@property NSTimeInterval lastCaptureAt;
@property FLEXAiFlexTouchDriver *touchDriver;
@property NSUInteger inputGeneration;
@end

@implementation FLEXAiFlexRuntime
+ (instancetype)sharedRuntime{
 static FLEXAiFlexRuntime *runtime;static dispatch_once_t once;
 dispatch_once(&once,^{runtime=[FLEXAiFlexRuntime new];});
 return runtime;
}
- (BOOL)agentCanOpenRow:(NSUInteger)row {
 // Keep credential viewers and arbitrary-address/method entry points manual.
 return row<FLEXGlobalsRowCount && ![@[@(FLEXGlobalsRowAddressInspector),@(FLEXGlobalsRowAppKeychainItems),@(FLEXGlobalsRowCookies),@(FLEXGlobalsRowUserDefaults),@(FLEXGlobalsRowPasteboard),@(FLEXGlobalsRowPushNotifications)] containsObject:@(row)];
}
- (NSArray<NSDictionary *> *)toolCatalog {
 NSMutableArray *items=[NSMutableArray new];
 for(NSUInteger row=0;row<FLEXGlobalsRowCount;row++){
  FLEXGlobalsEntry *entry=[FLEXGlobalsViewController globalsEntryForRow:row];
  [items addObject:@{@"id":[NSString stringWithFormat:@"global.%lu",(unsigned long)row],@"name":entry.entryNameFuture?entry.entryNameFuture():@"",@"agentOpenSupported":@([self agentCanOpenRow:row]&&entry.viewControllerFuture!=nil&&!entry.rowAction),@"source":@"FLEX globals"}];
 }
 NSUInteger index=0;for(FLEXGlobalsEntry *entry in FLEXManager.sharedManager.userGlobalEntries){
  [items addObject:@{@"id":[NSString stringWithFormat:@"custom.%lu",(unsigned long)index++],@"name":entry.entryNameFuture?entry.entryNameFuture():@"",@"agentOpenSupported":@NO,@"source":@"custom manual entry"}];
 }
 for(NSDictionary *item in @[
  @{@"id":@"extension.headers",@"name":@"xx.h · 类头文件",@"agentOpenSupported":@(NSClassFromString(@"UCClassSearchViewController")!=nil),@"source":@"FLEX++ native extension"},
  @{@"id":@"extension.disassembly",@"name":@"反汇编 · 类/方法列表",@"agentOpenSupported":@(NSClassFromString(@"UCClassSearchViewController")!=nil),@"source":@"FLEX++ native extension"},
  @{@"id":@"extension.filza",@"name":@"Filza",@"agentOpenSupported":@NO,@"reason":@"文件写入与系统目录操作继续走既有人工流程",@"source":@"FLEX++ native extension"},
  @{@"id":@"extension.capture",@"name":@"抓取",@"agentOpenSupported":@NO,@"reason":@"二进制复制/注入继续走既有人工流程",@"source":@"FLEX++ native extension"},
  @{@"id":@"extension.protection",@"name":@"保护",@"agentOpenSupported":@NO,@"reason":@"开启入口会立即改变宿主状态；不作为只读导航入口",@"source":@"FLEX++ native extension"}])[items addObject:item];
 return items;
}
- (UIViewController *)controllerForTool:(NSString *)identifier error:(NSString **)error {
 if([identifier isEqual:@"extension.headers"]||[identifier isEqual:@"extension.disassembly"])
  return [UCClassSearchViewController searchViewControllerWithMode:[identifier isEqual:@"extension.headers"]?UCClassSearchModeClassDump:UCClassSearchModeDisassembler];
 for(NSUInteger row=0;row<FLEXGlobalsRowCount;row++)if([identifier isEqual:[NSString stringWithFormat:@"global.%lu",(unsigned long)row]]){
  if(![self agentCanOpenRow:row])break;
  FLEXGlobalsEntry *entry=[FLEXGlobalsViewController globalsEntryForRow:row];
  if(entry.viewControllerFuture&&!entry.rowAction){UIViewController *controller=entry.viewControllerFuture();if(controller)return controller;}
  break;
 }
 if(error)*error=@"此入口未开放给 AI，或当前设备无法打开；请读取 tool_catalog，勿猜测入口 ID";return nil;
}
- (UIViewController *)flexVisibleController {
 UIWindow *window=FLEXManager.sharedManager.explorerWindow;
 if(window.hidden)return nil;
 UIViewController *controller=[self visibleControllerInWindow:window path:[NSMutableArray new]];
 if([DXClass(controller) containsString:@"AiFlex3ViewController"])return nil;
 return controller;
}
- (BOOL)allowsRowSelection:(UIViewController *)controller {
 // Object inspector rows can invoke methods; never automate those rows.
 return [@[@"FLEXObjcRuntimeViewController",@"FLEXLiveObjectsController",@"FLEXObjectListViewController",@"UCClassSearchViewController",@"UCMethodListViewController"] containsObject:DXClass(controller)];
}
- (UITableView *)tableInController:(UIViewController *)controller {
 if(!controller)return nil;
 if([controller isKindOfClass:UITableViewController.class])return ((UITableViewController *)controller).tableView;
 NSMutableArray *views=[NSMutableArray arrayWithObject:controller.view];NSUInteger scanned=0;
 while(views.count&&scanned++<1500){UIView *view=views.firstObject;[views removeObjectAtIndex:0];if([view isKindOfClass:UITableView.class]&&!view.hidden)return (UITableView *)view;[views addObjectsFromArray:view.subviews];}return nil;
}
- (void)cancelPendingInput {self.inputGeneration++;[self.touchDriver cancel];}
- (void)performGesture:(NSDictionary *)arguments completion:(void (^)(NSDictionary *,NSString *))completion {
 if(!self.touchDriver)self.touchDriver=[FLEXAiFlexTouchDriver new];
 if(self.touchDriver.running){completion(nil,@"另一个触摸序列仍在进行");return;}
 if(!FLEXManager.sharedManager.isHidden){completion(nil,@"FLEX 覆盖层仍可见。请先 minimize_chat(surface=target)，查询 chat_status.targetReady=true 后再操作，避免手势落在 FLEX 覆盖层");return;}
 NSString *kind=arguments[@"kind"];NSArray *kinds=@[@"tap",@"double_tap",@"long_press",@"swipe",@"drag",@"pinch",@"rotate"];
 id x=arguments[@"x"],y=arguments[@"y"];
 if(![kinds containsObject:kind]||![x isKindOfClass:NSNumber.class]||![y isKindOfClass:NSNumber.class]){completion(nil,@"手势类型和窗口坐标无效");return;}
 for(NSString *key in @[@"x",@"y",@"end_x",@"end_y",@"duration",@"start_radius",@"end_radius",@"radius",@"angle"]){id value=arguments[key];if(value&&(![value isKindOfClass:NSNumber.class]||!isfinite([value doubleValue]))){completion(nil,@"手势数值必须是有限数字");return;}}
 CGPoint start=CGPointMake([x doubleValue],[y doubleValue]);NSTimeInterval duration=[arguments[@"duration"] doubleValue];
 if(!arguments[@"duration"])duration=[kind isEqual:@"long_press"]?.8:[kind isEqual:@"drag"]?.9:[kind isEqual:@"tap"]||[kind isEqual:@"double_tap"]?.08:.5;
 if([kind isEqual:@"long_press"]&&duration<.4){completion(nil,@"长按至少持续 0.4 秒");return;}
 NSMutableArray *paths=[NSMutableArray new];
 if([kind isEqual:@"pinch"]||[kind isEqual:@"rotate"]){
  CGFloat r=arguments[@"radius"]?[arguments[@"radius"] doubleValue]:50,from=arguments[@"start_radius"]?[arguments[@"start_radius"] doubleValue]:35,to=arguments[@"end_radius"]?[arguments[@"end_radius"] doubleValue]:75,angle=arguments[@"angle"]?[arguments[@"angle"] doubleValue]:90;
  if(r<=0||r>300||from<=0||from>300||to<=0||to>300||fabs(angle)>360){completion(nil,@"双指半径或角度无效");return;}
  for(NSUInteger finger=0;finger<2;finger++){NSMutableArray *path=[NSMutableArray new];for(NSUInteger i=0;i<=30;i++){CGFloat t=i/30.0;CGFloat a=finger*M_PI+([kind isEqual:@"rotate"]?angle*M_PI/180*t:0),radius=[kind isEqual:@"pinch"]?from+(to-from)*t:r;[path addObject:[NSValue valueWithCGPoint:CGPointMake(start.x+cos(a)*radius,start.y+sin(a)*radius)]];}[paths addObject:path];}
 }else{
  CGPoint end=start;if([kind isEqual:@"swipe"]||[kind isEqual:@"drag"]){if(![arguments[@"end_x"] isKindOfClass:NSNumber.class]||![arguments[@"end_y"] isKindOfClass:NSNumber.class]){completion(nil,@"滑动/拖动需要 end_x、end_y");return;}end=CGPointMake([arguments[@"end_x"] doubleValue],[arguments[@"end_y"] doubleValue]);}
  NSMutableArray *path=[NSMutableArray arrayWithObject:[NSValue valueWithCGPoint:start]];
  if([kind isEqual:@"drag"])[path addObject:[NSValue valueWithCGPoint:start]];
  [path addObject:[NSValue valueWithCGPoint:end]];[paths addObject:path];
 }
 NSUInteger generation=++self.inputGeneration;UIWindow *window=[self window];
 [self.touchDriver performPaths:paths window:window duration:duration completion:^(NSDictionary *result,NSString *error){
  if(error||![kind isEqual:@"double_tap"]){completion(result,error);return;}
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
   if(generation!=self.inputGeneration){completion(nil,@"触摸序列已取消");return;}
   [self.touchDriver performPaths:paths window:window duration:duration completion:completion];
  });
 }];
}
- (instancetype)init { if ((self=[super init])) { _views=[NSMapTable strongToWeakObjectsMapTable]; _viewIDs=[NSMapTable weakToStrongObjectsMapTable]; _objects=[NSMapTable strongToWeakObjectsMapTable]; _objectIDs=[NSMapTable weakToStrongObjectsMapTable]; _snapshots=[NSMutableArray new]; _traceRecords=[NSMutableArray new]; _traceHooks=[NSMutableDictionary new]; } return self; }
- (BOOL)isTargetWindow:(UIWindow *)window {
 if(!window||window.hidden||window.alpha<.01||window==FLEXManager.sharedManager.explorerWindow)return NO;
 for(NSString *name in @[@"FLEXWindow",@"FLEXDoKitFloatingWindow"]){Class cls=NSClassFromString(name);if(cls&&[window isKindOfClass:cls])return NO;}
 return YES;
}
- (UIWindow *)window {
 UIView *selected=[self.selectedObject isKindOfClass:UIView.class]?self.selectedObject:nil;
 UIWindow *selectedWindow=[selected isKindOfClass:UIWindow.class]?(UIWindow *)selected:selected.window;
 if([self isTargetWindow:selectedWindow])return selectedWindow;
 UIWindow *appWindow=FLEXUtility.appKeyWindow;if([self isTargetWindow:appWindow])return appWindow;
 for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.isKeyWindow&&[self isTargetWindow:window]) return window;
 for (UIWindow *window in UIApplication.sharedApplication.windows) if([self isTargetWindow:window])return window;
 return nil;
}
- (NSString *)registerView:(UIView *)view {
 NSString *identifier=[self.viewIDs objectForKey:view];
 if(!identifier){identifier=NSUUID.UUID.UUIDString;[self.viewIDs setObject:identifier forKey:view];}
 [self.views setObject:view forKey:identifier];return identifier;
}
- (NSString *)registerObject:(id)object {
 if(!object)return nil;
 NSString *identifier=[self.objectIDs objectForKey:object];
 if(!identifier){identifier=[@"obj-" stringByAppendingString:NSUUID.UUID.UUIDString];[self.objectIDs setObject:identifier forKey:object];}
 [self.objects setObject:object forKey:identifier];return identifier;
}
- (id)objectForIdentifier:(NSString *)identifier {
 if(![identifier isKindOfClass:NSString.class])return nil;
 id object=[self.views objectForKey:identifier];
 if(!object)object=[self.objects objectForKey:identifier];
 return object;
}
- (BOOL)isAttached:(UIView *)view {UIWindow *window=[self window];return window&&(view==window||view.window==window);}
- (BOOL)isVisibleInput:(UIView *)view {
 if(!view||![self isAttached:view]||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return NO;
 for(UIView *parent=view;parent;parent=parent.superview)if(parent.hidden||parent.alpha<.01||!parent.userInteractionEnabled)return NO;
 UIWindow *window=[self window];CGRect frame=[view convertRect:view.bounds toView:window];
 return !CGRectIsEmpty(frame)&&CGRectIntersectsRect(frame,window.bounds);
}
- (void)screenElementsInView:(UIView *)view window:(UIWindow *)window items:(NSMutableArray *)items scanned:(NSUInteger *)scanned {
 if (!view || *scanned>=1500 || view.hidden || view.alpha<0.01) return;
 (*scanned)++;
 CGRect frame=[view convertRect:view.bounds toView:window];
 if (view!=window && (CGRectIsEmpty(frame) || !CGRectIntersectsRect(frame,window.bounds))) return;
 NSString *label=view.accessibilityLabel;
 if([view isKindOfClass:UILabel.class])label=((UILabel *)view).text?:label;
 if([view isKindOfClass:UIButton.class])label=((UIButton *)view).currentTitle?:label;
 if([view isKindOfClass:UITextField.class])label=((UITextField *)view).placeholder?:label;
 BOOL interactive=[view isKindOfClass:UIControl.class] || [view isKindOfClass:UIScrollView.class] || (view.accessibilityTraits&UIAccessibilityTraitButton)!=0;
 if(!interactive)for(UIGestureRecognizer *gesture in view.gestureRecognizers)if([gesture isKindOfClass:UITapGestureRecognizer.class]){interactive=YES;break;}
 if((label.length || interactive)&&items.count<1200){
  NSMutableDictionary *row=[@{@"id":[self registerView:view],@"class":DXClass(view),@"frame":NSStringFromCGRect(frame),@"interactive":@(interactive)} mutableCopy];
  if(label.length)row[@"label"]=DXShort(label,120);
  if(view.superview)row[@"parentID"]=[self registerView:view.superview];
  [items addObject:row];
 }
 for(UIView *child in view.subviews){if(*scanned>=1500)break;[self screenElementsInView:child window:window items:items scanned:scanned];}
}
- (NSDictionary *)captureWindow:(UIWindow *)window rect:(NSString *)rectText error:(NSString **)error {
 if(!window || window.hidden || CGRectIsEmpty(window.bounds)){if(error)*error=@"目标 App 当前没有可截图的窗口";return nil;}
 CGRect crop=CGRectNull;
 if([rectText isKindOfClass:NSString.class]&&rectText.length){
  NSArray *parts=[rectText componentsSeparatedByString:@","];
  if(parts.count!=4){if(error)*error=@"rect 格式应为 \"x,y,w,h\"（窗口坐标，单位 point）";return nil;}
  crop=CGRectMake([parts[0] doubleValue],[parts[1] doubleValue],[parts[2] doubleValue],[parts[3] doubleValue]);
  crop=CGRectIntersection(window.bounds,crop);
  if(CGRectIsNull(crop)||CGRectIsEmpty(crop)||!isfinite(crop.size.width)||!isfinite(crop.size.height)){if(error)*error=@"rect 必须位于当前窗口内且宽高大于 0";return nil;}
 }
 NSTimeInterval now=NSDate.date.timeIntervalSince1970;
 if(now-self.lastCaptureAt<2){if(error)*error=@"截图过于频繁，请稍后重试";return nil;}
 self.lastCaptureAt=now;
 CGFloat scale=MIN(2.0,960.0/MAX(window.bounds.size.width,window.bounds.size.height));
 for(NSUInteger attempt=0;attempt<3;attempt++){
  CGSize size=CGSizeMake(MAX(1,round(window.bounds.size.width*scale)),MAX(1,round(window.bounds.size.height*scale)));
  UIGraphicsBeginImageContextWithOptions(size,YES,1);
  CGContextRef context=UIGraphicsGetCurrentContext();
  if(!context){UIGraphicsEndImageContext();if(error)*error=@"无法分配截图绘图上下文";return nil;}
  CGContextScaleCTM(context,scale,scale);
  BOOL drawn=[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
  UIImage *image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
  if(!drawn || !image){if(error)*error=@"目标窗口截图失败，可能是受保护或不可渲染内容";return nil;}
  if(!CGRectIsNull(crop)){
   if(!image.CGImage){if(error)*error=@"截图裁剪失败：没有可用的位图";return nil;}
   CGRect pixelRect=CGRectMake(round(CGRectGetMinX(crop)*scale),round(CGRectGetMinY(crop)*scale),round(CGRectGetWidth(crop)*scale),round(CGRectGetHeight(crop)*scale));
   CGImageRef cropped=CGImageCreateWithImageInRect(image.CGImage,pixelRect);
   if(!cropped){if(error)*error=@"截图裁剪失败";return nil;}
   image=[UIImage imageWithCGImage:cropped scale:1 orientation:image.imageOrientation];CGImageRelease(cropped);
  }
  NSInteger width=image.CGImage?CGImageGetWidth(image.CGImage):(NSInteger)size.width;
  NSInteger height=image.CGImage?CGImageGetHeight(image.CGImage):(NSInteger)size.height;
  for(CGFloat quality=0.72;quality>=0.35;quality-=0.12){
   NSData *jpeg=UIImageJPEGRepresentation(image,quality);
   if(jpeg.length>0&&jpeg.length<=120*1024)return @{@"imageBase64":[jpeg base64EncodedStringWithOptions:0],@"mime":@"image/jpeg",@"pixelWidth":@(width),@"pixelHeight":@(height),@"windowBounds":NSStringFromCGRect(window.bounds),@"capturedAt":@(NSDate.date.timeIntervalSince1970),@"bytes":@(jpeg.length),@"scope":@"target_app_window",@"cropped":@(!CGRectIsNull(crop))};
  }
  scale*=0.72;
 }
 if(error)*error=@"截图超过传输上限，请缩小目标窗口内容";return nil;
}
- (NSArray *)controlActions:(UIControl *)control {
 NSMutableArray *actions=[NSMutableArray new];
 NSArray *events=@[@{@"name":@"touchUpInside",@"value":@(UIControlEventTouchUpInside)},@{@"name":@"touchDown",@"value":@(UIControlEventTouchDown)},@{@"name":@"valueChanged",@"value":@(UIControlEventValueChanged)}];
 for(id target in control.allTargets)for(NSDictionary *event in events){
  for(NSString *action in [control actionsForTarget:target forControlEvent:[event[@"value"] unsignedIntegerValue]]){
   if(actions.count>=20)return actions;
   [actions addObject:@{@"event":event[@"name"],@"targetClass":DXClass(target),@"targetImage":DXClassImage([target class]),@"selector":action}];
  }
 }
 return actions;
}
- (NSArray *)siblingsForView:(UIView *)view {
 NSMutableArray *rows=[NSMutableArray new];
 for(UIView *sibling in view.superview.subviews){if(rows.count>=16)break;
  NSMutableDictionary *row=[@{@"selected":@(sibling==view),@"class":DXClass(sibling),@"frame":NSStringFromCGRect(sibling.frame)} mutableCopy];
  NSString *label=[sibling isKindOfClass:UILabel.class]?((UILabel *)sibling).text:sibling.accessibilityLabel;
  if([sibling isKindOfClass:UIButton.class])label=((UIButton *)sibling).currentTitle?:label;
  label=DXShort(label,100);if(label.length)row[@"label"]=label;
  [rows addObject:row];
 }
 return rows;
}
- (NSArray *)ancestorsForView:(UIView *)view {
 NSMutableArray *rows=[NSMutableArray new];
 for(UIView *ancestor=view;ancestor&&rows.count<16;ancestor=ancestor.superview){
  NSMutableDictionary *row=[@{@"id":[self registerView:ancestor],@"class":DXClass(ancestor),@"frame":NSStringFromCGRect(ancestor.frame)} mutableCopy];
  NSString *image=DXClassImage([ancestor class]);if(image.length)row[@"classImage"]=image;
  NSString *label=DXShort(ancestor.accessibilityLabel,120);if(label.length)row[@"label"]=label;
  NSString *accessibilityID=DXShort(ancestor.accessibilityIdentifier,120);if(accessibilityID.length)row[@"accessibilityID"]=accessibilityID;
  if([ancestor isKindOfClass:UIButton.class]){NSString *title=DXShort(((UIButton *)ancestor).currentTitle,120);if(title.length)row[@"title"]=title;}
  if([ancestor isKindOfClass:UIControl.class]){NSArray *actions=[self controlActions:(UIControl *)ancestor];if(actions.count)row[@"controlActions"]=actions;}
  [rows addObject:row];
 }
 return rows;
}
- (NSDictionary *)interactiveAncestorForView:(UIView *)view {
 for(UIView *ancestor=view;ancestor;ancestor=ancestor.superview){
  BOOL control=[ancestor isKindOfClass:UIControl.class],tap=NO,buttonTrait=(ancestor.accessibilityTraits&UIAccessibilityTraitButton)!=0;
  for(UIGestureRecognizer *gesture in ancestor.gestureRecognizers)if([gesture isKindOfClass:UITapGestureRecognizer.class]){tap=YES;break;}
  if(control||tap||buttonTrait){NSMutableDictionary *info=[[self objectInfo:ancestor] mutableCopy];info[@"interaction"]=control?@"control":tap?@"tapGesture":@"accessibilityButton";info[@"ownerController"]=[self controllerForView:ancestor];return info;}
 }
 return @{@"available":@NO};
}
- (UIViewController *)visibleControllerInWindow:(UIWindow *)window path:(NSMutableArray *)path {
 UIViewController *controller=window.rootViewController;
 for(NSUInteger i=0;controller&&i<20;i++){
  [path addObject:DXClass(controller)];UIViewController *next=controller.presentedViewController;
  if(!next&&[controller isKindOfClass:UINavigationController.class])next=((UINavigationController *)controller).visibleViewController;
  if(!next&&[controller isKindOfClass:UITabBarController.class])next=((UITabBarController *)controller).selectedViewController;
  if(!next&&[controller isKindOfClass:UISplitViewController.class])next=((UISplitViewController *)controller).viewControllers.lastObject;
  if(!next)for(UIViewController *child in controller.childViewControllers.reverseObjectEnumerator)if(child.isViewLoaded&&child.view.window==window&&!child.view.hidden){next=child;break;}
  if(!next||next==controller)break;controller=next;
 }
 return controller;
}
- (NSString *)controllerForView:(UIView *)view {
 for(UIResponder *responder=view;responder;responder=responder.nextResponder)if([responder isKindOfClass:UIViewController.class])return DXClass(responder);
 return @"";
}
- (void)collectScreenTexts:(UIView *)view window:(UIWindow *)window items:(NSMutableArray *)items scanned:(NSUInteger *)scanned {
 if(!view||*scanned>=1200||items.count>=60||view.hidden||view.alpha<0.01)return;
 (*scanned)++;
 if(view!=window){CGRect frame=[view convertRect:view.bounds toView:window];if(CGRectIsEmpty(frame)||!CGRectIntersectsRect(frame,window.bounds))return;}
 NSString *value=nil;
 if([view isKindOfClass:UILabel.class])value=((UILabel *)view).text;
 else if([view isKindOfClass:UIButton.class])value=((UIButton *)view).currentTitle;
 else if([view isKindOfClass:UITextField.class])value=((UITextField *)view).placeholder;
 else if([view isKindOfClass:UITextView.class])value=((UITextView *)view).text;
 if(!value.length)value=view.accessibilityLabel;
 value=DXShort([value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],120);
 if(value.length&&![items containsObject:value])[items addObject:value];
 for(UIView *child in view.subviews){if(*scanned>=1200||items.count>=60)break;[self collectScreenTexts:child window:window items:items scanned:scanned];}
}
- (NSDictionary *)viewRow:(UIView *)view depth:(NSUInteger)depth count:(NSUInteger *)count maxDepth:(NSUInteger)maxDepth {
 NSString *identifier=[self registerView:view]; (*count)++;
 NSMutableDictionary *row=[@{@"id":identifier,@"class":DXClass(view),@"depth":@(depth),@"interactive":@([self isInteractiveView:view]),@"frame":NSStringFromCGRect(view.frame),@"frameInWindow":NSStringFromCGRect([view convertRect:view.bounds toView:[self window]]),@"hidden":@(view.hidden),@"alpha":@(view.alpha)} mutableCopy];
 if ([view isKindOfClass:UILabel.class]) row[@"text"]=DXShort(((UILabel *)view).text,160);
 if ([view isKindOfClass:UIButton.class]) row[@"title"]=DXShort([((UIButton *)view) titleForState:UIControlStateNormal],120);
 if ([view isKindOfClass:UITextField.class]) row[@"placeholder"]=DXShort(((UITextField *)view).placeholder,120);
 if (depth<maxDepth && *count<120) {
  NSMutableArray *children=[NSMutableArray new]; for (UIView *child in view.subviews) { if (*count>=120) break; [children addObject:[self viewRow:child depth:depth+1 count:count maxDepth:maxDepth]]; }
  row[@"children"]=children;
 }
 return row;
}
// Runtime metadata only: declarations and responder relationships are evidence,
// never a claim that a lifecycle callback has actually executed.
- (NSArray *)lifecycleCandidates:(Class)cls controller:(BOOL)controller {
 NSSet *wanted=[NSSet setWithArray:controller?@[@"loadView",@"viewDidLoad",@"viewWillAppear:",@"viewDidAppear:",@"viewWillLayoutSubviews",@"viewDidLayoutSubviews"]:@[@"initWithFrame:",@"initWithCoder:",@"awakeFromNib",@"didMoveToSuperview",@"didMoveToWindow",@"layoutSubviews",@"prepareForReuse",@"setHidden:"]];
 NSMutableArray *rows=[NSMutableArray new];NSUInteger depth=0;
 for(Class item=cls;item&&depth<12;item=class_getSuperclass(item),depth++){
  unsigned int count=0;Method *methods=class_copyMethodList(item,&count);
  for(unsigned int i=0;i<count;i++){NSString *selector=NSStringFromSelector(method_getName(methods[i]));if(![wanted containsObject:selector])continue;
   [rows addObject:@{@"selector":selector,@"declaredIn":NSStringFromClass(item),@"image":DXClassImage(item),@"encoding":DXShort([NSString stringWithUTF8String:method_getTypeEncoding(methods[i])?:""],160),@"inherited":@(item!=cls),@"executionObserved":@NO}];
  }free(methods);
 }return rows;
}
- (NSDictionary *)hookEvidenceForView:(UIView *)view {
 UIViewController *controller=nil;NSUInteger depth=0;
 for(UIResponder *r=view;r&&depth<64;r=r.nextResponder,depth++)if([r isKindOfClass:UIViewController.class]){controller=(id)r;break;}
 NSArray *ancestors=[self ancestorsForView:view];NSMutableArray *classes=[NSMutableArray new];for(NSDictionary *entry in ancestors)[classes addObject:entry[@"class"]];
 NSMutableDictionary *signature=[@{@"class":DXClass(view),@"ancestorClasses":classes,@"controllerClass":controller?DXClass(controller):@""} mutableCopy];
 if(view.accessibilityIdentifier.length)signature[@"accessibilityID"]=DXShort(view.accessibilityIdentifier,120);
 if([view isKindOfClass:UIButton.class]&&((UIButton *)view).currentTitle.length)signature[@"title"]=DXShort(((UIButton *)view).currentTitle,120);
 NSDictionary *owner=controller?@{@"class":DXClass(controller),@"image":DXClassImage([controller class]),@"relationship":@"nearest_responder_controller",@"lifecycleCandidates":[self lifecycleCandidates:[controller class] controller:YES]}:@{@"available":@NO};
 return @{@"observedAt":@(NSDate.date.timeIntervalSince1970),@"instanceID":[self registerView:view],@"signature":signature,@"ancestors":ancestors,@"controller":owner,@"viewLifecycleCandidates":[self lifecycleCandidates:[view class] controller:NO],@"lifecycleExecutionObserved":@NO,@"stabilityVerified":@NO,@"limitations":@"Responder controller is containment evidence, not proof of the allocating owner. Lifecycle entries are method declarations, not invocation traces. Re-query after navigation/reuse and compare signatures before choosing a scoped Hook; an instance ID/address is not a persistent selector."};
}
- (NSDictionary *)objectInfo:(id)object {
 if (!object) return @{@"available":@NO};
 Class cls=[object class]; NSMutableArray *chain=[NSMutableArray new];
 for (Class item=cls;item&&chain.count<12;item=class_getSuperclass(item)) [chain addObject:NSStringFromClass(item)];
 NSMutableDictionary *result=[@{@"available":@YES,@"class":NSStringFromClass(cls),@"superclasses":chain,@"address":[NSString stringWithFormat:@"%p",object]} mutableCopy];
 NSString *image=DXClassImage(cls);if(image.length)result[@"classImage"]=image;
 if ([object isKindOfClass:UIView.class]) { UIView *view=object; result[@"id"]=[self registerView:view];result[@"attached"]=@([self isAttached:view]);result[@"frame"]=NSStringFromCGRect(view.frame); result[@"hidden"]=@(view.hidden); result[@"alpha"]=@(view.alpha); result[@"subviewCount"]=@(view.subviews.count);result[@"hookEvidence"]=[self hookEvidenceForView:view];NSString *label=DXShort(view.accessibilityLabel,120);if(label.length)result[@"label"]=label;NSString *accessibilityID=DXShort(view.accessibilityIdentifier,120);if(accessibilityID.length)result[@"accessibilityID"]=accessibilityID;if([view isKindOfClass:UIButton.class]){NSString *title=DXShort(((UIButton *)view).currentTitle,120);if(title.length)result[@"title"]=title;}if([view isKindOfClass:UIControl.class])result[@"controlActions"]=[self controlActions:(UIControl *)view];NSMutableArray *gestures=[NSMutableArray new];for(UIGestureRecognizer *gesture in view.gestureRecognizers){if(gestures.count>=8)break;[gestures addObject:@{@"class":DXClass(gesture),@"delegateClass":DXClass(gesture.delegate)}];}if(gestures.count)result[@"gestures"]=gestures; }
 return result;
}
- (NSString *)safePath:(NSString *)relative directory:(BOOL)directory {
 if (![relative isKindOfClass:NSString.class] || relative.length>512 || [relative hasPrefix:@"/"] || [relative containsString:@"\0"]) return nil;
 NSString *home=NSHomeDirectory().stringByStandardizingPath;
 NSString *path=[home stringByAppendingPathComponent:relative?:@""].stringByStandardizingPath;
 if (![path isEqual:home] && ![path hasPrefix:[home stringByAppendingString:@"/"]]) return nil;
 NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
 if ([attributes[NSFileType] isEqual:NSFileTypeSymbolicLink]) return nil;
 NSString *resolved=path.stringByResolvingSymlinksInPath;
 if (![resolved isEqual:home] && ![resolved hasPrefix:[home stringByAppendingString:@"/"]]) return nil;
 if (directory && ![attributes[NSFileType] isEqual:NSFileTypeDirectory]) return nil;
 if (!directory && ![attributes[NSFileType] isEqual:NSFileTypeRegular]) return nil;
 return resolved;
}
- (BOOL)setInvocation:(NSInvocation *)invocation value:(id)value type:(const char *)type index:(NSInteger)index error:(NSString **)error {
 if (!type) { if (error) *error = @"方法参数类型未知"; return NO; } switch (type[0]) {
  case '@': {
   if (type[1] == '?') { if (error) *error = @"暂不支持 block 参数"; return NO; }
   id objectValue = [value isKindOfClass:NSNull.class] ? nil : value;
   if (objectValue && ![objectValue isKindOfClass:NSString.class] && ![objectValue isKindOfClass:NSNumber.class] && ![objectValue isKindOfClass:NSArray.class] && ![objectValue isKindOfClass:NSDictionary.class]) {
    if (error) *error = @"对象参数仅支持字符串、数字、null、数组或字典";
    return NO;
   }
   [invocation setArgument:&objectValue atIndex:index];
   return YES;
  }
  case ':': {
   if (![value isKindOfClass:NSString.class]) { if (error) *error = @"SEL 参数需要字符串"; return NO; }
   SEL selector = NSSelectorFromString(value);
   [invocation setArgument:&selector atIndex:index];
   return YES;
  }
  case '*': {
   if (![value isKindOfClass:NSString.class]) { if (error) *error = @"C 字符串参数需要字符串"; return NO; }
   const char *text = [value UTF8String];
   [invocation setArgument:&text atIndex:index];
   return YES;
  }
  default: break;
 }
 if (![value isKindOfClass:NSNumber.class]) {
  if (error) *error = [NSString stringWithFormat:@"第 %ld 个参数需要数字", (long)index - 1];
  return NO;
 }
 NSNumber *number = value;
 switch (type[0]) {
  case 'c': { char v = number.charValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'C': { unsigned char v = number.unsignedCharValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'B': { bool v = number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
  case 's': { short v = number.shortValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'S': { unsigned short v = number.unsignedShortValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'i': { int v = number.intValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'I': { unsigned int v = number.unsignedIntValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'l': { long v = number.longValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'L': { unsigned long v = number.unsignedLongValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'q': { long long v = number.longLongValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'Q': { unsigned long long v = number.unsignedLongLongValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'f': { float v = number.floatValue; [invocation setArgument:&v atIndex:index]; break; }
  case 'd': { double v = number.doubleValue; [invocation setArgument:&v atIndex:index]; break; }
  default:
   if (error) *error = [NSString stringWithFormat:@"暂不支持参数类型 %s（结构体/联合体/指针）", type];
   return NO;
 }
 return YES;
}

- (NSDictionary *)invokeMethod:(NSDictionary *)arguments error:(NSString **)error {
 id identifier = arguments[@"id"];
 NSString *className = arguments[@"class"];
 NSString *selectorName = arguments[@"selector"];
 if (![selectorName isKindOfClass:NSString.class] || selectorName.length == 0 || selectorName.length > 300) {
  if (error) *error = @"selector 无效（1–300 个字符）";
  return nil;
 }
 static NSSet *blockedSelectors; static dispatch_once_t once;
 dispatch_once(&once, ^{ blockedSelectors = [NSSet setWithArray:@[@"dealloc", @"release", @"retain", @"autorelease", @"retainCount"]]; });
 if ([blockedSelectors containsObject:selectorName]) {
  if (error) *error = [@"该 selector 不允许远程调用：" stringByAppendingString:selectorName];
  return nil;
 }
 id target = nil; BOOL classTarget = NO;
 if ([identifier isKindOfClass:NSString.class]) {
  target = [self objectForIdentifier:identifier];
  if (!target) { if (error) *error = @"对象 ID 已过期，请重新读取页面元素或重新获取实例"; return nil; }
 } else if ([className isKindOfClass:NSString.class] && className.length) {
  Class cls = NSClassFromString(className);
  if (!cls) { if (error) *error = [@"找不到类：" stringByAppendingString:className]; return nil; }
  target = (id)cls; classTarget = YES;
 } else {
  target = self.selectedObject;
  if (!target) { if (error) *error = @"没有可调用对象，请传 id、class 或先在 FLEX 中选中对象"; return nil; }
 }
 SEL selector = NSSelectorFromString(selectorName);
 Method method = classTarget ? class_getClassMethod((Class)target, selector) : class_getInstanceMethod([target class], selector);
 if (!method) { if (error) *error = [@"目标不存在该 selector：" stringByAppendingString:selectorName]; return nil; }
 NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
 NSArray *values = arguments[@"arguments"] ?: @[];
 if (![values isKindOfClass:NSArray.class]) { if (error) *error = @"arguments 必须是数组"; return nil; }
 if (values.count + 2 != signature.numberOfArguments) {
  if (error) *error = [NSString stringWithFormat:@"%@ 需要 %lu 个参数，收到 %lu 个", selectorName, (unsigned long)(signature.numberOfArguments - 2), (unsigned long)values.count];
  return nil;
 }
 NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
 invocation.target = target;
 invocation.selector = selector;
 NSMutableArray *types = [NSMutableArray new];
 for (NSUInteger i = 0; i < values.count; i++) {
  const char *type = [signature getArgumentTypeAtIndex:i + 2];
  [types addObject:[NSString stringWithUTF8String:type] ?: @"?"];
  if (![self setInvocation:invocation value:values[i] type:type index:(NSInteger)i + 2 error:error]) return nil;
 }
 @try {
  [invocation invoke];
 } @catch (NSException *exception) {
  if (error) *error = [NSString stringWithFormat:@"调用 %@ 抛出异常：%@", selectorName, exception.reason ?: exception.name];
  return nil;
 }
 NSMutableDictionary *result = [@{@"invoked":@YES,@"target":classTarget?NSStringFromClass((Class)target):NSStringFromClass([target class]),@"selector":selectorName,@"argumentTypes":types,@"requeryRequired":@YES} mutableCopy];
 const char *returnType = signature.methodReturnType;
 NSString *typeName = returnType ? [NSString stringWithUTF8String:returnType] : @"?";
 result[@"returnType"] = typeName;
 if (returnType[0] == 'v') {
  result[@"returnValue"] = NSNull.null;
 } else if (returnType[0] == '@') {
  __unsafe_unretained id objectValue = nil;
  [invocation getReturnValue:&objectValue];
  id strongValue = objectValue;
  result[@"returnValue"] = strongValue ? DXShort([strongValue description], 2000) : NSNull.null;
  result[@"returnClass"] = strongValue ? NSStringFromClass([strongValue class]) : NSNull.null;
  result[@"returnId"] = strongValue ? [self registerObject:strongValue] : NSNull.null;
 } else if (returnType[0] == ':') {
  SEL returned = NULL; [invocation getReturnValue:&returned];
  result[@"returnValue"] = returned ? NSStringFromSelector(returned) : NSNull.null;
 } else if (returnType[0] == 'c') {
  char v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'C') {
  unsigned char v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'B') {
  bool v = false; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 's') {
  short v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'S') {
  unsigned short v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'i') {
  int v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'I') {
  unsigned int v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'l') {
  long v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'L') {
  unsigned long v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'q') {
  long long v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'Q') {
  unsigned long long v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'f') {
  float v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else if (returnType[0] == 'd') {
  double v = 0; [invocation getReturnValue:&v]; result[@"returnValue"] = @(v);
 } else {
  result[@"returnUnsupported"] = @YES;
  result[@"returnValue"] = [NSString stringWithFormat:@"无法序列化的返回类型 %@", typeName];
 }
 return result;
}

- (void)collectInstancesFromController:(UIViewController *)controller into:(NSMutableArray *)items depth:(NSUInteger)depth {
 if(!controller||items.count>=200||depth>12)return;
 [items addObject:controller];
 [self collectInstancesFromController:controller.presentedViewController into:items depth:depth+1];
 for(UIViewController *child in controller.childViewControllers)[self collectInstancesFromController:child into:items depth:depth+1];
}

- (NSDictionary *)findInstances:(NSDictionary *)arguments error:(NSString **)error {
 NSString *name=arguments[@"class"];
 if(![name isKindOfClass:NSString.class]||name.length<2||name.length>200){if(error)*error=@"class 参数应为 2–200 字符的类名";return nil;}
 Class cls=NSClassFromString(name);
 if(!cls){if(error)*error=[@"找不到类：" stringByAppendingString:name];return nil;}
 id limitValue=arguments[@"limit"];
 NSUInteger limit=[limitValue isKindOfClass:NSNumber.class]?MIN(MAX([limitValue integerValue],1),50):20;
 UIApplication *app=UIApplication.sharedApplication;
 NSMutableArray *candidates=[NSMutableArray new];
 if(app)[candidates addObject:app];
 if(app.delegate)[candidates addObject:app.delegate];
 NSMutableArray *controllers=[NSMutableArray new];
 for(UIWindow *window in app.windows){
  [candidates addObject:window];
  if(window.rootViewController)[self collectInstancesFromController:window.rootViewController into:controllers depth:0];
 }
 [candidates addObjectsFromArray:controllers];
 NSUInteger scanned=0;NSMutableArray *stack=[NSMutableArray arrayWithArray:app.windows];
 while(stack.count&&scanned<1500){
  UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
  [candidates addObject:view];
  [stack addObjectsFromArray:view.subviews];
  UIResponder *next=view.nextResponder;
  if([next isKindOfClass:UIViewController.class]&&![controllers containsObject:next])[candidates addObject:next];
 }
 NSMutableArray *rows=[NSMutableArray new];NSMutableSet *seen=[NSMutableSet new];
 for(id object in candidates){
  if(rows.count>=limit)break;
  NSValue *key=[NSValue valueWithPointer:(__bridge const void *)object];
  if([seen containsObject:key])continue;
  [seen addObject:key];
  if(![object isKindOfClass:cls])continue;
  NSString *identifier=[self registerObject:object];
  NSMutableDictionary *row=[@{@"id":identifier?:@"",@"class":DXClass(object),@"address":[NSString stringWithFormat:@"%p",object],@"description":DXShort([object description],240)} mutableCopy];
  if([object isKindOfClass:UIView.class]){
   UIView *view=(UIView *)object;
   CGRect frame=view.window?[view convertRect:view.bounds toView:view.window]:view.bounds;
   row[@"frame"]=NSStringFromCGRect(frame);
   row[@"hidden"]=@(view.hidden);
   row[@"alpha"]=@(view.alpha);
   row[@"attached"]=@(view.window!=nil);
   row[@"isWindow"]=@([view isKindOfClass:UIWindow.class]);
  } else if([object isKindOfClass:UIViewController.class]){
   UIViewController *controller=(UIViewController *)object;
   if(controller.title)row[@"title"]=controller.title;
   row[@"viewLoaded"]=@(controller.isViewLoaded);
   row[@"presented"]=@(controller.presentingViewController!=nil);
  }
  [rows addObject:row];
 }
 return @{@"class":name,@"instances":rows,@"scanned":@(scanned),@"truncated":@(rows.count>=limit),@"scope":@"UIApplication、AppDelegate、窗口、视图层级与控制器树；非界面对象不做堆扫描"};
}

- (NSString *)searchableTextForView:(UIView *)view {
 NSMutableArray *parts=[NSMutableArray new];
 if(view.accessibilityLabel.length)[parts addObject:view.accessibilityLabel];
 if(view.accessibilityIdentifier.length)[parts addObject:view.accessibilityIdentifier];
 if([view isKindOfClass:UILabel.class]){NSString *text=((UILabel *)view).text;if(text.length)[parts addObject:text];}
 else if([view isKindOfClass:UIButton.class]){NSString *text=((UIButton *)view).currentTitle;if(text.length)[parts addObject:text];}
 else if([view isKindOfClass:UITextField.class]){UITextField *field=(id)view;if(field.text.length)[parts addObject:field.text];if(field.placeholder.length)[parts addObject:field.placeholder];}
 else if([view isKindOfClass:UITextView.class]){NSString *text=((UITextView *)view).text;if(text.length)[parts addObject:text];}
 else if([view isKindOfClass:UISearchBar.class]){NSString *text=((UISearchBar *)view).text;if(text.length)[parts addObject:text];}
 return [parts componentsJoinedByString:@" · "];
}
- (BOOL)isInteractiveView:(UIView *)view {
 if([view isKindOfClass:UIControl.class]||[view isKindOfClass:UIScrollView.class]||(view.accessibilityTraits&UIAccessibilityTraitButton)!=0)return YES;
 for(UIGestureRecognizer *gesture in view.gestureRecognizers)if([gesture isKindOfClass:UITapGestureRecognizer.class])return YES;
 return NO;
}
- (NSDictionary *)findText:(NSDictionary *)arguments error:(NSString **)error {
 NSString *query=arguments[@"query"];
 if(![query isKindOfClass:NSString.class]||query.length==0||query.length>200){if(error)*error=@"query 应为 1–200 字符的文本";return nil;}
 BOOL exact=[arguments[@"exact"] boolValue];
 id limitValue=arguments[@"limit"];
 NSUInteger limit=[limitValue isKindOfClass:NSNumber.class]?MIN(MAX([limitValue integerValue],1),50):20;
 UIWindow *window=[self window];if(!window){if(error)*error=@"当前没有可见窗口";return nil;}
 NSMutableArray *matches=[NSMutableArray new];NSMutableArray *stack=[NSMutableArray arrayWithObject:window];NSUInteger scanned=0;
 while(stack.count&&scanned<1500&&matches.count<limit){
  UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
  if(!view||view.hidden||view.alpha<0.01)continue;
  [stack addObjectsFromArray:view.subviews];
  NSString *text=[self searchableTextForView:view];if(!text.length)continue;
  BOOL hit=exact?[text isEqualToString:query]:([text rangeOfString:query options:NSCaseInsensitiveSearch].location!=NSNotFound);
  if(!hit)continue;
  CGRect frame=[view convertRect:view.bounds toView:window];if(CGRectIsEmpty(frame))continue;
  [matches addObject:@{@"id":[self registerView:view],@"class":DXClass(view),@"text":DXShort(text,200),@"frame":NSStringFromCGRect(frame),@"interactive":@([self isInteractiveView:view]),@"center":@{@"x":@(CGRectGetMidX(frame)),@"y":@(CGRectGetMidY(frame))}}];
 }
 return @{@"query":query,@"matches":matches,@"scanned":@(scanned),@"truncated":@(matches.count>=limit)};
}
- (NSDictionary *)screenTexts:(NSDictionary *)arguments error:(NSString **)error {
 id limitValue=arguments[@"limit"];
 NSUInteger limit=[limitValue isKindOfClass:NSNumber.class]?MIN(MAX([limitValue integerValue],1),200):120;
 UIWindow *window=[self window];if(!window){if(error)*error=@"当前没有可见窗口";return nil;}
 NSMutableArray *rows=[NSMutableArray new];NSMutableArray *stack=[NSMutableArray arrayWithObject:window];NSUInteger scanned=0;
 while(stack.count&&scanned<1500&&rows.count<limit){
  UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
  if(!view||view.hidden||view.alpha<0.01)continue;
  [stack addObjectsFromArray:view.subviews];
  NSString *text=[self searchableTextForView:view];if(!text.length)continue;
  [rows addObject:@{@"id":[self registerView:view],@"class":DXClass(view),@"text":DXShort(text,200)}];
 }
 return @{@"texts":rows,@"scanned":@(scanned),@"truncated":@(rows.count>=limit)};
}
- (NSString *)primitiveValueForType:(const char *)type pointer:(const void *)pointer {
 if(!type||!pointer)return nil;
 switch(type[0]){
  case 'c':{char v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%d",v];}
  case 'C':{unsigned char v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%u",v];}
  case 'B':{bool v=false;memcpy(&v,pointer,sizeof(v));return v?@"true":@"false";}
  case 's':{short v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%d",v];}
  case 'S':{unsigned short v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%u",v];}
  case 'i':{int v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%d",v];}
  case 'I':{unsigned int v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%u",v];}
  case 'l':{long v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%ld",v];}
  case 'L':{unsigned long v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%lu",v];}
  case 'q':{long long v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%lld",v];}
  case 'Q':{unsigned long long v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%llu",v];}
  case 'f':{float v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%g",v];}
  case 'd':{double v=0;memcpy(&v,pointer,sizeof(v));return [NSString stringWithFormat:@"%g",v];}
  default:return nil;
 }
}
- (NSDictionary *)objectProperties:(NSDictionary *)arguments error:(NSString **)error {
 id object=arguments[@"id"]?[self objectForIdentifier:arguments[@"id"]]:self.selectedObject;
 if(!object){if(error)*error=@"对象已释放或没有被选中";return nil;}
 NSMutableArray *rows=[NSMutableArray new];unsigned int count=0;Ivar *ivars=class_copyIvarList([object class],&count);
 for(unsigned int i=0;i<count&&rows.count<60;i++){
  Ivar ivar=ivars[i];const char *name=ivar_getName(ivar);const char *type=ivar_getTypeEncoding(ivar);if(!name||!type)continue;
  NSMutableDictionary *row=[@{@"name":[NSString stringWithUTF8String:name]?:@"?",@"type":[NSString stringWithUTF8String:type]?:@"?"} mutableCopy];
  @try{
   if(type[0]=='@'){
    if(type[1]=='?'){row[@"value"]=@"<block>";}
    else{
     id value=object_getIvar(object,ivar);
     row[@"value"]=value?DXShort([value description],300):@"nil";
     if(value){row[@"class"]=DXClass(value);NSString *identifier=[self registerObject:value];if(identifier)row[@"valueId"]=identifier;}
    }
   } else {
    NSString *value=[self primitiveValueForType:type pointer:(const char *)(__bridge const void *)object+ivar_getOffset(ivar)];
    row[@"value"]=value?:@"<unsupported>";
   }
  }@catch(NSException *exception){row[@"value"]=@"<read failed>";}
  [rows addObject:row];
 }
 free(ivars);
 NSString *identifier=[self registerObject:object];
 return @{@"id":identifier?:@"",@"class":DXClass(object),@"ivars":rows,@"truncated":@(rows.count>=60),@"note":@"只读取 ivar，不调用 getter"};
}
- (NSMutableDictionary *)networkRowForTransaction:(FLEXHTTPTransaction *)item detail:(BOOL)detail {
 NSURL *url=item.request.URL;NSMutableDictionary *row=[@{@"id":item.requestID?:@"",@"host":url.host?:@"",@"path":DXShort(url.path,240),@"method":item.request.HTTPMethod?:@"GET",@"state":@(item.state),@"receivedBytes":@(item.receivedDataLength),@"startedAt":@(item.startTime.timeIntervalSince1970)} mutableCopy];
 if([item.response isKindOfClass:NSHTTPURLResponse.class])row[@"status"]=@(((NSHTTPURLResponse *)item.response).statusCode);
 if(detail){
  row[@"url"]=DXShort(url.absoluteString,2048);
  row[@"requestContentType"]=DXShort([item.request valueForHTTPHeaderField:@"Content-Type"],120);
  row[@"responseContentType"]=DXShort(item.response.MIMEType,120);
  row[@"requestBody"]=DXBody(item.cachedRequestBody);
  row[@"responseBody"]=DXBody([FLEXNetworkRecorder.defaultRecorder cachedResponseBodyForTransaction:item]);
 }
 return row;
}
- (NSDictionary *)networkSearch:(NSDictionary *)arguments error:(NSString **)error {
 NSString *query=arguments[@"query"],*host=arguments[@"host"],*method=arguments[@"method"];id status=arguments[@"status"];
 id limitValue=arguments[@"limit"];
 NSUInteger limit=[limitValue isKindOfClass:NSNumber.class]?MIN(MAX([limitValue integerValue],1),50):20;
 NSArray<FLEXHTTPTransaction *> *items=FLEXNetworkRecorder.defaultRecorder.HTTPTransactions;NSMutableArray *rows=[NSMutableArray new];
 for(FLEXHTTPTransaction *item in items){
  NSMutableDictionary *row=[self networkRowForTransaction:item detail:NO];
  if(query.length&&[row[@"path"] rangeOfString:query options:NSCaseInsensitiveSearch].location==NSNotFound&&[row[@"host"] rangeOfString:query options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
  if(host.length&&[row[@"host"] rangeOfString:host options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
  if(method.length&&![row[@"method"] isEqualToString:method.uppercaseString])continue;
  if([status isKindOfClass:NSNumber.class]&&[row[@"status"] integerValue]!=[status integerValue])continue;
  [rows addObject:row];if(rows.count>=limit)break;
 }
 return @{@"transactions":rows,@"truncated":@(rows.count>=limit),@"recordingEnabled":@(FLEXNetworkObserver.isEnabled)};
}
- (NSDictionary *)sandboxGrep:(NSDictionary *)arguments error:(NSString **)error {
 NSString *relative=arguments[@"path"],*query=arguments[@"query"];
 if(![query isKindOfClass:NSString.class]||query.length==0||query.length>200){if(error)*error=@"query 应为 1–200 字符";return nil;}
 NSString *path=[self safePath:relative directory:NO];if(!path){if(error)*error=@"文件不存在或不在当前 App 沙盒内";return nil;}
 id limitValue=arguments[@"limit"];
 NSUInteger limit=[limitValue isKindOfClass:NSNumber.class]?MIN(MAX([limitValue integerValue],1),200):50;
 BOOL caseSensitive=[arguments[@"case_sensitive"] boolValue];
 NSUInteger chunk=8*1024*1024;NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:path];
 if(!file){if(error)*error=@"文件无法打开";return nil;}
 NSData *data=nil;@try{data=[file readDataOfLength:chunk];[file closeFile];}@catch(NSException *exception){[file closeFile];if(error)*error=@"文件读取失败";return nil;}
 NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
 if(!text){if(error)*error=@"该文件不是 UTF-8 文本，无法搜索";return nil;}
 NSArray *lines=[text componentsSeparatedByString:@"\n"];NSMutableArray *matches=[NSMutableArray new];
 NSStringCompareOptions options=caseSensitive?0:NSCaseInsensitiveSearch;
 for(NSUInteger i=0;i<lines.count&&matches.count<limit;i++){
  NSString *line=lines[i];if([line rangeOfString:query options:options].location==NSNotFound)continue;
  [matches addObject:@{@"line":@(i+1),@"text":DXShort(line,400)}];
 }
 NSDictionary *fileAttributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
 unsigned long long fileBytes=[fileAttributes[NSFileSize] unsignedLongLongValue];
 return @{@"path":relative,@"query":query,@"matches":matches,@"scannedBytes":@(data.length),@"fileBytes":@(fileBytes),@"truncatedFile":@(fileBytes>data.length),@"truncatedMatches":@(matches.count>=limit)};
}
- (NSDictionary *)networkExport:(NSDictionary *)arguments error:(NSString **)error {
 NSArray<FLEXHTTPTransaction *> *items=FLEXNetworkRecorder.defaultRecorder.HTTPTransactions;
 if(!items.count){if(error)*error=@"当前没有网络记录可导出";return nil;}
 NSMutableArray *entries=[NSMutableArray new];
 for(FLEXHTTPTransaction *item in items){[entries addObject:[self networkRowForTransaction:item detail:YES]];}
 NSDictionary *payload=@{@"creator":@"AiFlex3",@"exportedAt":@(NSDate.date.timeIntervalSince1970),@"bundleID":NSBundle.mainBundle.bundleIdentifier?:@"",@"entries":entries};
 NSData *json=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
 if(!json){if(error)*error=@"网络记录无法序列化";return nil;}
 NSString *directory=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/AiFlex3"];
 if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]){if(error)*error=@"无法创建导出目录";return nil;}
 NSString *name=[NSString stringWithFormat:@"network-%.0f.json",NSDate.date.timeIntervalSince1970*1000];
 NSString *path=[directory stringByAppendingPathComponent:name];NSString *relative=[@"Documents/AiFlex3" stringByAppendingPathComponent:name];
 if(![json writeToFile:path atomically:YES]){if(error)*error=@"导出文件写入失败";return nil;}
 return @{@"path":relative,@"entries":@(entries.count),@"bytes":@(json.length)};
}
- (NSDictionary *)visibleTextMatch:(NSString *)query {
 UIWindow *window=[self window];if(!window)return nil;
 NSMutableArray *stack=[NSMutableArray arrayWithObject:window];NSUInteger scanned=0;
 while(stack.count&&scanned<1500){
  UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
  if(!view||view.hidden||view.alpha<0.01)continue;
  [stack addObjectsFromArray:view.subviews];
  NSString *text=[self searchableTextForView:view];if(!text.length)continue;
  if([text rangeOfString:query options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
  CGRect frame=[view convertRect:view.bounds toView:window];
  if(CGRectIsEmpty(frame)||!CGRectIntersectsRect(frame,window.bounds))continue;
  return @{@"id":[self registerView:view],@"class":DXClass(view),@"text":DXShort(text,200),@"frame":NSStringFromCGRect(frame),@"center":@{@"x":@(CGRectGetMidX(frame)),@"y":@(CGRectGetMidY(frame))}};
 }
 return nil;
}
- (BOOL)waitCondition:(NSString *)condition arguments:(NSDictionary *)arguments observed:(NSDictionary **)observed {
 UIWindow *window=[self window];if(!window)return NO;
 NSMutableArray *path=[NSMutableArray new];UIViewController *top=[self visibleControllerInWindow:window path:path];
 NSMutableDictionary *snapshot=[NSMutableDictionary dictionaryWithDictionary:@{@"controller":DXClass(top),@"controllerPath":path}];
 if([condition isEqualToString:@"controller"]){
  NSString *wanted=arguments[@"class"]?:arguments[@"query"];
  BOOL matched=wanted.length&&[DXClass(top) rangeOfString:wanted options:NSCaseInsensitiveSearch].location!=NSNotFound;
  if(observed)*observed=snapshot;return matched;
 }
 if([condition isEqualToString:@"network"]){
  NSString *query=arguments[@"query"];BOOL matched=NO;
  for(FLEXHTTPTransaction *item in FLEXNetworkRecorder.defaultRecorder.HTTPTransactions){
   NSURL *url=item.request.URL;
   if(query.length&&[url.absoluteString rangeOfString:query options:NSCaseInsensitiveSearch].location!=NSNotFound){matched=YES;snapshot[@"transaction"]=[self networkRowForTransaction:item detail:NO];break;}
  }
  if(observed)*observed=snapshot;return matched;
 }
 if([condition isEqualToString:@"text_exists"]||[condition isEqualToString:@"text_gone"]){
  NSString *query=arguments[@"query"];
  NSDictionary *match=query.length?[self visibleTextMatch:query]:nil;
  if(match)snapshot[@"match"]=match;
  if(observed)*observed=snapshot;
  return [condition isEqualToString:@"text_exists"]?match!=nil:match==nil;
 }
 if([condition isEqualToString:@"element_exists"]||[condition isEqualToString:@"element_gone"]){
  UIView *target=nil;NSString *identifier=arguments[@"id"],*className=arguments[@"class"];
  if([identifier isKindOfClass:NSString.class]){
   id object=[self objectForIdentifier:identifier];
   if([object isKindOfClass:UIView.class])target=object;
  } else if([className isKindOfClass:NSString.class]&&className.length){
   NSMutableArray *stack=[NSMutableArray arrayWithObject:window];NSUInteger scanned=0;
   while(stack.count&&scanned<1500){
    UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
    if(!view)continue;
    if([NSStringFromClass(view.class) isEqualToString:className]&&[self isAttached:view]&&!view.hidden&&view.alpha>=0.01){target=view;break;}
    [stack addObjectsFromArray:view.subviews];
   }
  }
  BOOL present=target&&[self isAttached:target]&&!target.hidden&&target.alpha>=0.01;
  if(present){
   CGRect frame=[target convertRect:target.bounds toView:window];
   snapshot[@"match"]=@{@"id":[self registerView:target],@"class":DXClass(target),@"frame":NSStringFromCGRect(frame)};
  }
  if(observed)*observed=snapshot;
  return [condition isEqualToString:@"element_exists"]?present:!present;
 }
 if(observed)*observed=snapshot;return NO;
}
- (void)waitFor:(NSDictionary *)arguments completion:(void (^)(NSDictionary *, NSString *))completion {
 NSString *condition=arguments[@"condition"];
 NSArray *supported=@[@"text_exists",@"text_gone",@"element_exists",@"element_gone",@"controller",@"network"];
 if(![supported containsObject:condition]){completion(nil,@"condition 仅支持 text_exists / text_gone / element_exists / element_gone / controller / network");return;}
 if(([condition hasPrefix:@"text"]||[condition isEqualToString:@"network"])&&![arguments[@"query"] isKindOfClass:NSString.class]){completion(nil,@"该条件需要 query");return;}
 if([condition hasPrefix:@"element"]&&![arguments[@"id"] isKindOfClass:NSString.class]&&![arguments[@"class"] isKindOfClass:NSString.class]){completion(nil,@"element 条件需要 id 或 class");return;}
 double requested=[arguments[@"timeout"] doubleValue];
 NSTimeInterval timeout=(requested>=0.5&&requested<=10)?requested:3.0;
 NSTimeInterval started=NSDate.date.timeIntervalSince1970;NSTimeInterval deadline=started+timeout;
 __block BOOL finished=NO;__weak typeof(self) weakSelf=self;
 __block void (^poll)(void)=nil;
 poll=^{
  FLEXAiFlexRuntime *strong=weakSelf;
  if(!strong){if(!finished){finished=YES;completion(nil,@"运行时已释放");}poll=nil;return;}
  if(finished){poll=nil;return;}
  NSDictionary *observed=nil;
  BOOL satisfied=[strong waitCondition:condition arguments:arguments observed:&observed];
  if(satisfied){
   finished=YES;NSTimeInterval waited=NSDate.date.timeIntervalSince1970-started;
   completion(@{@"condition":condition,@"satisfied":@YES,@"waited":@(waited),@"timedOut":@NO,@"observed":observed?:@{}},nil);
   poll=nil;return;
  }
  if(NSDate.date.timeIntervalSince1970>=deadline){
   finished=YES;NSTimeInterval waited=NSDate.date.timeIntervalSince1970-started;
   completion(@{@"condition":condition,@"satisfied":@NO,@"waited":@(waited),@"timedOut":@YES,@"observed":observed?:@{}},nil);
   poll=nil;return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(),poll);
 };
 poll();
}
- (UIScrollView *)bestScrollViewInWindow:(UIWindow *)window {
 if(!window)return nil;
 UIScrollView *best=nil;CGFloat bestArea=0;
 NSMutableArray *stack=[NSMutableArray arrayWithObject:window];NSUInteger scanned=0;
 while(stack.count&&scanned<1500){
  UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
  if(!view||view.hidden||view.alpha<0.01)continue;
  [stack addObjectsFromArray:view.subviews];
  if([view isKindOfClass:UIScrollView.class]&&view.window){
   UIScrollView *scroll=(id)view;CGFloat maxY=scroll.contentSize.height-CGRectGetHeight(scroll.bounds)+scroll.adjustedContentInset.bottom;
   CGFloat area=CGRectGetWidth(scroll.bounds)*CGRectGetHeight(scroll.bounds);
   if(maxY>1&&area>bestArea){best=scroll;bestArea=area;}
  }
 }
 return best;
}
- (void)scrollToText:(NSDictionary *)arguments completion:(void (^)(NSDictionary *, NSString *))completion {
 NSString *query=arguments[@"query"];
 if(![query isKindOfClass:NSString.class]||query.length==0||query.length>200){completion(nil,@"query 应为 1–200 字符");return;}
 NSInteger requestedPages=[arguments[@"max_pages"] integerValue];
 NSInteger maxPages=(requestedPages>=1&&requestedPages<=10)?requestedPages:5;
 BOOL upwards=[arguments[@"direction"] isEqualToString:@"up"];
 UIWindow *window=[self window];if(!window){completion(nil,@"当前没有可见窗口");return;}
 UIScrollView *scroll=nil;
 NSString *container=arguments[@"container"];
 if([container isKindOfClass:NSString.class]){
  id object=[self objectForIdentifier:container];
  if([object isKindOfClass:UIScrollView.class])scroll=object;
  if(!scroll){completion(nil,@"container 不是可用的 UIScrollView");return;}
 } else scroll=[self bestScrollViewInWindow:window];
 if(!scroll){completion(nil,@"当前页面没有可滚动的列表或滚动视图");return;}
 CGPoint originalOffset=scroll.contentOffset;__block NSInteger page=0;
 __weak typeof(self) weakSelf=self;__block void (^step)(void)=nil;
 step=^{
  FLEXAiFlexRuntime *strong=weakSelf;if(!strong){completion(nil,@"运行时已释放");step=nil;return;}
  NSDictionary *match=[strong visibleTextMatch:query];
  if(match){
   completion(@{@"found":@YES,@"pages":@(page),@"match":match,@"contentOffset":@{@"x":@(scroll.contentOffset.x),@"y":@(scroll.contentOffset.y)},@"atEnd":@NO},nil);
   step=nil;return;
  }
  CGFloat minY=-scroll.adjustedContentInset.top;
  CGFloat maxY=MAX(minY,scroll.contentSize.height-CGRectGetHeight(scroll.bounds)+scroll.adjustedContentInset.bottom);
  CGFloat delta=CGRectGetHeight(scroll.bounds)*0.8*(upwards?-1:1);
  CGFloat nextY=MIN(maxY,MAX(minY,scroll.contentOffset.y+delta));
  BOOL atEnd=fabs(nextY-scroll.contentOffset.y)<1;
  if(page>=maxPages||atEnd){
   completion(@{@"found":@NO,@"pages":@(page),@"atEnd":@(atEnd),@"truncated":@(!atEnd&&page>=maxPages),@"contentOffset":@{@"x":@(scroll.contentOffset.x),@"y":@(scroll.contentOffset.y)},@"startedAt":@{@"x":@(originalOffset.x),@"y":@(originalOffset.y)}},nil);
   step=nil;return;
  }
  [scroll setContentOffset:CGPointMake(scroll.contentOffset.x,nextY) animated:NO];
  page++;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)),dispatch_get_main_queue(),step);
 };
 step();
}
- (NSDictionary *)controllerStack {
 UIWindow *window=[self window];if(!window)return nil;
 NSMutableArray *path=[NSMutableArray new];UIViewController *top=[self visibleControllerInWindow:window path:path];
 NSMutableArray *presented=[NSMutableArray new];
 for(UIViewController *controller=window.rootViewController;controller&&presented.count<10;controller=controller.presentedViewController){
  [presented addObject:@{@"class":DXClass(controller),@"title":DXShort(controller.title,120)}];
 }
 NSMutableArray *navigation=[NSMutableArray new];
 UIViewController *root=window.rootViewController;
 if([root isKindOfClass:UINavigationController.class]){
  for(UIViewController *controller in ((UINavigationController *)root).viewControllers){
   [navigation addObject:@{@"class":DXClass(controller),@"title":DXShort(controller.title,120)}];
   if(navigation.count>=20)break;
  }
 }
 return @{@"top":DXClass(top),@"topTitle":DXShort(top.title,120),@"controllerPath":path,@"navigation":navigation,@"presented":presented,@"hasModal":@(presented.count>1)};
}
- (NSDictionary *)appInfo {
 NSDictionary *info=NSBundle.mainBundle.infoDictionary?:@{};
 NSProcessInfo *process=NSProcessInfo.processInfo;
 NSMutableDictionary *result=[@{@"bundleID":NSBundle.mainBundle.bundleIdentifier?:@"",@"name":info[@"CFBundleDisplayName"]?:info[@"CFBundleName"]?:@"",@"version":info[@"CFBundleShortVersionString"]?:@"",@"build":info[@"CFBundleVersion"]?:@"",@"executable":NSBundle.mainBundle.executablePath?:@"",@"bundlePath":NSBundle.mainBundle.bundlePath?:@"",@"container":NSHomeDirectory(),@"documents":[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],@"library":[NSHomeDirectory() stringByAppendingPathComponent:@"Library"],@"tmp":NSTemporaryDirectory(),@"pid":@(process.processIdentifier),@"systemUptime":@(process.systemUptime),@"launchTime":@(NSDate.date.timeIntervalSince1970-process.systemUptime),@"processorCount":@(process.processorCount),@"activeProcessors":@(process.activeProcessorCount),@"physicalMemory":@(process.physicalMemory),@"lowPowerMode":@(process.isLowPowerModeEnabled),@"thermalState":@(process.thermalState)} mutableCopy];
 task_vm_info_data_t vmInfo;mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vmInfo,&count)==KERN_SUCCESS)result[@"footprintBytes"]=@(vmInfo.phys_footprint);
 return result;
}
- (NSDictionary *)deviceInfo {
 UIDevice *device=UIDevice.currentDevice;UIScreen *screen=UIScreen.mainScreen;
 NSMutableDictionary *result=[@{@"systemName":device.systemName?:@"",@"systemVersion":device.systemVersion?:@"",@"model":device.model?:@"",@"localizedModel":device.localizedModel?:@"",@"idiom":@(device.userInterfaceIdiom),@"screenBounds":NSStringFromCGRect(screen.bounds),@"nativeBounds":NSStringFromCGRect(screen.nativeBounds),@"scale":@(screen.scale),@"nativeScale":@(screen.nativeScale),@"locale":NSLocale.currentLocale.localeIdentifier?:@"",@"languages":NSLocale.preferredLanguages?:@[],@"darkMode":@(UITraitCollection.currentTraitCollection.userInterfaceStyle==UIUserInterfaceStyleDark)} mutableCopy];
 NSArray *jbPaths=@[@"/var/jb",@"/Applications/Cydia.app",@"/usr/sbin/sshd",@"/private/preboot"];
 NSMutableArray *found=[NSMutableArray new];
 for(NSString *path in jbPaths)if([NSFileManager.defaultManager fileExistsAtPath:path])[found addObject:path];
 result[@"jailbreakPaths"]=found;result[@"jailbroken"]=@(found.count>0);
 return result;
}
- (NSDictionary *)filterTreeNode:(NSDictionary *)node classFilter:(NSString *)classFilter textFilter:(NSString *)textFilter interactiveOnly:(BOOL)interactiveOnly includeHidden:(BOOL)includeHidden maxDepth:(NSInteger)maxDepth {
 if(!includeHidden&&([node[@"hidden"] boolValue]||[node[@"alpha"] doubleValue]<0.01))return nil;
 if(maxDepth>=0&&[node[@"depth"] integerValue]>maxDepth)return nil;
 BOOL matches=YES;
 if(classFilter.length)matches=[node[@"class"] rangeOfString:classFilter options:NSCaseInsensitiveSearch].location!=NSNotFound;
 if(matches&&textFilter.length){
  NSString *haystack=[@[node[@"class"]?:@"",node[@"text"]?:@"",node[@"title"]?:@"",node[@"placeholder"]?:@""] componentsJoinedByString:@" "];
  matches=[haystack rangeOfString:textFilter options:NSCaseInsensitiveSearch].location!=NSNotFound;
 }
 if(interactiveOnly&&![node[@"interactive"] boolValue])matches=NO;
 NSMutableArray *children=[NSMutableArray new];
 for(NSDictionary *child in node[@"children"]){NSDictionary *kept=[self filterTreeNode:child classFilter:classFilter textFilter:textFilter interactiveOnly:interactiveOnly includeHidden:includeHidden maxDepth:maxDepth];if(kept)[children addObject:kept];}
 if(!matches&&children.count==0)return nil;
 NSMutableDictionary *copy=[node mutableCopy];copy[@"children"]=children;return copy;
}

- (NSDictionary *)captureSnapshot {
 UIWindow *window=[self window];NSMutableArray *path=[NSMutableArray new];
 UIViewController *controller=window?[self visibleControllerInWindow:window path:path]:nil;
 NSMutableArray *texts=[NSMutableArray new];NSUInteger scanned=0;
 if(window)[self collectScreenTexts:window window:window items:texts scanned:&scanned];
 NSMutableArray *elements=[NSMutableArray new];NSUInteger elementScanned=0;NSMutableArray *items=[NSMutableArray new];
 if(window)[self screenElementsInView:window window:window items:items scanned:&elementScanned];
 for(NSDictionary *item in items){if(elements.count>=80)break;[elements addObject:[NSString stringWithFormat:@"%@|%@|%@",item[@"class"]?:@"",item[@"label"]?:@"",item[@"frame"]?:@""]];}
 return @{@"time":@(NSDate.date.timeIntervalSince1970),@"controller":DXClass(controller),@"controllerPath":path?:@[],@"texts":texts?:@[],@"elements":elements};
}
- (NSDictionary *)snapshot:(NSDictionary *)arguments error:(NSString **)error {
 NSString *action=arguments[@"action"]?:@"save";
 if([action isEqualToString:@"clear"]){@synchronized(self){[self.snapshots removeAllObjects];}return @{@"cleared":@YES,@"count":@0};}
 if([action isEqualToString:@"save"]){
  NSDictionary *snapshot=[self captureSnapshot];@synchronized(self){[self.snapshots addObject:snapshot];while(self.snapshots.count>5)[self.snapshots removeObjectAtIndex:0];}
  return @{@"saved":@YES,@"count":@(self.snapshots.count),@"controller":snapshot[@"controller"],@"texts":@(((NSArray *)snapshot[@"texts"]).count),@"elements":@(((NSArray *)snapshot[@"elements"]).count)};
 }
 if([action isEqualToString:@"diff"]){
  NSDictionary *before=nil,*after=nil;@synchronized(self){if(self.snapshots.count>=2){before=self.snapshots[self.snapshots.count-2];after=self.snapshots.lastObject;}}
  if(!before){if(error)*error=@"至少需要两次 snapshot save 才能对比";return nil;}
  NSSet *oldTexts=[NSSet setWithArray:before[@"texts"]];NSSet *newTexts=[NSSet setWithArray:after[@"texts"]];
  NSMutableSet *added=[newTexts mutableCopy];[added minusSet:oldTexts];
  NSMutableSet *removed=[oldTexts mutableCopy];[removed minusSet:newTexts];
  NSArray *oldElements=before[@"elements"],*newElements=after[@"elements"];
  return @{@"controllerBefore":before[@"controller"],@"controllerAfter":after[@"controller"],@"controllerChanged":@(![before[@"controller"] isEqual:after[@"controller"]]),@"addedTexts":added.allObjects,@"removedTexts":removed.allObjects,@"elementsBefore":@(oldElements.count),@"elementsAfter":@(newElements.count),@"elementsDelta":@((NSInteger)newElements.count-(NSInteger)oldElements.count)};
 }
 if(error)*error=@"action 仅支持 save / diff / clear";return nil;
}
- (NSDictionary *)highlightElement:(NSDictionary *)arguments error:(NSString **)error {
 NSString *identifier=arguments[@"id"];UIView *view=[identifier isKindOfClass:NSString.class]?[self.views objectForKey:identifier]:nil;
 if(!view&&![identifier isKindOfClass:NSString.class])view=[self.selectedObject isKindOfClass:UIView.class]?self.selectedObject:nil;
 if(!view||![self isAttached:view]){if(error)*error=@"视图 ID 已过期或已离开当前页面";return nil;}
 id durationValue=arguments[@"duration"];NSTimeInterval duration=[durationValue isKindOfClass:NSNumber.class]?MIN(MAX([durationValue doubleValue],0.5),10):2;
 UIWindow *window=[self window];if(!window){if(error)*error=@"当前没有可见窗口";return nil;}
 const NSInteger tag=0x41F1E1;
 [[window viewWithTag:tag] removeFromSuperview];
 CGRect frame=[view convertRect:view.bounds toView:window];
 UIView *overlay=[UIView new];overlay.tag=tag;overlay.frame=frame;overlay.userInteractionEnabled=NO;
 overlay.layer.borderColor=UIColor.systemRedColor.CGColor;overlay.layer.borderWidth=2;
 overlay.backgroundColor=[UIColor.systemRedColor colorWithAlphaComponent:0.12];
 [window addSubview:overlay];[window bringSubviewToFront:overlay];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[overlay removeFromSuperview];});
 return @{@"highlighted":@YES,@"id":identifier?:@"",@"frame":NSStringFromCGRect(frame),@"duration":@(duration)};
}
- (void)performTapText:(NSDictionary *)arguments completion:(void (^)(NSDictionary *, NSString *))completion {
 NSString *query=arguments[@"query"];
 if(![query isKindOfClass:NSString.class]||query.length==0||query.length>200){completion(nil,@"query 应为 1–200 字符的文本");return;}
 id indexValue=arguments[@"index"];NSUInteger index=[indexValue isKindOfClass:NSNumber.class]?MIN([indexValue integerValue],9):0;
 NSString *error=nil;NSDictionary *found=[self findText:arguments error:&error];
 if(!found){completion(nil,error);return;}
 NSArray *matches=found[@"matches"];if(index>=matches.count){completion(nil,@"没有找到匹配该文本的可见元素，或 index 超出范围");return;}
 NSDictionary *match=matches[index];UIView *view=[self.views objectForKey:match[@"id"]];
 if(!view){completion(nil,@"匹配元素已失效，请重新查找");return;}
 BOOL activated=NO;
 if([view isKindOfClass:UIButton.class]&&[self isAttached:view]&&!view.hidden&&view.alpha>=0.01&&((UIControl *)view).enabled){
  [(UIButton *)view sendActionsForControlEvents:UIControlEventTouchUpInside];activated=YES;
  completion(@{@"tapped":@YES,@"method":@"activate_control",@"id":match[@"id"],@"text":match[@"text"],@"requeryRequired":@YES},nil);return;
 }
 if(!FLEXManager.sharedManager.isHidden){completion(nil,@"FLEX 覆盖层仍可见，请先 minimize_chat(surface=target) 后重试");return;}
 if(!self.touchDriver)self.touchDriver=[FLEXAiFlexTouchDriver new];
 if(self.touchDriver.running){completion(nil,@"另一个触摸序列仍在进行");return;}
 CGPoint center=CGPointMake([match[@"center"][@"x"] doubleValue],[match[@"center"][@"y"] doubleValue]);
 NSArray *path=@[[NSValue valueWithCGPoint:center],[NSValue valueWithCGPoint:center]];
 [self.touchDriver performPaths:@[path] window:[self window] duration:.08 completion:^(NSDictionary *result,NSString *touchError){
  if(touchError){completion(nil,touchError);return;}
  completion(@{@"tapped":@YES,@"method":@"gesture",@"id":match[@"id"],@"text":match[@"text"],@"delivery":result?:@{},@"requeryRequired":@YES},nil);
 }];
 (void)activated;
}
- (UIView *)webViewInWindow:(UIWindow *)window preferred:(NSString *)identifier {
 if([identifier isKindOfClass:NSString.class]){
  id object=[self objectForIdentifier:identifier];
  if([object isKindOfClass:UIView.class])return object;
 }
 if(!window)return nil;
 NSMutableArray *stack=[NSMutableArray arrayWithObject:window];NSUInteger scanned=0;
 while(stack.count&&scanned<1500){
  UIView *view=[stack lastObject];[stack removeLastObject];scanned++;
  NSString *name=NSStringFromClass([view class]);
  if([name containsString:@"WKWebView"]||[name containsString:@"UIWebView"])return view;
  [stack addObjectsFromArray:view.subviews];
 }
 return nil;
}
- (void)runJavaScript:(NSDictionary *)arguments completion:(void (^)(NSDictionary *, NSString *))completion {
 NSString *code=arguments[@"code"];
 if(![code isKindOfClass:NSString.class]||code.length==0||code.length>20000){completion(nil,@"code 应为 1–20000 字符的 JavaScript");return;}
 UIWindow *window=[self window];UIView *webView=[self webViewInWindow:window preferred:arguments[@"id"]];
 if(!webView){completion(nil,@"当前页面没有可执行脚本的 WKWebView/UIWebView");return;}
 if(![webView respondsToSelector:@selector(evaluateJavaScript:completionHandler:)]){completion(nil,@"该 WebView 不支持 evaluateJavaScript");return;}
 __block BOOL finished=NO;NSTimeInterval started=NSDate.date.timeIntervalSince1970;
 void (^finish)(NSDictionary *,NSString *)=^(NSDictionary *result,NSString *error){
  if(finished)return;finished=YES;completion(result,error);
 };
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
  finish(nil,@"JavaScript 执行超时（15 秒）");
 });
 [webView evaluateJavaScript:code completionHandler:^(id result,NSError *error){
  if(error){finish(nil,[NSString stringWithFormat:@"JavaScript 执行失败：%@",error.localizedDescription?:error.domain]);return;}
  NSString *text=nil;
  if([NSJSONSerialization isValidJSONObject:@[result?:NSNull.null]]){
   NSData *data=[NSJSONSerialization dataWithJSONObject:result?:NSNull.null options:0 error:nil];
   text=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
  }
  if(!text)text=result?DXShort([result description],8000):@"null";
  finish(@{@"result":text?:@"null",@"resultClass":result?DXClass(result):@"null",@"webView":DXClass(webView),@"duration":@(NSDate.date.timeIntervalSince1970-started)},nil);
 }];
}
- (void)recordTrace:(NSString *)key values:(NSArray *)values result:(id)result {
 static __thread BOOL inTrace=NO;
 if(inTrace)return;inTrace=YES;
 @try{
  NSDictionary *hook=nil;@synchronized(self){hook=self.traceHooks[key];}
  if(hook){
   NSMutableArray *args=[NSMutableArray new];
   for(id value in values){
    if(!value||value==NSNull.null)[args addObject:@"nil"];
    else if([value isKindOfClass:NSString.class])[args addObject:DXShort(value,200)];
    else [args addObject:DXShort([value description],200)];
   }
   NSMutableDictionary *row=[@{@"time":@(NSDate.date.timeIntervalSince1970),@"class":hook[@"class"],@"selector":hook[@"selector"],@"thread":NSThread.isMainThread?@"main":@"background",@"args":args} mutableCopy];
   if(result&&result!=NSNull.null)row[@"return"]=DXShort([result description],300);
   @synchronized(self){
    if(self.traceRecords.count<500)[self.traceRecords addObject:row];
    else self.traceDropped++;
   }
  }
 }@catch(NSException *exception){}
 inTrace=NO;
}
- (NSDictionary *)stopTraceWithClass:(NSString *)className selector:(NSString *)selectorName {
 NSUInteger stopped=0;NSArray *keys=nil;@synchronized(self){keys=self.traceHooks.allKeys;}
 for(NSString *key in keys){
  NSDictionary *hook=nil;@synchronized(self){hook=self.traceHooks[key];}
  if(!hook)continue;
  if(className.length&&![hook[@"class"] isEqual:className])continue;
  if(selectorName.length&&![hook[@"selector"] isEqual:selectorName])continue;
  Class cls=NSClassFromString(hook[@"class"]);
  if(cls){
   SEL selector=NSSelectorFromString(hook[@"selector"]);
   IMP original=(IMP)[hook[@"original"] pointerValue];
   const char *types=[hook[@"types"] UTF8String];
   if(original&&types)class_replaceMethod(cls,selector,original,types);
  }
  @synchronized(self){[self.traceHooks removeObjectForKey:key];}
  stopped++;
 }
 return @{@"stopped":@(stopped),@"activeHooks":@(self.traceHooks.count)};
}
- (NSDictionary *)traceOperation:(NSString *)action arguments:(NSDictionary *)arguments error:(NSString **)error {
 if([action isEqualToString:@"read"]){
  NSArray *records=nil,*hooks=nil;
  @synchronized(self){records=[[self.traceRecords reverseObjectEnumerator] allObjects];hooks=self.traceHooks.allValues;}
  NSMutableArray *names=[NSMutableArray new];for(NSDictionary *hook in hooks)[names addObject:[NSString stringWithFormat:@"%@|%@",hook[@"class"],hook[@"selector"]]];
  return @{@"records":records,@"count":@(records.count),@"dropped":@(self.traceDropped),@"hooks":names,@"recording":@(self.traceHooks.count>0)};
 }
 if([action isEqualToString:@"clear"]){@synchronized(self){[self.traceRecords removeAllObjects];}self.traceDropped=0;return @{@"cleared":@YES};}
 if([action isEqualToString:@"stop"]){
  NSDictionary *result=[self stopTraceWithClass:arguments[@"class"] selector:arguments[@"selector"]];
  if(!self.traceHooks.count)self.traceGeneration++;
  return result;
 }
 if(![action isEqualToString:@"start"]){if(error)*error=@"trace 操作仅支持 start / stop / read / clear";return nil;}
 NSString *className=arguments[@"class"],*selectorName=arguments[@"selector"];
 if(![className isKindOfClass:NSString.class]||className.length>200||![selectorName isKindOfClass:NSString.class]||selectorName.length==0||selectorName.length>300){if(error)*error=@"trace_start 需要 class 与 selector";return nil;}
 if(self.traceHooks.count>=8){if(error)*error=@"同时最多追踪 8 个方法，请先 stop";return nil;}
 Class cls=NSClassFromString(className);if(!cls){if(error)*error=[@"找不到类：" stringByAppendingString:className];return nil;}
 SEL selector=NSSelectorFromString(selectorName);Method method=class_getInstanceMethod(cls,selector);
 if(!method){if(error)*error=[@"类中不存在实例方法：" stringByAppendingString:selectorName];return nil;}
 NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
 NSUInteger argumentCount=signature.numberOfArguments>=2?signature.numberOfArguments-2:0;
 if(argumentCount>3){if(error)*error=@"方法追踪最多支持 3 个参数";return nil;}
 for(NSUInteger i=2;i<signature.numberOfArguments;i++){
  const char *type=[signature getArgumentTypeAtIndex:i];
  if(type[0]!='@'||type[1]=='?'){if(error)*error=[NSString stringWithFormat:@"参数 %lu 不是对象类型，暂不支持追踪",(unsigned long)(i-1)];return nil;}
 }
 const char *returnType=signature.methodReturnType;
 if(returnType[0]!='v'&&returnType[0]!='@'){if(error)*error=@"仅支持返回 void 或对象的方法";return nil;}
 NSString *key=[NSString stringWithFormat:@"%@|%@",className,selectorName];
 @synchronized(self){if(self.traceHooks[key]){if(error)*error=@"该方法已在追踪中";return nil;}}
 IMP original=method_getImplementation(method);const char *types=method_getTypeEncoding(method);
 __weak typeof(self) weakSelf=self;
 typedef void (*AXV0)(id,SEL);typedef void (*AXV1)(id,SEL,id);typedef void (*AXV2)(id,SEL,id,id);typedef void (*AXV3)(id,SEL,id,id,id);
 typedef id (*AXI0)(id,SEL);typedef id (*AXI1)(id,SEL,id);typedef id (*AXI2)(id,SEL,id,id);typedef id (*AXI3)(id,SEL,id,id,id);
 IMP replacement=nil;
 if(returnType[0]=='v'){
  if(argumentCount==0)replacement=imp_implementationWithBlock(^(id target,SEL cmd){[weakSelf recordTrace:key values:@[] result:nil];((AXV0)original)(target,cmd);});
  else if(argumentCount==1)replacement=imp_implementationWithBlock(^(id target,SEL cmd,id a){[weakSelf recordTrace:key values:@[a?:NSNull.null] result:nil];((AXV1)original)(target,cmd,a);});
  else if(argumentCount==2)replacement=imp_implementationWithBlock(^(id target,SEL cmd,id a,id b){[weakSelf recordTrace:key values:@[a?:NSNull.null,b?:NSNull.null] result:nil];((AXV2)original)(target,cmd,a,b);});
  else replacement=imp_implementationWithBlock(^(id target,SEL cmd,id a,id b,id c){[weakSelf recordTrace:key values:@[a?:NSNull.null,b?:NSNull.null,c?:NSNull.null] result:nil];((AXV3)original)(target,cmd,a,b,c);});
 } else {
  if(argumentCount==0)replacement=imp_implementationWithBlock(^id(id target,SEL cmd){id result=((AXI0)original)(target,cmd);[weakSelf recordTrace:key values:@[] result:result];return result;});
  else if(argumentCount==1)replacement=imp_implementationWithBlock(^id(id target,SEL cmd,id a){id result=((AXI1)original)(target,cmd,a);[weakSelf recordTrace:key values:@[a?:NSNull.null] result:result];return result;});
  else if(argumentCount==2)replacement=imp_implementationWithBlock(^id(id target,SEL cmd,id a,id b){id result=((AXI2)original)(target,cmd,a,b);[weakSelf recordTrace:key values:@[a?:NSNull.null,b?:NSNull.null] result:result];return result;});
  else replacement=imp_implementationWithBlock(^id(id target,SEL cmd,id a,id b,id c){id result=((AXI3)original)(target,cmd,a,b,c);[weakSelf recordTrace:key values:@[a?:NSNull.null,b?:NSNull.null,c?:NSNull.null] result:result];return result;});
 }
 if(!replacement){if(error)*error=@"无法创建方法追踪实现";return nil;}
 class_replaceMethod(cls,selector,replacement,types);
 NSDictionary *hook=@{@"class":className,@"selector":selectorName,@"original":[NSValue valueWithPointer:(void *)original],@"replacement":[NSValue valueWithPointer:(void *)replacement],@"types":[NSString stringWithUTF8String:types]?:@""};
 @synchronized(self){self.traceHooks[key]=hook;}
 NSUInteger generation=++self.traceGeneration;
 __weak typeof(self) weak= self;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(600*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
  FLEXAiFlexRuntime *strong=weak;
  if(strong&&strong.traceGeneration==generation)[strong stopTraceWithClass:nil selector:nil];
 });
 return @{@"tracing":@YES,@"class":className,@"selector":selectorName,@"arguments":@(argumentCount),@"returnType":[NSString stringWithUTF8String:returnType]?:@"?",@"autoStopSeconds":@600};
}

- (NSDictionary *)execute:(NSString *)operation arguments:(NSDictionary *)arguments error:(NSString **)error {
 NSAssert(NSThread.isMainThread,@"FLEX runtime must run on main thread");
 if (![operation isKindOfClass:NSString.class] || ![arguments isKindOfClass:NSDictionary.class]) { if(error)*error=@"命令格式错误"; return nil; }
 if([operation isEqual:@"tool_catalog"])return @{@"tools":[self toolCatalog],@"arbitraryMethodInvocation":@YES};
 if([operation isEqual:@"gesture_capabilities"])return [FLEXAiFlexTouchDriver backendCapabilities];
 if([operation isEqual:@"invoke_method"]){
  NSDictionary *result=[self invokeMethod:arguments error:error];
  return result;
 }
 if([operation isEqual:@"input_text"]){
  NSString *identifier=arguments[@"id"],*text=arguments[@"text"];UIView *view=[identifier isKindOfClass:NSString.class]?[self.views objectForKey:identifier]:nil;
  if(![text isKindOfClass:NSString.class]||text.length>4096||![self isVisibleInput:view]||(![view isKindOfClass:UITextField.class]&&![view isKindOfClass:UITextView.class])){if(error)*error=@"仅能输入当前目标 App 的可见文本框（最多 4096 字符）";return nil;}
  id<UITextInput,UIKeyInput> input=(id)view;
  if(input.secureTextEntry){if(error)*error=@"安全文本框不开放给自动输入";return nil;}
  if([view isKindOfClass:UITextField.class]&&(!((UITextField *)view).enabled||!((UITextField *)view).userInteractionEnabled)){if(error)*error=@"文本框未启用";return nil;}
  if([view isKindOfClass:UITextView.class]&&!((UITextView *)view).editable){if(error)*error=@"文本视图不可编辑";return nil;}
  UITextRange *range=[arguments[@"replace"] boolValue]?[input textRangeFromPosition:input.beginningOfDocument toPosition:input.endOfDocument]:input.selectedTextRange;
  if(!range)range=[input textRangeFromPosition:input.endOfDocument toPosition:input.endOfDocument];
  NSRange edit=NSMakeRange([input offsetFromPosition:input.beginningOfDocument toPosition:range.start],[input offsetFromPosition:range.start toPosition:range.end]);
  if([view isKindOfClass:UITextField.class]){UITextField *field=(id)view;if([field.delegate respondsToSelector:@selector(textField:shouldChangeCharactersInRange:replacementString:)]&&![field.delegate textField:field shouldChangeCharactersInRange:edit replacementString:text]){if(error)*error=@"目标文本框的原生校验拒绝该输入";return nil;}}
  else{UITextView *field=(id)view;if([field.delegate respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]&&![field.delegate textView:field shouldChangeTextInRange:edit replacementText:text]){if(error)*error=@"目标文本视图的原生校验拒绝该输入";return nil;}}
  [input replaceRange:range withText:text];
  if([view isKindOfClass:UITextField.class])[(UITextField *)view sendActionsForControlEvents:UIControlEventEditingChanged];
  return @{@"inserted":@YES,@"characters":@(text.length),@"requeryRequired":@YES};
 }
 if([operation isEqual:@"set_control_value"]){
  NSString *identifier=arguments[@"id"];UIView *view=[identifier isKindOfClass:NSString.class]?[self.views objectForKey:identifier]:nil;
  if(![view isKindOfClass:UIControl.class]||![self isVisibleInput:view]||!((UIControl *)view).enabled){if(error)*error=@"控件已离开当前页面或未启用";return nil;}
  UIControl *control=(id)view;id value=arguments[@"value"],index=arguments[@"index"],enabled=arguments[@"enabled"];
  if([control isKindOfClass:UISwitch.class]&&[enabled isKindOfClass:NSNumber.class])[(UISwitch *)control setOn:[enabled boolValue] animated:NO];
  else if([control isKindOfClass:UISegmentedControl.class]&&[index isKindOfClass:NSNumber.class]&&[index integerValue]>=0&&[index integerValue]<((UISegmentedControl *)control).numberOfSegments&&[(UISegmentedControl *)control isEnabledForSegmentAtIndex:[index integerValue]])((UISegmentedControl *)control).selectedSegmentIndex=[index integerValue];
  else if([control isKindOfClass:UISlider.class]&&[value isKindOfClass:NSNumber.class]&&isfinite([value doubleValue])&&[value doubleValue]>=((UISlider *)control).minimumValue&&[value doubleValue]<=((UISlider *)control).maximumValue)[(UISlider *)control setValue:[value floatValue] animated:NO];
  else if([control isKindOfClass:UIStepper.class]&&[value isKindOfClass:NSNumber.class]&&isfinite([value doubleValue])&&[value doubleValue]>=((UIStepper *)control).minimumValue&&[value doubleValue]<=((UIStepper *)control).maximumValue)((UIStepper *)control).value=[value doubleValue];
  else{if(error)*error=@"仅支持开关 enabled、分段控件 index、滑块/步进器 value，且值必须在原生范围内";return nil;}
  [control sendActionsForControlEvents:UIControlEventValueChanged];return @{@"updated":@YES,@"requeryRequired":@YES};
 }
 if([operation isEqual:@"class_header"]){
  NSString *name=arguments[@"name"];id start=arguments[@"start_line"]?:@1,count=arguments[@"line_count"]?:@100;
  if(![name isKindOfClass:NSString.class]||name.length>200||!objc_getClass(name.UTF8String)||![start isKindOfClass:NSNumber.class]||![count isKindOfClass:NSNumber.class]||[start integerValue]<1||[count integerValue]<1||[count integerValue]>120){if(error)*error=@"类名或头文件分页参数无效";return nil;}
  NSString *header=[UCClassDumpTool headerForClassName:name];if(!header.length){if(error)*error=@"该类未能生成头文件";return nil;}
  NSArray *lines=[header componentsSeparatedByString:@"\n"];NSUInteger offset=MIN([start unsignedIntegerValue]-1,lines.count),length=MIN([count unsignedIntegerValue],lines.count-offset);NSString *text=[[lines subarrayWithRange:NSMakeRange(offset,length)] componentsJoinedByString:@"\n"];
  if([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>96*1024){if(error)*error=@"单页头文件过大，请减小 line_count";return nil;}
  return @{@"class":name,@"text":text,@"start_line":@(offset+1),@"total_lines":@(lines.count),@"next_line":offset+length<lines.count?@(offset+length+1):NSNull.null};
 }
 if([operation isEqual:@"flex_ui_state"]){
  UIViewController *controller=[self flexVisibleController];if(!controller){if(error)*error=@"请先 minimize_chat 或 open_tool；当前 FLEX 功能页不可见";return nil;}
  UIWindow *window=FLEXManager.sharedManager.explorerWindow;NSMutableArray *elements=[NSMutableArray new];NSUInteger scanned=0;
  [self screenElementsInView:controller.view window:window items:elements scanned:&scanned];
  NSMutableArray *rows=[NSMutableArray new];UITableView *table=[self tableInController:controller];
  for(NSIndexPath *path in [table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]){
   UITableViewCell *cell=[table cellForRowAtIndexPath:path];NSMutableArray *texts=[NSMutableArray new];NSUInteger n=0;[self collectScreenTexts:cell window:window items:texts scanned:&n];
   [rows addObject:@{@"id":[self registerView:cell],@"section":@(path.section),@"row":@(path.row),@"text":[texts componentsJoinedByString:@" · "],@"selectSupported":@([self allowsRowSelection:controller])}];
  }
  NSMutableArray *texts=[NSMutableArray new];NSUInteger textScanned=0;[self collectScreenTexts:controller.view window:window items:texts scanned:&textScanned];
  return @{@"surface":@"flex",@"controller":DXClass(controller),@"title":controller.title?:@"",@"texts":texts,@"textsAreSummaries":@YES,@"elements":[elements subarrayWithRange:NSMakeRange(0,MIN(100,elements.count))],@"truncated":@(elements.count>100||scanned>=1500),@"visibleRows":rows,@"canGoBack":@(controller.navigationController.viewControllers.count>1)};
 }
 if([operation isEqual:@"select_row"]){
  UIViewController *controller=[self flexVisibleController];id section=arguments[@"section"],row=arguments[@"row"];
  UITableView *table=[self tableInController:controller];
  if(![self allowsRowSelection:controller]||!table||![section isKindOfClass:NSNumber.class]||![row isKindOfClass:NSNumber.class]||[section integerValue]<0||[row integerValue]<0){if(error)*error=@"仅支持已验证的类/方法列表导航；对象方法行请用 invoke_method 调用";return nil;}
  NSIndexPath *path=[NSIndexPath indexPathForRow:[row integerValue] inSection:[section integerValue]];
  NSString *identifier=arguments[@"id"];
  if(![identifier isKindOfClass:NSString.class]||[self.views objectForKey:identifier]!=[table cellForRowAtIndexPath:path]||![table.indexPathsForVisibleRows containsObject:path]||![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]){if(error)*error=@"列表行 ID 已过期或离开可见范围，请重新读取 flex_ui_state";return nil;}
  [table.delegate tableView:table didSelectRowAtIndexPath:path];return @{@"selected":@YES,@"requeryRequired":@YES};
 }
 if([operation isEqual:@"set_search"]){
  UIViewController *controller=[self flexVisibleController];NSString *query=arguments[@"query"];
  if(!controller||![query isKindOfClass:NSString.class]||query.length>200){if(error)*error=@"搜索文本无效或 FLEX 功能页不可见";return nil;}
  UISearchBar *bar=controller.navigationItem.searchController.searchBar;
  NSMutableArray *pending=[NSMutableArray arrayWithObject:controller.view];while(!bar&&pending.count){UIView *v=pending.lastObject;[pending removeLastObject];if([v isKindOfClass:UISearchBar.class])bar=(UISearchBar *)v;else [pending addObjectsFromArray:v.subviews];}
  if(!bar){if(error)*error=@"当前 FLEX 页没有原生搜索栏";return nil;}
  bar.text=query;id<UISearchBarDelegate> delegate=bar.delegate;if([delegate respondsToSelector:@selector(searchBar:textDidChange:)])[delegate searchBar:bar textDidChange:query];
  [bar resignFirstResponder];return @{@"searched":@YES,@"query":query,@"requeryRequired":@YES};
 }
 if ([operation isEqual:@"capabilities"]) return @{@"read":@[@"capabilities",@"report",@"gesture_capabilities",@"tool_catalog",@"chat_status",@"current",@"screen_elements",@"screen_texts",@"find_text",@"wait_for",@"controller_stack",@"app_info",@"device_info",@"hit_test",@"view_tree",@"object_info",@"object_properties",@"find_instances",@"select_object",@"class_search",@"class_info",@"runtime_images",@"network_list",@"network_search",@"cookies_list",@"sandbox_list",@"defaults_keys",@"snapshot"],@"approvalRequired":@[@"class_header",@"input_text",@"set_control_value",@"flex_ui_state",@"minimize_chat",@"restore_chat",@"open_tool",@"navigate_back",@"dismiss_tool",@"select_row",@"set_search",@"flex_scroll",@"capture_screen",@"network_detail",@"network_export",@"sandbox_read",@"sandbox_grep",@"defaults_get",@"keychain_list",@"activate_control",@"tap_text",@"scroll_to_text",@"highlight_element",@"scroll_view",@"set_view",@"set_network_recording",@"undo",@"invoke_method",@"gesture"],@"gestureBackend":[FLEXAiFlexTouchDriver backendCapabilities],@"networkRecordingEnabled":@(FLEXNetworkObserver.isEnabled),@"limits":@{@"viewNodes":@120,@"screenElements":@100,@"screenshotBytes":@(120*1024),@"networkRecords":@50,@"fileBytes":@524288,@"fileDefaultBytes":@131072,@"filePagination":@YES,@"fileTail":@YES,@"resultBytes":@4194304,@"traceEvents":@500,@"traceMethods":@8},@"arbitraryMethodInvocation":@YES};
 if([operation isEqual:@"find_text"])return [self findText:arguments error:error];
 if([operation isEqual:@"controller_stack"]){NSDictionary *stack=[self controllerStack];if(!stack){if(error)*error=@"当前没有可见窗口";return nil;}return stack;}
 if([operation isEqual:@"app_info"])return [self appInfo];
 if([operation isEqual:@"device_info"])return [self deviceInfo];
 if([operation isEqual:@"screen_texts"])return [self screenTexts:arguments error:error];
 if([operation isEqual:@"object_properties"])return [self objectProperties:arguments error:error];
 if([operation isEqual:@"network_search"])return [self networkSearch:arguments error:error];
 if([operation isEqual:@"snapshot"])return [self snapshot:arguments error:error];
 if([operation isEqual:@"sandbox_grep"])return [self sandboxGrep:arguments error:error];
 if([operation isEqual:@"network_export"])return [self networkExport:arguments error:error];
 if([operation isEqual:@"highlight_element"])return [self highlightElement:arguments error:error];
 if ([operation isEqual:@"capture_screen"]) {
  BOOL flex=[arguments[@"surface"] isEqual:@"flex"];
  if(flex&&![self flexVisibleController]){if(error)*error=@"FLEX 功能页不可见，请先收起会话并打开工具页";return nil;}
  NSMutableDictionary *result=[[self captureWindow:flex?FLEXManager.sharedManager.explorerWindow:[self window] rect:arguments[@"rect"] error:error] mutableCopy];
  if(result)result[@"scope"]=flex?@"flex_window":@"target_app_window";return result;
 }
 if ([operation isEqual:@"screen_elements"]) {
  UIWindow *window=[self window];if(!window){if(error)*error=@"当前没有可见窗口";return nil;}
  id rawOffset=arguments[@"offset"]?:@0;if(![rawOffset isKindOfClass:NSNumber.class]||[rawOffset integerValue]<0||[rawOffset integerValue]>1200){if(error)*error=@"元素分页偏移无效";return nil;}
  NSMutableArray *items=[NSMutableArray new];NSUInteger scanned=0;[self screenElementsInView:window window:window items:items scanned:&scanned];
  NSUInteger offset=MIN([rawOffset unsignedIntegerValue],items.count),count=MIN(100,items.count-offset);NSUInteger next=offset+count;
  return @{@"elements":[items subarrayWithRange:NSMakeRange(offset,count)],@"offset":@(offset),@"nextOffset":next<items.count?@(next):NSNull.null,@"total":@(items.count),@"scanned":@(scanned),@"truncated":@(scanned>=1500||items.count>=1200),@"windowBounds":NSStringFromCGRect(window.bounds)};
 }
 if ([operation isEqual:@"hit_test"]) {
  UIWindow *window=[self window];id x=arguments[@"x"],y=arguments[@"y"];
  if(!window||![x isKindOfClass:NSNumber.class]||![y isKindOfClass:NSNumber.class]||!isfinite([x doubleValue])||!isfinite([y doubleValue])||![window pointInside:CGPointMake([x doubleValue],[y doubleValue]) withEvent:nil]){if(error)*error=@"坐标不在当前目标窗口内";return nil;}
  UIView *view=[window hitTest:CGPointMake([x doubleValue],[y doubleValue]) withEvent:nil];
  return @{@"hitView":[self objectInfo:view],@"interactiveAncestor":view?[self interactiveAncestorForView:view]:@{@"available":@NO},@"windowBounds":NSStringFromCGRect(window.bounds)};
 }
 if ([operation isEqual:@"report"]) {
  NSString *base=[self.contextReport copy]?:@"";
  NSDictionary *live=[self execute:@"current" arguments:@{} error:nil]?:@{};
  NSData *data=[NSJSONSerialization dataWithJSONObject:live options:0 error:nil];
  NSString *liveText=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:@"";
  NSString *name=self.contextClassName.length?self.contextClassName:(live[@"selectedObject"][@"class"]?:@"未知对象");
  if(!base.length){
   base=[NSString stringWithFormat:@"App: %@\nCurrent FLEX selection: %@\nUse this runtime evidence to locate the UI owner and implement the requested behavior in the AiFlex3 plugin project. A temporary FLEX view change is not a plugin implementation.",
    NSBundle.mainBundle.bundleIdentifier?:@"unknown",name?:@"当前宿主"];
  }
  NSString *text=[NSString stringWithFormat:@"%@\nCurrent FLEX runtime: %@",base,liveText?:@""];
  if(text.length>16000)text=[text substringToIndex:16000];
  return @{@"bundleID":NSBundle.mainBundle.bundleIdentifier?:@"unknown",@"className":name,@"report":text};
 }
 if ([operation isEqual:@"current"]) {
  UIWindow *window=[self window];NSMutableArray *path=[NSMutableArray new],*texts=[NSMutableArray new];NSUInteger scanned=0;
  UIViewController *controller=[self visibleControllerInWindow:window path:path];[self collectScreenTexts:window window:window items:texts scanned:&scanned];
  UIView *selected=[self.selectedObject isKindOfClass:UIView.class]?self.selectedObject:nil;
  return @{@"bundleID":NSBundle.mainBundle.bundleIdentifier?:@"",@"visibleController":DXClass(controller),@"controllerPath":path,@"screenTexts":texts,@"screenTextTruncated":@(texts.count>=60||scanned>=1200),@"selectedObject":[self objectInfo:self.selectedObject],@"selectedController":selected?[self controllerForView:selected]:@"",@"selectedAncestors":selected?[self ancestorsForView:selected]:@[],@"selectedSiblings":selected?[self siblingsForView:selected]:@[],@"interactiveAncestor":selected?[self interactiveAncestorForView:selected]:@{@"available":@NO}};
 }
 if ([operation isEqual:@"view_tree"]) {
  UIWindow *window=[self window]; if(!window){if(error)*error=@"当前没有可见窗口";return nil;}
  UIView *root=window;NSString *requested=arguments[@"id"];
  if(requested){root=[self.views objectForKey:requested];if(!root||![self isAttached:root]){if(error)*error=@"视图 ID 已过期，请先重新读取 screen_elements";return nil;}}
  if(!requested)self.views=[NSMapTable strongToWeakObjectsMapTable];NSUInteger count=0;
  NSInteger requestedDepth=[arguments[@"max_depth"] integerValue];
  NSUInteger maxDepth=(requestedDepth>=1&&requestedDepth<=12)?requestedDepth:6;
  NSDictionary *tree=[self viewRow:root depth:0 count:&count maxDepth:maxDepth];
  NSString *classFilter=[arguments[@"class_filter"] isKindOfClass:NSString.class]?arguments[@"class_filter"]:nil;
  NSString *textFilter=[arguments[@"text_filter"] isKindOfClass:NSString.class]?arguments[@"text_filter"]:nil;
  BOOL interactiveOnly=[arguments[@"interactive_only"] boolValue];
  BOOL includeHidden=arguments[@"include_hidden"]?[arguments[@"include_hidden"] boolValue]:YES;
  if(classFilter.length||textFilter.length||interactiveOnly||!includeHidden){
   tree=[self filterTreeNode:tree classFilter:classFilter textFilter:textFilter interactiveOnly:interactiveOnly includeHidden:includeHidden maxDepth:maxDepth];
  }
  if(!tree){if(error)*error=@"过滤后没有匹配的视图，请放宽 class_filter / text_filter 或关闭 interactive_only";return nil;}
  UIView *selected=[self.selectedObject isKindOfClass:UIView.class]?self.selectedObject:nil;
  NSString *selectedID=selected?[self.viewIDs objectForKey:selected]:nil;BOOL selectedInTree=selectedID&&[self.views objectForKey:selectedID]==selected;
  return @{@"tree":tree,@"count":@(count),@"truncated":@(count>=120),@"selectedObject":[self objectInfo:self.selectedObject],@"selectedInTree":@(selectedInTree),@"selectedAncestors":selected?[self ancestorsForView:selected]:@[],@"selectedSiblings":selected?[self siblingsForView:selected]:@[],@"interactiveAncestor":selected?[self interactiveAncestorForView:selected]:@{@"available":@NO}};
 }
 if ([operation isEqual:@"select_object"] || [operation isEqual:@"object_info"]) {
  id object=arguments[@"id"]?[self objectForIdentifier:arguments[@"id"]]:self.selectedObject;
  if (!object) {if(error)*error=@"对象已释放或不在当前视图树中";return nil;}
  if ([operation isEqual:@"select_object"]) self.selectedObject=object;
  NSMutableDictionary *info=[[self objectInfo:object] mutableCopy];
  NSString *identifier=[self registerObject:object];
  if(identifier)info[@"id"]=identifier;
  return info;
 }
 if ([operation isEqual:@"class_search"]) {
  NSString *query=arguments[@"query"];if(![query isKindOfClass:NSString.class]||query.length<2||query.length>100){if(error)*error=@"类名查询长度应为 2–100";return nil;}
  unsigned int total=0;Class *classes=objc_copyClassList(&total);NSMutableArray *matches=[NSMutableArray new];
  for(unsigned int i=0;i<total&&matches.count<60;i++){NSString *name=NSStringFromClass(classes[i]);if([name rangeOfString:query options:NSCaseInsensitiveSearch].location!=NSNotFound)[matches addObject:name];}free(classes);
  return @{@"classes":matches,@"truncated":@(matches.count==60)};
 }
 if ([operation isEqual:@"class_info"]) {
  NSString *name=arguments[@"name"];if(![name isKindOfClass:NSString.class]||name.length>200){if(error)*error=@"类名无效";return nil;}
  Class cls=objc_getClass(name.UTF8String);if(!cls){if(error)*error=@"类不存在";return nil;}
  NSMutableArray *methods=[NSMutableArray new],*properties=[NSMutableArray new];unsigned int count=0;Method *list=class_copyMethodList(cls,&count);
  for(unsigned int i=0;i<count&&i<100;i++)[methods addObject:@{@"selector":NSStringFromSelector(method_getName(list[i])),@"encoding":DXShort([NSString stringWithUTF8String:method_getTypeEncoding(list[i])?:""],120)}];free(list);
  objc_property_t *props=class_copyPropertyList(cls,&count);for(unsigned int i=0;i<count&&i<100;i++)[properties addObject:[NSString stringWithUTF8String:property_getName(props[i])]];free(props);
  return @{@"class":name,@"superclass":class_getSuperclass(cls)?NSStringFromClass(class_getSuperclass(cls)):@"",@"methods":methods,@"properties":properties};
 }
 if ([operation isEqual:@"find_instances"]) return [self findInstances:arguments error:error];
 if ([operation isEqual:@"runtime_images"]) {
  NSString *query=arguments[@"query"]?:@"";if(![query isKindOfClass:NSString.class]||query.length>100){if(error)*error=@"镜像查询无效";return nil;}
  unsigned int count=0;const char **images=objc_copyImageNames(&count);NSMutableArray *matches=[NSMutableArray new];
  for(unsigned int i=0;i<count&&matches.count<100;i++){NSString *name=[NSString stringWithUTF8String:images[i]?:""];if(!query.length||[name rangeOfString:query options:NSCaseInsensitiveSearch].location!=NSNotFound)[matches addObject:DXShort(name,512)];}free(images);
  return @{@"images":matches,@"truncated":@(matches.count==100)};
 }
 if ([operation isEqual:@"network_list"] || [operation isEqual:@"network_detail"]) {
  NSArray<FLEXHTTPTransaction *> *items=FLEXNetworkRecorder.defaultRecorder.HTTPTransactions;
  NSMutableArray *rows=[NSMutableArray new];NSString *target=arguments[@"id"];
  for(FLEXHTTPTransaction *item in items){if([operation isEqual:@"network_detail"]&&![item.requestID isEqual:target])continue;
   NSURL *url=item.request.URL;NSString *path=DXShort(url.path,240);NSMutableDictionary *row=[@{@"id":item.requestID?:@"",@"host":url.host?:@"",@"path":path,@"method":item.request.HTTPMethod?:@"GET",@"state":@(item.state),@"receivedBytes":@(item.receivedDataLength),@"startedAt":@(item.startTime.timeIntervalSince1970)} mutableCopy];
   if ([item.response isKindOfClass:NSHTTPURLResponse.class]) row[@"status"]=@(((NSHTTPURLResponse *)item.response).statusCode);
   if ([operation isEqual:@"network_detail"]) {
    row[@"url"]=DXShort(url.absoluteString,2048);
    row[@"requestContentType"]=DXShort([item.request valueForHTTPHeaderField:@"Content-Type"],120);
    row[@"responseContentType"]=DXShort(item.response.MIMEType,120);
    row[@"requestBody"]=DXBody(item.cachedRequestBody);
    row[@"responseBody"]=DXBody([FLEXNetworkRecorder.defaultRecorder cachedResponseBodyForTransaction:item]);
   }
   [rows addObject:row];if([operation isEqual:@"network_detail"]||rows.count>=50)break;
  }
  if([operation isEqual:@"network_detail"]&&!rows.count){if(error)*error=@"网络记录已过期";return nil;}
  return [operation isEqual:@"network_detail"]?rows.firstObject:@{@"transactions":rows,@"truncated":@(items.count>rows.count),@"recordingEnabled":@(FLEXNetworkObserver.isEnabled)};
 }
 if ([operation isEqual:@"cookies_list"]) {
  NSArray<NSHTTPCookie *> *cookies=NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies?:@[];NSMutableArray *items=[NSMutableArray new];
  for(NSHTTPCookie *cookie in cookies){if(items.count>=100)break;[items addObject:@{@"name":DXShort(cookie.name,120),@"domain":DXShort(cookie.domain,240),@"path":DXShort(cookie.path,120),@"secure":@(cookie.isSecure),@"expiresAt":cookie.expiresDate?@(cookie.expiresDate.timeIntervalSince1970):NSNull.null}];}
  return @{@"cookies":items,@"truncated":@(cookies.count>items.count),@"valuesIncluded":@NO};
 }
 if ([operation isEqual:@"sandbox_list"]) {
  NSString *relative=arguments[@"path"]?:@"";NSString *path=[self safePath:relative directory:YES];if(!path){if(error)*error=@"目录不在当前 App 沙盒内";return nil;}
  NSArray *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];NSMutableArray *items=[NSMutableArray new];
  for(NSString *name in names){if(items.count>=100)break;NSString *child=[path stringByAppendingPathComponent:name];NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:child error:nil];[items addObject:@{@"name":name,@"directory":@([attrs[NSFileType] isEqual:NSFileTypeDirectory]),@"size":attrs[NSFileSize]?:@0}];}
  return @{@"path":relative,@"items":items,@"truncated":@(names.count>items.count)};
 }
 if ([operation isEqual:@"sandbox_read"]) {
  NSString *relative=arguments[@"path"],*path=[self safePath:relative directory:NO];
  if(!path){if(error)*error=@"文件不存在或不在当前 App 沙盒内";return nil;}
  for(NSString *key in @[@"offset",@"limit"]){id n=arguments[key];if(n&&(![n isKindOfClass:NSNumber.class]||!isfinite([n doubleValue])||[n doubleValue]<0||floor([n doubleValue])!=[n doubleValue]||[n doubleValue]>9007199254740991.0)){if(error)*error=@"offset / limit 必须是非负整数字节数";return nil;}}
  NSUInteger limit=arguments[@"limit"]?[arguments[@"limit"] unsignedIntegerValue]:128*1024;
  if(!limit||limit>512*1024){if(error)*error=@"单次读取范围为 1–524288 字节；更大文件请分页读取";return nil;}
  if(arguments[@"tail"]&&![arguments[@"tail"] isKindOfClass:NSNumber.class]){if(error)*error=@"tail 必须是布尔值";return nil;}
  if([arguments[@"tail"] boolValue]&&arguments[@"offset"]){if(error)*error=@"tail 与 offset 不能同时使用";return nil;}
  NSError *failure=nil;NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:&failure];
  if(!file){if(error)*error=@"文件无法打开";return nil;}
  unsigned long long size=0,start=0;NSData *data=nil;
  @try{size=[file seekToEndOfFile];start=[arguments[@"tail"] boolValue]?(size>limit?size-limit:0):[arguments[@"offset"] unsignedLongLongValue];
   if(start>size){[file closeFile];if(error)*error=@"offset 超过文件大小，文件可能已轮转或截短；请重新读取末尾";return nil;}
   [file seekToFileOffset:start];data=[file readDataOfLength:(NSUInteger)MIN((unsigned long long)limit,size-start)];[file closeFile];
  }@catch(NSException *exception){[file closeFile];if(error)*error=@"文件读取失败，请重新列出并读取";return nil;}
  // Byte cursors remain lossless across UTF-8 page boundaries. A tail/explicit
  // offset may begin inside a character; skip only its continuation bytes.
  const unsigned char *bytes=data.bytes;NSUInteger head=0,length=data.length;
  if(start)while(head<MIN((NSUInteger)3,length)&&(bytes[head]&0xc0)==0x80)head++;
  NSString *value=nil;NSUInteger used=length-head;
  for(NSUInteger trim=0;trim<=MIN((NSUInteger)3,length-head);trim++){
   if(trim&&start+length>=size)break;
   used=length-head-trim;value=[[NSString alloc]initWithBytes:bytes+head length:used encoding:NSUTF8StringEncoding];if(value)break;
  }
  if(!value){if(error)*error=@"该范围不是有效 UTF-8 文本；请选择文本日志";return nil;}
  unsigned long long next=start+head+used;
  if(next==start&&next<size){if(error)*error=@"读取范围太小，无法容纳完整 UTF-8 字符；请增大 limit";return nil;}
  return @{@"path":relative,@"text":value,@"totalBytes":@(size),@"offset":@(start+head),@"bytesRead":@(used),@"next_offset":@(next),@"has_more":@(next<size),@"truncated":@(start+head>0||next<size),@"tail":@([arguments[@"tail"] boolValue]),@"modifiedAt":@([[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate] timeIntervalSince1970])};
 }
 if ([operation isEqual:@"defaults_keys"]) {
  NSArray *keys=[[NSUserDefaults.standardUserDefaults dictionaryRepresentation].allKeys sortedArrayUsingSelector:@selector(compare:)];return @{@"keys":[keys subarrayWithRange:NSMakeRange(0,MIN(keys.count,100))],@"truncated":@(keys.count>100)};
 }
 if ([operation isEqual:@"defaults_get"]) {
  NSString *key=arguments[@"key"];if(![key isKindOfClass:NSString.class]||key.length>200){if(error)*error=@"设置键无效";return nil;}
  id value=[NSUserDefaults.standardUserDefaults objectForKey:key];if(!value){if(error)*error=@"设置键不存在";return nil;}
  NSString *description=DXShort([value description],16000);return @{@"key":key,@"type":DXClass(value),@"value":description,@"truncated":@([value description].length>16000)};
 }
 if ([operation isEqual:@"keychain_list"]) {
  NSError *failure=nil;NSArray *accounts=[FLEXKeychain allAccounts:&failure];if(failure){if(error)*error=failure.localizedDescription;return nil;}
  NSMutableArray *items=[NSMutableArray new];for(NSDictionary *account in accounts){if(items.count>=50)break;
   [items addObject:@{@"account":DXShort(account[kFLEXKeychainAccountKey],160),@"service":DXShort(account[kFLEXKeychainWhereKey],160),@"group":DXShort(account[kFLEXKeychainGroupKey],160),@"class":DXShort(account[kFLEXKeychainClassKey],80)}];
  }return @{@"accounts":items,@"truncated":@(accounts.count>items.count),@"secretValuesIncluded":@NO};
 }
 if ([operation isEqual:@"activate_control"]) {
  NSString *identifier=arguments[@"id"];UIView *view=[identifier isKindOfClass:NSString.class]?[self.views objectForKey:identifier]:nil;
  if(![view isKindOfClass:UIButton.class]||![self isAttached:view]||view.hidden||view.alpha<0.01||!((UIControl *)view).enabled){if(error)*error=@"仅可激活当前页面可见且启用的 UIButton；请重新读取视图 ID";return nil;}
  UIWindow *window=[self window];CGRect frame=[view convertRect:view.bounds toView:window];
  if(CGRectIsEmpty(frame)||!CGRectIntersectsRect(frame,window.bounds)){if(error)*error=@"按钮不在可见窗口范围内";return nil;}
  NSString *oldController=DXClass([self visibleControllerInWindow:window path:[NSMutableArray new]]);
  [(UIButton *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
  UIViewController *current=[self visibleControllerInWindow:window path:[NSMutableArray new]];
  return @{@"activated":@YES,@"id":identifier,@"previousController":oldController,@"currentController":DXClass(current),@"requeryRequired":@YES};
 }
 if ([operation isEqual:@"scroll_view"]||[operation isEqual:@"flex_scroll"]) {
  NSString *identifier=arguments[@"id"],*direction=arguments[@"direction"];id pages=arguments[@"pages"];
  UIView *view=[identifier isKindOfClass:NSString.class]?[self.views objectForKey:identifier]:nil;
  UIViewController *flex=[operation isEqual:@"flex_scroll"]?[self flexVisibleController]:nil;
  BOOL attached=[operation isEqual:@"flex_scroll"]?flex&&[view isDescendantOfView:flex.view]:[self isAttached:view];
  if(![view isKindOfClass:UIScrollView.class]||!attached||view.hidden||view.alpha<0.01||![@[@"up",@"down",@"left",@"right"] containsObject:direction]||![pages isKindOfClass:NSNumber.class]||!isfinite([pages doubleValue])||[pages doubleValue]<=0||[pages doubleValue]>2){if(error)*error=@"滚动参数无效或目标 UIScrollView 已离开当前页面";return nil;}
  UIScrollView *scroll=(UIScrollView *)view;CGPoint previous=scroll.contentOffset,target=previous;BOOL horizontal=[direction isEqual:@"left"]||[direction isEqual:@"right"];CGFloat distance=(horizontal?scroll.bounds.size.width:scroll.bounds.size.height)*[pages doubleValue];
  if([direction isEqual:@"up"])target.y-=distance;else if([direction isEqual:@"down"])target.y+=distance;else if([direction isEqual:@"left"])target.x-=distance;else target.x+=distance;
  UIEdgeInsets inset=scroll.contentInset;if(@available(iOS 11.0,*))inset=scroll.adjustedContentInset;
  CGFloat minX=-inset.left,maxX=MAX(minX,scroll.contentSize.width-scroll.bounds.size.width+inset.right),minY=-inset.top,maxY=MAX(minY,scroll.contentSize.height-scroll.bounds.size.height+inset.bottom);
  if(horizontal)target.x=MAX(minX,MIN(target.x,maxX));else target.y=MAX(minY,MIN(target.y,maxY));
  [scroll setContentOffset:target animated:NO];
  CGPoint actual=scroll.contentOffset,delta=CGPointMake(actual.x-previous.x,actual.y-previous.y);BOOL moved=fabs(horizontal?delta.x:delta.y)>.01;
  BOOL boundary=[direction isEqual:@"up"]?actual.y<=minY+.01:[direction isEqual:@"down"]?actual.y>=maxY-.01:[direction isEqual:@"left"]?actual.x<=minX+.01:actual.x>=maxX-.01;
  return @{@"scrolled":@(moved),@"id":identifier,@"previousOffset":NSStringFromCGPoint(previous),@"contentOffset":NSStringFromCGPoint(actual),@"delta":@{@"x":@(delta.x),@"y":@(delta.y)},@"reachedBoundary":@(boundary),@"reason":moved?@"moved":boundary?@"boundary":@"no_movement",@"requeryRequired":@YES};
 }
 if ([operation isEqual:@"set_view"]) {
  NSString *identifier=arguments[@"id"];UIView *view=[identifier isKindOfClass:NSString.class]?[self.views objectForKey:identifier]:nil;if(!view){if(error)*error=@"视图 ID 已过期；请读取 current.selectedObject 或 view_tree 获取当前 ID";return nil;}
  if(![self isAttached:view]){if(error)*error=@"视图已离开当前页面；请在 FLEX 中重新选择目标";return nil;}
  id hidden=arguments[@"hidden"],alpha=arguments[@"alpha"];
  if ((!hidden&&!alpha)||(hidden&&![hidden isKindOfClass:NSNumber.class])||(alpha&&(![alpha isKindOfClass:NSNumber.class]||!isfinite([alpha doubleValue])||[alpha doubleValue]<0||[alpha doubleValue]>1))){if(error)*error=@"仅允许设置 hidden 或 0–1 的 alpha";return nil;}
  self.undoState=@{@"kind":@"view",@"view":view,@"hidden":@(view.hidden),@"alpha":@(view.alpha)};
  if(hidden)view.hidden=[hidden boolValue];if(alpha)view.alpha=[alpha doubleValue];
  return @{@"id":identifier,@"hidden":@(view.hidden),@"alpha":@(view.alpha),@"undoAvailable":@YES};
 }
 if ([operation isEqual:@"set_network_recording"]) {
  id enabled=arguments[@"enabled"];
  if(![enabled isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)enabled)!=CFBooleanGetTypeID()){if(error)*error=@"enabled 必须为布尔值";return nil;}
  self.undoState=@{@"kind":@"network",@"enabled":@(FLEXNetworkObserver.isEnabled)};
  FLEXNetworkObserver.enabled=[enabled boolValue];
  return @{@"recordingEnabled":@(FLEXNetworkObserver.isEnabled),@"undoAvailable":@YES};
 }
 if ([operation isEqual:@"undo"]) {
  if(!self.undoState){if(error)*error=@"没有可撤销的 FLEX 修改";return nil;}
  if([self.undoState[@"kind"] isEqual:@"network"])FLEXNetworkObserver.enabled=[self.undoState[@"enabled"] boolValue];
  else {UIView *view=self.undoState[@"view"];if(!view){self.undoState=nil;if(error)*error=@"原视图已释放";return nil;}view.hidden=[self.undoState[@"hidden"] boolValue];view.alpha=[self.undoState[@"alpha"] doubleValue];}
  self.undoState=nil;return @{@"restored":@YES};
 }
 if(error)*error=@"当前版本不支持此 FLEX 操作";return nil;
}
@end
