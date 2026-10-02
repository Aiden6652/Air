//
//  AiSleepTool.m
//  Amethyst
//
//  本文件承载两个工具：
//    1) AiSleepTool —— sleep（seconds 默认 1，异步等待后返回）
//    2) AiImageTool  —— view_image（读图：真图 + 文本摘要）
//
//  为什么 view_image 的实现和 AiSleepTool 放在同一文件：
//  Natives/CMakeLists.txt 的 AngelAuraAmethyst 目标是把每个源文件逐个列出来的（不是 GLOB），
//  新增 .m 必须同步改构建脚本才能编进去。挂在一个已经参与编译的小文件里，
//  可以做到「只改代码、不动构建」，降低上线风险。
//  如果以后要拆分文件，记得同时把 AiImageTool.m 加进 CMakeLists.txt 的源文件列表。
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
/// 纯文本兜底时缩略图的字符上限，防止极端宽高比把返回体撑爆
static const NSUInteger kAiImageArtMaxChars = 60000;
/// 送进模型的图片长边上限（太大白耗 token 且上传慢）
static const CGFloat kAiImageMaxSide = 1280.0;
/// 送进模型的 JPEG 质量（0.72 在 UI 截图上看得很清楚，体积百 KB 级）
static const CGFloat kAiImageJPEGQuality = 0.72;

@implementation AiImageTool

- (NSString *)name {
    return @"view_image";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"看图工具：把图片直接送进对话（模型真的能看像素），并附一份尺寸/黑边摘要。"
           "\n返回两部分：① 压缩后的真图（多模态 image，模型可看到画面）；"
           "② 文本摘要：像素尺寸、非黑内容边界（四周黑边像素与百分比、内容占比 + 一句结论），"
           "可直接判断有没有黑边、是否铺满屏幕。"
           "\n参数：path（string，必填，图片路径；支持直接写 Documents 目录下的文件名，如 \"有视频PE.PNG\"）；"
           "width（number，可选，纯文本兜底时的字符宽度，默认 96，范围 16~200）。"
           "\n典型用途：对比两张截图的 UI 大小/布局差异、确认画面是否被裁切或留黑边。"
           "\n边界：只读、不改文件、不联网。"
           "\n示例：view_image(path=\"无视频PE.PNG\")";
}

#pragma mark 文本通道（不支持视觉时的兜底）

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

    NSInteger cols = [AiImageTool columnsFromParams:params];
    NSString *resolved = [AiImageTool resolveImagePath:rawPath];
    if (resolved.length == 0) {
        NSString *message = [NSString stringWithFormat:@"找不到图片：%@\n（可用 list_files 先确认文件名；支持 Documents 目录下的相对文件名）", rawPath];
        completion(nil, [NSError errorWithDomain:@"AiImageTool" code:404
                                        userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = [AiImageTool textReportForPath:resolved columns:cols];
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

#pragma mark 真图通道（AiToolImageResult）

- (void)executeReturningImage:(NSDictionary<NSString *, id> *)params
                   completion:(void (^)(NSString * _Nullable text,
                                        NSString * _Nullable imageDataURL,
                                        NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *rawPath = nil;
    id pathValue = params[@"path"];
    if ([pathValue isKindOfClass:[NSString class]]) rawPath = (NSString *)pathValue;
    if (rawPath.length == 0) {
        completion(nil, nil, [NSError errorWithDomain:@"AiImageTool" code:400
                                             userInfo:@{NSLocalizedDescriptionKey: @"view_image 需要 path 参数（图片路径，例如 \"有视频PE.PNG\"）"}]);
        return;
    }

    NSInteger cols = [AiImageTool columnsFromParams:params];
    NSString *resolved = [AiImageTool resolveImagePath:rawPath];
    if (resolved.length == 0) {
        NSString *message = [NSString stringWithFormat:@"找不到图片：%@\n（可用 list_files 先确认文件名；支持 Documents 目录下的相对文件名）", rawPath];
        completion(nil, nil, [NSError errorWithDomain:@"AiImageTool" code:404
                                             userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *image = [AiImageTool loadImageAtPath:resolved];
        NSDictionary *analysis = image ? [AiImageTool analyzeImage:image columns:cols includeArt:NO] : nil;
        NSString *dataURL = image ? [AiImageTool jpegDataURLForImage:image maxSide:kAiImageMaxSide quality:kAiImageJPEGQuality] : nil;

        NSString *text = nil;
        if (analysis) {
            text = [AiImageTool summaryTextFromAnalysis:analysis path:resolved imageAttached:(dataURL.length > 0)];
        }

        // 兜底：图片编不出来（或图片格式奇怪）时，退回纯文本 ASCII 报告，至少还能看形状
        if (dataURL.length == 0) {
            if (text.length == 0) {
                text = [AiImageTool textReportForPath:resolved columns:cols];
            }
            if (text.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *error = [NSError errorWithDomain:@"AiImageTool" code:415
                                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法解码这张图片（可能不是图片格式 / 文件损坏 / 空文件）：%@", resolved]}];
                    completion(nil, nil, error);
                });
                return;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(text, dataURL.length > 0 ? dataURL : nil, nil);
        });
    });
}

#pragma mark 参数与路径

+ (NSInteger)columnsFromParams:(NSDictionary<NSString *, id> *)params {
    NSInteger cols = kAiImageDefaultColumns;
    id widthValue = params[@"width"];
    if ([widthValue isKindOfClass:[NSNumber class]]) {
        cols = [(NSNumber *)widthValue integerValue];
    } else if ([widthValue isKindOfClass:[NSString class]]) {
        cols = [(NSString *)widthValue integerValue];
    }
    if (cols < kAiImageMinColumns) cols = kAiImageMinColumns;
    if (cols > kAiImageMaxColumns) cols = kAiImageMaxColumns;
    return cols;
}

/// 依次尝试：文件工具的安全解析 → 启动器 Documents 根 → 原样绝对路径，返回第一个真实存在的文件
+ (nullable NSString *)resolveImagePath:(NSString *)raw {
    if (raw.length == 0) return nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    @try {
        NSString *safe = [AiFileTools resolveSafely:raw];
        if (safe.length > 0) [candidates addObject:safe];
    } @catch (NSException *exception) {
        // 忽略：解析失败继续走后两个候选
    }

    NSArray<NSString *> *documentList = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (documentList.count > 0) {
        NSString *relative = raw;
        while ([relative hasPrefix:@"/"]) {
            relative = [relative substringFromIndex:1];
        }
        [candidates addObject:[documentList.firstObject stringByAppendingPathComponent:relative]];
    }

    if ([raw hasPrefix:@"/"]) [candidates addObject:raw];

    for (NSString *candidate in candidates) {
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:candidate isDirectory:&isDirectory] && !isDirectory) {
            return candidate;
        }
    }
    return nil;
}

+ (nullable UIImage *)loadImageAtPath:(NSString *)path {
    if (path.length == 0) return nil;
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image == nil || image.size.width < 1.0 || image.size.height < 1.0) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data.length > 0) image = [UIImage imageWithData:data];
    }
    if (image == nil || image.size.width < 1.0 || image.size.height < 1.0) return nil;
    return image;
}

#pragma mark 分析

/// 灰度网格分析：返回像素尺寸、网格尺寸、可选 ASCII 图、非黑内容边界与结论。
/// 返回 nil 表示无法绘制（图片异常）。
+ (nullable NSDictionary *)analyzeImage:(UIImage *)image columns:(NSInteger)cols includeArt:(BOOL)includeArt {
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
    NSMutableString *art = includeArt ? [NSMutableString stringWithCapacity:bufferSize + gridH] : nil;
    NSInteger minX = (NSInteger)gridW;
    NSInteger maxX = -1;
    NSInteger minY = (NSInteger)gridH;
    NSInteger maxY = -1;

    for (size_t y = 0; y < gridH; y++) {
        for (size_t x = 0; x < gridW; x++) {
            unsigned char value = gray[y * gridW + x];
            if (art) {
                NSInteger level = (NSInteger)(((double)value / 256.0) * 10.0);
                if (level < 0) level = 0;
                if (level > 9) level = 9;
                [art appendFormat:@"%c", ramp[level]];
            }
            if (value > kAiImageContentThreshold) {
                if ((NSInteger)x < minX) minX = (NSInteger)x;
                if ((NSInteger)x > maxX) maxX = (NSInteger)x;
                if ((NSInteger)y < minY) minY = (NSInteger)y;
                if ((NSInteger)y > maxY) maxY = (NSInteger)y;
            }
        }
        if (art) [art appendString:@"\n"];
    }
    free(gray);

    double scaleX = (double)pixelW / (double)gridW;
    double scaleY = (double)pixelH / (double)gridH;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"pixelWidth"] = @(pixelW);
    info[@"pixelHeight"] = @(pixelH);
    info[@"gridWidth"] = @(gridW);
    info[@"gridHeight"] = @(gridH);
    info[@"scaleX"] = @(scaleX);
    info[@"scaleY"] = @(scaleY);
    if (art) info[@"art"] = [art copy];

    if (maxX < 0 || maxY < 0) {
        info[@"hasContent"] = @NO;
        info[@"conclusion"] = @"整张图都是黑的（没有亮度 > 16 的内容）。";
        return info;
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

    info[@"hasContent"] = @YES;
    info[@"contentLeft"] = @(contentLeft);
    info[@"contentRight"] = @(contentRight);
    info[@"contentTop"] = @(contentTop);
    info[@"contentBottom"] = @(contentBottom);
    info[@"marginTop"] = @(marginTop);
    info[@"marginBottom"] = @(marginBottom);
    info[@"marginLeft"] = @(marginLeft);
    info[@"marginRight"] = @(marginRight);

    BOOL fullWidth = (marginLeft <= 2.0 && marginRight <= 2.0);
    BOOL fullHeight = (marginTop <= 2.0 && marginBottom <= 2.0);
    NSString *conclusion = nil;
    if (fullWidth && fullHeight) {
        conclusion = @"内容基本铺满整屏（四周没有明显黑边）。";
    } else if (fullWidth) {
        conclusion = @"左右铺满、上下有黑边 → 画面没有铺满屏幕（宽高比不符，上下留黑）。";
    } else if (fullHeight) {
        conclusion = @"上下铺满、左右有黑边 → 画面没有铺满屏幕（左右留黑）。";
    } else {
        conclusion = @"四周都有黑边 → 内容没有铺满屏幕。";
    }
    info[@"conclusion"] = conclusion;
    return info;
}

#pragma mark 文本组装

+ (NSString *)summaryTextFromAnalysis:(NSDictionary *)info path:(NSString *)path imageAttached:(BOOL)imageAttached {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"== view_image ==\n"];
    [out appendFormat:@"文件: %@\n", path];
    [out appendFormat:@"像素尺寸: %@ x %@\n", info[@"pixelWidth"], info[@"pixelHeight"]];
    if (imageAttached) {
        [out appendFormat:@"已附上图片（长边压到 %.0f px 的 JPEG），请看图判断实际布局。\n", kAiImageMaxSide];
    }

    if (![info[@"hasContent"] boolValue]) {
        [out appendFormat:@"\n%@\n", info[@"conclusion"]];
        return out;
    }

    double pixelW = [info[@"pixelWidth"] doubleValue];
    double pixelH = [info[@"pixelHeight"] doubleValue];
    double marginTop = [info[@"marginTop"] doubleValue];
    double marginBottom = [info[@"marginBottom"] doubleValue];
    double marginLeft = [info[@"marginLeft"] doubleValue];
    double marginRight = [info[@"marginRight"] doubleValue];
    NSInteger contentLeft = [info[@"contentLeft"] integerValue];
    NSInteger contentRight = [info[@"contentRight"] integerValue];
    NSInteger contentTop = [info[@"contentTop"] integerValue];
    NSInteger contentBottom = [info[@"contentBottom"] integerValue];

    [out appendString:@"\n== 非黑内容边界（亮度阈值 16）==\n"];
    [out appendFormat:@"内容区域: x %ld..%ld, y %ld..%ld\n",
        (long)contentLeft, (long)contentRight, (long)contentTop, (long)contentBottom];
    [out appendFormat:@"黑边: 上 %.0f px (%.1f%%)、下 %.0f px (%.1f%%)、左 %.0f px (%.1f%%)、右 %.0f px (%.1f%%)\n",
        marginTop, 100.0 * marginTop / pixelH,
        marginBottom, 100.0 * marginBottom / pixelH,
        marginLeft, 100.0 * marginLeft / pixelW,
        marginRight, 100.0 * marginRight / pixelW];
    [out appendFormat:@"内容占比: 宽 %.1f%% / 高 %.1f%%\n",
        100.0 * (double)(contentRight - contentLeft + 1) / pixelW,
        100.0 * (double)(contentBottom - contentTop + 1) / pixelH];
    [out appendFormat:@"结论: %@\n", info[@"conclusion"]];
    return out;
}

+ (NSString *)fullTextFromAnalysis:(NSDictionary *)info path:(NSString *)path {
    NSMutableString *out = [NSMutableString stringWithString:[self summaryTextFromAnalysis:info path:path imageAttached:NO]];
    NSString *art = info[@"art"];
    if (art.length > 0) {
        [out appendString:@"\n== 亮度缩略图（自上而下 = 图片上→下；空格最黑，@ 最亮）==\n"];
        if (art.length > kAiImageArtMaxChars) {
            [out appendString:@"[缩略图过大已省略，请把 width 调小]\n"];
        } else {
            [out appendString:art];
        }
    }
    return out;
}

/// 纯文本报告（ASCII 缩略图 + 摘要），用于不支持视觉 / 图片编码失败时的兜底
+ (nullable NSString *)textReportForPath:(NSString *)path columns:(NSInteger)cols {
    if (path.length == 0) return nil;
    UIImage *image = [self loadImageAtPath:path];
    if (image == nil) return nil;
    NSDictionary *info = [self analyzeImage:image columns:cols includeArt:YES];
    if (info == nil) return nil;
    return [self fullTextFromAnalysis:info path:path];
}

#pragma mark 图片编码

/// 把图片等比缩放到长边 maxSide 以内，再编成 JPEG data URL
+ (nullable NSString *)jpegDataURLForImage:(UIImage *)image maxSide:(CGFloat)maxSide quality:(CGFloat)quality {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == NULL) return nil;
    size_t pixelW = CGImageGetWidth(cgImage);
    size_t pixelH = CGImageGetHeight(cgImage);
    if (pixelW == 0 || pixelH == 0) return nil;

    CGFloat longSide = (CGFloat)MAX(pixelW, pixelH);
    CGFloat scale = (longSide > maxSide) ? (maxSide / longSide) : 1.0;
    CGFloat targetW = MAX(1.0, floor((CGFloat)pixelW * scale));
    CGFloat targetH = MAX(1.0, floor((CGFloat)pixelH * scale));

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(targetW, targetH), YES, 1.0);
    [image drawInRect:CGRectMake(0, 0, targetW, targetH)];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (scaled == nil) return nil;

    NSData *jpeg = UIImageJPEGRepresentation(scaled, quality);
    if (jpeg.length == 0) return nil;

    return [NSString stringWithFormat:@"data:image/jpeg;base64,%@", [jpeg base64EncodedStringWithOptions:0]];
}

@end
