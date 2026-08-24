//
//  AiSettings.h
//  Amethyst
//
//  AI 相关偏好：单例，读取/写入 NSUserDefaults 的 ai.* 键。
//  setters/getters 直接读写 UserDefaults，不做内存缓存。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安全模式
typedef NS_ENUM(NSInteger, AiSafetyMode) {
    AiSafetyModeSafe = 0, // 安全：仅执行只读操作
    AiSafetyModeAsk = 1,  // 询问：执行前询问用户
    AiSafetyModeYOLO = 2, // 完全：执行前不询问（谨慎使用）
};

@interface AiSettings : NSObject

/// 单例
+ (instancetype)sharedSettings;

/// 当前选中的提供商 id（NSUserDefaults ai.selected_provider_id）
@property (nonatomic, copy, nullable) NSString *selectedProviderId;
/// 安全模式（0=Safe/1=Ask/2=YOLO，默认 0）
@property (nonatomic, assign) AiSafetyMode safetyMode;
/// 是否启用 Markdown 渲染（默认 YES）
@property (nonatomic, assign) BOOL markdownEnabled;
/// 自定义系统提示词（默认返回 defaultSystemPrompt）
@property (nonatomic, copy) NSString *systemPrompt;

/// 默认系统提示词（中文），约定 Air 行为
+ (NSString *)defaultSystemPrompt;

@end

NS_ASSUME_NONNULL_END