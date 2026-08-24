//
//  AiMessage.h
//  Amethyst
//
//  对话消息数据模型：role + content。
//  tool_calls / function_call 等字段留待 Phase 3 扩展，本期仅保留 role/content。
//  streaming 仅运行时标记，用于标识正在流式生成中的占位助手消息，不持久化。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AiMessage : NSObject

/// 消息角色：system / user / assistant
@property (nonatomic, copy) NSString *role;
/// 消息内容
@property (nonatomic, copy) NSString *content;
/// 是否正处于流式生成中（仅运行时标记，不写入磁盘）
@property (nonatomic, assign) BOOL streaming;
/// 创建时间
@property (nonatomic, strong) NSDate *createdAt;

/// 便捷构造
+ (instancetype)messageWithRole:(NSString *)role content:(NSString *)content;

/// JSON 系列化
- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END