//
//  AiSettings.m
//  Amethyst
//

#import "AiSettings.h"

@implementation AiSettings

static NSString * const kSelectedProviderIdKey = @"ai.selected_provider_id";
static NSString * const kSafetyModeKey = @"ai.safety_mode";
static NSString * const kMarkdownEnabledKey = @"ai.markdown_enabled";
static NSString * const kSystemPromptKey = @"ai.systemPrompt";

+ (instancetype)sharedSettings {
    static AiSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiSettings alloc] init];
    });
    return instance;
}

#pragma mark - setters / getters（直接读写 NSUserDefaults，不缓存）

- (nullable NSString *)selectedProviderId {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kSelectedProviderIdKey];
}

- (void)setSelectedProviderId:(nullable NSString *)selectedProviderId {
    if (selectedProviderId.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedProviderIdKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:selectedProviderId forKey:kSelectedProviderIdKey];
    }
}

- (AiSafetyMode)safetyMode {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kSafetyModeKey];
    return (value < AiSafetyModeSafe || value > AiSafetyModeYOLO) ? AiSafetyModeSafe : (AiSafetyMode)value;
}

- (void)setSafetyMode:(AiSafetyMode)safetyMode {
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)safetyMode forKey:kSafetyModeKey];
}

- (BOOL)markdownEnabled {
    // 未显式设置时默认 YES
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kMarkdownEnabledKey];
    if (obj == nil) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMarkdownEnabledKey];
}

- (void)setMarkdownEnabled:(BOOL)markdownEnabled {
    [[NSUserDefaults standardUserDefaults] setBool:markdownEnabled forKey:kMarkdownEnabledKey];
}

- (NSString *)systemPrompt {
    NSString *prompt = [[NSUserDefaults standardUserDefaults] stringForKey:kSystemPromptKey];
    if (prompt.length == 0) {
        prompt = [[self class] defaultSystemPrompt];
    }
    return prompt;
}

- (void)setSystemPrompt:(NSString *)systemPrompt {
    [[NSUserDefaults standardUserDefaults] setObject:systemPrompt ?: @"" forKey:kSystemPromptKey];
}

+ (NSString *)defaultSystemPrompt {
    return @"你是 Air（Amethyst iOS Remastered）启动器内置的 AI 助手，运行在 iOS 的 Minecraft Java 版启动器内。你的任务是帮助使用此启动器的玩家：排查启动/崩溃问题、安装游戏版本与各类资源（模组、光影、资源包、数据包等）、解答 Minecraft 相关问题。"
    "重要——讲解要求：向用户解释任何专业内容时，必须用生动、通俗、贴近生活的比喻和具体例子，避免堆砌专业术语；必要时分步讲解，确保普通用户能清晰理解。比如解释内存分配要用「工资/房租」这类比喻，而不是直接说 JVM -Xmx。"
    "行为纪律：优先执行只读操作；涉及修改、下载、安装前，先向用户确认目标（版本、实例、加载器等）；不确定时主动询问用户，而不是凭记忆猜测；不要编造不存在的版本号和链接。若你的模型能力不足以完成任务，如实告知用户。";
}

@end