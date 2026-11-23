#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "UCDisassembler.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, UCDisasmViewMode) {
    /// CFG 基本块图。默认视图。
    UCDisasmViewModeGraph = 0,
    /// 线性汇编列表：地址 / 机器码 / 助记符 / 注释。
    UCDisasmViewModeListing = 1,
};

@interface UCDisasmViewController : UIViewController

@property (nonatomic, assign) UCDisasmViewMode viewMode;

- (instancetype)initWithAddress:(uint64_t)address
                           size:(NSUInteger)size
                          title:(nullable NSString *)title;

- (instancetype)initWithMethod:(Method)method
                         class:(nullable NSString *)className
                      selector:(nullable NSString *)selectorName;

- (instancetype)initWithClass:(Class)cls
                     selector:(SEL)selector
               isClassMethod:(BOOL)isClassMethod;

- (instancetype)initWithFunction:(UCFunction *)function
                           title:(nullable NSString *)title;

@end

@interface UCCFGView : UIView

@property (nonatomic, strong, nullable) NSArray<UCBasicBlock *> *basicBlocks;
@property (nonatomic, copy, nullable) void (^blockTapHandler)(UCBasicBlock *block);
@property (nonatomic, strong, readonly, nullable) NSMutableDictionary<NSNumber *, UIView *> *blockViewMap;

- (void)layoutGraph;

@end

@interface UCFuncListViewController : UIViewController

- (instancetype)initWithFunctions:(NSArray<UCFunction *> *)functions;

@end

NS_ASSUME_NONNULL_END
