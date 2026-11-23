#import "FLEXAiFlex3ViewController.h"
#import "FLEXAiFlexMCPServer.h"
#import "FLEXAiFlexRuntime.h"
#import "FLEXManager.h"
#import "FLEXManager+Private.h"
#import "FLEXUtility.h"
#import "FLEXAiFlex3UI.h"

static __weak FLEXAiFlex3ViewController *AXCurrentPanel;

#pragma mark - Panel

@interface FLEXAiFlex3ViewController ()
@property (nonatomic, copy) NSString *report;
@property (nonatomic, copy) NSString *className;
@property (nonatomic) BOOL minimized;
@property (nonatomic) BOOL uiTransitioning;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIRefreshControl *axRefreshControl;

@property (nonatomic, strong) UIView *statusChip;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *heroSubtitle;
@property (nonatomic, strong) UILabel *heroHint;

// 服务设置合并进主页后，这里就是唯一的开关入口：不再有第二份设置页。
@property (nonatomic, strong) AXRowView *serviceRow;
@property (nonatomic, strong) AXRowView *portRow;
@property (nonatomic, strong) AXRowView *endpointRow;
@property (nonatomic, strong) AXRowView *tokenRow;
@property (nonatomic, strong) AXRowView *customTokenRow;
@property (nonatomic, strong) AXRowView *rotateRow;

@property (nonatomic, strong) AXRowView *contextObjectRow;
@property (nonatomic, strong) AXRowView *contextReportRow;
@property (nonatomic, strong) AXRowView *restartRow;
@property (nonatomic, copy) NSArray<UISwitch *> *permissionSwitches;
@property (nonatomic, copy) NSArray<AXRowView *> *toolRowViews;
@property (nonatomic, strong) UILabel *permissionFootnote;
- (void)applyGlassNavigationBar;
- (void)showBuildFailure:(NSString *)reason;
- (void)scheduleRefresh;
- (AXGlassCard *)buildServiceCard;
- (void)toggleService:(BOOL)on;
- (void)editPort;
- (void)showToken;
- (void)editCustomToken;
- (void)rotateToken;
- (BOOL)panelVisible;
@end

@implementation FLEXAiFlex3ViewController

+ (instancetype)aiFlex3CurrentPanel { return AXCurrentPanel; }

- (instancetype)initWithReport:(NSString *)report className:(NSString *)className {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _report = [report copy] ?: @"";
        _className = [className copy] ?: @"未知对象";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    AXCurrentPanel = self;
    self.title = @"AiFlex3";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.down"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(collapseTapped)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"收起面板，MCP 继续运行";
    self.navigationItem.rightBarButtonItem = AXCheckmarkItem(self, @selector(doneTapped));

    // 整页柔光背景：铺满整个页面，给玻璃卡片提供可折射的底色。
    AXInstallBackdrop(self.view);

    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = YES;
    self.scrollView.backgroundColor = UIColor.clearColor;
    // 滚动视图铺到整页（含导航栏区域），由安全区 inset 让内容避开导航栏。
    // 这样内容滚动时会从导航栏底下透出来，导航栏的玻璃模糊才有内容可折射。
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    self.axRefreshControl = [UIRefreshControl new];
    [self.axRefreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.axRefreshControl];

    // 建页失败时给出可见提示，而不是留下一片空白让人猜。
    @try {
        [self buildContent];
    } @catch (NSException *exception) {
        [self showBuildFailure:exception.reason ?: exception.name];
        return;
    }
    [self refresh];
}

- (void)showBuildFailure:(NSString *)reason {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = UIColor.secondaryLabelColor;
    label.text = [NSString stringWithFormat:@"面板渲染失败\n%@", reason ?: @"未知原因"];
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24]
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyGlassNavigationBar];
    // 顶部是半透明玻璃，状态栏文字跟着页面深浅走，避免浅色底上白字看不清。
    AXApplyStatusBarStyle(self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark);
    [self refresh];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 只有整个面板被收起/关掉时才交还状态栏；push 到设置页不算。
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        AXRestoreStatusBarStyle();
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 滚动视图铺满全屏、用安全区补内边距：内容首行落在顶部栏下方，
    // 滚动时从玻璃栏底下穿过，被模糊层透出来。
    UIEdgeInsets insets = UIEdgeInsetsMake(self.view.safeAreaInsets.top, 0,
                                           self.view.safeAreaInsets.bottom, 0);
    if (UIEdgeInsetsEqualToEdgeInsets(self.scrollView.contentInset, insets)) return;
    self.scrollView.contentInset = insets;
    self.scrollView.verticalScrollIndicatorInsets = insets;
}

- (void)applyGlassNavigationBar {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar) AXApplyGlassNavigationBar(bar);
}

// 顶部是半透明玻璃，不画默认的 hairline 分割线。
- (UIStatusBarStyle)preferredStatusBarStyle {
    return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? UIStatusBarStyleLightContent
        : UIStatusBarStyleDarkContent;
}

#pragma mark - Layout

- (void)buildContent {
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self buildHero],
        [self sectionWithTitle:@"MCP 服务" card:[self buildServiceCard]
                      footnote:@"服务只在本进程内监听：宿主被挂起或杀死时连接会中断，重新打开 App 后自动恢复。"],
        [self sectionWithTitle:@"当前现场" card:[self buildContextCard] footnote:nil],
        [self sectionWithTitle:@"快捷操作" card:[self buildActionsCard] footnote:nil],
        [self sectionWithTitle:@"授权" card:[self buildPermissionCard] footnote:nil],
        [self sectionWithTitle:@"可用工具" card:[self buildToolsCard]
                      footnote:@"工具组关闭后，对应工具不会出现在 MCP tools/list 中。"],
        [self sectionWithTitle:@"使用方式" card:[self buildUsageCard] footnote:nil]
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 24;
    content.alignment = UIStackViewAlignmentFill;
    content.translatesAutoresizingMaskIntoConstraints = NO;

    // 用一层朴素容器托住栈：滚动视图只负责尺寸，内容高度完全由容器与栈决定，
    // 避免栈直接挂在 contentLayoutGuide 上时被外层滚动容器压缩成零高。
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:content];
    [self.scrollView addSubview:container];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [container.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [container.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
        [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-36]
    ]];
}

- (UIView *)sectionWithTitle:(NSString *)title card:(UIView *)card footnote:(NSString *)footnote {
    return AXSectionView(title, card, footnote);
}

- (UILabel *)footnoteLabel:(NSString *)text {
    return AXFootnoteLabel(text);
}

- (AXGlassCard *)cardWithRows:(NSArray<UIView *> *)rows radius:(CGFloat)radius {
    return AXCardWithRows(rows, radius);
}

#pragma mark - Hero

- (UIView *)buildHero {
    AXGlassCard *card = [[AXGlassCard alloc] initWithRadius:26];

    AXGradientView *badge = [AXGradientView new];
    badge.colors = @[
        (__bridge id)[UIColor systemBlueColor].CGColor,
        (__bridge id)[UIColor systemIndigoColor].CGColor
    ];
    badge.layer.cornerRadius = 15;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.clipsToBounds = YES;
    UIImageView *spark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold]]];
    spark.tintColor = UIColor.whiteColor;
    spark.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:spark];
    [NSLayoutConstraint activateConstraints:@[
        [badge.widthAnchor constraintEqualToConstant:52],
        [badge.heightAnchor constraintEqualToConstant:52],
        [spark.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [spark.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor]
    ]];

    UILabel *title = [UILabel new];
    title.text = @"AiFlex3";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;

    UILabel *subtitle = [UILabel new];
    subtitle.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.heroSubtitle = subtitle;

    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle, [self buildStatusChip]]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 3;
    titles.alignment = UIStackViewAlignmentFill;
    [titles setCustomSpacing:9 afterView:subtitle];

    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[badge, titles]];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.spacing = 13;
    head.alignment = UIStackViewAlignmentTop;

    UILabel *hint = [self footnoteLabel:@"服务随宿主 App 生命周期运行 · 地址、端口与令牌在下方「MCP 服务」中管理"];
    self.heroHint = hint;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, hint]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [card bringSubviewToFront:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)buildStatusChip {
    UIView *chip = [UIView new];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.layer.cornerRadius = 13;
    chip.clipsToBounds = YES;
    self.statusChip = chip;

    UIView *dot = [UIView new];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 3;
    dot.layer.cornerCurve = kCACornerCurveContinuous;
    self.statusDot = dot;

    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.statusLabel = label;

    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:@[dot, label]];
    inner.axis = UILayoutConstraintAxisHorizontal;
    inner.spacing = 6;
    inner.alignment = UIStackViewAlignmentCenter;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [chip addSubview:inner];

    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:6],
        [dot.heightAnchor constraintEqualToConstant:6],
        [inner.topAnchor constraintEqualToAnchor:chip.topAnchor constant:4.5],
        [inner.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-4.5],
        [inner.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:9],
        [inner.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-11]
    ]];

    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chip];
    [NSLayoutConstraint activateConstraints:@[
        [chip.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [chip.topAnchor constraintEqualToAnchor:row.topAnchor],
        [chip.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [chip.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor]
    ]];
    return row;
}

// 服务与授权原来分散在「主页 / 设置页」两处，同一批开关维护两条刷新路径。
// 现在合成一张卡：开关、端口、地址、令牌、授权码都在这里，不再有第二个页面。
- (AXGlassCard *)buildServiceCard {
    __weak typeof(self) weakSelf = self;

    self.serviceRow = [self rowTitle:@"MCP 服务" subtitle:@"关闭后端口不再监听，外部客户端无法连接"
                              symbol:@"antenna.radiowaves.left.and.right" tint:UIColor.systemGreenColor];
    [self.serviceRow setShowsSwitch:YES];
    self.serviceRow.onToggle = ^(BOOL on) { [weakSelf toggleService:on]; };

    self.portRow = [self rowTitle:@"监听端口" subtitle:nil symbol:@"number" tint:UIColor.systemBlueColor];
    [self.portRow setShowsChevron:YES];
    self.portRow.valueLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.portRow.onTap = ^{ [weakSelf editPort]; };

    self.endpointRow = [self rowTitle:@"访问地址" subtitle:nil symbol:@"link" tint:UIColor.systemIndigoColor];
    [self.endpointRow setShowsChevron:YES];
    self.endpointRow.valueLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    self.endpointRow.valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.endpointRow.onTap = ^{ [weakSelf editEndpoint]; };

    self.tokenRow = [self rowTitle:@"访问令牌" subtitle:@"轻点查看完整令牌并可复制"
                            symbol:@"key.horizontal.fill" tint:UIColor.systemBlueColor];
    [self.tokenRow setShowsChevron:YES];
    self.tokenRow.valueLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    self.tokenRow.onTap = ^{ [weakSelf showToken]; };

    self.customTokenRow = [self rowTitle:@"自定义授权码" subtitle:@"6–64 位字母、数字、点、下划线或短横线"
                                  symbol:@"square.and.pencil" tint:UIColor.systemBlueColor];
    [self.customTokenRow setShowsChevron:YES];
    self.customTokenRow.onTap = ^{ [weakSelf editCustomToken]; };

    self.rotateRow = [self rowTitle:@"重新生成令牌" subtitle:@"旧令牌立即失效，需同步修改电脑端配置"
                             symbol:@"arrow.triangle.2.circlepath" tint:UIColor.systemRedColor];
    [self.rotateRow setShowsChevron:YES];
    self.rotateRow.titleLabel.textColor = UIColor.systemRedColor;
    self.rotateRow.onTap = ^{ [weakSelf rotateToken]; };

    return [self cardWithRows:@[self.serviceRow, self.portRow, self.endpointRow, self.tokenRow,
                                self.customTokenRow, self.rotateRow] radius:22];
}

#pragma mark - Cards

- (AXRowView *)rowTitle:(NSString *)title
               subtitle:(NSString *)subtitle
                 symbol:(NSString *)symbol
                   tint:(UIColor *)tint {
    AXRowView *row = [[AXRowView alloc] initWithFrame:CGRectZero];
    row.titleLabel.text = title;
    if (subtitle.length) {
        row.subtitleLabel.text = subtitle;
        row.subtitleLabel.hidden = NO;
    }
    [row setSymbol:symbol tint:tint];
    return row;
}

- (AXGlassCard *)buildContextCard {
    __weak typeof(self) weakSelf = self;
    AXRowView *object = [self rowTitle:@"当前对象" subtitle:@"回 FLEX 点选视图后自动同步" symbol:@"scope" tint:UIColor.systemBlueColor];
    object.userInteractionEnabled = NO;
    self.contextObjectRow = object;

    AXRowView *report = [self rowTitle:@"现场报告" subtitle:@"暂无" symbol:@"doc.text.magnifyingglass"
                                  tint:UIColor.systemIndigoColor];
    report.userInteractionEnabled = NO;
    report.subtitleLabel.numberOfLines = 2;
    self.contextReportRow = report;

    AXRowView *copy = [self rowTitle:@"复制现场报告" subtitle:nil symbol:@"doc.on.doc" tint:UIColor.systemBlueColor];
    [copy setShowsChevron:YES];
    copy.onTap = ^{ [weakSelf copyText:weakSelf.report message:@"已复制现场报告"]; };

    return [self cardWithRows:@[object, report, copy] radius:22];
}

- (AXGlassCard *)buildActionsCard {
    __weak typeof(self) weakSelf = self;

    AXRowView *config = [self rowTitle:@"复制 MCP 客户端配置" subtitle:nil
                                symbol:@"square.on.square" tint:UIColor.systemBlueColor];
    [config setShowsChevron:YES];
    config.onTap = ^{ [weakSelf copyClientConfiguration]; };

    AXRowView *enable = [self rowTitle:@"一键开启常用工具组" subtitle:nil
                                symbol:@"bolt.fill" tint:UIColor.systemOrangeColor];
    [enable setShowsChevron:YES];
    enable.onTap = ^{ [weakSelf enableAllGroupsTapped]; };

    AXRowView *restart = [self rowTitle:@"重启 MCP 服务" subtitle:nil
                                 symbol:@"arrow.triangle.2.circlepath" tint:UIColor.systemGreenColor];
    [restart setShowsChevron:YES];
    restart.onTap = ^{ [weakSelf restartService]; };
    self.restartRow = restart;

    AXRowView *collapse = [self rowTitle:@"收起面板（回到 App）" subtitle:nil
                                  symbol:@"chevron.down.circle" tint:UIColor.systemBlueColor];
    collapse.titleLabel.textColor = UIColor.systemBlueColor;
    [collapse setShowsChevron:YES];
    collapse.onTap = ^{ [weakSelf collapseTapped]; };

    return [self cardWithRows:@[config, enable, restart, collapse] radius:22];
}

- (UIView *)buildPermissionCard {
    __weak typeof(self) weakSelf = self;
    NSArray *titles = @[@"授权保护", @"敏感读取", @"界面控制", @"脚本执行", @"方法追踪"];
    NSArray *details = @[
        @"要求客户端携带 Bearer 令牌；关闭后同局域网可直接连接",
        @"头文件、日志/网络正文、文件搜索、截图、Keychain 元数据",
        @"点击、输入、滚动、手势、方法调用与高亮，会改变 App 状态",
        @"在 WKWebView 执行 JavaScript，可能改变网页状态",
        @"替换方法实现并记录调用，高风险，10 分钟自动停止"
    ];
    NSArray *symbols = @[@"lock.shield.fill", @"eye.fill", @"hand.tap.fill", @"curlybraces", @"waveform.path.ecg"];
    NSArray *tints = @[UIColor.systemGreenColor, UIColor.systemBlueColor, UIColor.systemIndigoColor,
                       UIColor.systemOrangeColor, UIColor.systemRedColor];

    NSMutableArray *rows = [NSMutableArray new];
    NSMutableArray *switches = [NSMutableArray new];
    for (NSInteger index = 0; index < (NSInteger)titles.count; index++) {
        AXRowView *row = [self rowTitle:titles[index] subtitle:details[index]
                                 symbol:symbols[index] tint:tints[index]];
        [row setShowsSwitch:YES];
        row.onToggle = ^(BOOL on) { [weakSelf permissionChanged:index on:on]; };
        [rows addObject:row];
        [switches addObject:row.toggle];
    }
    self.permissionSwitches = switches;

    AXGlassCard *card = [self cardWithRows:rows radius:22];

    self.permissionFootnote = [self footnoteLabel:@""];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[card, self.permissionFootnote]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentFill;
    return stack;
}

- (UIView *)buildUsageCard {
    AXRowView *row = [self rowTitle:@"MCP 客户端"
                           subtitle:@"在 Claude Desktop、Cursor、Cherry Studio 等客户端添加 Streamable HTTP 服务，URL 填上方访问地址；需要授权时在请求头加 Authorization: Bearer <访问令牌>。"
                             symbol:@"desktopcomputer" tint:UIColor.systemGrayColor];
    row.subtitleLabel.numberOfLines = 0;
    row.userInteractionEnabled = NO;
    return [self cardWithRows:@[row] radius:22];
}

- (AXGlassCard *)buildToolsCard {
    NSArray *items = [self toolItems];
    NSMutableArray *rows = [NSMutableArray new];
    NSMutableArray *views = [NSMutableArray new];
    for (NSDictionary *item in items) {
        AXRowView *row = [self rowTitle:item[@"name"] subtitle:item[@"detail"]
                                 symbol:@"checkmark.seal.fill" tint:UIColor.systemGreenColor];
        row.titleLabel.font = [UIFont monospacedSystemFontOfSize:13.5 weight:UIFontWeightSemibold];
        row.subtitleLabel.numberOfLines = 2;
        row.userInteractionEnabled = NO;
        [rows addObject:row];
        [views addObject:row];
    }
    self.toolRowViews = rows;
    return [self cardWithRows:views radius:22];
}

#pragma mark - Refresh

- (void)refresh {
    // 目标视图可能在面板之外换过（回 FLEX 里重新点选一个视图，再回来打开面板）。
    // 面板是复用的，这里每次刷新都和运行时对齐，避免一直显示第一次打开时的那个对象。
    FLEXAiFlexRuntime *runtime = [FLEXAiFlexRuntime sharedRuntime];
    if ([runtime.selectedObject isKindOfClass:UIView.class]) {
        self.selectedObject = runtime.selectedObject;
        NSString *liveName = NSStringFromClass([runtime.selectedObject class]);
        if (liveName.length) self.className = liveName;
        if (runtime.contextReport.length) self.report = runtime.contextReport;
    }
    BOOL enabled = [FLEXAiFlexMCPServer isEnabled];
    NSString *state = [FLEXAiFlexMCPServer status];
    UIColor *tint = [state hasPrefix:@"运行中"]
        ? UIColor.systemGreenColor
        : (enabled ? UIColor.systemOrangeColor : UIColor.systemGrayColor);
    self.statusLabel.text = state;
    self.statusLabel.textColor = tint;
    self.statusDot.backgroundColor = tint;
    self.statusChip.backgroundColor = [tint colorWithAlphaComponent:0.16];

    // 与服务卡共用同一份状态：开关、端口、地址、令牌都从这里回写。
    UISwitch *serviceToggle = self.serviceRow.toggle;
    if (!serviceToggle.isTracking && serviceToggle.isOn != enabled) serviceToggle.on = enabled;
    [self.portRow setValueText:[NSString stringWithFormat:@"%lu", (unsigned long)[FLEXAiFlexMCPServer port]]];
    [self.endpointRow setValueText:[FLEXAiFlexMCPServer endpoint]];
    if ([FLEXAiFlexMCPServer authRequired]) {
        NSString *token = [FLEXAiFlexMCPServer token];
        [self.tokenRow setValueText:token.length > 4
            ? [NSString stringWithFormat:@"%@••••••••", [token substringToIndex:4]]
            : @"已生成"];
    } else {
        [self.tokenRow setValueText:@"未启用（仅限可信局域网）"];
    }
    self.customTokenRow.hidden = ![FLEXAiFlexMCPServer authRequired];
    self.rotateRow.hidden = ![FLEXAiFlexMCPServer authRequired];

    // 端口被占自动顺延过就把原因写在脚注上，避免用户以为端口被无故改掉。
    NSString *notice = [FLEXAiFlexMCPServer portNotice];
    if (notice.length) {
        self.heroHint.text = notice;
        self.heroHint.textColor = UIColor.systemOrangeColor;
    } else {
        self.heroHint.text = @"服务随宿主 App 生命周期运行 · 地址、端口与令牌在下方「MCP 服务」中管理";
        self.heroHint.textColor = UIColor.tertiaryLabelColor;
    }
    // 没选视图时兜底对象是 key window，直接写 "UIWindow" 会让人以为选错了东西。
    NSString *displayName = [self.className isEqualToString:@"UIWindow"] ? @"未选择视图（当前窗口）" : self.className;
    self.heroSubtitle.text = [NSString stringWithFormat:@"FLEX++ 运行时 · %@", displayName];
    self.contextObjectRow.valueLabel.text = displayName;
    self.contextObjectRow.valueLabel.hidden = displayName.length == 0;
    NSString *summary = [self reportSummary];
    self.contextReportRow.subtitleLabel.text = summary.length ? summary : @"暂无";
    self.restartRow.titleLabel.text = enabled ? @"重启 MCP 服务" : @"开启 MCP 服务";

    NSArray<NSNumber *> *states = @[
        @([FLEXAiFlexMCPServer authRequired]),
        @([FLEXAiFlexMCPServer sensitiveEnabled]),
        @([FLEXAiFlexMCPServer controlEnabled]),
        @([FLEXAiFlexMCPServer scriptEnabled]),
        @([FLEXAiFlexMCPServer tracingEnabled])
    ];
    NSArray *names = @[@"授权保护", @"敏感读取", @"界面控制", @"脚本执行", @"方法追踪"];
    NSMutableArray *summaryParts = [NSMutableArray new];
    for (NSUInteger index = 0; index < self.permissionSwitches.count && index < states.count; index++) {
        UISwitch *toggle = self.permissionSwitches[index];
        // 正在拨动或切换动画未结束时不要回写，否则会把动画从中间打断。
        if (!toggle.isTracking && toggle.isOn != states[index].boolValue) {
            toggle.on = states[index].boolValue;
        }
        [summaryParts addObject:[NSString stringWithFormat:@"%@ %@", names[index],
            states[index].boolValue ? @"开" : @"关"]];
    }
    self.permissionFootnote.text = [NSString stringWithFormat:
        @"当前状态：%@\n\n关闭授权保护后同局域网可直接连接，请仅在可信网络使用；界面控制会真实改变 App 状态；方法追踪可能导致崩溃或卡顿，默认关闭。",
        [summaryParts componentsJoinedByString:@" · "]];

    NSArray *items = [self toolItems];
    for (NSUInteger index = 0; index < self.toolRowViews.count && index < items.count; index++) {
        BOOL on = [items[index][@"enabled"] boolValue];
        AXRowView *row = self.toolRowViews[index];
        row.titleLabel.textColor = on ? UIColor.labelColor : UIColor.secondaryLabelColor;
        [row setSymbol:on ? @"checkmark.seal.fill" : @"circle.dashed"
                 tint:on ? UIColor.systemGreenColor : UIColor.tertiaryLabelColor];
    }

    [self.axRefreshControl endRefreshing];
}

- (void)syncRuntimeContext {
    FLEXAiFlexRuntime *runtime = [FLEXAiFlexRuntime sharedRuntime];
    runtime.selectedObject = self.selectedObject;
    runtime.contextReport = self.report;
    runtime.contextClassName = self.className;
}

- (void)updateReport:(NSString *)report className:(NSString *)className selectedObject:(id)object {
    self.report = [report copy] ?: @"";
    self.className = [className copy] ?: @"未知对象";
    self.selectedObject = object;
    [self syncRuntimeContext];
    if (self.isViewLoaded) [self refresh];
}

- (NSArray<NSDictionary *> *)toolItems {
    return @[
        @{@"name": @"aiflex_status", @"detail": @"读取注入 App、端点与工具组状态", @"enabled": @YES},
        @{@"name": @"aiflex_read", @"detail": @"元素/文字查找、对象属性、实例、网络搜索与快照（免授权）", @"enabled": @YES},
        @{@"name": @"aiflex_sensitive", @"detail": @"头文件、日志搜索/网络正文、文件、截图（需敏感读取）", @"enabled": @([FLEXAiFlexMCPServer sensitiveEnabled])},
        @{@"name": @"aiflex_control", @"detail": @"按文字点击、高亮、输入、滚动、方法调用与手势（需界面控制）", @"enabled": @([FLEXAiFlexMCPServer controlEnabled])},
        @{@"name": @"aiflex_script", @"detail": @"在 WKWebView 执行 JavaScript（需脚本执行，单独授权）", @"enabled": @([FLEXAiFlexMCPServer scriptEnabled])},
        @{@"name": @"aiflex_trace", @"detail": @"方法调用追踪，高风险，10 分钟自动停止（需方法追踪）", @"enabled": @([FLEXAiFlexMCPServer tracingEnabled])}
    ];
}

- (NSString *)reportSummary {
    NSString *text = [self.report stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) {
        return [NSString stringWithFormat:@"App: %@\n当前对象: %@",
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown", self.className];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length) [lines addObject:line];
        if (lines.count >= 4) break;
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Actions

- (void)permissionChanged:(NSInteger)row on:(BOOL)on {
    if (row == 0) {
        [FLEXAiFlexMCPServer setAuthRequired:on];
        if ([FLEXAiFlexMCPServer isEnabled]) {
            [[FLEXAiFlexMCPServer shared] stop];
            [[FLEXAiFlexMCPServer shared] start];
        }
    } else if (row == 1) {
        [FLEXAiFlexMCPServer setSensitiveEnabled:on];
    } else if (row == 2) {
        [FLEXAiFlexMCPServer setControlEnabled:on];
    } else if (row == 3) {
        [FLEXAiFlexMCPServer setScriptEnabled:on];
    } else if (row == 4) {
        [FLEXAiFlexMCPServer setTracingEnabled:on];
    }
    // 等切换动画走完再同步 UI：立刻 refresh 会把正在动画中的 UISwitch 直接改写，
    // 视觉上就像“拨了又弹回去、点了没反应”。
    [self scheduleRefresh];
}

- (void)enableAllGroupsTapped {
    BOOL allOn = [FLEXAiFlexMCPServer sensitiveEnabled] && [FLEXAiFlexMCPServer controlEnabled];
    if (allOn) {
        [self toast:@"常用工具组已开启"];
        return;
    }
    AXPresentAlert(self, @"一键开启常用工具组？",
        @"将同时开启「敏感读取」与「界面控制」两组工具，让连接上的 AI 能读取现场并操作界面。\n\n「脚本执行」与「方法追踪」风险较高，保持关闭，仍需在下方授权区单独开启。开启后请重新发现工具。",
        AXAlertMessageStyleText, nil, @[
        [AXAlertButton buttonWithTitle:@"开启" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer setSensitiveEnabled:YES];
            [FLEXAiFlexMCPServer setControlEnabled:YES];
            [self refresh];
            [self toast:@"已开启敏感读取与界面控制，请在 AI 端重新发现工具"];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)copyClientConfiguration {
    NSString *url = [FLEXAiFlexMCPServer endpoint];
    NSString *json;
    if ([FLEXAiFlexMCPServer authRequired]) {
        json = [NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex3\":{\"type\":\"http\",\"url\":\"%@\",\"headers\":{\"Authorization\":\"Bearer %@\"}}}}",
            url, [FLEXAiFlexMCPServer token]];
    } else {
        json = [NSString stringWithFormat:@"{\"mcpServers\":{\"aiflex3\":{\"type\":\"http\",\"url\":\"%@\"}}}", url];
    }
    [self copyText:json message:@"已复制 MCP 客户端配置"];
}

- (void)editEndpoint {
    AXPresentAlert(self, @"自定义访问地址",
        @"填写手机可达的 IP 或域名（可粘贴完整 URL），端口沿用上方配置。\n同机连接用 127.0.0.1；电脑端连接用手机局域网地址。",
        AXAlertMessageStyleText, ^(UITextField *field) {
        field.text = [FLEXAiFlexMCPServer endpointHost];
        field.placeholder = @"IP 或域名，如 127.0.0.1";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }, @[
        [AXAlertButton buttonWithTitle:@"保存" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            if (![FLEXAiFlexMCPServer setEndpointHost:alert.text]) {
                [self toast:@"地址格式不正确"];
                return;
            }
            [self refresh];
        }],
        [AXAlertButton buttonWithTitle:@"本地地址" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer setEndpointHost:@"127.0.0.1"];
            [self refresh];
        }],
        [AXAlertButton buttonWithTitle:@"局域网地址" style:AXAlertButtonStyleInline handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer setEndpointHost:[FLEXAiFlexMCPServer localAddress]];
            [self refresh];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

#pragma mark - Service actions

- (void)toggleService:(BOOL)on {
    [FLEXAiFlexMCPServer setEnabled:on];
    if (on) [[FLEXAiFlexMCPServer shared] start];
    else [[FLEXAiFlexMCPServer shared] stop];
    [self scheduleRefresh];
}

- (void)editPort {
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"监听端口",
        @"1024–65535，修改后自动重启服务。若端口已被占用，会自动顺延到下一个可用端口。",
        AXAlertMessageStyleText, ^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = [NSString stringWithFormat:@"%lu", (unsigned long)[FLEXAiFlexMCPServer port]];
        }, @[
        [AXAlertButton buttonWithTitle:@"保存" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            NSUInteger port = [alert.text integerValue];
            if (port < 1024 || port > 65535) {
                [weakSelf toast:@"端口需在 1024–65535 之间"];
                return;
            }
            [FLEXAiFlexMCPServer setPort:port];
            if ([FLEXAiFlexMCPServer isEnabled]) {
                [[FLEXAiFlexMCPServer shared] stop];
                [[FLEXAiFlexMCPServer shared] start];
            }
            [weakSelf scheduleRefresh];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)showToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前未启用授权保护"];
        return;
    }
    NSString *token = [FLEXAiFlexMCPServer token];
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"访问令牌", token ?: @"", AXAlertMessageStyleCode, nil, @[
        [AXAlertButton buttonWithTitle:@"复制" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            UIPasteboard.generalPasteboard.string = token ?: @"";
            [weakSelf toast:@"已复制访问令牌"];
        }],
        [AXAlertButton buttonWithTitle:@"关闭" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)editCustomToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前未启用授权保护"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"自定义授权码", @"6–64 位字母、数字、点、下划线或短横线。",
        AXAlertMessageStyleText, ^(UITextField *field) {
            field.placeholder = @"输入授权码";
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }, @[
        [AXAlertButton buttonWithTitle:@"保存" style:AXAlertButtonStylePrimary handler:^(AXGlassAlert *alert) {
            if (![FLEXAiFlexMCPServer setToken:alert.text]) {
                [weakSelf toast:@"授权码格式不正确"];
                return;
            }
            if ([FLEXAiFlexMCPServer isEnabled]) {
                [[FLEXAiFlexMCPServer shared] stop];
                [[FLEXAiFlexMCPServer shared] start];
            }
            [weakSelf toast:@"已更新授权码"];
            [weakSelf scheduleRefresh];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

- (void)rotateToken {
    if (![FLEXAiFlexMCPServer authRequired]) {
        [self toast:@"当前未启用授权保护"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    AXPresentAlert(self, @"重新生成令牌", @"旧令牌立即失效，需要同步修改电脑端 MCP 配置。",
        AXAlertMessageStyleText, nil, @[
        [AXAlertButton buttonWithTitle:@"重新生成" style:AXAlertButtonStyleDestructive handler:^(AXGlassAlert *alert) {
            [FLEXAiFlexMCPServer rotateToken];
            [weakSelf toast:@"已重新生成令牌"];
            [weakSelf scheduleRefresh];
        }],
        [AXAlertButton buttonWithTitle:@"取消" style:AXAlertButtonStyleCancel handler:nil]
    ]);
}

// 拨动开关到 refresh 之间隔一拍：立刻回写会把正在播放的切换动画直接截断。
- (void)scheduleRefresh {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
}

- (void)copyText:(NSString *)text message:(NSString *)message {
    UIPasteboard.generalPasteboard.string = text ?: @"";
    [self toast:message];
}

- (void)restartService {
    [FLEXAiFlexMCPServer setEnabled:YES];
    [[FLEXAiFlexMCPServer shared] stop];
    [[FLEXAiFlexMCPServer shared] start];
    [self toast:@"正在重启 MCP 服务"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)collapseTapped {
    // 只收起 AiFlex3 面板，保留 FLEX 悬浮工具条，方便继续在 App 里操作。
    [self minimizeWithTarget:NO completion:nil];
}

- (void)doneTapped {
    [self minimizeWithTarget:NO completion:nil];
}

- (void)toast:(NSString *)text {
    // 挂到 FLEX 的 explorerWindow（或 keyWindow）并居中，避免面板非全屏时提示偏离屏幕中央。
    UIWindow *window = FLEXManager.sharedManager.explorerWindow ?: UIApplication.sharedApplication.keyWindow ?: self.view.window;
    UIView *host = window ?: self.view;
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.82];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.layer.cornerRadius = 16;
    label.layer.masksToBounds = YES;
    label.alpha = 0;
    CGFloat maxWidth = CGRectGetWidth(host.bounds) - 48;
    CGRect textBox = [text boundingRectWithSize:CGSizeMake(maxWidth - 28, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{NSFontAttributeName:label.font} context:nil];
    CGRect frame = CGRectMake(0, 0, MIN(maxWidth, CGRectGetWidth(textBox) + 28), MAX(36, CGRectGetHeight(textBox) + 20));
    label.frame = frame;
    label.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
    label.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin
        | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [host addSubview:label];
    [UIView animateWithDuration:0.18 animations:^{ label.alpha = 1; } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.1 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    }];
}

#pragma mark - Window operations for MCP

- (BOOL)panelVisible {
    UIWindow *window = self.viewIfLoaded.window;
    return window != nil && !window.hidden && !self.navigationController.isBeingDismissed;
}

// MCP 契约里的 chat_status 只描述 AiFlex3 面板：chatVisible 表示面板可见，
// minimized 表示面板已收起，targetReady 表示面板与 FLEX 覆盖层都不在目标界面上。
// 字段名保持原样，已配置的 MCP 客户端不需要改调用方式。
- (NSDictionary *)panelStatus {
    BOOL running = [[FLEXAiFlexMCPServer status] hasPrefix:@"运行中"];
    return @{
        @"chatVisible": @([self panelVisible]),
        @"minimized": @(self.minimized),
        @"connected": @(running),
        @"taskRunning": @NO,
        @"stopped": @NO,
        @"sessionID": @"",
        @"flexVisible": @(!FLEXManager.sharedManager.isHidden),
        @"targetReady": @(![self panelVisible] && FLEXManager.sharedManager.isHidden && !self.uiTransitioning),
        @"statusVisible": @NO,
        @"activity": [FLEXAiFlexMCPServer status],
        @"uiTransitioning": @(self.uiTransitioning)
    };
}

- (void)performWindowOperation:(NSString *)operation
                     arguments:(NSDictionary *)arguments
                    completion:(void (^)(NSDictionary *, NSString *))completion {
    if ([operation isEqualToString:@"chat_status"]) {
        completion([self panelStatus], nil);
        return;
    }
    if (self.uiTransitioning) {
        completion(nil, @"窗口正在切换，请稍后重新读取 chat_status");
        return;
    }
    self.uiTransitioning = YES;
    void (^done)(void) = ^{
        self.uiTransitioning = NO;
        completion([self panelStatus], nil);
    };

    if ([operation isEqualToString:@"minimize_chat"]) {
        [self minimizeWithTarget:![arguments[@"surface"] isEqualToString:@"flex"] completion:done];
        return;
    }
    if ([operation isEqualToString:@"restore_chat"]) {
        [self restoreWithCompletion:done];
        return;
    }
    if ([operation isEqualToString:@"open_tool"]) {
        NSString *failure = nil;
        UIViewController *controller = nil;
        @try {
            controller = [[FLEXAiFlexRuntime sharedRuntime] controllerForTool:arguments[@"tool_id"] error:&failure];
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"FLEX 入口暂不可用（%@）", exception.name];
        }
        if (!controller) {
            self.uiTransitioning = NO;
            completion(nil, failure ?: @"无法打开该工具");
            return;
        }
        [self minimizeWithTarget:NO completion:^{
            [FLEXManager.sharedManager dismissAnyPresentedTools:^{
                [FLEXManager.sharedManager presentEmbeddedTool:controller completion:^(UINavigationController *nav) { done(); }];
            }];
        }];
        return;
    }

    UIViewController *visible = [FLEXUtility topViewControllerInWindow:FLEXManager.sharedManager.explorerWindow];
    if ([visible isKindOfClass:UIAlertController.class] || AXGlassAlertVisible()) {
        self.uiTransitioning = NO;
        completion(nil, @"请先人工处理当前弹窗");
        return;
    }
    if ([operation isEqualToString:@"navigate_back"]) {
        UINavigationController *nav = visible.navigationController;
        if (nav.viewControllers.count < 2) {
            self.uiTransitioning = NO;
            completion(nil, @"当前 FLEX 页已经在导航根部");
            return;
        }
        [nav popViewControllerAnimated:NO];
        done();
        return;
    }
    [FLEXManager.sharedManager dismissAnyPresentedTools:^{ done(); }];
}

- (void)minimizeWithTarget:(BOOL)target completion:(dispatch_block_t)completion {
    [self.view endEditing:YES];
    void (^done)(void) = ^{
        self.minimized = YES;
        // 面板收起后状态栏交还宿主，避免把 FLEX 的深色样式留在别人页面上。
        AXRestoreStatusBarStyle();
        if (target) [FLEXManager.sharedManager hideExplorer];
        if (completion) completion();
    };
    if (self.navigationController.presentingViewController) {
        [self.navigationController dismissViewControllerAnimated:YES completion:done];
    } else {
        done();
    }
}

- (void)restoreWithCompletion:(dispatch_block_t)completion {
    if (self.viewIfLoaded.window) {
        [FLEXManager.sharedManager showExplorer];
        self.minimized = NO;
        if (completion) completion();
        return;
    }
    UINavigationController *nav = self.navigationController;
    if (!nav) nav = [[UINavigationController alloc] initWithRootViewController:self];
    [FLEXManager.sharedManager dismissAnyPresentedTools:^{
        [FLEXManager.sharedManager presentTool:^UINavigationController *{ return nav; } animated:NO completion:^{
            self.minimized = NO;
            if (completion) completion();
        }];
    }];
}

@end
