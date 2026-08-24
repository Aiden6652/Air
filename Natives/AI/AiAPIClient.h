//
//  AiAPIClient.h
//  Amethyst
//
//  OpenAI 兼容流式 Chat Completions 客户端。
//  支持 SSE 流式返回，节流 onChunk 回调（≤200ms），block 一律回主线程。
//

#import <Foundation/Foundation.h>
#import "AiProvider.h"
#import "AiMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiAPIClient : NSObject

/// 发起一次流式对话请求
/// @param messages 对话上下文（system/user/assistant）
/// @param tools 工具定义（Phase 3 使用，本期通常传 nil）
/// @param onChunk 流式片段回调（delta 为本次累计的内容增量；toolCalls 透传，Phase 3 使用）
/// @param onComplete 请求结束回调（fullResponse 含 @"content" 全文；error 为空表示成功）
- (void)streamChatWithProvider:(AiProvider *)provider
                      messages:(NSArray<AiMessage *> *)messages
                         tools:(nullable NSArray<NSDictionary *> *)tools
                       onChunk:(void (^)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls))onChunk
                    onComplete:(void (^)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error))onComplete;

/// 取消当前请求（供停止按钮）
- (void)stop;

@end

NS_ASSUME_NONNULL_END