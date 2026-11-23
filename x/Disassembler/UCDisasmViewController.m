#import "UCDisasmViewController.h"
#import "FLEXColor.h"
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - UCDisasmViewController

@interface UCDisasmViewController () <UIScrollViewDelegate>

@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;

@property (nonatomic, strong) UCDisasmResult *disasmResult;

@property (nonatomic, assign) uint64_t startAddress;
@property (nonatomic, assign) NSUInteger codeSize;
@property (nonatomic, copy) NSString *navTitle;

/// 视图切换控件。索引与 UCDisasmViewMode 一一对应。
@property (nonatomic, strong) UISegmentedControl *modeControl;

/// 汇编列表模式。
@property (nonatomic, strong) UITextView *listingTextView;

/// CFG 图形模式。
@property (nonatomic, strong) UIScrollView *graphScrollView;
@property (nonatomic, strong) UCCFGView *cfgView;
@property (nonatomic, strong) UIView *graphStatusBar;
@property (nonatomic, strong) UILabel *graphStatusLabel;
@property (nonatomic, strong) UIButton *zoomInBtn;
@property (nonatomic, strong) UIButton *zoomOutBtn;
@property (nonatomic, strong) UIButton *zoomResetBtn;

@property (nonatomic, strong) UCFunction *currentFunction;

@end

@implementation UCDisasmViewController

#pragma mark - 初始化

- (instancetype)initWithAddress:(uint64_t)address size:(NSUInteger)size title:(NSString *)title {
    self = [super init];
    if (self) {
        _startAddress = address;
        _codeSize = size;
        _navTitle = title ?: [NSString stringWithFormat:@"0x%llx", address];
        _viewMode = UCDisasmViewModeGraph;
    }
    return self;
}

- (instancetype)initWithMethod:(Method)method class:(NSString *)className selector:(NSString *)selectorName {
    if (!method) return nil;
    
    IMP imp = method_getImplementation(method);
    NSString *title = [NSString stringWithFormat:@"%@ %@",
                       className ?: @"Unknown",
                       selectorName ?: @"unknown"];
    
    return [self initWithAddress:(uint64_t)imp size:4096 title:title];
}

- (instancetype)initWithClass:(Class)cls selector:(SEL)selector isClassMethod:(BOOL)isClassMethod {
    if (!cls || !selector) return nil;
    
    Method method = NULL;
    if (isClassMethod) {
        method = class_getClassMethod(cls, selector);
    } else {
        method = class_getInstanceMethod(cls, selector);
    }
    
    NSString *className = NSStringFromClass(cls);
    NSString *selName = NSStringFromSelector(selector);
    NSString *title = [NSString stringWithFormat:@"%@[%@ %@]",
                       isClassMethod ? @"+" : @"-",
                       className, selName];
    
    return [self initWithMethod:method class:className selector:selName];
}

- (instancetype)initWithFunction:(UCFunction *)function title:(NSString *)title {
    self = [super init];
    if (self) {
        _currentFunction = function;
        _startAddress = function.startAddress;
        _codeSize = function.size;
        _navTitle = title ?: function.name;
        _viewMode = UCDisasmViewModeGraph;
    }
    return self;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FLEXColor.primaryBackgroundColor;
    self.title = self.navTitle;
    
    [self setupNavigationBar];
    [self setupViewModeControl];
    [self setupGraphView];
    [self setupListingView];
    [self setupLoadingIndicator];
    [self applyViewMode:self.viewMode];

    [self loadDisassembly];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    CGFloat width = self.view.bounds.size.width;

    CGFloat labelH = 32;
    self.modeControl.frame = CGRectMake(10, top + 4, width - 20, labelH);

    CGFloat graphY = top + labelH + 8;
    CGFloat statusBarH = 32;
    CGFloat graphH = self.view.bounds.size.height - graphY - bottom;

    // 显隐由 applyViewMode 决定，这里只排位置，不要覆盖 hidden ——
    // 之前写死 hidden = NO 会让切到汇编列表时底部缩放条浮在文字上。
    self.graphStatusBar.frame = CGRectMake(0, self.view.bounds.size.height - bottom - statusBarH, width, statusBarH);
    self.graphScrollView.frame = CGRectMake(0, graphY, width, graphH - statusBarH);
    self.listingTextView.frame = CGRectMake(0, graphY, width, graphH);

    CGFloat btnW = 44;
    CGFloat btnH = statusBarH;
    CGFloat resetW = 52;
    self.zoomInBtn.frame = CGRectMake(width - btnW, 0, btnW, btnH);
    self.zoomResetBtn.frame = CGRectMake(width - btnW - 4 - resetW, 0, resetW, btnH);
    self.zoomOutBtn.frame = CGRectMake(width - btnW - 4 - resetW - 4 - btnW, 0, btnW, btnH);
    self.graphStatusLabel.frame = CGRectMake(12, 0, width - btnW * 2 - resetW - 24, btnH);

    self.loadingIndicator.center = CGPointMake(width / 2, graphY + graphH / 2);
}

- (void)setupNavigationBar {
    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];
    
    UIBarButtonItem *more = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self
        action:@selector(moreAction)];
    
    self.navigationItem.rightBarButtonItems = @[done, more];
}

- (void)setupViewModeControl {
    // 原来是写死 "CFG图形" 的 UILabel —— 没有任何可交互控件，
    // 也就是说"视图模式"这个概念在界面上从来不存在。
    // 这里换成真的分段控件，索引直接对应 UCDisasmViewMode。
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"CFG 图形", @"汇编"]];
    self.modeControl.selectedSegmentIndex = (NSInteger)self.viewMode;
    self.modeControl.tintColor = FLEXColor.tintColor;
    if (@available(iOS 13.0, *)) {
        self.modeControl.selectedSegmentTintColor = FLEXColor.tintColor;
    }
    [self.modeControl addTarget:self
                         action:@selector(modeChanged:)
               forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeControl];
}

- (void)modeChanged:(UISegmentedControl *)sender {
    [self applyViewMode:(UCDisasmViewMode)sender.selectedSegmentIndex];
}

- (void)applyViewMode:(UCDisasmViewMode)mode {
    _viewMode = mode;

    BOOL listing = (mode == UCDisasmViewModeListing);
    self.listingTextView.hidden = !listing;
    self.graphScrollView.hidden = listing;
    self.graphStatusBar.hidden = listing;

    if (listing) {
        [self refreshListing];
    } else if (self.currentFunction) {
        // 切回图形时重新适配缩放：列表模式下视图尺寸变过，
        // 之前算出来的 zoomScale 会错位。
        [self updateCFGView];
    }

    // 让分段控件跟上：外部改 viewMode 时界面不能停在旧状态。
    if (self.modeControl.selectedSegmentIndex != (NSInteger)mode) {
        self.modeControl.selectedSegmentIndex = (NSInteger)mode;
    }

    [self.view setNeedsLayout];
}

/// 让 viewMode 变成真正可用的入口：外部设置时同步界面。
- (void)setViewMode:(UCDisasmViewMode)viewMode {
    if (_viewMode == viewMode) return;
    [self applyViewMode:viewMode];
}

- (void)setupListingView {
    self.listingTextView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.listingTextView.editable = NO;
    self.listingTextView.selectable = YES;
    self.listingTextView.alwaysBounceVertical = YES;
    self.listingTextView.textContainerInset = UIEdgeInsetsMake(8, 8, 24, 8);
    self.listingTextView.backgroundColor = [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1.0];
    self.listingTextView.textColor = [UIColor colorWithRed:0.16 green:0.16 blue:0.20 alpha:1.0];

    UIFont *mono = [UIFont fontWithName:@"Menlo-Regular" size:11];
    if (!mono) {
        if (@available(iOS 13.0, *)) {
            mono = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        } else {
            mono = [UIFont fontWithName:@"Courier" size:11];
        }
    }
    self.listingTextView.font = mono;
    self.listingTextView.text = @"反汇编加载中...";
    self.listingTextView.hidden = YES;
    [self.view addSubview:self.listingTextView];
}

- (void)setupGraphView {
    self.graphScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.graphScrollView.backgroundColor = [UIColor colorWithRed:0.85 green:0.90 blue:0.96 alpha:1.0];
    self.graphScrollView.minimumZoomScale = 0.3;
    self.graphScrollView.maximumZoomScale = 3.0;
    self.graphScrollView.delegate = self;
    self.graphScrollView.hidden = NO;
    [self.view addSubview:self.graphScrollView];
    
    self.cfgView = [[UCCFGView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    self.cfgView.blockTapHandler = ^(UCBasicBlock *block) {
        [weakSelf handleBasicBlockTap:block];
    };
    [self.graphScrollView addSubview:self.cfgView];
    
    [self setupGraphStatusBar];
}

- (void)setupGraphStatusBar {
    self.graphStatusBar = [[UIView alloc] init];
    self.graphStatusBar.backgroundColor = [UIColor colorWithRed:0.25 green:0.30 blue:0.40 alpha:0.95];
    self.graphStatusBar.layer.borderWidth = 0.5;
    self.graphStatusBar.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    [self.view addSubview:self.graphStatusBar];
    
    self.graphStatusLabel = [[UILabel alloc] init];
    self.graphStatusLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:11];
    self.graphStatusLabel.textColor = [UIColor whiteColor];
    self.graphStatusLabel.text = @"CFG: 加载中...";
    [self.graphStatusBar addSubview:self.graphStatusLabel];
    
    self.zoomOutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.zoomOutBtn setTitle:@"－" forState:UIControlStateNormal];
    [self.zoomOutBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.zoomOutBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.zoomOutBtn addTarget:self action:@selector(zoomOutAction) forControlEvents:UIControlEventTouchUpInside];
    [self.graphStatusBar addSubview:self.zoomOutBtn];
    
    self.zoomResetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.zoomResetBtn setTitle:@"100%" forState:UIControlStateNormal];
    [self.zoomResetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.zoomResetBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.zoomResetBtn addTarget:self action:@selector(zoomResetAction) forControlEvents:UIControlEventTouchUpInside];
    [self.graphStatusBar addSubview:self.zoomResetBtn];
    
    self.zoomInBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.zoomInBtn setTitle:@"＋" forState:UIControlStateNormal];
    [self.zoomInBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.zoomInBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.zoomInBtn addTarget:self action:@selector(zoomInAction) forControlEvents:UIControlEventTouchUpInside];
    [self.graphStatusBar addSubview:self.zoomInBtn];
}

- (void)zoomInAction {
    CGFloat newScale = self.graphScrollView.zoomScale * 1.2;
    if (newScale > self.graphScrollView.maximumZoomScale) {
        newScale = self.graphScrollView.maximumZoomScale;
    }
    [self.graphScrollView setZoomScale:newScale animated:YES];
    [self updateZoomLabel];
}

- (void)zoomOutAction {
    CGFloat newScale = self.graphScrollView.zoomScale / 1.2;
    if (newScale < self.graphScrollView.minimumZoomScale) {
        newScale = self.graphScrollView.minimumZoomScale;
    }
    [self.graphScrollView setZoomScale:newScale animated:YES];
    [self updateZoomLabel];
}

- (void)zoomResetAction {
    [self.graphScrollView setZoomScale:1.0 animated:YES];
    [self updateZoomLabel];
}

- (void)updateZoomLabel {
    NSInteger percent = (NSInteger)(self.graphScrollView.zoomScale * 100);
    [self.zoomResetBtn setTitle:[NSString stringWithFormat:@"%ld%%", (long)percent] forState:UIControlStateNormal];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView == self.graphScrollView) {
        [self updateZoomLabel];
    }
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
}

#pragma mark - 加载反汇编

- (void)loadDisassembly {
    [self.loadingIndicator startAnimating];
    
    __weak typeof(self) weakSelf = self;
    uint64_t startAddr = self.startAddress;
    NSUInteger codeSz = self.codeSize;
    UCFunction *existingFunc = self.currentFunction;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        UCDisassembler *disasm = [UCDisassembler sharedInstance];
        UCDisasmResult *result = nil;
        UCFunction *function = nil;
        
        if (existingFunc) {
            function = existingFunc;
            result = [disasm disassembleAtAddress:function.startAddress
                                             size:function.size];
        } else {
            function = [disasm analyzeFunctionAtAddress:startAddr
                                               maxSize:codeSz];
            if (function) {
                result = [disasm disassembleAtAddress:function.startAddress
                                                 size:function.size];
                if (result) {
                    result.functions = @[function];
                }
            } else {
                result = [disasm disassembleAtAddress:startAddr
                                                 size:codeSz];
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            strongSelf.disasmResult = result;
            strongSelf.currentFunction = function;
            [strongSelf.loadingIndicator stopAnimating];

            if (function) {
                strongSelf.navTitle = function.name;
                strongSelf.title = function.name;
                [strongSelf updateCFGView];
                [strongSelf refreshListing];
            } else {
                // 认不出函数边界就没有 CFG 可画。原来这里什么都不做，
                // 用户看到的是一片空白，只有一个写死的 "CFG图形" 标签。
                // 现在退回汇编列表：至少能读出这片字节到底是什么。
                NSString *reason = result ? @"未能识别函数边界，已退回汇编列表" : @"该地址无法反汇编";
                strongSelf.modeControl.selectedSegmentIndex = UCDisasmViewModeListing;
                [strongSelf applyViewMode:UCDisasmViewModeListing];   // 内部会 refreshListing
                strongSelf.listingTextView.text =
                    [NSString stringWithFormat:@"%@\n\n起始地址 0x%llx   读取长度 %lu bytes\n\n--------\n\n%@",
                     reason, startAddr, (unsigned long)codeSz,
                     [strongSelf listingText]];
            }
        });
    });
}

- (void)updateCFGView {
    if (!self.currentFunction) return;
    
    NSArray *blocks = self.currentFunction.basicBlocks;
    self.cfgView.basicBlocks = blocks;
    [self.cfgView layoutGraph];
    
    self.graphScrollView.contentSize = self.cfgView.bounds.size;
    
    CGSize viewSize = self.graphScrollView.bounds.size;
    CGSize contentSize = self.cfgView.bounds.size;
    
    if (contentSize.width > 0 && contentSize.height > 0 && viewSize.width > 0 && viewSize.height > 0) {
        CGFloat scaleX = viewSize.width / contentSize.width;
        CGFloat scaleY = viewSize.height / contentSize.height;
        CGFloat fitScale = MIN(scaleX, scaleY) * 0.95;
        
        fitScale = MIN(fitScale, 1.0);
        fitScale = MAX(fitScale, self.graphScrollView.minimumZoomScale);
        
        self.graphScrollView.zoomScale = fitScale;
        
        CGPoint offset = CGPointMake(
            (contentSize.width * fitScale - viewSize.width) / 2,
            (contentSize.height * fitScale - viewSize.height) / 2
        );
        self.graphScrollView.contentOffset = offset;
    }
    
    NSString *funcName = self.currentFunction.name;
    if (funcName.length > 40) {
        funcName = [NSString stringWithFormat:@"%@...", [funcName substringToIndex:40]];
    }
    
    self.graphStatusLabel.text = [NSString stringWithFormat:@"%@  |  %lu blocks  |  %lu bytes  |  %lu instr",
                                   funcName,
                                   (unsigned long)self.currentFunction.basicBlockCount,
                                   (unsigned long)self.currentFunction.size,
                                   (unsigned long)self.currentFunction.instructions.count];
    
    [self updateZoomLabel];
    [self.view setNeedsLayout];
}

#pragma mark - 汇编列表

/// 把指令流渲染成等宽文本。
/// 只读 disasmResult / currentFunction 上已经算好的字段，不额外调 dladdr ——
/// 一个 8 KiB 函数有上千条指令，逐条查符号会让切换视图肉眼可见地卡。
- (NSString *)listingText {
    NSArray<UCDisasmInstruction *> *instructions = self.disasmResult.instructions;
    if (instructions.count == 0) {
        instructions = self.currentFunction.instructions;
    }
    if (instructions.count == 0) {
        return @"没有可显示的指令。\n\n可能原因：地址不可读、未按 4 字节对齐，或该地址落在数据段而不是代码段。";
    }

    NSMutableString *text = [NSMutableString stringWithCapacity:instructions.count * 80];

    UCFunction *function = self.currentFunction;
    if (function) {
        [text appendFormat:@"// %@\n", function.name.length ? function.name : @"<unknown>"];
        [text appendFormat:@"// 0x%llx - 0x%llx   %lu bytes   %lu blocks   %lu instr\n\n",
         function.startAddress, function.endAddress,
         (unsigned long)function.size,
         (unsigned long)function.basicBlockCount,
         (unsigned long)instructions.count];
    }

    UCDisasmInstruction *first = instructions.firstObject;
    for (UCDisasmInstruction *instruction in instructions) {
        if (instruction.isFunctionStart && instruction.functionName.length) {
            [text appendFormat:@"\n; ---- %@ ----\n", instruction.functionName];
        } else if (instruction.isBasicBlockStart && instruction != first) {
            [text appendString:@"\n"];
        }

        // 机器码列补齐到 12 字符（4 字节指令是 11 字符）。
        // 不能直接 stringByPaddingToLength: —— 它对超长串会截断，
        // 8 字节指令的机器码会被砍掉一半。
        NSMutableString *padded = [(instruction.bytesHex ?: @"") mutableCopy];
        while (padded.length < 12) {
            [padded appendString:@" "];
        }

        if (!instruction.isValid) {
            [text appendFormat:@"%012llx  %@<无法解码>\n", instruction.address, padded];
            continue;
        }

        [text appendFormat:@"%012llx  %@%@\n",
         instruction.address, padded, instruction.fullText ?: @""];

        // 注释单独缩进成一行：符号名很长时不会把机器码列挤歪。
        NSMutableArray<NSString *> *notes = [NSMutableArray array];
        if (instruction.isBranch && instruction.branchTarget != 0) {
            [notes addObject:[NSString stringWithFormat:@"-> 0x%llx", instruction.branchTarget]];
        }
        if (instruction.comment.length) {
            [notes addObject:instruction.comment];
        }
        if (instruction.xrefComment.length) {
            [notes addObject:instruction.xrefComment];
        }
        for (NSString *note in notes) {
            [text appendFormat:@"              ; %@\n", note];
        }
    }

    return text;
}

- (void)refreshListing {
    if (!self.listingTextView) return;
    self.listingTextView.text = [self listingText];
    [self.listingTextView setContentOffset:CGPointZero animated:NO];
}

- (void)handleBasicBlockTap:(UCBasicBlock *)block {
    if (!block) return;
    UIView *blockView = self.cfgView.blockViewMap[@(block.blockId)];
    if (blockView) {
        blockView.backgroundColor = [UIColor colorWithRed:1.0 green:0.95 blue:0.6 alpha:0.8];
        NSInteger blockId = block.blockId;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *currentView = self.cfgView.blockViewMap[@(blockId)];
            if (currentView) {
                currentView.backgroundColor = [UIColor whiteColor];
            }
        });
    }
}

#pragma mark - UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    if (scrollView == self.graphScrollView) {
        return self.cfgView;
    }
    return nil;
}

#pragma mark - 操作

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)moreAction {
    // 原来这个菜单只有「取消」一个选项 —— 点了等于什么也没做。
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选项"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [alert addAction:[UIAlertAction actionWithTitle:@"复制反汇编文本"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf copyText:[strongSelf listingText] label:@"反汇编文本"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"复制函数摘要"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf copyText:[strongSelf functionSummary] label:@"函数摘要"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"导出 .asm 到沙盒"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf exportListingToSandbox];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 导出与复制

- (NSString *)functionSummary {
    UCFunction *function = self.currentFunction;
    if (!function) {
        return [NSString stringWithFormat:
                @"起始地址: 0x%llx\n读取长度: %lu bytes\n指令数: %lu\n引擎: %@",
                self.startAddress,
                (unsigned long)self.codeSize,
                (unsigned long)self.disasmResult.instructions.count,
                self.disasmResult.engineName ?: @"unknown"];
    }

    return [NSString stringWithFormat:
            @"函数: %@\n起始: 0x%llx\n结束: 0x%llx\n大小: %lu bytes\n"
            @"基本块: %lu\n指令: %lu\n被调用: %lu 处\n调用出: %lu 处\n引擎: %@",
            function.name.length ? function.name : @"<unknown>",
            function.startAddress,
            function.endAddress,
            (unsigned long)function.size,
            (unsigned long)function.basicBlockCount,
            (unsigned long)function.instructions.count,
            (unsigned long)function.calledFrom.count,
            (unsigned long)function.callSites.count,
            self.disasmResult.engineName ?: @"unknown"];
}

- (void)copyText:(NSString *)text label:(NSString *)label {
    if (!text.length) {
        [self showToast:@"没有可复制的内容"];
        return;
    }
    [UIPasteboard generalPasteboard].string = text;
    [self showToast:[NSString stringWithFormat:@"%@ 已复制\n%lu 字符",
                     label, (unsigned long)text.length]];
}

- (NSString *)sanitizedFileName:(NSString *)name {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<> \n\t"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"_"];
    if (clean.length > 80) {
        clean = [clean substringToIndex:80];
    }
    return clean.length ? clean : @"disasm";
}

- (void)exportListingToSandbox {
    NSString *text = [self listingText];
    if (!text.length) {
        [self showToast:@"没有可导出的内容"];
        return;
    }

    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) {
        [self showToast:@"找不到沙盒 Documents 目录"];
        return;
    }

    NSString *directory = [documents stringByAppendingPathComponent:@"AiFlex3Disasm"];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) {
        [self showToast:[NSString stringWithFormat:@"创建目录失败\n%@",
                         directoryError.localizedDescription ?: @"unknown"]];
        return;
    }

    uint64_t base = self.currentFunction ? self.currentFunction.startAddress : self.startAddress;
    NSString *baseName = [self sanitizedFileName:self.currentFunction.name ?: @"sub"];
    NSString *fileName = [NSString stringWithFormat:@"%@_%llx.asm", baseName, base];
    NSString *path = [directory stringByAppendingPathComponent:fileName];

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    NSString *header = [NSString stringWithFormat:
                        @"; AiFlex3 disassembly export\n; %@\n; %@\n\n",
                        [self functionSummary],
                        [formatter stringFromDate:[NSDate date]]];

    NSError *writeError = nil;
    if (![[header stringByAppendingString:text] writeToFile:path
                                                atomically:YES
                                                  encoding:NSUTF8StringEncoding
                                                     error:&writeError]) {
        [self showToast:[NSString stringWithFormat:@"写入失败\n%@",
                         writeError.localizedDescription ?: @"unknown"]];
        return;
    }

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    [self showToast:[NSString stringWithFormat:@"已导出 %@\n%llu 字节\n\nDocuments/AiFlex3Disasm/",
                     fileName, size]];
}

- (void)showToast:(NSString *)message {
    // ActionSheet 的 handler 执行时它自身还在 dismiss 动画里，直接 present 会
    // 撞上 "already presenting"。推迟一帧到动画结束再弹。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.presentedViewController && self.view.window) {
            UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                                                                          message:message
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [self presentViewController:toast animated:YES completion:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [toast dismissViewControllerAnimated:YES completion:nil];
                });
            }];
        }
    });
}

@end

#pragma mark - UCCFGView

@interface UCCFGView ()

@property (nonatomic, strong) NSMutableArray *blockViews;
@property (nonatomic, strong) NSMutableArray *edgeLayers;
@property (nonatomic, strong, readwrite) NSMutableDictionary *blockViewMap;
@property (nonatomic, strong) CAGradientLayer *bgGradient;

@end

@implementation UCCFGView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.blockViews = [NSMutableArray array];
        self.edgeLayers = [NSMutableArray array];
        self.blockViewMap = [NSMutableDictionary dictionary];
        
        self.bgGradient = [CAGradientLayer layer];
        self.bgGradient.colors = @[
            (__bridge id)[UIColor colorWithRed:0.90 green:0.94 blue:0.98 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.80 green:0.88 blue:0.96 alpha:1.0].CGColor
        ];
        [self.layer addSublayer:self.bgGradient];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.bgGradient.frame = self.bounds;
}

- (void)setBasicBlocks:(NSArray<UCBasicBlock *> *)basicBlocks {
    _basicBlocks = basicBlocks;
    
    for (UIView *v in self.blockViews) [v removeFromSuperview];
    for (CALayer *l in self.edgeLayers) [l removeFromSuperlayer];
    [self.blockViews removeAllObjects];
    [self.edgeLayers removeAllObjects];
    [self.blockViewMap removeAllObjects];
    
    if (!basicBlocks) return;
    
    for (UCBasicBlock *block in basicBlocks) {
        UIView *blockView = [self createBlockView:block];
        [self addSubview:blockView];
        [self.blockViews addObject:blockView];
        self.blockViewMap[@(block.blockId)] = blockView;
    }
}

- (UIView *)createBlockView:(UCBasicBlock *)block {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [UIColor whiteColor];
    view.layer.borderWidth = 1.0;
    view.layer.cornerRadius = 4;
    view.clipsToBounds = YES;
    view.layer.shadowColor = [UIColor blackColor].CGColor;
    view.layer.shadowOffset = CGSizeMake(0, 2);
    view.layer.shadowRadius = 3;
    view.layer.shadowOpacity = 0.15;
    view.layer.masksToBounds = NO;
    
    UIColor *borderColor = [UIColor colorWithRed:0.55 green:0.65 blue:0.80 alpha:1.0];
    UIColor *headerColor = [UIColor colorWithRed:0.70 green:0.80 blue:0.92 alpha:1.0];
    
    switch (block.type) {
        case UCBasicBlockTypeEntry:
            borderColor = [UIColor colorWithRed:0.20 green:0.70 blue:0.20 alpha:1.0];
            headerColor = [UIColor colorWithRed:0.65 green:0.88 blue:0.65 alpha:1.0];
            break;
        case UCBasicBlockTypeExit:
            borderColor = [UIColor colorWithRed:0.75 green:0.20 blue:0.20 alpha:1.0];
            headerColor = [UIColor colorWithRed:0.92 green:0.65 blue:0.65 alpha:1.0];
            break;
        case UCBasicBlockTypeConditionalTrue:
            borderColor = [UIColor colorWithRed:0.20 green:0.65 blue:0.20 alpha:1.0];
            break;
        case UCBasicBlockTypeConditionalFalse:
            borderColor = [UIColor colorWithRed:0.70 green:0.20 blue:0.20 alpha:1.0];
            break;
        default:
            break;
    }
    view.layer.borderColor = borderColor.CGColor;
    
    UIView *headerBar = [[UIView alloc] init];
    headerBar.backgroundColor = headerColor;
    headerBar.tag = 100;
    [view addSubview:headerBar];
    
    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.font = [UIFont boldSystemFontOfSize:9];
    headerLabel.textColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    headerLabel.tag = 101;
    
    NSString *startAddr = [NSString stringWithFormat:@"%llx", block.startAddress];
    uint64_t endAddrVal = block.endAddress >= 4 ? block.endAddress - 4 : block.endAddress;
    NSString *endAddr = [NSString stringWithFormat:@"%llx", endAddrVal];
    if (startAddr.length < 8) startAddr = [@"0" stringByAppendingString:startAddr];
    if (endAddr.length < 8) endAddr = [@"0" stringByAppendingString:endAddr];
    
    headerLabel.text = [NSString stringWithFormat:@"loc_%@", startAddr];
    [headerBar addSubview:headerLabel];
    
    UITextView *textView = [[UITextView alloc] init];
    textView.backgroundColor = [UIColor whiteColor];
    textView.editable = NO;
    textView.scrollEnabled = NO;
    textView.textContainerInset = UIEdgeInsetsMake(4, 6, 4, 6);
    textView.textContainer.lineFragmentPadding = 0;
    textView.tag = 200;
    
    NSMutableAttributedString *attrText = [[NSMutableAttributedString alloc] init];
    for (UCDisasmInstruction *insn in block.instructions) {
        NSString *addr = [NSString stringWithFormat:@"%llx", insn.address];
        if (addr.length < 8) {
            addr = [addr stringByPaddingToLength:8 withString:@"0" startingAtIndex:0];
        }
        
        UIColor *mnemColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        if (insn.isCall) {
            mnemColor = [UIColor colorWithRed:0.6 green:0.3 blue:0.0 alpha:1.0];
        } else if (insn.isReturn) {
            mnemColor = [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:1.0];
        } else if (insn.isBranch) {
            mnemColor = [UIColor colorWithRed:0.1 green:0.45 blue:0.15 alpha:1.0];
        } else if (insn.isNop) {
            mnemColor = [UIColor colorWithWhite:0.5 alpha:1.0];
        }
        
        NSAttributedString *addrAttr = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@  ", addr]
            attributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.45 alpha:1.0],
                NSFontAttributeName: [UIFont fontWithName:@"Menlo-Regular" size:9]
            }];
        
        NSString *mnem = [(insn.mnemonic ?: @"") stringByPaddingToLength:8 withString:@" " startingAtIndex:0];
        NSAttributedString *mnemAttr = [[NSAttributedString alloc]
            initWithString:mnem
            attributes:@{
                NSForegroundColorAttributeName: mnemColor,
                NSFontAttributeName: [UIFont fontWithName:@"Menlo-Bold" size:9]
            }];
        
        NSAttributedString *opAttr = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@\n", insn.operands ?: @""]
            attributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.2 alpha:1.0],
                NSFontAttributeName: [UIFont fontWithName:@"Menlo-Regular" size:9]
            }];
        
        [attrText appendAttributedString:addrAttr];
        [attrText appendAttributedString:mnemAttr];
        [attrText appendAttributedString:opAttr];
    }
    
    textView.attributedText = attrText;
    [view addSubview:textView];
    
    CGFloat blockWidth = 320;
    NSUInteger lineCount = block.instructions.count;
    CGFloat headerHeight = 18;
    CGFloat bodyHeight = lineCount * 13 + 8;
    CGFloat blockHeight = headerHeight + bodyHeight;
    
    view.frame = CGRectMake(0, 0, blockWidth, blockHeight);
    headerBar.frame = CGRectMake(0, 0, blockWidth, headerHeight);
    headerLabel.frame = CGRectMake(8, 2, blockWidth - 16, 14);
    textView.frame = CGRectMake(0, headerHeight, blockWidth, bodyHeight);
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(blockTapped:)];
    [view addGestureRecognizer:tap];
    view.userInteractionEnabled = YES;
    view.tag = block.blockId;
    
    return view;
}

- (void)blockTapped:(UITapGestureRecognizer *)gesture {
    UIView *blockView = gesture.view;
    NSInteger blockId = blockView.tag;
    
    for (UCBasicBlock *block in self.basicBlocks) {
        if (block.blockId == blockId) {
            if (self.blockTapHandler) {
                self.blockTapHandler(block);
            }
            break;
        }
    }
}

- (void)layoutGraph {
    if (self.basicBlocks.count == 0) return;
    
    NSMutableDictionary<NSNumber *, NSNumber *> *levelMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *levelBlocks = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *backEdges = [NSMutableSet set];
    
    UCBasicBlock *entryBlock = nil;
    for (UCBasicBlock *block in self.basicBlocks) {
        if (block.type == UCBasicBlockTypeEntry || block.predecessors.count == 0) {
            entryBlock = block;
            break;
        }
    }
    if (!entryBlock) entryBlock = self.basicBlocks.firstObject;
    
    NSMutableArray *stack = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableSet *onStack = [NSMutableSet set];
    
    [stack addObject:entryBlock];
    [onStack addObject:@(entryBlock.blockId)];
    levelMap[@(entryBlock.blockId)] = @0;
    
    while (stack.count > 0) {
        UCBasicBlock *current = stack.lastObject;
        NSNumber *curId = @(current.blockId);
        
        if ([visited containsObject:curId]) {
            [stack removeLastObject];
            [onStack removeObject:curId];
            continue;
        }
        [visited addObject:curId];
        
        NSInteger currentLevel = [levelMap[curId] integerValue];
        
        if (!levelBlocks[@(currentLevel)]) {
            levelBlocks[@(currentLevel)] = [NSMutableArray array];
        }
        if (![levelBlocks[@(currentLevel)] containsObject:curId]) {
            [levelBlocks[@(currentLevel)] addObject:curId];
        }
        
        for (UCBasicBlock *succ in current.successors) {
            NSNumber *succId = @(succ.blockId);

            if ([visited containsObject:succId] && [onStack containsObject:succId]) {
                NSString *edgeKey = [NSString stringWithFormat:@"%ld->%ld", (long)current.blockId, (long)succ.blockId];
                [backEdges addObject:edgeKey];
                continue;
            }

            NSNumber *existingLevel = levelMap[succId];
            NSInteger newLevel = currentLevel + 1;
            if (!existingLevel || [existingLevel integerValue] < newLevel) {
                levelMap[succId] = @(newLevel);
            }

            if (![visited containsObject:succId]) {
                [stack addObject:succ];
                [onStack addObject:succId];
            }
        }
    }
    
    for (UCBasicBlock *block in self.basicBlocks) {
        NSNumber *bid = @(block.blockId);
        if (!levelMap[bid]) {
            NSInteger maxLevel = 0;
            for (NSNumber *l in levelMap.allValues) {
                maxLevel = MAX(maxLevel, l.integerValue);
            }
            levelMap[bid] = @(maxLevel + 1);
            if (!levelBlocks[@(maxLevel + 1)]) {
                levelBlocks[@(maxLevel + 1)] = [NSMutableArray array];
            }
            [levelBlocks[@(maxLevel + 1)] addObject:bid];
        }
    }
    
    CGFloat horizontalGap = 40;
    CGFloat verticalGap = 60;
    CGFloat blockWidth = 320;
    
    NSInteger maxLevel = 0;
    for (NSNumber *l in levelMap.allValues) {
        maxLevel = MAX(maxLevel, l.integerValue);
    }
    
    NSArray *sortedLevels = [levelBlocks.allKeys sortedArrayUsingSelector:@selector(compare:)];
    
    CGFloat maxLevelWidth = 0;
    for (NSNumber *level in sortedLevels) {
        NSArray *blocks = levelBlocks[level];
        CGFloat levelWidth = blocks.count * blockWidth + (blocks.count - 1) * horizontalGap;
        maxLevelWidth = MAX(maxLevelWidth, levelWidth);
    }
    CGFloat totalWidth = maxLevelWidth + horizontalGap * 3;
    
    CGFloat totalHeight = verticalGap * 2;
    for (NSNumber *level in sortedLevels) {
        NSArray *blocks = levelBlocks[level];
        CGFloat levelMaxHeight = 0;
        for (NSNumber *bid in blocks) {
            UIView *bv = self.blockViewMap[bid];
            if (!bv) continue;
            levelMaxHeight = MAX(levelMaxHeight, bv.frame.size.height);
        }
        totalHeight += levelMaxHeight + verticalGap;
    }
    
    self.frame = CGRectMake(0, 0, totalWidth, totalHeight);
    self.bgGradient.frame = self.bounds;
    
    CGFloat currentY = verticalGap;
    
    for (NSNumber *level in sortedLevels) {
        NSArray *blockIds = levelBlocks[level];
        CGFloat levelMaxHeight = 0;
        for (NSNumber *bid in blockIds) {
            UIView *bv = self.blockViewMap[bid];
            if (!bv) continue;
            levelMaxHeight = MAX(levelMaxHeight, bv.frame.size.height);
        }

        CGFloat levelWidth = blockIds.count * blockWidth + (blockIds.count - 1) * horizontalGap;
        CGFloat startX = (totalWidth - levelWidth) / 2;
        
        for (NSUInteger i = 0; i < blockIds.count; i++) {
            NSNumber *bid = blockIds[i];
            UIView *bv = self.blockViewMap[bid];
            if (!bv) continue;
            CGRect frame = bv.frame;
            frame.origin.x = startX + i * (blockWidth + horizontalGap);
            frame.origin.y = currentY;
            bv.frame = frame;
        }
        
        currentY += levelMaxHeight + verticalGap;
    }
    
    [self drawEdges:backEdges];
}

- (void)drawEdges:(NSSet<NSString *> *)backEdges {
    for (CALayer *l in self.edgeLayers) [l removeFromSuperlayer];
    [self.edgeLayers removeAllObjects];
    
    for (UCBasicBlock *block in self.basicBlocks) {
        UIView *fromView = self.blockViewMap[@(block.blockId)];
        if (!fromView) continue;
        
        for (UCBasicBlock *succ in block.successors) {
            UIView *toView = self.blockViewMap[@(succ.blockId)];
            if (!toView) continue;
            
            NSString *edgeKey = [NSString stringWithFormat:@"%ld->%ld", (long)block.blockId, (long)succ.blockId];
            BOOL isBackEdge = [backEdges containsObject:edgeKey];
            
            UIColor *lineColor;
            if (isBackEdge) {
                lineColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.1 alpha:1.0];
            } else if (succ.type == UCBasicBlockTypeConditionalTrue) {
                lineColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1.0];
            } else if (succ.type == UCBasicBlockTypeConditionalFalse) {
                lineColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0];
            } else {
                lineColor = [UIColor colorWithRed:0.3 green:0.4 blue:0.7 alpha:1.0];
            }
            
            [self drawEdgeFrom:fromView to:toView color:lineColor isBackEdge:isBackEdge];
        }
    }
}

- (void)drawEdgeFrom:(UIView *)fromView to:(UIView *)toView color:(UIColor *)color isBackEdge:(BOOL)isBackEdge {
    CGFloat fromX, fromY, toX, toY;
    
    if (isBackEdge) {
        fromX = CGRectGetMidX(fromView.frame);
        fromY = CGRectGetMinY(fromView.frame);
        toX = CGRectGetMidX(toView.frame);
        toY = CGRectGetMaxY(toView.frame);
        
        CGFloat offset = -60;
        CGFloat sideX = MIN(fromX, toX) + offset;
        
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(fromX, fromY)];
        [path addLineToPoint:CGPointMake(fromX, fromY - 15)];
        [path addCurveToPoint:CGPointMake(sideX, (fromY + toY) / 2)
                controlPoint1:CGPointMake(fromX - 20, fromY - 15)
                controlPoint2:CGPointMake(sideX, fromY - 15)];
        [path addCurveToPoint:CGPointMake(toX, toY + 15)
                controlPoint1:CGPointMake(sideX, toY + 15)
                controlPoint2:CGPointMake(toX - 20, toY + 15)];
        [path addLineToPoint:CGPointMake(toX, toY)];
        
        [self addEdgeLayer:path color:color arrowAt:CGPointMake(toX, toY) directionUp:YES];
    } else {
        fromX = CGRectGetMidX(fromView.frame);
        fromY = CGRectGetMaxY(fromView.frame);
        toX = CGRectGetMidX(toView.frame);
        toY = CGRectGetMinY(toView.frame);
        
        CGFloat midY = (fromY + toY) / 2;
        
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(fromX, fromY)];
        
        if (fabs(toX - fromX) < 20) {
            [path addLineToPoint:CGPointMake(toX, toY - 6)];
        } else {
            CGFloat cpOffset = (toY - fromY) * 0.4;
            [path addCurveToPoint:CGPointMake(toX, toY - 6)
                    controlPoint1:CGPointMake(fromX, fromY + cpOffset)
                    controlPoint2:CGPointMake(toX, toY - cpOffset)];
        }
        
        [self addEdgeLayer:path color:color arrowAt:CGPointMake(toX, toY) directionUp:NO];
    }
}

- (void)addEdgeLayer:(UIBezierPath *)path color:(UIColor *)color arrowAt:(CGPoint)arrowPos directionUp:(BOOL)up {
    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    shapeLayer.path = path.CGPath;
    shapeLayer.strokeColor = color.CGColor;
    shapeLayer.fillColor = [UIColor clearColor].CGColor;
    shapeLayer.lineWidth = 1.5;
    shapeLayer.lineCap = kCALineCapRound;
    
    CGFloat arrowSize = 8;
    UIBezierPath *arrowPath = [UIBezierPath bezierPath];
    [arrowPath moveToPoint:arrowPos];
    if (up) {
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x - arrowSize / 2, arrowPos.y + arrowSize)];
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x + arrowSize / 2, arrowPos.y + arrowSize)];
    } else {
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x - arrowSize / 2, arrowPos.y - arrowSize)];
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x + arrowSize / 2, arrowPos.y - arrowSize)];
    }
    [arrowPath closePath];
    
    CAShapeLayer *arrowLayer = [CAShapeLayer layer];
    arrowLayer.path = arrowPath.CGPath;
    arrowLayer.fillColor = color.CGColor;
    
    [self.layer addSublayer:shapeLayer];
    [self.layer addSublayer:arrowLayer];
    [self.edgeLayers addObject:shapeLayer];
    [self.edgeLayers addObject:arrowLayer];
}

@end

#pragma mark - UCFuncListViewController

@interface UCFuncListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<UCFunction *> *allFunctions;
@property (nonatomic, strong) NSArray<UCFunction *> *filteredFunctions;

@end

@implementation UCFuncListViewController

- (instancetype)initWithFunctions:(NSArray<UCFunction *> *)functions {
    self = [super init];
    if (self) {
        _allFunctions = functions;
        _filteredFunctions = functions;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FLEXColor.primaryBackgroundColor;
    self.title = @"函数列表";
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];
    
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索函数名...";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"FuncCell"];
    
    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.frame = self.view.bounds;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredFunctions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FuncCell" forIndexPath:indexPath];
    UCFunction *func = self.filteredFunctions[indexPath.row];
    
    cell.textLabel.text = func.name;
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:12];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"0x%llx  %lu bytes  %lu blocks",
                                  func.startAddress, (unsigned long)func.size, (unsigned long)func.basicBlockCount];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    UCFunction *func = self.filteredFunctions[indexPath.row];
    UCDisasmViewController *disasmVC = [[UCDisasmViewController alloc] initWithFunction:func title:func.name];
    [self.navigationController pushViewController:disasmVC animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredFunctions = self.allFunctions;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"name contains[c] %@", searchText];
        self.filteredFunctions = [self.allFunctions filteredArrayUsingPredicate:pred];
    }
    [self.tableView reloadData];
}

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end
