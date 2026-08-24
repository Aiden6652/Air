//
//  AIMessageCell.h
//  Amethyst
//
//  聊天消息气泡 Cell：用户消息右对齐（accent 色调底），助手消息左对齐（毛玻璃气泡），
//  助手内容用 MarkdownParser 渲染。提供静态高度估算方法供自动行高使用。
//

#import <UIKit/UIKit.h>
#import "AiMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface AIMessageCell : UITableViewCell

/// 配置气泡内容与排版
- (void)configureWithMessage:(AiMessage *)message markdownEnabled:(BOOL)enabled;

/// 估算某条消息在该宽度下所需的行高
+ (CGFloat)cellHeightForMessage:(AiMessage *)message width:(CGFloat)width markdownEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END