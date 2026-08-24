//
//  AiAgent.m
//  Amethyst
//

#import "AiAgent.h"
#import "AiMessage.h"
#import "AiSessionStore.h"
#import "AiSettings.h"
#import "AiAPIClient.h"

@interface AiAgent ()
@property (nonatomic, strong) AiAPIClient *client;
@end

@implementation AiAgent

+ (instancetype)sharedAgent {
    static AiAgent *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiAgent alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _client = [[AiAPIClient alloc] init];
    }
    return self;
}

- (void)sendUserMessage:(NSString *)text
                session:(AiSession *)session
               provider:(AiProvider *)provider
               streaming:(BOOL)streaming
           chunkHandler:(void (^)(NSString *partial))chunkHandler
     completionHandler:(void (^)(NSError *error))completionHandler {
    if (!session) {
        if (completionHandler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler([NSError errorWithDomain:@"AiAgent" code:1 userInfo:@{NSLocalizedDescriptionKey: @"会话为空"}]);
            });
        }
        return;
    }

    // 1. 追加用户消息
    AiMessage *userMessage = [AiMessage messageWithRole:@"user" content:text ?: @""];
    [session.messages addObject:userMessage];

    // 2. 组装发送 payload：system + 历史（跳过流式占位）+ 本用户消息
    NSMutableArray *payloadMessages = [NSMutableArray array];
    NSString *systemPrompt = [[AiSettings sharedSettings] systemPrompt];
    if (systemPrompt.length > 0) {
        [payloadMessages addObject:[AiMessage messageWithRole:@"system" content:systemPrompt]];
    }
    for (AiMessage *m in session.messages) {
        if (m.streaming) continue;
        [payloadMessages addObject:m];
    }

    // 3. 创建助手占位消息（streaming 标记）
    AiMessage *assistantMessage = [AiMessage messageWithRole:@"assistant" content:@""];
    assistantMessage.streaming = YES;
    [session.messages addObject:assistantMessage];

    // 4. 发起流式请求
    __weak typeof(self) weakSelf = self;
    __weak AiMessage *weakAssistant = assistantMessage;
    [self.client streamChatWithProvider:provider
                               messages:payloadMessages
                                  tools:nil
                                onChunk:^(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls) {
        __strong AiMessage *strongAssistant = weakAssistant;
        if (strongAssistant && delta.length > 0) {
            // 就地累积到助手消息 content（调用方负责 UI 刷新与最终保存）
            strongAssistant.content = [strongAssistant.content stringByAppendingString:delta];
            if (chunkHandler) {
                chunkHandler(delta);
            }
        }
    } onComplete:^(NSDictionary * _Nullable fullResponse, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        __strong AiMessage *fAssistant = weakAssistant;
        if (fAssistant) {
            fAssistant.streaming = NO;
            if (fullResponse[@"content"]) {
                fAssistant.content = fullResponse[@"content"];
            }
            // 出错且无任何产出时，移除空的占位助手消息
            if (error && fAssistant.content.length == 0) {
                [session.messages removeObject:fAssistant];
            }
        }
        [[AiSessionStore sharedStore] updateSession:session];
        if (completionHandler) {
            completionHandler(error);
        }
    }];
}

- (void)stopCurrent {
    [self.client stop];
}

@end