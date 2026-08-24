//
//  AiMessage.m
//  Amethyst
//

#import "AiMessage.h"

@implementation AiMessage

+ (instancetype)messageWithRole:(NSString *)role content:(NSString *)content {
    AiMessage *message = [[AiMessage alloc] init];
    message.role = role ?: @"user";
    message.content = content ?: @"";
    return message;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _role = @"user";
        _content = @"";
        _streaming = NO;
        _createdAt = [NSDate date];
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    self = [self init];
    if (!self) return nil;
    if ([dict[@"role"] isKindOfClass:[NSString class]]) _role = dict[@"role"];
    if ([dict[@"content"] isKindOfClass:[NSString class]]) _content = dict[@"content"];
    // 时间戳（可选）
    NSNumber *ts = dict[@"createdAt"];
    if ([ts isKindOfClass:[NSNumber class]]) {
        _createdAt = [NSDate dateWithTimeIntervalSince1970:ts.doubleValue];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    return @{
        @"role": self.role ?: @"",
        @"content": self.content ?: @"",
        @"createdAt": @([self.createdAt timeIntervalSince1970]),
    };
}

@end