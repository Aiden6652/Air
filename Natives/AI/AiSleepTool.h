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

/// view_image：把本地图片转成「文本缩略图」，让 AI 能感知画面（尺寸 / 明暗缩略图 /
/// 非黑内容边界），用于判断 UI 大小、四周有没有黑边、内容是否铺满屏幕。只读、不联网。
@interface AiImageTool : NSObject <AiTool>
@end

NS_ASSUME_NONNULL_END
