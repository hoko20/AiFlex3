#import "FLEXAiFlex3UI.h"

#pragma mark - Liquid Glass primitives

// iOS 26 起系统提供 UIGlassEffect。本 dylib 用较低 SDK 编译，所以只在运行时探测，
// 找不到（iOS 15–18）就退回系统毛玻璃材质，保证外观与可读性都不塌。
UIVisualEffect *AXGlassEffect(void) {
    static UIVisualEffect *effect;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"UIGlassEffect");
        if (!cls) return;
        @try {
            SEL selector = @selector(effect);
            if ([cls respondsToSelector:selector]) {
                id (*function)(id, SEL) = (id (*)(id, SEL))[cls methodForSelector:selector];
                id value = function ? function(cls, selector) : nil;
                if ([value isKindOfClass:UIVisualEffect.class]) effect = value;
            }
        } @catch (__unused NSException *exception) {}
        if (!effect) {
            @try {
                id value = [[cls alloc] init];
                if ([value isKindOfClass:UIVisualEffect.class]) effect = value;
            } @catch (__unused NSException *exception) {}
        }
    });
    return effect;
}

@implementation AXGradientView

+ (Class)layerClass { return CAGradientLayer.class; }

- (CAGradientLayer *)gradientLayer { return (CAGradientLayer *)self.layer; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.userInteractionEnabled = NO;
        self.gradientLayer.startPoint = CGPointMake(0, 0);
        self.gradientLayer.endPoint = CGPointMake(1, 1);
    }
    return self;
}

- (void)setColors:(NSArray *)colors {
    _colors = [colors copy];
    self.gradientLayer.colors = colors;
}

- (void)setGradientStart:(CGPoint)point {
    _gradientStart = point;
    self.gradientLayer.startPoint = point;
}

- (void)setGradientEnd:(CGPoint)point {
    _gradientEnd = point;
    self.gradientLayer.endPoint = point;
}

@end

@implementation AXGlassCard {
    CGFloat _radius;
}

- (instancetype)initWithRadius:(CGFloat)radius {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _radius = radius;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    // 底色保证在玻璃不可用时也不会变成全透明卡片。
    self.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.78];

    UIVisualEffect *effect = AXGlassEffect();
    if (!effect) effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.translatesAutoresizingMaskIntoConstraints = NO;
    glass.userInteractionEnabled = NO;
    // 玻璃只做背景：始终压在最底层，后续添加的内容自然在它上面。
    [self insertSubview:glass atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [glass.topAnchor constraintEqualToAnchor:self.topAnchor],
        [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];
    [self updateStroke];
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (!previous) return;
    if (previous.userInterfaceStyle == self.traitCollection.userInterfaceStyle) return;
    [self updateStroke];
}

- (void)updateStroke {
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor.separatorColor
        resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}

@end

@interface AXRowView () <UIGestureRecognizerDelegate>
@end

@implementation AXRowView {
    UIView *_tile;
    UIImageView *_icon;
    UIImageView *_chevron;
    UITapGestureRecognizer *_tap;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = UIColor.clearColor;

    _tile = [UIView new];
    _tile.translatesAutoresizingMaskIntoConstraints = NO;
    _tile.layer.cornerRadius = 9;
    _tile.layer.cornerCurve = kCACornerCurveContinuous;
    // 纯展示：让触摸继续往行控件冒泡，否则点在图标上会没反应。
    _tile.userInteractionEnabled = NO;
    [self addSubview:_tile];

    _icon = [UIImageView new];
    _icon.translatesAutoresizingMaskIntoConstraints = NO;
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    [_tile addSubview:_icon];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:16];
    _titleLabel.textColor = UIColor.labelColor;

    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = UIColor.secondaryLabelColor;
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.hidden = YES;

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.alignment = UIStackViewAlignmentFill;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    // UIStackView 默认自己接收触摸，会把落在文字上的点吞掉，导致只有行边距可点。
    texts.userInteractionEnabled = NO;
    [self addSubview:texts];

    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    _valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _valueLabel.hidden = YES;
    _valueLabel.userInteractionEnabled = NO;
    [_valueLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
    _chevron.tintColor = UIColor.tertiaryLabelColor;
    _chevron.contentMode = UIViewContentModeScaleAspectFit;
    _chevron.hidden = YES;
    _chevron.userInteractionEnabled = NO;
    [_chevron.widthAnchor constraintEqualToConstant:9].active = YES;

    _toggle = [UISwitch new];
    _toggle.hidden = YES;
    // 开关完全走系统自身的触摸处理：不做任何重定向、不加 exclusiveTouch。
    // 之前那套"整行控件抢触摸再放行开关"的做法会和 UISwitch 的 tracking 打架，
    // 表现为拨不动或拨完弹回去。这里只保证它在栈里不被压缩变形。
    [_toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_toggle addTarget:self action:@selector(toggleFired) forControlEvents:UIControlEventValueChanged];

    UIStackView *trailing = [[UIStackView alloc] initWithArrangedSubviews:@[_valueLabel, _toggle, _chevron]];
    trailing.axis = UILayoutConstraintAxisHorizontal;
    trailing.spacing = 8;
    trailing.alignment = UIStackViewAlignmentCenter;
    trailing.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:trailing];

    [NSLayoutConstraint activateConstraints:@[
        [_tile.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_tile.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_tile.widthAnchor constraintEqualToConstant:30],
        [_tile.heightAnchor constraintEqualToConstant:30],
        [_icon.centerXAnchor constraintEqualToAnchor:_tile.centerXAnchor],
        [_icon.centerYAnchor constraintEqualToAnchor:_tile.centerYAnchor],
        [_icon.widthAnchor constraintEqualToConstant:17],
        [_icon.heightAnchor constraintEqualToConstant:17],
        [texts.leadingAnchor constraintEqualToAnchor:_tile.trailingAnchor constant:12],
        [texts.trailingAnchor constraintLessThanOrEqualToAnchor:trailing.leadingAnchor constant:-8],
        [texts.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [texts.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:11],
        [texts.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-11],
        [trailing.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [trailing.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:54]
    ]];

    // 让行高跟着文字长，而不是把两行副标题压扁截断。
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [_subtitleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    // 整行点击用 tap 手势识别：手势观察的是整棵子树的触摸，
    // 不会被 UIStackView/UILabel 的 hit-test 剪枝挡住，也不需要重写 hitTest 去抢触摸。
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleRowTap:)];
    _tap.delegate = self;
    _tap.cancelsTouchesInView = NO;
    [self addGestureRecognizer:_tap];
    return self;
}

- (void)setSymbol:(NSString *)symbol tint:(UIColor *)tint {
    _icon.image = [UIImage systemImageNamed:symbol
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    _icon.tintColor = tint;
    _tile.backgroundColor = [tint colorWithAlphaComponent:0.15];
}

- (void)setValueText:(NSString *)text {
    _valueLabel.text = text;
    _valueLabel.hidden = text.length == 0;
}

- (void)setShowsChevron:(BOOL)shows {
    _chevron.hidden = !shows;
    if (shows) self.userInteractionEnabled = YES;
}

- (void)setShowsSwitch:(BOOL)shows {
    _toggle.hidden = !shows;
    if (shows) self.userInteractionEnabled = YES;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted
        ? [UIColor.labelColor colorWithAlphaComponent:0.06]
        : UIColor.clearColor;
}

- (void)handleRowTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    if (self.onTap) { self.onTap(); return; }
    // 开关行的其余区域也能切换，手感和系统设置一致；真正的开关点击由 UISwitch 自己处理。
    UISwitch *toggle = self.toggle;
    if (toggle && !toggle.hidden && self.onToggle) {
        BOOL next = !toggle.isOn;
        [toggle setOn:next animated:YES];
        self.onToggle(next);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // 手指落在开关上时放手让 UISwitch 自己处理，否则手势会抢走这次触摸。
    if (self.toggle && !self.toggle.hidden && [touch.view isDescendantOfView:self.toggle]) return NO;
    return YES;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    self.highlighted = YES;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    self.highlighted = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    self.highlighted = NO;
}

- (void)toggleFired {
    if (self.onToggle) self.onToggle(self.toggle.isOn);
}

@end

#pragma mark - Helpers

AXGradientView *AXInstallBackdrop(UIView *host) {
    if (!host) return nil;
    AXGradientView *bloom = [AXGradientView new];
    bloom.colors = @[
        (__bridge id)[[UIColor systemBlueColor] colorWithAlphaComponent:0.20].CGColor,
        (__bridge id)[[UIColor systemIndigoColor] colorWithAlphaComponent:0.11].CGColor,
        (__bridge id)([UIColor clearColor].CGColor)
    ];
    bloom.gradientStart = CGPointMake(0.1, 0);
    bloom.gradientEnd = CGPointMake(0.9, 0.92);
    [host insertSubview:bloom atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [bloom.topAnchor constraintEqualToAnchor:host.topAnchor],
        [bloom.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [bloom.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [bloom.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
    ]];
    return bloom;
}

UILabel *AXSectionLabel(NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

UILabel *AXFootnoteLabel(NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11.5];
    label.textColor = UIColor.tertiaryLabelColor;
    label.numberOfLines = 0;
    return label;
}

UIView *AXSeparatorView(void) {
    UIView *wrap = [UIView new];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
    [wrap addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:58],
        [line.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:0.5]
    ]];
    return wrap;
}

UIStackView *AXSectionView(NSString *title, UIView *card, NSString *footnote) {
    NSMutableArray *views = [NSMutableArray new];
    if (title.length) [views addObject:AXSectionLabel(title)];
    if (card) [views addObject:card];
    if (footnote.length) [views addObject:AXFootnoteLabel(footnote)];
    if (!views.count) return nil;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentFill;
    if (footnote.length && card) [stack setCustomSpacing:7 afterView:card];
    return stack;
}

AXGlassCard *AXCardWithRows(NSArray<UIView *> *rows, CGFloat radius) {
    AXGlassCard *card = [[AXGlassCard alloc] initWithRadius:radius];
    NSMutableArray *views = [NSMutableArray new];
    for (NSUInteger index = 0; index < rows.count; index++) {
        if (index) [views addObject:AXSeparatorView()];
        [views addObject:rows[index]];
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [card bringSubviewToFront:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:4],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4]
    ]];
    return card;
}

UIBarButtonItem *AXCheckmarkItem(id target, SEL action) {
    UIImage *image = [UIImage systemImageNamed:@"checkmark"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16
                                                                          weight:UIImageSymbolWeightSemibold]];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:image
                                                             style:UIBarButtonItemStylePlain
                                                            target:target
                                                            action:action];
    item.accessibilityLabel = @"完成";
    return item;
}

#pragma mark - 顶部栏

// 半透明 + 模糊：不画 hairline，内容从栏下透出。
// 底色只留很低的不透明度，主要靠 UIGlassEffect / 薄材质提供模糊，
// 这样滚动手感是「内容在玻璃下移动」，而不是一块死板色块。
void AXApplyGlassNavigationBar(UINavigationBar *bar) {
    if (!bar) return;

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.shadowColor = UIColor.clearColor;
    appearance.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.22];
    UIVisualEffect *effect = AXGlassEffect();
    if (!effect) effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    appearance.backgroundEffect = effect;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.labelColor};
    appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: UIColor.labelColor};

    bar.standardAppearance = appearance;
    bar.compactAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
    if (@available(iOS 15.0, *)) bar.compactScrollEdgeAppearance = appearance;

    // 清掉实底时代留下的兜底：纯色背景图或 barTintColor 会直接盖住模糊层。
    bar.translucent = YES;
    bar.barTintColor = nil;
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    bar.shadowImage = [UIImage new];
}

#pragma mark - 状态栏

static BOOL AXStatusBarStyleSaved = NO;
static UIStatusBarStyle AXStatusBarStyleBefore = UIStatusBarStyleDefault;

static void AXSetStatusBarStyle(UIStatusBarStyle style) {
    UIApplication *app = UIApplication.sharedApplication;
    @try {
        if (app.statusBarStyle == style) return;
    } @catch (__unused NSException *exception) {}

    // 公开接口在 UIViewControllerBasedStatusBarAppearance=NO 的宿主里会被忽略，
    // 这种情况只能走私有 setStatusBarStyle:animated:（越狱环境可用）。
    SEL selector = NSSelectorFromString(@"setStatusBarStyle:animated:");
    if (![app respondsToSelector:selector]) return;
    NSMethodSignature *signature = [app methodSignatureForSelector:selector];
    if (!signature) return;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = app;
    invocation.selector = selector;
    NSInteger raw = (NSInteger)style;
    BOOL animated = YES;
    [invocation setArgument:&raw atIndex:2];
    [invocation setArgument:&animated atIndex:3];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {}
}

void AXApplyStatusBarStyle(BOOL darkContent) {
    UIStatusBarStyle style = darkContent ? UIStatusBarStyleDarkContent
                                         : UIStatusBarStyleLightContent;
    if (!AXStatusBarStyleSaved) {
        @try {
            AXStatusBarStyleBefore = UIApplication.sharedApplication.statusBarStyle;
            AXStatusBarStyleSaved = YES;
        } @catch (__unused NSException *exception) {}
    }
    AXSetStatusBarStyle(style);
    [UIApplication.sharedApplication.keyWindow.rootViewController
        setNeedsStatusBarAppearanceUpdate];
}

void AXRestoreStatusBarStyle(void) {
    if (!AXStatusBarStyleSaved) return;
    AXStatusBarStyleSaved = NO;
    AXSetStatusBarStyle(AXStatusBarStyleBefore);
}

#pragma mark - 玻璃弹窗

// 轻触反馈：弹层出现与选择落点给一次，让"点到了"有物理确认。
static void AXFeedback(UIImpactFeedbackStyle style) {
    UIImpactFeedbackGenerator *generator =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [generator prepare];
    [generator impactOccurred];
}

// 弹窗与底部列表共用一个可见栈：AI 走界面自动化前要能判断"用户还有没处理完的层"。
static NSMutableArray *AXVisibleAlerts(void) {
    static NSMutableArray *alerts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ alerts = [NSMutableArray new]; });
    return alerts;
}

@implementation AXAlertField

+ (instancetype)fieldWithPlaceholder:(NSString *)placeholder
                                text:(NSString *)text
                                kind:(AXAlertFieldKind)kind {
    AXAlertField *field = [AXAlertField new];
    field->_placeholder = [placeholder copy] ?: @"";
    field->_text = [text copy];
    field->_kind = kind;
    return field;
}

@end

@implementation AXAlertButton

+ (instancetype)buttonWithTitle:(NSString *)title
                          style:(AXAlertButtonStyle)style
                        handler:(void (^)(AXGlassAlert *))handler {
    AXAlertButton *button = [AXAlertButton new];
    button->_title = [title copy];
    button->_style = style;
    button->_handler = [handler copy];
    return button;
}

@end

@interface AXGlassAlert () <UITextFieldDelegate>
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) AXGlassCard *card;
@property (nonatomic, strong, nullable) UITextField *textField;
@property (nonatomic, strong) NSArray<UITextField *> *fields;
@property (nonatomic, strong) NSLayoutConstraint *centerConstraint;
@property (nonatomic, copy) NSArray<AXAlertButton *> *buttons;
@property (nonatomic, assign) BOOL dismissing;
@property (nonatomic, strong, nullable) UISwitch *toggle;
@property (nonatomic, copy, nullable) NSString *toggleTitle;
@property (nonatomic, assign) BOOL toggleValue;
- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
           configureTextField:(void (^)(UITextField *field))configureTextField
                      buttons:(NSArray<AXAlertButton *> *)buttons;
- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
                        fields:(NSArray<AXAlertField *> *)fields
                       buttons:(NSArray<AXAlertButton *> *)buttons;
- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
                        fields:(NSArray<AXAlertField *> *)fields
                   toggleTitle:(NSString *)toggleTitle
                      toggleOn:(BOOL)toggleOn
                       buttons:(NSArray<AXAlertButton *> *)buttons;
@end

@implementation AXGlassAlert

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
           configureTextField:(void (^)(UITextField *field))configureTextField
                      buttons:(NSArray<AXAlertButton *> *)buttons {
    NSArray<AXAlertField *> *fields = configureTextField
        ? @[[AXAlertField fieldWithPlaceholder:@"" text:nil kind:AXAlertFieldKindText]]
        : @[];
    self = [self initWithTitle:title
                       message:message
                  messageStyle:messageStyle
                        fields:fields
                       buttons:buttons];
    if (self && configureTextField && self.textField) configureTextField(self.textField);
    return self;
}

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
                        fields:(NSArray<AXAlertField *> *)fields
                       buttons:(NSArray<AXAlertButton *> *)buttons {
    return [self initWithTitle:title
                       message:message
                  messageStyle:messageStyle
                        fields:fields
                   toggleTitle:nil
                      toggleOn:NO
                       buttons:buttons];
}

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                 messageStyle:(AXAlertMessageStyle)messageStyle
                        fields:(NSArray<AXAlertField *> *)fields
                   toggleTitle:(NSString *)toggleTitle
                      toggleOn:(BOOL)toggleOn
                       buttons:(NSArray<AXAlertButton *> *)buttons {
    self = [super init];
    if (!self) return nil;
    _buttons = [buttons copy] ?: @[];
    _toggleTitle = [toggleTitle copy];
    _toggleValue = toggleOn;

    _overlay = [UIView new];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    _overlay.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.34];

    AXGradientView *bloom = [AXGradientView new];
    bloom.colors = @[
        (__bridge id)[[UIColor systemBlueColor] colorWithAlphaComponent:0.18].CGColor,
        (__bridge id)([UIColor clearColor].CGColor)
    ];
    bloom.gradientStart = CGPointMake(0.15, 0.05);
    bloom.gradientEnd = CGPointMake(0.85, 0.95);
    [_overlay addSubview:bloom];
    [NSLayoutConstraint activateConstraints:@[
        [bloom.topAnchor constraintEqualToAnchor:_overlay.topAnchor],
        [bloom.leadingAnchor constraintEqualToAnchor:_overlay.leadingAnchor],
        [bloom.trailingAnchor constraintEqualToAnchor:_overlay.trailingAnchor],
        [bloom.bottomAnchor constraintEqualToAnchor:_overlay.bottomAnchor]
    ]];

    _card = [[AXGlassCard alloc] initWithRadius:26];
    [_overlay addSubview:_card];

    _centerConstraint = [_card.centerYAnchor constraintEqualToAnchor:_overlay.centerYAnchor];
    NSLayoutConstraint *fluidWidth = [_card.widthAnchor constraintEqualToAnchor:_overlay.widthAnchor
                                                                      constant:-52];
    fluidWidth.priority = 990;
    NSLayoutConstraint *topGuard = [_card.topAnchor constraintGreaterThanOrEqualToAnchor:_overlay.topAnchor
                                                                               constant:44];
    topGuard.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor constraintEqualToAnchor:_overlay.centerXAnchor],
        _centerConstraint,
        [_card.widthAnchor constraintLessThanOrEqualToConstant:340],
        fluidWidth,
        topGuard
    ]];

    NSMutableArray<UIView *> *content = [NSMutableArray new];

    if (title.length) {
        UILabel *label = [UILabel new];
        label.text = title;
        label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        label.textColor = UIColor.labelColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [content addObject:label];
    }

    if (message.length) {
        if (messageStyle == AXAlertMessageStyleCode) {
            UITextView *code = [UITextView new];
            code.translatesAutoresizingMaskIntoConstraints = NO;
            code.text = message;
            code.editable = NO;
            code.selectable = YES;
            code.scrollEnabled = NO;
            code.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.06];
            code.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
            code.textContainer.lineFragmentPadding = 0;
            code.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
            code.textColor = UIColor.labelColor;
            code.layer.cornerRadius = 12;
            code.layer.cornerCurve = kCACornerCurveContinuous;
            code.layer.borderWidth = 0.5;
            code.layer.borderColor = [UIColor.separatorColor
                resolvedColorWithTraitCollection:code.traitCollection].CGColor;
            [code.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
            // 诊断输出可能有几十行，不给上限会把卡片撑出屏幕；超过就由文字自己被裁，
            // 需要全文时用弹窗里的「复制」按钮。
            NSLayoutConstraint *codeCap = [code.heightAnchor constraintLessThanOrEqualToConstant:280];
            codeCap.priority = 999;
            codeCap.active = YES;
            [content addObject:code];
        } else {
            UILabel *label = [UILabel new];
            label.text = message;
            label.font = [UIFont systemFontOfSize:13];
            label.textColor = UIColor.secondaryLabelColor;
            // 一句话的提示居中好看；连接说明这种整段文字居中会让每行长短跳、读起来费劲。
            label.textAlignment = message.length > 64 ? NSTextAlignmentLeft : NSTextAlignmentCenter;
            label.numberOfLines = 0;
            [content addObject:label];
        }
    }

    if (fields.count) {
        NSMutableArray<UITextField *> *built = [NSMutableArray new];
        for (AXAlertField *spec in fields) {
            UITextField *field = [UITextField new];
            field.translatesAutoresizingMaskIntoConstraints = NO;
            field.font = [UIFont systemFontOfSize:15];
            field.textColor = UIColor.labelColor;
            field.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
            field.layer.cornerRadius = 13;
            field.layer.cornerCurve = kCACornerCurveContinuous;
            field.layer.borderWidth = 0.5;
            field.layer.borderColor = [UIColor.separatorColor
                resolvedColorWithTraitCollection:field.traitCollection].CGColor;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.delegate = self;
            [field addTarget:self action:@selector(fieldBeganEditing:)
                forControlEvents:UIControlEventEditingDidBegin];
            [field addTarget:self action:@selector(fieldEndedEditing:)
                forControlEvents:UIControlEventEditingDidEnd];
            field.placeholder = spec.placeholder;
            if (spec.text.length) field.text = spec.text;
            switch (spec.kind) {
                case AXAlertFieldKindSecure:
                    field.secureTextEntry = YES;
                    field.keyboardType = UIKeyboardTypeNumberPad;
                    field.clearButtonMode = UITextFieldViewModeNever;
                    break;
                case AXAlertFieldKindURL:
                    field.keyboardType = UIKeyboardTypeURL;
                    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
                    field.autocorrectionType = UITextAutocorrectionTypeNo;
                    break;
                case AXAlertFieldKindNumber:
                    field.keyboardType = UIKeyboardTypeNumberPad;
                    break;
                case AXAlertFieldKindText:
                    break;
            }
            field.returnKeyType = (built.count + 1 < fields.count) ? UIReturnKeyNext : UIReturnKeyDone;
            UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 13, 44)];
            field.leftView = pad;
            field.leftViewMode = UITextFieldViewModeAlways;
            [field.heightAnchor constraintEqualToConstant:46].active = YES;
            [built addObject:field];
            [content addObject:field];
        }
        _fields = built.copy;
        _textField = built.firstObject;
    }

    if (_toggleTitle.length) {
        UIView *row = [UIView new];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = _toggleTitle;
        label.font = [UIFont systemFontOfSize:14];
        label.textColor = UIColor.labelColor;
        label.numberOfLines = 0;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        UISwitch *toggle = [UISwitch new];
        toggle.on = toggleOn;
        toggle.translatesAutoresizingMaskIntoConstraints = NO;
        [toggle addTarget:self action:@selector(toggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        [row addSubview:label];
        [row addSubview:toggle];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
            [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-4],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12],
            [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [row.heightAnchor constraintGreaterThanOrEqualToConstant:34]
        ]];
        _toggle = toggle;
        [content addObject:row];
    }

    if (_buttons.count) {
        UIStackView *column = [self columnForButtons:_buttons];
        [content addObject:column];
    }

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:content];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack];
    [_card bringSubviewToFront:stack];

    if (content.count > 1) {
        NSUInteger titleIndex = title.length ? 0 : NSNotFound;
        if (titleIndex != NSNotFound) [stack setCustomSpacing:8 afterView:content[titleIndex]];
        [stack setCustomSpacing:18 afterView:content[content.count - 2]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:22],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-20]
    ]];
    return self;
}

- (UIStackView *)columnForButtons:(NSArray<AXAlertButton *> *)buttons {
    NSMutableArray<UIView *> *rows = [NSMutableArray new];
    NSMutableArray<AXAlertButton *> *inlineActions = [NSMutableArray new];
    for (AXAlertButton *action in buttons) {
        if (action.style == AXAlertButtonStyleInline) {
            [inlineActions addObject:action];
            continue;
        }
        if (inlineActions.count) {
            [rows addObjectsFromArray:[self chipRows:inlineActions]];
            [inlineActions removeAllObjects];
        }
        UIButton *button = [self buttonForAction:action];
        if (!button) continue;
        [button.heightAnchor constraintEqualToConstant:48].active = YES;
        [rows addObject:button];
    }
    if (inlineActions.count) [rows addObjectsFromArray:[self chipRows:inlineActions]];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:rows];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 9;
    column.alignment = UIStackViewAlignmentFill;
    return column;
}

// 卡片内容宽度：卡片最宽 340，左右各留 20 的内边距，屏幕更窄时按屏幕宽度收缩。
static CGFloat AXAlertContentWidth(void) {
    CGFloat card = MIN(340.0, CGRectGetWidth(UIScreen.mainScreen.bounds) - 52.0);
    return MAX(180.0, card - 40.0);
}

// inline 按钮原来是等分一行，像「上次连接诊断 / 使用已保存连接 / MCP 服务设置」
// 这种长标题在窄屏上会被截成「使用...存连接」。改成按文字宽度整体排布的胶囊，
// 一行放不下就换行——标题永远完整，卡片也不会横向溢出。
- (NSArray<UIView *> *)chipRows:(NSArray<AXAlertButton *> *)buttons {
    CGFloat limit = AXAlertContentWidth();
    UIFont *font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    NSMutableArray<UIView *> *rows = [NSMutableArray new];
    NSMutableArray<UIButton *> *current = [NSMutableArray new];
    NSMutableArray<NSNumber *> *widths = [NSMutableArray new];
    CGFloat used = 0;
    for (AXAlertButton *action in buttons) {
        if (!action.title.length) continue;
        CGFloat width = ceil([action.title sizeWithAttributes:@{NSFontAttributeName: font}].width) + 30;
        width = MIN(width, limit);
        CGFloat needed = current.count ? used + 10 + width : width;
        if (current.count && needed > limit) {
            [rows addObject:[self chipRow:current widths:widths limit:limit]];
            [current removeAllObjects];
            [widths removeAllObjects];
            needed = width;
        }
        UIButton *chip = [self chipForAction:action];
        if (!chip) continue;
        [current addObject:chip];
        [widths addObject:@(width)];
        used = needed;
    }
    if (current.count) [rows addObject:[self chipRow:current widths:widths limit:limit]];
    return rows;
}

- (UIStackView *)chipRow:(NSArray<UIButton *> *)chips
                  widths:(NSArray<NSNumber *> *)widths
                   limit:(CGFloat)limit {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:chips];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    [chips enumerateObjectsUsingBlock:^(UIButton *chip, NSUInteger index, BOOL *stop) {
        CGFloat width = index < widths.count ? widths[index].doubleValue : limit;
        NSLayoutConstraint *exact = [chip.widthAnchor constraintEqualToConstant:width];
        exact.priority = 998;
        NSLayoutConstraint *floor = [chip.widthAnchor constraintGreaterThanOrEqualToConstant:44];
        floor.priority = 999;
        [NSLayoutConstraint activateConstraints:@[exact, floor]];
        [chip.heightAnchor constraintEqualToConstant:36].active = YES;
    }];
    // 尾部放一个会自动撑开的占位视图：胶囊按文字宽度靠左排列，多余空间不会把按钮拉宽。
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                              forAxis:UILayoutConstraintAxisHorizontal];
    [spacer.widthAnchor constraintGreaterThanOrEqualToConstant:0].active = YES;
    [row addArrangedSubview:spacer];
    return row;
}

- (UIButton *)chipForAction:(AXAlertButton *)action {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.tag = [_buttons indexOfObjectIdenticalTo:action];
    chip.layer.cornerRadius = 18;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
    chip.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    chip.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    chip.titleLabel.adjustsFontSizeToFitWidth = YES;
    chip.titleLabel.minimumScaleFactor = 0.85;
    chip.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [chip setTitle:action.title forState:UIControlStateNormal];
    [chip setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [chip addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
    [chip addTarget:self action:@selector(buttonPressed:)
   forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [chip addTarget:self action:@selector(buttonReleased:)
   forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                    UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return chip;
}

- (UIButton *)buttonForAction:(AXAlertButton *)action {
    if (!action.title.length) return nil;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = [_buttons indexOfObjectIdenticalTo:action];
    button.layer.cornerRadius = 14;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.titleLabel.font = [UIFont systemFontOfSize:
        (action.style == AXAlertButtonStylePrimary ? 16 : 15)
        weight:(action.style == AXAlertButtonStylePrimary ? UIFontWeightSemibold : UIFontWeightMedium)];
    [button setTitle:action.title forState:UIControlStateNormal];
    [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(buttonPressed:)
        forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [button addTarget:self action:@selector(buttonReleased:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                         UIControlEventTouchCancel | UIControlEventTouchDragExit];

    switch (action.style) {
        case AXAlertButtonStylePrimary:
            button.backgroundColor = UIColor.systemBlueColor;
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            break;
        case AXAlertButtonStyleDestructive:
            button.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.14];
            [button setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
            break;
        case AXAlertButtonStyleSecondary:
        case AXAlertButtonStyleInline:
            button.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
            [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
            break;
        case AXAlertButtonStyleCancel:
            button.backgroundColor = UIColor.clearColor;
            [button setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateNormal];
            break;
    }
    // 按压反馈交给系统的自定义按钮高亮，这里不需要额外配色。
    button.alpha = 1;
    return button;
}

- (void)fieldBeganEditing:(UITextField *)field {
    field.layer.borderWidth = 1.5;
    field.layer.borderColor = UIColor.systemBlueColor.CGColor;
}

- (void)fieldEndedEditing:(UITextField *)field {
    field.layer.borderWidth = 0.5;
    field.layer.borderColor = [UIColor.separatorColor
        resolvedColorWithTraitCollection:field.traitCollection].CGColor;
}

- (void)buttonPressed:(UIButton *)sender { sender.alpha = 0.72; }

- (void)buttonReleased:(UIButton *)sender { sender.alpha = 1; }

- (void)fireAction:(AXAlertButton *)action {
    if (self.dismissing || !action) return;
    if (action.style == AXAlertButtonStylePrimary ||
        action.style == AXAlertButtonStyleDestructive) {
        AXFeedback(UIImpactFeedbackStyleMedium);
    }
    void (^handler)(AXGlassAlert *) = action.handler;
    [self dismiss];
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{ handler(self); });
    }
}

- (void)actionTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.buttons.count) return;
    [self fireAction:self.buttons[(NSUInteger)index]];
}

- (NSString *)text {
    return self.textField.text ?: @"";
}

- (NSArray<NSString *> *)values {
    NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:self.fields.count];
    for (UITextField *field in self.fields) [list addObject:field.text ?: @""];
    return list;
}

- (BOOL)toggleOn {
    return self.toggle ? self.toggle.isOn : self.toggleValue;
}

- (void)toggleChanged:(UISwitch *)sender {
    self.toggleValue = sender.isOn;
    AXFeedback(UIImpactFeedbackStyleLight);
}

- (void)present {
    UIWindow *window = self.overlay.superview.window ?: self.card.window;
    if (!window) return;
    [AXVisibleAlerts() addObject:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    self.overlay.alpha = 0;
    self.card.transform = CGAffineTransformMakeScale(1.04, 1.04);
    AXFeedback(UIImpactFeedbackStyleLight);
    [UIView animateWithDuration:0.26 delay:0 usingSpringWithDamping:0.86
           initialSpringVelocity:0.4 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.overlay.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
    if (self.textField) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self.textField becomeFirstResponder];
        });
    }
}

- (void)dismiss {
    if (self.dismissing) return;
    self.dismissing = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.textField resignFirstResponder];
    [AXVisibleAlerts() removeObjectIdenticalTo:self];
    UIView *overlay = self.overlay;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        overlay.alpha = 0;
        self.card.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboard = [self.overlay convertRect:frame fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.overlay.bounds) - CGRectGetMinY(keyboard);
    if (overlap < 0) overlap = 0;
    // 键盘很高时不要把卡片顶出屏幕上沿，最多上移三成屏高。
    CGFloat limit = CGRectGetHeight(self.overlay.bounds) * 0.3;
    self.centerConstraint.constant = -MIN(overlap / 2.0, limit);
    [UIView animateWithDuration:0.2 animations:^{
        [self.overlay layoutIfNeeded];
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // 多输入框时回车跳下一框，最后一框才等同主操作，少一次点击。
    NSUInteger index = [self.fields indexOfObjectIdenticalTo:textField];
    if (index != NSNotFound && index + 1 < self.fields.count) {
        [self.fields[index + 1] becomeFirstResponder];
        return YES;
    }
    for (AXAlertButton *action in self.buttons) {
        if (action.style != AXAlertButtonStylePrimary) continue;
        [self fireAction:action];
        break;
    }
    return YES;
}

@end

static AXGlassAlert *AXInstallAlert(UIViewController *host, AXGlassAlert *alert) {
    if (!alert) return nil;
    UIView *hostView = host.viewIfLoaded ?: host.view;
    UIWindow *window = hostView.window ?: UIApplication.sharedApplication.keyWindow;
    if (!window) return nil;
    [window addSubview:alert.overlay];
    [NSLayoutConstraint activateConstraints:@[
        [alert.overlay.topAnchor constraintEqualToAnchor:window.topAnchor],
        [alert.overlay.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [alert.overlay.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [alert.overlay.bottomAnchor constraintEqualToAnchor:window.bottomAnchor]
    ]];
    [alert present];
    return alert;
}

AXGlassAlert *AXPresentAlert(UIViewController *host,
                             NSString *title,
                             NSString *message,
                             AXAlertMessageStyle messageStyle,
                             void (^configureTextField)(UITextField *),
                             NSArray<AXAlertButton *> *buttons) {
    return AXInstallAlert(host, [[AXGlassAlert alloc] initWithTitle:title
                                                           message:message
                                                      messageStyle:messageStyle
                                                configureTextField:configureTextField
                                                           buttons:buttons]);
}

AXGlassAlert *AXPresentAlertWithToggle(UIViewController *host,
                                       NSString *title,
                                       NSString *message,
                                       AXAlertMessageStyle messageStyle,
                                       NSString *toggleTitle,
                                       BOOL toggleOn,
                                       NSArray<AXAlertButton *> *buttons) {
    return AXInstallAlert(host, [[AXGlassAlert alloc] initWithTitle:title
                                                           message:message
                                                      messageStyle:messageStyle
                                                            fields:@[]
                                                       toggleTitle:toggleTitle
                                                          toggleOn:toggleOn
                                                           buttons:buttons]);
}

AXGlassAlert *AXPresentForm(UIViewController *host,
                            NSString *title,
                            NSString *message,
                            NSArray<AXAlertField *> *fields,
                            NSArray<AXAlertButton *> *buttons) {
    return AXInstallAlert(host, [[AXGlassAlert alloc] initWithTitle:title
                                                           message:message
                                                      messageStyle:AXAlertMessageStyleText
                                                            fields:fields
                                                           buttons:buttons]);
}

#pragma mark - 底部选择列表

@implementation AXSheetItem

+ (instancetype)itemWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    AXSheetItem *item = [AXSheetItem new];
    item->_title = [title copy] ?: @"";
    item->_subtitle = [subtitle copy];
    return item;
}

@end

@interface AXGlassSheet : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) AXGlassCard *card;
@property (nonatomic, copy) NSArray<AXSheetItem *> *items;
@property (nonatomic, copy, nullable) void (^handler)(NSInteger index);
@property (nonatomic, assign) BOOL dismissing;
- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                        items:(NSArray<AXSheetItem *> *)items
                      handler:(void (^)(NSInteger))handler;
- (void)present;
- (void)closeWithIndex:(NSInteger)index;
- (UIView *)separatorLine;
- (UIControl *)rowForItem:(AXSheetItem *)item index:(NSUInteger)index;
- (void)backdropTapped;
- (void)cancelTapped;
- (void)rowTapped:(UIControl *)sender;
- (void)rowPressed:(UIControl *)sender;
- (void)rowReleased:(UIControl *)sender;
@end

@implementation AXGlassSheet

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                        items:(NSArray<AXSheetItem *> *)items
                      handler:(void (^)(NSInteger))handler {
    self = [super init];
    if (!self) return nil;
    _items = [items copy] ?: @[];
    _handler = [handler copy];

    _overlay = [UIView new];
    _overlay.translatesAutoresizingMaskIntoConstraints = NO;
    _overlay.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.34];
    // 只用来点空白关闭。必须走代理判断落点，并且不能取消子视图的触摸：
    // 否则点在列表行上时，父层手势会先把 UIControl 的触摸取消掉，行看起来完全没反应。
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(backdropTapped)];
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [_overlay addGestureRecognizer:tap];

    AXGradientView *bloom = [AXGradientView new];
    bloom.colors = @[
        (__bridge id)[[UIColor systemBlueColor] colorWithAlphaComponent:0.16].CGColor,
        (__bridge id)([UIColor clearColor].CGColor)
    ];
    bloom.gradientStart = CGPointMake(0.2, 0.1);
    bloom.gradientEnd = CGPointMake(0.8, 0.9);
    [_overlay addSubview:bloom];
    [NSLayoutConstraint activateConstraints:@[
        [bloom.topAnchor constraintEqualToAnchor:_overlay.topAnchor],
        [bloom.leadingAnchor constraintEqualToAnchor:_overlay.leadingAnchor],
        [bloom.trailingAnchor constraintEqualToAnchor:_overlay.trailingAnchor],
        [bloom.bottomAnchor constraintEqualToAnchor:_overlay.bottomAnchor]
    ]];

    _card = [[AXGlassCard alloc] initWithRadius:26];
    [_overlay addSubview:_card];
    [NSLayoutConstraint activateConstraints:@[
        [_card.leadingAnchor constraintEqualToAnchor:_overlay.leadingAnchor constant:10],
        [_card.trailingAnchor constraintEqualToAnchor:_overlay.trailingAnchor constant:-10],
        [_card.bottomAnchor constraintEqualToAnchor:_overlay.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [_card.topAnchor constraintGreaterThanOrEqualToAnchor:_overlay.topAnchor constant:60]
    ]];

    NSMutableArray<UIView *> *content = [NSMutableArray new];
    if (title.length) {
        UILabel *label = [UILabel new];
        label.text = title;
        label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        label.textColor = UIColor.labelColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [content addObject:label];
    }
    if (message.length) {
        UILabel *label = [UILabel new];
        label.text = message;
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = UIColor.secondaryLabelColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [content addObject:label];
    }

    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 0;
    rows.alignment = UIStackViewAlignmentFill;
    for (NSUInteger index = 0; index < _items.count; index++) {
        if (index) [rows addArrangedSubview:[self separatorLine]];
        [rows addArrangedSubview:[self rowForItem:_items[index] index:index]];
    }

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = NO;
    [scroll addSubview:rows];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    // 内容多高就多高，只有超过半屏才滚动。这条不能放在上面：scroll 此时还没进层级，
    // 和 overlay 没有共同祖先，激活会直接抛异常并把宿主带走。
    NSLayoutConstraint *fitHeight =
        [scroll.heightAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.heightAnchor];
    fitHeight.priority = 750;
    fitHeight.active = YES;
    [content addObject:scroll];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.07];
    cancel.layer.cornerRadius = 14;
    cancel.layer.cornerCurve = kCACornerCurveContinuous;
    cancel.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [cancel.heightAnchor constraintEqualToConstant:48].active = YES;
    [content addObject:cancel];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:content];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:stack];
    if (content.count > 1) [stack setCustomSpacing:16 afterView:content[content.count - 2]];
    // 列表最多占半屏，再多就在卡片内滚动。此时 scroll 的祖先链已到 overlay，约束才合法。
    [scroll.heightAnchor constraintLessThanOrEqualToAnchor:_overlay.heightAnchor multiplier:0.5].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-14]
    ]];
    return self;
}

- (UIView *)separatorLine {
    UIView *wrap = [UIView new];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.4];
    [wrap addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [line.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:14],
        [line.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-14],
        [line.heightAnchor constraintEqualToConstant:0.5]
    ]];
    return wrap;
}

- (UIControl *)rowForItem:(AXSheetItem *)item index:(NSUInteger)index {
    UIControl *row = [UIControl new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.tag = (NSInteger)index;
    if (item.selected) row.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.06];
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [row addTarget:self action:@selector(rowPressed:) forControlEvents:UIControlEventTouchDown];
    [row addTarget:self action:@selector(rowReleased:) forControlEvents:
        UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    UILabel *title = [UILabel new];
    title.text = item.title;
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    title.textColor = item.destructive ? UIColor.systemRedColor : UIColor.labelColor;
    title.lineBreakMode = NSLineBreakByTruncatingTail;

    NSMutableArray<UIView *> *lines = [NSMutableArray arrayWithObject:title];
    if (item.subtitle.length) {
        UILabel *subtitle = [UILabel new];
        subtitle.text = item.subtitle;
        subtitle.font = [UIFont systemFontOfSize:11.5];
        subtitle.textColor = UIColor.secondaryLabelColor;
        subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
        [lines addObject:subtitle];
    }
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:lines];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.alignment = UIStackViewAlignmentLeading;
    texts.translatesAutoresizingMaskIntoConstraints = NO;
    texts.userInteractionEnabled = NO;
    [row addSubview:texts];

    UIImageView *check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13
                                                                        weight:UIImageSymbolWeightSemibold]]];
    check.tintColor = UIColor.systemBlueColor;
    check.hidden = !item.selected;
    check.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:check];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:54],
        [texts.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [texts.trailingAnchor constraintLessThanOrEqualToAnchor:check.leadingAnchor constant:-10],
        [texts.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [texts.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:11],
        [check.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:18]
    ]];
    return row;
}

- (void)present {
    [AXVisibleAlerts() addObject:self];
    self.overlay.alpha = 0;
    self.card.transform = CGAffineTransformMakeTranslation(0, 52);
    AXFeedback(UIImpactFeedbackStyleLight);
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.9
           initialSpringVelocity:0.35 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.overlay.alpha = 1;
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    // 卡片里的触摸交给行和按钮自己处理；只有卡片外才算“点空白”。
    return ![touch.view isDescendantOfView:_card];
}

- (void)backdropTapped { [self closeWithIndex:-1]; }
- (void)cancelTapped { [self closeWithIndex:-1]; }
- (void)rowTapped:(UIControl *)sender {
    AXFeedback(UIImpactFeedbackStyleLight);
    [self closeWithIndex:sender.tag];
}
- (void)rowPressed:(UIControl *)sender {
    sender.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.11];
}
- (void)rowReleased:(UIControl *)sender {
    NSInteger index = sender.tag;
    BOOL selected = index >= 0 && index < (NSInteger)self.items.count &&
                    self.items[(NSUInteger)index].selected;
    sender.backgroundColor = selected
        ? [UIColor.systemBlueColor colorWithAlphaComponent:0.06]
        : UIColor.clearColor;
}

- (void)closeWithIndex:(NSInteger)index {
    if (self.dismissing) return;
    self.dismissing = YES;
    // 收起动画期间不要再吃触摸：选择后经常立刻弹下一层（项目 → 模型），
    // 这一层还挡在上面会吞掉新弹窗的第一次点击。
    self.overlay.userInteractionEnabled = NO;
    [AXVisibleAlerts() removeObjectIdenticalTo:self];
    void (^handler)(NSInteger) = self.handler;
    UIView *overlay = self.overlay;    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        overlay.alpha = 0;
        self.card.transform = CGAffineTransformMakeTranslation(0, 30);
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
    if (handler) handler(index);
}

@end

void AXPresentSheet(UIViewController *host,
                    NSString *title,
                    NSString *message,
                    NSArray<AXSheetItem *> *items,
                    void (^handler)(NSInteger)) {
    UIView *hostView = host.viewIfLoaded ?: host.view;
    UIWindow *window = hostView.window ?: UIApplication.sharedApplication.keyWindow;
    if (!window || (!items.count && !title.length)) {
        if (handler) handler(-1);
        return;
    }
    AXGlassSheet *sheet = [[AXGlassSheet alloc] initWithTitle:title
                                                      message:message
                                                        items:items
                                                      handler:handler];
    [window addSubview:sheet.overlay];
    [NSLayoutConstraint activateConstraints:@[
        [sheet.overlay.topAnchor constraintEqualToAnchor:window.topAnchor],
        [sheet.overlay.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [sheet.overlay.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [sheet.overlay.bottomAnchor constraintEqualToAnchor:window.bottomAnchor]
    ]];
    [sheet present];
}

BOOL AXGlassAlertVisible(void) {
    return AXVisibleAlerts().count > 0;
}
