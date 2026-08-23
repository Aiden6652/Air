# Checklist

## Task 1: ResourceCardTableViewCell 基类
- [x] 基类实现三层卡片背景（半透明基底 0.08 + BackgroundManager 毛玻璃 + 0.5pt 边框 + 轻阴影 0.10/4/(0,2)）
- [x] 12pt 圆角 + `kCACornerCurveContinuous`
- [x] 图标容器 40×40 / 10pt 圆角 / 类型语义色背景 + SF Symbol
- [x] title3 Semibold 名称 + subhead 副标题，全部 labelColor 系列系统色
- [x] accessory 插槽支持：开关 / chevron（tertiaryLabelColor）/ 更新徽章
- [x] ModTableViewCell 改继承基类并保留原有功能（启用开关、加载器品牌色）

## Task 2: 资源列表基类与三态视图
- [x] 胶囊形搜索栏（L8，只搜本地）
- [x] 表格卡片间距 4pt、无系统分隔线
- [x] 空状态：类型语义色 SF Symbol + 文案 + 引导按钮（Mod/数据包/资源包/光影含"去下载"）
- [x] 加载态与错误态（含重试）
- [x] 批量选择模式底部工具栏（全选/取消 + 批量操作）
- [x] "去下载"按钮正确跳转统一下载界面对应资源类型
- [x] 首屏连锁进场动画（≤10 项，每项延迟 50ms）

## Task 3: Mod 更新检测修复
- [x] ModrinthAPI.projectForFileHash 使用 `GET /version_file/{sha1}?algorithm=sha1`（hash 路径参数）
- [x] MurmurHash2 本地实现（对 jar 文件字节流计算）
- [x] ModUpdateService CurseForge 反查传 MurmurHash2 指纹（不再传 filePath）
- [x] CurseForge 指纹响应项目 ID 取 `exactMatches[0].file.modId`
- [x] 沙箱实测：真实 mod jar 的双 hash 反查均命中（curl 验证）

## Task 4: Mod 管理 + 更新内置
- [x] 筛选 chips（全部/已启用/已禁用）+ 排序（名称/修改时间）
- [x] 批量启用/禁用/删除经基类工具栏可用
- [x] 顶栏"检查更新"→ 内联 Loading → 确认弹窗（名称/版本对比/来源彩色 pill/复选框默认全选）
- [x] 确认后经 PLDownloadClient 并发下载替换旧文件，完成刷新列表
- [x] 结果提示：成功 N / 跳过 N / 失败 N；无更新时提示"均为最新"
- [x] 可更新 Mod 的 Cell 显示 `arrow.up.circle.fill` accent 徽章
- [x] ModUpdateViewController.h/.m 已删除，CMakeLists 与引用全部清理
- [x] ModUpdateService/ModUpdateResult 保留且无残留编译错误

## Task 5-8: 四个管理界面重构
- [x] DataPacks：segmented control 与在线搜索逻辑已移除；teal 图标容器；开关保留；空状态"去下载"
- [x] ResourcePacks：同上（蓝图标容器）
- [x] Worlds：在线搜索移除；绿图标容器；导入/删除保留；空状态"去下载"
- [x] Shaders：接入基类与卡片 Cell（紫图标容器）；三态视图齐备
- [x] 四界面均无 `[UIColor whiteColor]` 文字色、无裸 SF Symbol、无纯文本来源标签

## Task 9: 本地化与全局自检
- [x] zh-Hans / zh-Hant / en Localizable.strings 补全新增文案（103 个 resman.* key × 3 语言）
- [x] Air-Design 第 14 章自检清单逐项核对六界面
- [x] 编译验证通过（新增文件已注册 CMakeLists，删除文件已移除）
- [x] 无残留 ModUpdateViewController 引用（grep 验证）
