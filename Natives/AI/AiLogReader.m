//
//  AiLogReader.m
//  Amethyst
//

#import "AiLogReader.h"
#import "LauncherPreferences.h"

@interface AiLogReader ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiLogReader

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"read_crash_report"]) {
        return @"读取最新一份崩溃报告（crash-report 目录中修改时间最新的 .txt 文件）。"
               "\n无参数。"
               "\n说明：优先读取 logs/crash-reports/ 目录，其次回退到 crash-reports/ 目录，返回最新 .txt 的内容，截断为末尾 6000 字符。"
               "\n边界：目录或文件不存在时返回「未找到崩溃报告」。";
    }
    // read_latest_log
    return @"读取当前选中实例的最近启动日志（logs/latest.log）。"
           "\n无参数。"
           "\n说明：返回日志末尾 4000 字符（过长时起始部分被截断并注明）。文件不存在时返回「未找到日志」。"
           "\n边界：仅读取 .log 文件，绝不读取其它类型文件。";
}

#pragma mark - 路径

/// 当前实例根目录（POJAV_GAME_DIR 或其回退）
+ (NSString *)currentGameRoot {
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return @(root);
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) {
        NSString *name = getPrefObject(@"general.game_directory");
        if (name.length == 0) name = @"default";
        return [NSString stringWithFormat:@"%s/instances/%@", home, name];
    }
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

/// 截断内容：保留末尾 N 字符，若被截断则在开头注明
- (NSString *)truncatedContent:(NSString *)content maxChars:(NSUInteger)max header:(NSString *)header {
    if (content.length <= max) return content;
    NSString *tail = [content substringFromIndex:(content.length - max)];
    return [header stringByAppendingString:tail];
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *gameRoot = [[self class] currentGameRoot];

    if ([self.internalName isEqualToString:@"read_crash_report"]) {
        NSString *content = [self latestCrashReportInGameRoot:gameRoot];
        completion(content ?: @"未找到崩溃报告", nil);
        return;
    }
    if ([self.internalName isEqualToString:@"read_latest_log"]) {
        NSString *logPath = [gameRoot stringByAppendingPathComponent:@"logs/latest.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:logPath isDirectory:&isDir] || isDir) {
            completion(@"未找到日志", nil);
            return;
        }
        NSString *content = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
        if (!content) {
            content = [NSString stringWithContentsOfFile:logPath encoding:NSISOLatin1StringEncoding error:nil];
        }
        if (!content) {
            completion(@"读取日志失败", nil);
            return;
        }
        NSString *result = [self truncatedContent:content
                                          maxChars:4000
                                            header:@"（日志过长已截断，显示末尾 4000 字符）\n"];
        completion(result, nil);
        return;
    }

    NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未知工具 %@", self.internalName]}];
    completion(nil, err);
}

/// 查找最新崩溃报告（优先 logs/crash-reports/，回退 crash-reports/）
- (NSString *)latestCrashReportInGameRoot:(NSString *)gameRoot {
    NSArray *candidates = @[
        [gameRoot stringByAppendingPathComponent:@"logs/crash-reports"],
        [gameRoot stringByAppendingPathComponent:@"crash-reports"],
    ];
    NSString *bestPath = nil;
    NSDate *bestDate = nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *dir in candidates) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            if (![file hasSuffix:@".txt"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs[NSFileType] || [NSFileTypeDirectory isEqualToString:attrs[NSFileType]]) continue;
            NSDate *mtime = attrs[NSFileModificationDate];
            if (!mtime) mtime = [NSDate distantPast];
            if (bestDate == nil || [mtime compare:bestDate] == NSOrderedDescending) {
                bestDate = mtime;
                bestPath = full;
            }
        }
    }
    if (!bestPath) return nil;

    NSString *content = [NSString stringWithContentsOfFile:bestPath encoding:NSUTF8StringEncoding error:nil];
    if (!content) content = [NSString stringWithContentsOfFile:bestPath encoding:NSISOLatin1StringEncoding error:nil];
    if (!content) return nil;

    return [self truncatedContent:content maxChars:6000 header:@"（崩溃报告过长已截断，显示末尾 6000 字符）\n"];
}

@end