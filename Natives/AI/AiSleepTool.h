//
//  AiSleepTool.h
//  Amethyst
//
//  sleep 工具（enhance-ai-agent Task 12.1）：seconds（默认 1）异步等待后返回，
//  供 AI 等待后台下载/任务间隔使用。READ_ONLY 无副作用。
//
//  另外：view_image（读图工具 AiImageTool）的实现也放在本文件 + AiSleepTool.m 里。
//  为什么不单独建 AiImageTool.m：Natives/CMakeLists.txt 的 AngelAuraAmethyst 目标
//  是把每个源文件逐个列出来的（不是 GLOB），新增 .m 必须同步改构建脚本才能编进去；
//  挂在一个已经参与编译的小文件里可以做到「只改代码、不动构建」，降低上线风险。
//  如果以后要拆分文件，记得同时把 AiImageTool.m 加进 CMakeLists.txt 的源文件列表。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiSleepTool : NSObject <AiTool>
@end

/// view_image：看得见画面的读图工具。同时提供两种输出：
/// 1) 真图（实现 AiToolImageResult）：把图片压缩成 JPEG data URL 交给 Agent，
///    作为多模态 image 送进模型，模型可直接看到像素（截图对比、UI 布局、黑边）；
/// 2) 文本摘要：像素尺寸 + 非黑内容边界（四周黑边像素/百分比 + 结论），
///    另附亮度 ASCII 缩略图作为不支持视觉时的兜底。
/// 只读、不联网、不修改文件。
@interface AiImageTool : NSObject <AiTool, AiToolImageResult>
@end

NS_ASSUME_NONNULL_END
