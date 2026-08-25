//
//  AiAgent.m
//  Amethyst
//

#import "AiAgent.h"
#import "AiMessage.h"
#import "AiSessionStore.h"
#import "AiSettings.h"
#import "AiAPIClient.h"
#import "AiToolRegistry.h"
#import "AiSafetyManager.h"

/// 工具循环最多轮数
static const NSInteger kMaxToolRounds = 10;
/// 同一工具调用最多尝试次数（含失败）
static const NSInteger kMaxToolAttempts = 3;

@interface AiAgent ()
@property (nonatomic, strong) AiAPIClient *client;

// 工具循环运行时状态（一次 sendUserMessage 生命周期内有效）
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *attempts; // toolCallID -> 已尝试次数
@property (nonatomic, assign) NSInteger toolRound;                                   // 当前工具轮数
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
        _attempts = [NSMutableDictionary dictionary];
    }
    return self;
}

/// 会话持久化（每轮工具往返后调用，保证打断/杀进程后 history 完整）
- (void)saveSession:(AiSession *)session {
    if (!session) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AiSessionStore sharedStore] updateSession:session];
    });
}

/// 累积流式 tool_calls 片段：按 index 合并 name 与 args（arguments 为逐片增量拼接）
- (void)accumulateToolCalls:(NSArray *)rawToolCalls
                       into:(NSMutableDictionary *)accumulator {
    for (id item in rawToolCalls) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *tc = item;
        NSNumber *idxNum = tc[@"index"];
        NSInteger idx = (idxNum && [idxNum isKindOfClass:[NSNumber class]]) ? idxNum.integerValue : (NSInteger)accumulator.count;
        NSMutableDictionary *entry = accumulator[@(idx)];
        if (!entry) {
            entry = [NSMutableDictionary dictionary];
            entry[@"index"] = @(idx);
            accumulator[@(idx)] = entry;
        }
        // id 通常只在首片段出现
        if ([tc[@"id"] isKindOfClass:[NSString class]] && [tc[@"id"] length] > 0) {
            entry[@"id"] = tc[@"id"];
        }
        NSDictionary *func = tc[@"function"];
        if ([func isKindOfClass:[NSDictionary class]]) {
            if ([func[@"name"] isKindOfClass:[NSString class]] && [func[@"name"] length] > 0) {
                entry[@"name"] = func[@"name"];
            }
            if ([func[@"arguments"] isKindOfClass:[NSString class]]) {
                NSString *prev = entry[@"arguments"] ?: @"";
                entry[@"arguments"] = [prev stringByAppendingString:func[@"arguments"]];
            }
        }
    }
}

/// 解析工具参数 JSON 字符串为字典（失败返回空字典）
- (NSDictionary *)parseArgumentsJSON:(NSString *)jsonString {
    if (jsonString.length == 0) return @{};
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        return obj;
    }
    return @{};
}

/// 发送用户消息，驱动工具循环
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

    // 初始化循环状态
    self.running = YES;
    self.toolRound = 0;
    [self.attempts removeAllObjects];

    // 追加用户消息
    AiMessage *userMessage = [AiMessage messageWithRole:@"user" content:text ?: @""];
    [session.messages addObject:userMessage];

    [self startRoundInSession:session
                     provider:provider
                 chunkHandler:chunkHandler
           completionHandler:completionHandler];
}

#pragma mark - 工具循环：单轮请求

- (void)startRoundInSession:(AiSession *)session
                   provider:(AiProvider *)provider
               chunkHandler:(void (^)(NSString *partial))chunkHandler
         completionHandler:(void (^)(NSError *error))completionHandler {
    if (!self.running) return;

    // 轮数护栏
    if (self.toolRound >= kMaxToolRounds) {
        AiMessage *capMsg = [AiMessage messageWithRole:@"assistant" content:@"本轮工具调用已达上限，请让用户进一步说明。"];
        [session.messages addObject:capMsg];
        [self saveSession:session];
        self.running = NO;
        if (completionHandler) completionHandler(nil);
        return;
    }

    // 1. 拼装 payload：system + 历史（剔除流式占位、含 tool 消息）
    NSMutableArray *payloadMessages = [NSMutableArray array];
    NSString *systemPrompt = [[AiSettings sharedSettings] systemPrompt];

    // 2. 工具定义
    NSArray *tools = [[AiToolRegistry sharedRegistry] openAIToolSchemas];

    // 关键修复（AI 不知道自己能使用工具）：即便 tools 随请求作为 functions 传入，
    // 若系统提示未点明，模型往往只给文字建议而不主动调用工具。
    // 因此在存在工具时向 system prompt 追加一句明确的能力说明（不覆盖用户自定义内容，仅追加其尾）。
    if (tools.count > 0) {
        systemPrompt = [systemPrompt stringByAppendingString:@"\n\n你可以调用内置工具来直接操控启动器，例如：排查并分析崩溃日志、读取已安装的游戏版本与组件状态、安装 Minecraft 版本或 Mod 加载器等、下载/安装模组、光影、资源包、数据包。当用户的请求可以通过这些工具完成时，请主动调用合适的工具去执行，而不是只给出文字建议；也请结合工具返回结果继续推进任务。"];
    }
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

    __weak typeof(self) weakSelf = self;
    __block NSMutableDictionary *accToolCalls = [NSMutableDictionary dictionary];

    [self.client streamChatWithProvider:provider
                               messages:payloadMessages
                                  tools:tools
                                onChunk:^(NSString * _Nullable delta, NSDictionary * _Nullable toolCalls) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) return;
        if (delta.length > 0) {
            assistantMessage.content = [assistantMessage.content stringByAppendingString:delta];
            if (chunkHandler) chunkHandler(delta);
        }
        NSArray *raw = toolCalls[@"tool_calls"];
        if ([raw isKindOfClass:[NSArray class]] && raw.count > 0) {
            [strongSelf accumulateToolCalls:raw into:accToolCalls];
        }
    } onComplete:^(NSDictionary * _Nullable fullResponse, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        assistantMessage.streaming = NO;

        // 停止请求：直接收尾，不触发 completionHandler（UI 已由停止按钮复位）
        if (!strongSelf.running) {
            [strongSelf saveSession:session];
            return;
        }

        if (error) {
            // 出错：不追加错误消息到 history，仅 completionHandler 通知 UI 弹错
            if (assistantMessage.content.length == 0) {
                [session.messages removeObject:assistantMessage];
            }
            [strongSelf saveSession:session];
            strongSelf.running = NO;
            if (completionHandler) completionHandler(error);
            return;
        }

        if (accToolCalls.count > 0) {
            // 进入工具执行阶段
            [strongSelf saveSession:session];
            [strongSelf runToolCalls:accToolCalls
                    assistantMessage:assistantMessage
                             session:session
                            provider:provider
                        chunkHandler:chunkHandler
                  completionHandler:completionHandler];
        } else {
            // 无工具调用，正常结束
            [strongSelf saveSession:session];
            strongSelf.running = NO;
            if (completionHandler) completionHandler(nil);
        }
    }];
}

#pragma mark - 工具执行阶段

/// 按副本 index 升序逐个执行工具；全部完成后决定是继续下一轮还是收尾
- (void)runToolCalls:(NSDictionary *)accToolCalls
    assistantMessage:(AiMessage *)assistantMessage
             session:(AiSession *)session
            provider:(AiProvider *)provider
        chunkHandler:(void (^)(NSString *partial))chunkHandler
  completionHandler:(void (^)(NSError *error))completionHandler {
    NSArray *allValues = accToolCalls.allValues;
    NSArray *orderedCalls = [allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger ia = [a[@"index"] integerValue];
        NSInteger ib = [b[@"index"] integerValue];
        return (ia > ib) ? NSOrderedDescending : ((ia < ib) ? NSOrderedAscending : NSOrderedSame);
    }];

    // 把首个调用挂到助手消息上（isToolCall），其余调用以 toolCallMessage 追加，
    // 序列化时这些连续的 isToolCall 助手消息被合并为同一条 assistant tool_calls 数组（见 AiAPIClient）。
    for (NSUInteger i = 0; i < orderedCalls.count; i++) {
        NSDictionary *call = orderedCalls[i];
        NSString *callID = call[@"id"];
        if (callID.length == 0) callID = [NSString stringWithFormat:@"call_%ld", (long)[call[@"index"] integerValue]];
        NSString *name = call[@"name"];
        NSString *args = call[@"arguments"] ?: @"";
        if (i == 0) {
            assistantMessage.isToolCall = YES;
            assistantMessage.toolCallID = callID;
            assistantMessage.toolName = name ?: @"";
            assistantMessage.toolArguments = args;
        } else {
            AiMessage *tc = [AiMessage toolCallMessageWithName:name ?: @"" arguments:args];
            tc.toolCallID = callID;
            [session.messages addObject:tc];
        }
    }
    [self saveSession:session];

    __block NSError *terminalError = nil;
    __weak typeof(self) weakSelf = self;

    // 逐个异步执行工具。用 __block 自引用保持递归块在异步回调期间存活，
    // 终止分支（完成 / 错误 / 停止）时置 nil 断开自引用，避免循环持有。
    __block void (^executeBlock)(NSUInteger);
    executeBlock = ^(NSUInteger offset) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) { executeBlock = nil; return; }

        if (offset >= orderedCalls.count) {
            // 该轮全部工具执行完毕
            if (strongSelf.running == NO) { executeBlock = nil; return; }
            if (terminalError) {
                // 达到重试上限，以最终错误结束本轮
                strongSelf.running = NO;
                if (completionHandler) completionHandler(terminalError);
                executeBlock = nil;
                return;
            }
            strongSelf.toolRound++;
            [strongSelf startRoundInSession:session
                                   provider:provider
                               chunkHandler:chunkHandler
                         completionHandler:completionHandler];
            executeBlock = nil; // 本轮结束
            return;
        }

        NSDictionary *call = orderedCalls[offset];
        NSString *callID = call[@"id"];
        NSString *name = call[@"name"];
        NSString *arguments = call[@"arguments"] ?: @"";
        if (callID.length == 0) callID = [NSString stringWithFormat:@"call_%ld", (long)[call[@"index"] integerValue]];

        // 重试护栏：同一 callID 已执行 ≥3 次则不再回喂
        NSInteger attempts = [strongSelf.attempts[callID] integerValue];
        if (attempts >= kMaxToolAttempts) {
            [session.messages addObject:[AiMessage toolResultMessageWithContent:[NSString stringWithFormat:@"多次尝试仍失败：%@", name ?: @""] toolCallID:callID]];
            [strongSelf saveSession:session];
            terminalError = [NSError errorWithDomain:@"AiAgent" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"工具 %@ 多次尝试仍失败", name ?: callID]}];
            executeBlock(offset + 1);
            return;
        }
        attempts++;
        strongSelf.attempts[callID] = @(attempts);

        // 校验工具是否存在
        id<AiTool> tool = [[AiToolRegistry sharedRegistry] toolForName:name ?: @""];
        if (!tool) {
            [session.messages addObject:[AiMessage toolResultMessageWithContent:[NSString stringWithFormat:@"未知工具：%@", name ?: @""] toolCallID:callID]];
            [strongSelf saveSession:session];
            executeBlock(offset + 1);
            return;
        }

        NSDictionary *normalizedParams = [[AiToolRegistry sharedRegistry] normalizedParams:[strongSelf parseArgumentsJSON:arguments]];

        // 安全确认（DangerousWrite 等需确认时阻塞等待用户选择）
        void (^proceed)(void) = ^{
            __strong typeof(weakSelf) ss2 = weakSelf;
            if (!ss2 || !ss2.running) { executeBlock = nil; return; }
            [[AiToolRegistry sharedRegistry] executeToolNamed:name ?: @""
                                                       params:normalizedParams
                                                   completion:^(NSString * _Nullable result, NSError * _Nullable error) {
                __strong typeof(weakSelf) ss3 = weakSelf;
                if (!ss3) { executeBlock = nil; return; }
                NSString *content = result;
                if (content.length == 0 && error) content = error.localizedDescription;
                if (content.length == 0) content = @"（无返回）";
                [session.messages addObject:[AiMessage toolResultMessageWithContent:content toolCallID:callID]];
                [ss3 saveSession:session];
                executeBlock(offset + 1);
            }];
        };

        if ([[AiSafetyManager sharedManager] needsUserConfirmationForPermission:tool.permission]) {
            [[AiSafetyManager sharedManager] requestConfirmationWithTitle:[NSString stringWithFormat:@"AI 请求执行「%@」", name ?: @""]
                                                                  message:[NSString stringWithFormat:@"该工具需要你确认后才执行。\n参数：%@", arguments]
                                                              completion:^(BOOL approved) {
                __strong typeof(weakSelf) ss4 = weakSelf;
                if (!ss4 || !ss4.running) { executeBlock = nil; return; }
                if (!approved) {
                    [session.messages addObject:[AiMessage toolResultMessageWithContent:@"用户已取消该操作" toolCallID:callID]];
                    [ss4 saveSession:session];
                    executeBlock(offset + 1);
                    return;
                }
                proceed();
            }];
        } else {
            proceed();
        }
    };
    executeBlock(0);
}

#pragma mark - 停止

- (void)stopCurrent {
    if (self.client) [self.client stop];
    self.running = NO;
}

@end