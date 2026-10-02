//
//  AiAPIClient.m
//  Amethyst
//
//  说明（多模态图片）：本类负责把 AiMessage 列表序列化成 OpenAI 的 messages。
//  带图片的消息（AiMessage.imageDataURLs 非空）会把 content 写成内容数组
//  [{type:text,text:...},{type:image_url,image_url:{url:data:...}}]；
//  其余消息保持纯字符串格式，兼容性最好。
//  注意：role=tool 的消息不能携带图片（OpenAI 限制），所以图片统一走 user 消息；
//  图片由 AiAgent 在本轮工具结果全部按序落盘后补一条 user 消息送出，
//  这样 assistant(tool_calls) → tool 的配对顺序不会被破坏，不会触发 HTTP 400。
//

#import "AiAPIClient.h"

/// 节流阈值：流式回调最多每 200ms 触发一次，避免主队列/UI 过载
static const NSTimeInterval kChunkThrottleInterval = 0.2;

@interface AiAPIClient () <NSURLSessionDataDelegate>
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;

@property (nonatomic, copy, nullable) void (^onChunk)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls);
@property (nonatomic, copy, nullable) void (^onComplete)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error);

@property (nonatomic, strong) NSMutableString *streamBuffer;
@property (nonatomic, strong) NSMutableData *streamData;
@property (nonatomic, strong) NSMutableString *fullResponseText;
@property (nonatomic, strong) NSMutableString *pendingDelta;
@property (nonatomic, assign) NSTimeInterval lastChunkFlushTime;
@property (nonatomic, assign) BOOL streamDone;
@property (nonatomic, assign) NSInteger statusCode;
@end

@implementation AiAPIClient

- (instancetype)init {
    self = [super init];
    if (self) {
        self.streamBuffer = [NSMutableString string];
        self.streamData = [NSMutableData data];
        self.fullResponseText = [NSMutableString string];
        self.pendingDelta = [NSMutableString string];
    }
    return self;
}

- (void)dealloc {
    [self.session invalidateAndCancel];
}

#pragma mark - 请求入口

- (void)streamChatWithProvider:(AiProvider *)provider
                      messages:(NSArray<AiMessage *> *)messages
                         tools:(nullable NSArray<NSDictionary *> *)tools
                       onChunk:(void (^)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls))onChunk
                    onComplete:(void (^)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error))onComplete {
    if (!provider || provider.baseURL.length == 0 || provider.model.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiAPIClient" code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"AI 提供商配置不完整（缺少 baseURL 或 model）"}];
        if (onComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, err); });
        }
        return;
    }

    self.onChunk = onChunk;
    self.onComplete = onComplete;
    [self.streamBuffer setString:@""];
    [self.streamData setLength:0];
    [self.fullResponseText setString:@""];
    [self.pendingDelta setString:@""];
    self.streamDone = NO;
    self.statusCode = 0;

    NSString *base = provider.baseURL;
    if (![base hasSuffix:@"/"]) {
        base = [base stringByAppendingString:@"/"];
    }
    NSString *urlString = [base stringByAppendingString:@"chat/completions"];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *err = [NSError errorWithDomain:@"AiAPIClient" code:101
                                        userInfo:@{NSLocalizedDescriptionKey: @"无效的 API 地址"}];
        if (onComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, err); });
        }
        return;
    }

    NSMutableArray *payloadMessages = [NSMutableArray array];
    __block NSString *pendingAssistantContent = @"";
    __block NSMutableArray *pendingToolCalls = nil;
    dispatch_block_t flushPendingToolCalls = ^{
        if (pendingToolCalls.count == 0) { pendingToolCalls = nil; return; }
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"role"] = @"assistant";
        entry[@"content"] = pendingAssistantContent ?: @"";
        entry[@"tool_calls"] = pendingToolCalls;
        [payloadMessages addObject:entry];
        pendingToolCalls = nil;
        pendingAssistantContent = @"";
    };
    for (AiMessage *m in messages) {
        if (m.streaming) continue;

        if (m.isToolCall && [m.role isEqualToString:@"assistant"]) {
            if (!pendingToolCalls) {
                pendingToolCalls = [NSMutableArray array];
                pendingAssistantContent = m.content ?: @"";
            } else if (m.content.length > 0 && pendingAssistantContent.length == 0) {
                pendingAssistantContent = m.content;
            }
            NSMutableDictionary *func = [NSMutableDictionary dictionary];
            if (m.toolName.length > 0) func[@"name"] = m.toolName;
            if (m.toolArguments.length > 0) func[@"arguments"] = m.toolArguments;
            NSMutableDictionary *call = [NSMutableDictionary dictionary];
            if (m.toolCallID.length > 0) call[@"id"] = m.toolCallID;
            call[@"type"] = @"function";
            call[@"function"] = func;
            [pendingToolCalls addObject:call];
            continue;
        }

        flushPendingToolCalls();

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"role"] = m.role ?: @"";
        if (m.imageDataURLs.count > 0) {
            NSMutableArray *parts = [NSMutableArray array];
            if (m.content.length > 0) {
                [parts addObject:@{@"type": @"text", @"text": m.content}];
            }
            for (id imageURL in m.imageDataURLs) {
                if (![imageURL isKindOfClass:[NSString class]] || [(NSString *)imageURL length] == 0) continue;
                [parts addObject:@{@"type": @"image_url", @"image_url": @{@"url": imageURL}}];
            }
            entry[@"content"] = parts.count > 0 ? parts : (m.content ?: @"");
        } else {
            entry[@"content"] = m.content ?: @"";
        }
        if ([m.role isEqualToString:@"tool"] && m.toolCallID.length > 0) {
            entry[@"tool_call_id"] = m.toolCallID;
        }
        [payloadMessages addObject:entry];
    }
    flushPendingToolCalls();

    // ===== 历史清洗：剔除「悬空工具调用」（防止 HTTP 400）=====
    {
        NSMutableDictionary<NSString *, NSNumber *> *resultIndexForCallID = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < payloadMessages.count; i++) {
            NSDictionary *entry = payloadMessages[i];
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            if (![entry[@"role"] isEqualToString:@"tool"]) continue;
            NSString *cid = entry[@"tool_call_id"];
            if ([cid isKindOfClass:[NSString class]] && cid.length > 0 && !resultIndexForCallID[cid]) {
                resultIndexForCallID[cid] = @(i);
            }
        }

        NSMutableArray *sanitized = [NSMutableArray arrayWithCapacity:payloadMessages.count];
        for (NSUInteger i = 0; i < payloadMessages.count; i++) {
            NSDictionary *entry = payloadMessages[i];
            if (![entry isKindOfClass:[NSDictionary class]]) continue;

            NSString *role = entry[@"role"];
            BOOL isAssistant = [role isEqualToString:@"assistant"];
            BOOL isToolResult = [role isEqualToString:@"tool"];

            if (isToolResult) {
                NSString *cid = entry[@"tool_call_id"];
                BOOL valid = NO;
                if ([cid isKindOfClass:[NSString class]] && cid.length > 0) {
                    for (NSUInteger j = 0; j < i; j++) {
                        NSDictionary *prev = payloadMessages[j];
                        NSArray *calls = prev[@"tool_calls"];
                        if (![calls isKindOfClass:[NSArray class]]) continue;
                        for (NSDictionary *c in calls) {
                            if ([c[@"id"] isEqualToString:cid]) { valid = YES; break; }
                        }
                        if (valid) break;
                    }
                }
                if (valid) [sanitized addObject:entry];
                continue;
            }

            if (isAssistant) {
                NSArray *calls = entry[@"tool_calls"];
                if ([calls isKindOfClass:[NSArray class]] && calls.count > 0) {
                    NSMutableArray *keptCalls = [NSMutableArray array];
                    for (NSDictionary *c in calls) {
                        NSString *cid = c[@"id"];
                        BOOL closed = NO;
                        if ([cid isKindOfClass:[NSString class]] && cid.length > 0) {
                            NSNumber *resultIdx = resultIndexForCallID[cid];
                            closed = (resultIdx != nil && resultIdx.unsignedIntegerValue > i);
                        }
                        if (closed) [keptCalls addObject:c];
                    }
                    if (keptCalls.count == 0) {
                        NSString *content = entry[@"content"];
                        if ([content isKindOfClass:[NSString class]] && content.length > 0) {
                            [sanitized addObject:@{@"role": @"assistant", @"content": content}];
                        }
                        continue;
                    }
                    NSMutableDictionary *newEntry = [entry mutableCopy];
                    newEntry[@"tool_calls"] = keptCalls;
                    [sanitized addObject:newEntry];
                    continue;
                }
            }

            [sanitized addObject:entry];
        }

        // 兜底：丢弃空 assistant 消息与空 tool 结果。
        // content 现在可能是内容数组（多模态），判断要同时兼容 NSString / NSArray。
        NSMutableArray *compacted = [NSMutableArray arrayWithCapacity:sanitized.count];
        for (NSDictionary *entry in sanitized) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *role = entry[@"role"];
            id contentValue = entry[@"content"];
            BOOL hasContent = NO;
            if ([contentValue isKindOfClass:[NSString class]]) hasContent = ([(NSString *)contentValue length] > 0);
            else if ([contentValue isKindOfClass:[NSArray class]]) hasContent = ([(NSArray *)contentValue count] > 0);
            BOOL hasToolCalls = [entry[@"tool_calls"] isKindOfClass:[NSArray class]] && [entry[@"tool_calls"] count] > 0;
            BOOL hasToolCallID = [entry[@"tool_call_id"] isKindOfClass:[NSString class]] && [(NSString *)entry[@"tool_call_id"] length] > 0;
            if ([role isEqualToString:@"assistant"] && !hasContent && !hasToolCalls) continue;
            if ([role isEqualToString:@"tool"] && !hasToolCallID) continue;
            [compacted addObject:entry];
        }
        payloadMessages = compacted;
    }

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = provider.model ?: @"";
    body[@"messages"] = payloadMessages;
    body[@"stream"] = @YES;
    body[@"temperature"] = @(provider.temperature);
    body[@"max_tokens"] = @(provider.maxTokens);
    if (tools.count > 0) {
        body[@"tools"] = tools;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (provider.apiKey.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", provider.apiKey] forHTTPHeaderField:@"Authorization"];
    }
    request.timeoutInterval = 120;
    NSError *serializeError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializeError];
    if (serializeError || !request.HTTPBody) {
        if (onComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{ onComplete(nil, serializeError); });
        }
        return;
    }

    if (!self.session) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120;
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    }

    self.currentTask = [self.session dataTaskWithRequest:request];
    [self.currentTask resume];
}

#pragma mark - 取消

- (void)stop {
    [self.currentTask cancel];
}

#pragma mark - 连通性测试

- (void)testConnectionWithProvider:(AiProvider *)provider
                        completion:(void (^)(NSString * _Nullable successMessage, NSError * _Nullable error))completion {
    if (!provider || provider.baseURL.length == 0 || provider.model.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiAPIClient" code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"AI 提供商配置不完整（缺少 baseURL 或 model）"}];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        }
        return;
    }

    AiMessage *ping = [AiMessage messageWithRole:@"user" content:@"ping"];
    [self streamChatWithProvider:provider
                        messages:@[ping]
                           tools:nil
                         onChunk:nil
                      onComplete:^(NSDictionary * _Nullable fullResponse, NSError * _Nullable error) {
        if (completion) {
            if (error) {
                completion(nil, error);
            } else {
                completion(@"连接成功", nil);
            }
        }
    }];
}

#pragma mark - 流式解析

- (void)processBufferedStreamData {
    if (self.streamData.length == 0) return;
    static unsigned char lf = '\n';
    NSData *lfData = [NSData dataWithBytes:&lf length:1];
    NSRange lastLF = [self.streamData rangeOfData:lfData options:NSDataSearchBackwards
                                            range:NSMakeRange(0, self.streamData.length)];
    if (lastLF.location == NSNotFound) return;
    NSUInteger completeLen = lastLF.location + 1;
    NSData *completeData = [self.streamData subdataWithRange:NSMakeRange(0, completeLen)];
    NSString *text = [[NSString alloc] initWithData:completeData encoding:NSUTF8StringEncoding];
    if (text.length > 0) {
        [self processStreamText:text];
    }
    [self.streamData replaceBytesInRange:NSMakeRange(0, completeLen) withBytes:NULL length:0];
}

- (void)processStreamText:(NSString *)text {
    if (text.length == 0 || self.streamDone) return;
    [self.streamBuffer appendString:text];

    NSInteger consumed = 0;
    NSRange range;
    BOOL done = NO;
    while (!done) {
        range = [self.streamBuffer rangeOfString:@"\n"];
        if (range.location == NSNotFound) break;
        NSString *line = [self.streamBuffer substringToIndex:range.location];
        NSRange fullRange = NSMakeRange(0, range.location + 1);
        [self.streamBuffer deleteCharactersInRange:fullRange];
        consumed += range.location + 1;
        [self processStreamLine:line];
    }
    (void)consumed;

    if (self.streamBuffer.length > 1024 * 1024) {
        [self.streamBuffer setString:@""];
    }
}

- (void)processStreamLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    // 前缀兼容："data: " / "data:" / 整行无前缀
    NSString *payload = nil;
    if ([trimmed hasPrefix:@"data: "]) {
        payload = [trimmed substringFromIndex:6];
    } else if ([trimmed hasPrefix:@"data:"]) {
        payload = [trimmed substringFromIndex:5];
    } else {
        payload = trimmed;
    }
    NSString *payloadTrimmed = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([payloadTrimmed isEqualToString:@"[DONE]"]) {
        self.streamDone = YES;
        return;
    }

    NSData *jsonData = [payloadTrimmed dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || ![json isKindOfClass:[NSDictionary class]]) return;

    NSArray *choices = json[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) return;
    NSDictionary *choice = choices[0];
    if (![choice isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *delta = choice[@"delta"];
    if (![delta isKindOfClass:[NSDictionary class]]) return;

    id content = delta[@"content"];
    NSString *deltaText = nil;
    if ([content isKindOfClass:[NSString class]] && content != (id)[NSNull null]) {
        deltaText = content;
        [self.fullResponseText appendString:deltaText];
        [self.pendingDelta appendString:deltaText];
    }

    NSArray *toolCallArr = delta[@"tool_calls"];
    if ([toolCallArr isKindOfClass:[NSArray class]]) {
        NSDictionary *toolCallsInfo = @{@"tool_calls": toolCallArr};
        void (^chunk)(NSString *, NSDictionary *) = self.onChunk;
        if (chunk) {
            NSString *emptyDelta = @"";
            dispatch_async(dispatch_get_main_queue(), ^{ chunk(emptyDelta, toolCallsInfo); });
        }
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - self.lastChunkFlushTime) >= kChunkThrottleInterval) {
        [self flushPendingDelta];
    }
}

- (void)flushPendingDelta {
    if (self.pendingDelta.length > 0 && self.onChunk) {
        NSString *delta = [self.pendingDelta copy];
        [self.pendingDelta setString:@""];
        void (^chunk)(NSString *, NSDictionary *) = self.onChunk;
        if (chunk) {
            NSString *safeDelta = delta;
            dispatch_async(dispatch_get_main_queue(), ^{ chunk(safeDelta, nil); });
        }
    }
    self.lastChunkFlushTime = [[NSDate date] timeIntervalSince1970];
}

#pragma mark - 错误构造

- (NSError *)errorFromResponseBody {
    NSString *body = self.fullResponseText.length > 0 ? self.fullResponseText : @"";
    NSString *message = [NSString stringWithFormat:@"请求失败（HTTP %ld）", (long)self.statusCode];
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0 error:&jsonError];
    if (json && [json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *errorObj = json[@"error"];
        if ([errorObj isKindOfClass:[NSDictionary class]] && [errorObj[@"message"] isKindOfClass:[NSString class]]) {
            NSString *m = errorObj[@"message"];
            if (m.length > 0) message = m;
        }
    }
    return [NSError errorWithDomain:@"AiAPIClient" code:self.statusCode
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.statusCode = [(NSHTTPURLResponse *)response statusCode];
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.streamDone) return;
    if (data.length == 0) return;
    // 字节级缓冲：只解码以 \n 结尾的完整字节串，避免多字节字符被块边界切断而丢字
    [self.streamData appendData:data];
    [self processBufferedStreamData];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.streamDone = YES;

    void (^complete)(NSDictionary *, NSError *) = self.onComplete;
    self.onComplete = nil;
    self.onChunk = nil;

    if (error) {
        NSError *outError = error;
        if (error.code == NSURLErrorCancelled) {
            outError = [NSError errorWithDomain:@"AiAPIClient" code:NSURLErrorCancelled
                                       userInfo:@{NSLocalizedDescriptionKey: @"已停止生成"}];
        }
        [self flushPendingDelta];
        if (complete) {
            dispatch_async(dispatch_get_main_queue(), ^{ complete(nil, outError); });
        }
        return;
    }

    if (self.statusCode != 0 && self.statusCode != 200) {
        [self flushPendingDelta];
        NSError *apiError = [self errorFromResponseBody];
        if (complete) {
            dispatch_async(dispatch_get_main_queue(), ^{ complete(nil, apiError); });
        }
        return;
    }

    if (self.streamData.length > 0) {
        NSString *tail = [[NSString alloc] initWithData:self.streamData encoding:NSUTF8StringEncoding];
        if (tail.length > 0) {
            [self processStreamText:tail];
        }
        [self.streamData setLength:0];
    }
    if (self.streamBuffer.length > 0) {
        NSString *tailLine = [self.streamBuffer copy];
        [self.streamBuffer setString:@""];
        [self processStreamLine:tailLine];
    }
    [self flushPendingDelta];
    NSDictionary *fullResponse = @{@"content": [self.fullResponseText copy] ?: @""};
    if (complete) {
        dispatch_async(dispatch_get_main_queue(), ^{ complete(fullResponse, nil); });
    }
}

@end
