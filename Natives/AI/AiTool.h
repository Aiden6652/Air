//
//  AiTool.h
//  Amethyst
//
//  Air AI Agent 工具基础协议：定义统一的工具权限级别与执行接口。
//  所有内置工具（实例/日志/崩溃/文件/问答等）都遵循该协议，供注册表管理。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 工具权限级别（决定是否需要用户确认）
typedef NS_ENUM(NSInteger, AiToolPermission) {
    /// 只读：仅查看，无副作用，始终允许
    AiToolPermissionReadOnly = 0,
    /// 受控写入：修改启动器/实例内的文本文件，Ask/YOLO 模式下放行或询问
    AiToolPermissionControlledWrite = 1,
    /// 危险写入：删除文件等高风险操作，所有安全模式都要求确认
    AiToolPermissionDangerousWrite = 2,
    /// 外部网络：发起网络请求，YOLO 模式下免确认，其余模式询问
    AiToolPermissionExternalNetwork = 3,
};

/// 安全模式（与 AiSettings.safetyMode 取值一致）
typedef NS_ENUM(NSInteger, AiSafetyMode) {
    AiSafetyModeSafe = 0, // 安全：仅执行只读操作
    AiSafetyModeAsk = 1,  // 询问：执行前询问用户
    AiSafetyModeYOLO = 2, // 完全：执行前不询问（谨慎使用）
};

/// AI 工具协议：每个内置工具实现该协议
@protocol AiTool <NSObject>

/// 工具名，如 list_instances
@property (nonatomic, readonly) NSString *name;
/// 给 LLM 的描述（用途 + 参数说明 + 边界 + 示例）
@property (nonatomic, readonly) NSString *summary;
/// 权限级别
@property (nonatomic, readonly) AiToolPermission permission;

/// 执行工具
/// @param params 规范化后的参数字典
/// @param completion 结果回调（result/error 至少其一非空；回调必须恰好调用一次）
- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion;

@end

/// 可选协议：工具除文本外还能返回一张图片（data URL）。
/// 实现该协议的工具具备「真图」能力：图片会作为 OpenAI 多模态 image 部分进入下一轮请求，
/// 模型可直接看到像素（例如对比两张截图、判断 UI 大小与黑边）。
///
/// 为什么需要单独一条通道：OpenAI 协议里 role=tool 的消息 content 只能是字符串，
/// 不能携带图片。所以图片由 AiAgent 在「本轮全部工具结果按序落盘之后」
/// 以一条额外的 user 消息（content 为内容数组）送入下一轮请求，
/// 既不破坏 assistant(tool_calls) → tool 的配对顺序，也能让模型看到真实画面。
@protocol AiToolImageResult <NSObject>

/// 执行并返回「文本 + 图片」
/// @param params 规范化后的参数字典
/// @param completion 结果回调；imageDataURL 为 data:image/jpeg;base64,... 形式，无图片时传 nil
- (void)executeReturningImage:(NSDictionary<NSString *, id> *)params
                   completion:(void (^)(NSString * _Nullable text,
                                        NSString * _Nullable imageDataURL,
                                        NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
