//
//  AiSleepTool.m
//  Amethyst
//
//  本文件承载两个工具：
//    1) AiSleepTool —— sleep（见文件头注释）
//    2) AiImageTool —— view_image（读图；实现放在本文件的原因见 AiSleepTool.h 顶部注释）
//

#import "AiSleepTool.h"
#import "AiFileTools.h"

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

/// 单次最长等待（防模型传入超大值卡死会话）
static const double kAiSleepMaxSeconds = 120.0;

@implementation AiSleepTool

- (NSString *)name {
    return @"sleep";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"等待指定秒数后返回（用于等待后台下载推进或模拟任务间隔）。"
           "\n参数：seconds（number，可选，默认 1，上限 120）。"
           "\n返回「已等待 N 秒」。";
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    double seconds = 1.0;
    id v = params[@"seconds"];
    if ([v isKindOfClass:[NSNumber class]]) {
        seconds = [(NSNumber *)v doubleValue];
    } else if ([v isKindOfClass:[NSString class]]) {
        seconds = [(NSString *)v doubleValue];
    }
    if (seconds < 0) seconds = 0;
    if (seconds > kAiSleepMaxSeconds) seconds = kAiSleepMaxSeconds;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        completion([NSString stringWithFormat:@"已等待 %.1f 秒", seconds], nil);
    });
}

@end

#pragma mark - view_image（读图工具）

/// 缩略图默认/边界宽度（字符数）
static const NSInteger kAiImageDefaultColumns = 96;
static const NSInteger kAiImageMinColumns = 16;
static const NSInteger kAiImageMaxColumns = 200;
/// 亮度阈值：低于它视为「黑」（四周黑边判定用）
static const unsigned char kAiImageContentThreshold = 16;
/// 缩略图文本的硬上限，防止极端宽高比把返回体撑爆
static const NSUInteger kAiImageArtMaxChars = 60000;

@implementation AiImageTool

- (NSString *)name {
    return @"view_image";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"把本地图片转成「文本缩略图」，让 AI 能感知画面内容与布局（无需模型支持视觉）。"
           "\n输出三部分：像素尺寸；亮度 ASCII 缩略图（空格最黑、@ 最亮，自上而下对应图片上→下）；"
           "以及「非黑内容边界」（内容区域 + 四周黑边像素数与百分比 + 内容占比），可直接判断有没有黑边、是否铺满屏幕。"
           "\n参数：path（string，必填，图片路径；支持直接写 Documents 目录下的文件名，如 \"有视频PE.PNG\"）；"
           "width（number，可选，缩略图字符宽度，默认 96，范围 16~200，越大越清晰）。"
           "\n典型用途：对比两张截图的 UI 大小/布局差异、确认画面是否被裁切或留黑边。"
           "\n边界：只读、不改文件、不联网；只能看到明暗形状，认不出图片里的文字内容。"
           "\n示例：view_image(path=\"无视频PE.PNG\", width=120)";
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *rawPath = nil;
    id pathValue = params[@"path"];
    if ([pathValue isKindOfClass:[NSString class]]) rawPath = (NSString *)pathValue;
    if (rawPath.length == 0) {
        completion(nil, [NSError errorWithDomain:@"AiImageTool" code:400
                                        userInfo:@{NSLocalizedDescriptionKey: @"view_image 需要 path 参数（图片路径，例如 \"有视频PE.PNG\"）"}]);
        return;
    }

    NSInteger cols = kAiImageDefaultColumns;
    id widthValue = params[@"width"];
    if ([widthValue isKindOfClass:[NSNumber class]]) {
        cols = [(NSNumber *)widthValue integerValue];
    } else if ([widthValue isKindOfClass:[NSString class]]) {
        cols = [(NSString *)widthValue integerValue];
    }
    if (cols < kAiImageMinColumns) cols = kAiImageMinColumns;
    if (cols > kAiImageMaxColumns) cols = kAiImageMaxColumns;

    NSString *resolved = [AiImageTool resolveImagePath:rawPath];
    if (resolved.length == 0) {
        NSString *message = [NSString stringWithFormat:@"找不到图片：%@\n（可用 list_files 先确认文件名；支持 Documents 目录下的相对文件名）", rawPath];
        completion(nil, [NSError errorWithDomain:@"AiImageTool" code:404
                                        userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }

    // 解码/缩放放后台线程：几千万像素的截图在主线程做会卡住 UI
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = [AiImageTool renderReportForPath:resolved columns:cols];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (report.length == 0) {
                NSError *error = [NSError errorWithDomain:@"AiImageTool" code:415
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法解码这张图片（可能不是图片格式 / 文件损坏 / 空文件）：%@", resolved]}];
                completion(nil, error);
            } else {
                completion(report, nil);
            }
        });
    });
}

#pragma mark 路径解析

/// 依次尝试：文件工具的安全解析 → 启动器 Documents 根 → 原样绝对路径，返回第一个真实存在的文件
+ (nullable NSString *)resolveImagePath:(NSString *)raw {
    if (raw.length == 0) return nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // 1) 复用文件工具的安全解析（沙盒内路径 / $GAMEDIR 占位符）
    @try {
        NSString *safe = [AiFileTools resolveSafely:raw];
        if (safe.length > 0) [candidates addObject:safe];
    } @catch (NSException *exception) {
        // 忽略：解析失败继续走后两个候选
    }

    // 2) 启动器 Documents 根目录（用户常把截图直接丢在这里）
    NSArray<NSString *> *documentList = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (documentList.count > 0) {
        NSString *relative = raw;
        while ([relative hasPrefix:@"/"]) {
            relative = [relative substringFromIndex:1];
        }
        [candidates addObject:[documentList.firstObject stringByAppendingPathComponent:relative]];
    }

    // 3) 绝对路径原样
    if ([raw hasPrefix:@"/"]) [candidates addObject:raw];

    for (NSString *candidate in candidates) {
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory) {
            return candidate;
        }
    }
    return nil;
}

#pragma mark 渲染

/// 生成文本报告；解码失败返回 nil
+ (nullable NSString *)renderReportForPath:(NSString *)path columns:(NSInteger)cols {
    if (path.length == 0) return nil;

    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image == nil || image.size.width < 1.0 || image.size.height < 1.0) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length > 0) image = [UIImage imageWithData:data];
    }
    if (image == nil || image.size.width < 1.0 || image.size.height < 1.0) return nil;

    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) return nil;

    size_t pixelW = CGImageGetWidth(cgImage);
    size_t pixelH = CGImageGetHeight(cgImage);
    if (pixelW == 0 || pixelH == 0) return nil;

    size_t gridW = (size_t)cols;
    // 等宽字体里字符高度约是宽度的 2 倍，所以纵向压一半，缩略图比例才不会拉长
    double gridHeightDouble = (double)cols * ((double)pixelH / (double)pixelW) * 0.5;
    size_t gridH = (size_t)lround(gridHeightDouble);
    if (gridH < 4) gridH = 4;
    if (gridH > 120) gridH = 120;

    size_t bufferSize = gridW * gridH;
    unsigned char *gray = (unsigned char *)calloc(bufferSize, 1);
    if (gray == NULL) return nil;

    CGColorSpaceRef graySpace = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(gray, gridW, gridH, 8, gridW, graySpace, kCGImageAlphaNone);
    CGColorSpaceRelease(graySpace);
    if (context == NULL) {
        free(gray);
        return nil;
    }

    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)gridW, (CGFloat)gridH), cgImage);
    CGContextRelease(context);

    static const char *ramp = " .:-=+*#%@";
    NSMutableString *art = [NSMutableString stringWithCapacity:bufferSize + gridH];
    NSInteger minX = (NSInteger)gridW;
    NSInteger maxX = -1;
    NSInteger minY = (NSInteger)gridH;
    NSInteger maxY = -1;

    for (size_t y = 0; y < gridH; y++) {
        for (size_t x = 0; x < gridW; x++) {
            unsigned char value = gray[y * gridW + x];
            NSInteger level = (NSInteger)(((double)value / 256.0) * 10.0);
            if (level < 0) level = 0;
            if (level > 9) level = 9;
            [art appendFormat:@"%c", ramp[level]];
            if (value > kAiImageContentThreshold) {
                if ((NSInteger)x < minX) minX = (NSInteger)x;
                if ((NSInteger)x > maxX) maxX = (NSInteger)x;
                if ((NSInteger)y < minY) minY = (NSInteger)y;
                if ((NSInteger)y > maxY) maxY = (NSInteger)y;
            }
        }
        [art appendString:@"\n"];
    }
    free(gray);

    double scaleX = (double)pixelW / (double)gridW;
    double scaleY = (double)pixelH / (double)gridH;

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"== view_image ==\n"];
    [out appendFormat:@"文件: %@\n", path];
    [out appendFormat:@"像素尺寸: %lu x %lu\n", (unsigned long)pixelW, (unsigned long)pixelH];
    [out appendFormat:@"缩略图: %lu x %lu（1 个字符 ≈ %.1f x %.1f 像素）\n",
        (unsigned long)gridW, (unsigned long)gridH, scaleX, scaleY];

    [out appendString:@"\n== 亮度缩略图（自上而下 = 图片上→下；空格最黑，@ 最亮）==\n"];
    if (art.length > kAiImageArtMaxChars) {
        [out appendString:@"[缩略图过大已省略，请把 width 调小]\n"];
    } else {
        [out appendString:art];
    }

    if (maxX < 0 || maxY < 0) {
        [out appendString:@"\n== 内容边界 ==\n整张图都是黑的（没有亮度 > 16 的内容）。\n"];
        return out;
    }

    NSInteger contentLeft = (NSInteger)floor(minX * scaleX);
    NSInteger contentTop = (NSInteger)floor(minY * scaleY);
    NSInteger contentRight = (NSInteger)ceil((maxX + 1) * scaleX) - 1;
    NSInteger contentBottom = (NSInteger)ceil((maxY + 1) * scaleY) - 1;
    if (contentLeft < 0) contentLeft = 0;
    if (contentTop < 0) contentTop = 0;
    if (contentRight > (NSInteger)pixelW - 1) contentRight = (NSInteger)pixelW - 1;
    if (contentBottom > (NSInteger)pixelH - 1) contentBottom = (NSInteger)pixelH - 1;

    double marginTop = (double)contentTop;
    double marginBottom = (double)pixelH - 1.0 - (double)contentBottom;
    double marginLeft = (double)contentLeft;
    double marginRight = (double)pixelW - 1.0 - (double)contentRight;

    [out appendString:@"\n== 非黑内容边界（亮度阈值 16）==\n"];
    [out appendFormat:@"内容区域: x %ld..%ld, y %ld..%ld\n",
        (long)contentLeft, (long)contentRight, (long)contentTop, (long)contentBottom];
    [out appendFormat:@"黑边: 上 %.0f px (%.1f%%)、下 %.0f px (%.1f%%)、左 %.0f px (%.1f%%)、右 %.0f px (%.1f%%)\n",
        marginTop, 100.0 * marginTop / (double)pixelH,
        marginBottom, 100.0 * marginBottom / (double)pixelH,
        marginLeft, 100.0 * marginLeft / (double)pixelW,
        marginRight, 100.0 * marginRight / (double)pixelW];
    [out appendFormat:@"内容占比: 宽 %.1f%% / 高 %.1f%%\n",
        100.0 * (double)(contentRight - contentLeft + 1) / (double)pixelW,
        100.0 * (double)(contentBottom - contentTop + 1) / (double)pixelH];

    BOOL fullWidth = (marginLeft <= 2.0 && marginRight <= 2.0);
    BOOL fullHeight = (marginTop <= 2.0 && marginBottom <= 2.0);
    if (fullWidth && fullHeight) {
        [out appendString:@"结论: 内容基本铺满整屏（四周没有明显黑边）。\n"];
    } else if (fullWidth) {
        [out appendString:@"结论: 左右铺满、上下有黑边 → 画面没有铺满屏幕（宽高比不符，上下留黑）。\n"];
    } else if (fullHeight) {
        [out appendString:@"结论: 上下铺满、左右有黑边 → 画面没有铺满屏幕（左右留黑）。\n"];
    } else {
        [out appendString:@"结论: 四周都有黑边 → 内容没有铺满屏幕。\n"];
    }
    return out;
}

@end
