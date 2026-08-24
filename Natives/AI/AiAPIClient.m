//
//  AiAPIClient.m
//  Amethyst
//

#import "AiAPIClient.h"

/// 节流阈值：流式回调最多每 200ms 触发一次，避免主队列/UI 过载
static const NSTimeInterval kChunkThrottleInterval = 0.2;

@interface AiAPIClient () <NSURLSessionDataDelegate>
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentTask;

@property (nonatomic, copy, nullable) void (^onChunk)(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls);
@property (nonatomic, copy, nullable) void (^onComplete)(NSDictionary * _Nullable fullResponse, NSError * _Nullable error);

@property (nonatomic, strong) NSMutableString *streamBuffer;    // 未切分完的流缓冲
@property (nonatomic, strong) NSMutableString *fullResponseText; // 已接收全文
@property (nonatomic, strong) NSMutableString *pendingDelta;     // 待节流刷新的增量
@property (nonatomic, assign) NSTimeInterval lastChunkFlushTime;
@property (nonatomic, assign) BOOL streamDone;
@property (nonatomic, assign) NSInteger statusCode;
@end

@implementation AiAPIClient

- (instancetype)init {
    self = [super init];
    if (self) {
        self.streamBuffer = [NSMutableString string];
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
    [self.fullResponseText setString:@""];
    [self.pendingDelta setString:@""];
    self.streamDone = NO;
    self.statusCode = 0;

    // 构造 URL：baseURL 末尾不是 / 则补 /，再拼 chat/completions
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

    // Body
    NSMutableArray *payloadMessages = [NSMutableArray array];
    for (AiMessage *m in messages) {
        // 跳过流式占位消息
        if (m.streaming) continue;
        [payloadMessages addObject:@{
            @"role": m.role ?: @"",
            @"content": m.content ?: @"",
        }];
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

    // 会话（后台专用队列解析，避免阻塞主线程）
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

#pragma mark - 流式解析

/// 追加接收到的文本并切行处理
- (void)processStreamText:(NSString *)text {
    if (text.length == 0 || self.streamDone) return;
    [self.streamBuffer appendString:text];

    // 每次处理缓冲里完整的一行
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

    // 缓冲过大但一直没换行符（异常）时清空，避免无限累积
    if (self.streamBuffer.length > 1024 * 1024) {
        [self.streamBuffer setString:@""];
    }
}

- (void)processStreamLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    if (![trimmed hasPrefix:@"data: "]) return;

    NSString *payload = [trimmed substringFromIndex:6];
    NSString *payloadTrimmed = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([payloadTrimmed isEqualToString:@"[DONE]"]) {
        self.streamDone = YES;
        // 标记，交 toComplete 处理剩余刷新
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

    // tool_calls（Phase 3 使用，本期仅透传）
    NSArray *toolCallArr = delta[@"tool_calls"];
    if ([toolCallArr isKindOfClass:[NSArray class]]) {
        NSDictionary *toolCallsInfo = @{@"tool_calls": toolCallArr};
        void (^chunk)(NSString *, NSDictionary *) = self.onChunk;
        if (chunk) {
            NSString *emptyDelta = @"";
            dispatch_async(dispatch_get_main_queue(), ^{ chunk(emptyDelta, toolCallsInfo); });
        }
    }

    // 节流：距上次刷新 < 200ms 则暂存 pendingDelta，等待下次刷新/结束刷出
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
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        // 尝试兼容 BOM/非 UTF8 部分
        text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    }
    if (text.length > 0) {
        [self processStreamText:text];
    }
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

    [self flushPendingDelta];
    NSDictionary *fullResponse = @{@"content": [self.fullResponseText copy] ?: @""};
    if (complete) {
        dispatch_async(dispatch_get_main_queue(), ^{ complete(fullResponse, nil); });
    }
}

@end