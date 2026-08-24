//
//  AIMessageCell.m
//  Amethyst
//

#import "AIMessageCell.h"
#import "MarkdownParser.h"
#import "LauncherPreferences.h"

// 说明：助手气泡采用白 0.08 半透明底，聊天气泡不叠加 UIVisualEffectView 毛玻璃，
// 以避免滚动表格中反复插入模糊视图导致的性能/复用问题；外层内容区已由
// BackgroundManager 提供整体毛玻璃，气泡透出即可。参考 AnnouncementCardCell 的处理。

/// 内容字体
static const CGFloat kMsgFontSize = 16.0;
/// 气泡内边距
static const CGFloat kMsgBubblePadding = 10.0;
/// 气泡最大宽度占容器比例
static const CGFloat kMsgMaxBubbleWidthRatio = 0.72;
/// 水平外边距
static const CGFloat kMsgHMargin = 12.0;
/// cell 上下留白
static const CGFloat kMsgVerticalPadding = 10.0;
/// 气泡圆角（连续圆角）
static const CGFloat kMsgCornerRadius = 12.0;

@interface AIMessageCell ()
@property (nonatomic, strong) UIView *bubbleView;
@property (nonatomic, strong) UITextView *contentTextView;
@end

@implementation AIMessageCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.bubbleView = [[UIView alloc] init];
        self.bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
        self.bubbleView.layer.cornerRadius = kMsgCornerRadius;
        self.bubbleView.layer.cornerCurve = kCACornerCurveContinuous;
        self.bubbleView.clipsToBounds = YES;
        [self.contentView addSubview:self.bubbleView];

        self.contentTextView = [[UITextView alloc] init];
        self.contentTextView.translatesAutoresizingMaskIntoConstraints = NO;
        self.contentTextView.editable = NO;
        self.contentTextView.scrollEnabled = NO;
        self.contentTextView.selectable = YES;
        self.contentTextView.backgroundColor = [UIColor clearColor];
        self.contentTextView.textContainerInset = UIEdgeInsetsZero;
        self.contentTextView.textContainer.lineFragmentPadding = 0;
        [self.bubbleView addSubview:self.contentTextView];

        // 约束：文本顶/左/右贴气泡内边距，从内容尺寸撑起气泡高度（不主动撑起）
        [NSLayoutConstraint activateConstraints:@[
            [self.contentTextView.topAnchor constraintEqualToAnchor:self.bubbleView.topAnchor constant:kMsgBubblePadding],
            [self.contentTextView.leadingAnchor constraintEqualToAnchor:self.bubbleView.leadingAnchor constant:kMsgBubblePadding],
            [self.contentTextView.trailingAnchor constraintEqualToAnchor:self.bubbleView.trailingAnchor constant:-kMsgBubblePadding],
            [self.contentTextView.bottomAnchor constraintEqualToAnchor:self.bubbleView.bottomAnchor constant:-kMsgBubblePadding],
            // 限制气泡最大宽度
            [self.bubbleView.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:kMsgMaxBubbleWidthRatio],
        ]];

        // 气泡垂直方向由内容顶/底撑起，再由 cell 上下留白约束 min 高度
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:kMsgVerticalPadding],
            [self.bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-kMsgVerticalPadding],
        ]];
    }
    return self;
}

/// 布局后同步 preferredMaxLayoutWidth，保证 UITextView 换行后的固有高度准确
- (void)layoutSubviews {
    [super layoutSubviews];
    self.contentTextView.preferredMaxLayoutWidth = CGRectGetWidth(self.contentTextView.bounds);
}

- (void)configureWithMessage:(AiMessage *)message markdownEnabled:(BOOL)enabled {
    if (!message) return;
    BOOL isUser = [message.role isEqualToString:@"user"];
    NSString *content = message.content ?: @"";
    UIColor *contentColor = [UIColor labelColor];

    // 文本内容
    if (isUser || !enabled) {
        UIFont *font = [UIFont systemFontOfSize:kMsgFontSize];
        self.contentTextView.font = font;
        self.contentTextView.text = content;
        self.contentTextView.textColor = contentColor;
    } else {
        NSAttributedString *attr = [MarkdownParser parseMarkdown:content baseFont:[UIFont systemFontOfSize:kMsgFontSize]];
        self.contentTextView.attributedText = attr;
    }

    // 气泡样式
    if (isUser) {
        // 用户消息：右对齐，accent 色调 0.10 底 + labelColor 文字
        self.bubbleView.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
        self.contentTextView.textColor = contentColor;
        [self rebuildHorizontalConstraintsForUser:YES];
    } else {
        // 助手消息：左对齐，白 0.08 底 + MarkdownParser 内置系统文字色 + 毛玻璃
        self.bubbleView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [self rebuildHorizontalConstraintsForUser:NO];
    }
}

/// 重建气泡水平对齐约束（用户右对齐，助手左对齐）
- (void)rebuildHorizontalConstraintsForUser:(BOOL)isUser {
    // 移除此前添加的水平对齐约束（识别存储的标记）
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSLayoutConstraint *c in [self.contentView constraints]) {
        BOOL touchesBubble = (c.firstItem == self.bubbleView || c.secondItem == self.bubbleView);
        BOOL horizontal = (c.firstAttribute == NSLayoutAttributeLeading ||
                           c.firstAttribute == NSLayoutAttributeTrailing ||
                           c.secondAttribute == NSLayoutAttributeLeading ||
                           c.secondAttribute == NSLayoutAttributeTrailing);
        if (touchesBubble && horizontal) {
            [toRemove addObject:c];
        }
    }
    if (toRemove.count > 0) {
        [NSLayoutConstraint deactivateConstraints:toRemove];
    }

    if (isUser) {
        // 右对齐
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kMsgHMargin],
            [self.bubbleView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:kMsgHMargin],
        ]];
    } else {
        // 左对齐
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kMsgHMargin],
            [self.bubbleView.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-kMsgHMargin],
        ]];
    }
}

#pragma mark - 高度估算

+ (CGFloat)cellHeightForMessage:(AiMessage *)message width:(CGFloat)width markdownEnabled:(BOOL)enabled {
    if (!message || !width) return 60.0;
    NSString *content = message.content ?: @"";
    CGFloat maxBubbleWidth = width * kMsgMaxBubbleWidthRatio;
    CGFloat textWidth = maxBubbleWidth - 2 * kMsgBubblePadding;
    if (textWidth < 20) textWidth = 20;

    BOOL isUser = [message.role isEqualToString:@"user"];
    CGSize textSize;
    if (isUser || !enabled) {
        UIFont *font = [UIFont systemFontOfSize:kMsgFontSize];
        CGRect r = [content boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                      attributes:@{NSFontAttributeName: font}
                                         context:nil];
        textSize = r.size;
    } else {
        NSAttributedString *attr = [MarkdownParser parseMarkdown:content baseFont:[UIFont systemFontOfSize:kMsgFontSize]];
        CGRect r = [attr boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                      context:nil];
        textSize = r.size;
    }

    CGFloat textHeight = ceil(textSize.height);
    if (textHeight < 20) textHeight = 20;
    CGFloat total = textHeight + 2 * kMsgBubblePadding + 2 * kMsgVerticalPadding;
    return MAX(total, 48.0);
}

@end