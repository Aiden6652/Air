# Tasks

## Phase 1：数据层——阶段化任务模型
- [x] Task 1.1: 新建 PLTaskStage 模型（`Natives/PLTaskStage.{h,m}`）：title/iconName/status 五态枚举（Pending/Running/Completed/Failed/Skipped）/message/progress(-1~1)/rateBytesPerSec/completedFileCount/totalFileCount；提供 `snapshotDictionary` 与 `initWithSnapshotDictionary:`；注册进 CMakeLists
- [x] Task 1.2: DownloadTaskItem 扩展 `stages`/`currentStageIndex` 属性，snapshotDictionary/initWithSnapshotDictionary 兼容旧快照（无 stages 字段回退纯进度展示）
- [x] Task 1.3: DownloadTaskManager 新增阶段上报 API：`setTaskWithId:stages:`（整体替换）、`updateTaskWithId:stageAtIndex:status:`、`updateTaskWithId:stageAtIndex:progress:message:`、`updateTaskWithId:stageAtIndex:rate:`、`updateTaskWithId:stageAtIndex:fileCount:totalFileCount:`、`updateTaskWithId:currentStageIndex:`；全部走既有通知与快照持久化机制
- [x] Task 1.4: 新增统一阶段定义常量（`Natives/PLTaskStages.h`）：原版 6 步、+Fabric/Quilt 3 步、+Forge/NeoForge 3 步、整合包 6 步、单文件下载 1 步的标题与 SF Symbol 图标名（供业务方与 UI 共用，收敛现有 4 处硬编码）

## Phase 2：统一进度页 + 下载中心增强
- [x] Task 2.1: 新建 `Natives/PLTaskProgressViewController.{h,m}`（注册进 CMakeLists）：ZL2 风格布局——标题+类别图标 / 阶段步骤列表（五态图标，仅运行中阶段展开：message 当前文件、进度条+速率+百分比一行、双维度"12/38 个文件 · 45MB/180MB"、ETA）/ 总进度汇总条 / 底部按钮区（最小化、按能力动态显示的暂停/继续/取消/重试/查看详情）；失败态可展开完整错误（domain/code/底层错误/retryCount/当前阶段名）
- [x] Task 2.2: PLTaskProgressViewController 双端适配：iPhone 全屏模态（pageSheet）；iPad formSheet 居中卡片（约 560pt 宽，内容超高内部滚动）；订阅 DownloadTaskManagerDidUpdateTaskNotification 实时刷新
- [x] Task 2.3: 自动弹出与最小化：安装类任务注册时可标记 `autoPresentDetail`；进度页"最小化"关闭页面任务后台继续；提供 `+presentForTaskId:` 供下载中心再次打开；同屏仅弹一个进度页（新任务自动弹出时若已有进度页则替换内容）
- [x] Task 2.4: DownloadTasksViewController 卡片增强：卡片显示当前阶段名（item.stages[currentStageIndex].title）与阶段计数（"3/6"）；点击卡片打开 PLTaskProgressViewController（didSelectItem 回调）；下载中心按钮（LauncherRightPanelViewController/LauncherNavigationController）增强聚合进度显示（进行中任务数徽标）

## Phase 3：安装类流程接入（原版/加载器）
- [x] Task 3.1: MinecraftResourceDownloadTask 桥接：下载过程按 PLTaskStages 原版 6 步上报阶段（版本清单/版本JSON/客户端/库文件/资源文件/验证），内部 progressList 文件级进度映射到对应阶段 message 与双维度计数；注册 DownloadTaskManager 任务（autoPresentDetail=YES）
- [x] Task 3.2: DownloadViewController 安装逻辑改造：删除私有 InstallerProgressViewController 类（约 400 行）及其全部引用；原版预装/直装、Fabric/Quilt、Forge 直装、NeoForge 直装改为"注册任务 + 阶段上报 + 自动弹统一进度页"；安装器内部 reportProgress 回调映射到对应阶段（获取profile/下载加载器库/写入JSON 或 下载安装器/解析依赖/安装）
- [x] Task 3.3: FabricUtils/ForgeDirectInstaller/NeoForgeDirectInstaller 阶段回调对接：安装器回调签名保持不变，由 DownloadViewController 侧桥接为阶段上报（不改安装器内部逻辑）
- [x] Task 3.4: LauncherRightPanelViewController/LauncherNavigationController 清理：删除各自维护的 DownloadProgressViewController present 逻辑与重复通知代码，版本下载入口统一走"注册任务+自动弹出"

## Phase 4：资源下载接入（Mod/Shader/资源包/数据包/JRE）
- [x] Task 4.1: ModService/ShaderService/ResourcePackService/DataPackService 注册 DownloadTaskManager 任务（单阶段"下载文件"，含 SHA1/大小元数据），下载回调桥接阶段进度/速率；DownloadViewController 与各 Manager VC 的下载入口改为自动弹统一进度页；删除 DownloadProgressCardView 相关调用
- [x] Task 4.2: ForgeInstallViewController：删除 dlopen WFWorkflowProgressView 私有类代码，installer jar 下载注册为下载中心任务（卡片进度展示）
- [x] Task 4.3: LauncherPrefManageJREViewController JRE 下载：改注册下载中心任务，移除对 progressViewMain 的复用
- [x] Task 4.4: ProfileSettingsViewController Fabric API/OptiFine 安装：改注册任务+统一进度页，移除 DownloadProgressCardView 调用

## Phase 5：整合包导入重构与修复（参考 ZL2）
- [x] Task 5.1: ModpackImportService 接入阶段模型：导入全程按整合包 6 阶段（解析/解压/下载依赖/安装加载器/下载游戏文件/完成配置）上报 DownloadTaskManager（autoPresentDetail=YES）；ModpackImportViewController 删除自定义进度卡，改用统一进度页
- [x] Task 5.2: P0-1 修复：downloadModFiles 失败不再静默——非 404 失败导致 importModpack 返回 NO 并携带失败文件详情；404/server-only 跳过文件在成功结果中明确列出（成功页展示跳过清单）
- [x] Task 5.3: P0-2 修复：CurseForge 依赖文件补 SHA1 校验（BMCLAPI 指纹/filesByFileID 可用时；不可用回退 zip EOCD 兜底）
- [x] Task 5.4: P0-3 修复：CurseForge 按项目类型分发目录（shaderpacks/resourcepacks/datapacks 类文件路由到对应目录，不全塞 mods/）
- [x] Task 5.5: P1 修复：Modrinth 非标准前缀嵌套子目录路径重复 bug（else 分支 relativeUnder 取 lastPathComponent）
- [x] Task 5.6: P1 修复：versionId 唯一化（自动生成追加 modpack 短 hash 后缀，profile lastVersionId 同步指向）
- [x] Task 5.7: P1 功能：MCBBS 格式支持（mcbbs.packmeta/MCBBS manifest.json 解析：addons 识别加载器、launchInfo 提取 minMemory/javaArguments/launchArguments 写入 profile）
- [x] Task 5.8: P1 功能：instance.cfg 完整解析（jvmArgs/maxMemory/minMemory/joinServerOnLaunch 写入 profile，替代仅取 name）
- [x] Task 5.9: P2 修复：取消清理（主 versions 目录本次创建的 version JSON、tmpInstallerPath 临时 jar、进行中的 MinecraftResourceDownloadTask 取消）
- [x] Task 5.10: P2 统一：在线整合包下载路径（ModrinthAPI/CurseForgeAPI downloader:submitDownloadTasksFromPackage:）改为下载 zip 后复用 ModpackImportService 统一导入流程，消除双轨

## Phase 6：旧 UI 清理与双端打磨
- [x] Task 6.1: 删除 DownloadProgressCardView.{h,m} 与 DownloadProgressViewController.{h,m} 文件及 CMakeLists 条目；全局搜索确认无残留引用
- [x] Task 6.2: 删除 LauncherNavigationController progressViewMain 属性与全部代码；下载中心按钮聚合进度显示就位
- [x] Task 6.3: 全局清理：DownloadViewController 中废弃的整合包旧安装路径（installModpackFromFile: 标注废弃段）、各处临时 alert 式进度提示一并收敛到统一入口（Mods/Shaders/ResourcePacks/DataPacks/Worlds 五个 Manager VC 的"正在下载"alert 删除；死代码 LauncherProfilesViewController 连同假下载 alert 整体删除）
- [x] Task 6.4: 双端适配走查：统一进度页与下载中心在 iPhone（含小屏 SE）/iPad（含分屏 1/3 宽）/横竖屏下的布局验证；深色模式颜色适配（代码走查：两 VC 全部使用动态颜色 systemBackground/labelColor 等，pageSheet/formSheet 双端呈现）

## Phase 7：本地化与构建验证
- [x] Task 7.1: 全语言本地化（zh-Hans/zh-Hant/en 补全 48 key：18 个阶段标题 taskStage.title.* + 30 个进度页文案 taskProgress.*；其余语言经 NSLocalizedString 兜底机制显示中文，与项目既有硬编码中文风格一致；下载中心/整合包导入等既有硬编码中文 UI 维持现状）
- [x] Task 7.2: 提交 GitHub 触发 Actions 构建（macOS 14/Xcode 15.4），修复编译错误直至产物生成（ipa/tipa/dSYM）——run 32248491900 构建成功，三产物（com.air-devs.air-ios.ipa / trollstore.tipa / AngelAuraAmethyst.dSYM）均已生成；期间修复 ModpackImportService.m 参数解析语法错误（commit 1c3e3aa7）
- [x] Task 7.3: 按 checklist.md 自检全部场景（代码层面：清理残留搜索、本地化 key 比对、关键接入点抽查全部通过）；真机/TrollStore 验证留待用户安装 run 32248491900 产物手动验证（原版安装、Forge 安装、整合包导入含失败路径、Mod 下载、下载中心交互、最小化恢复）

# Task Dependencies
- Phase 1（模型）是 Phase 2-5 的前置
- Task 2.1-2.3（进度页）依赖 Phase 1；Task 2.4（下载中心）依赖 Task 2.3
- Phase 3/4/5 各自依赖 Phase 1+2，三者间相互独立可并行
- Task 5.10（在线路径统一）依赖 Task 5.1-5.4 完成（先稳定本地导入）
- Phase 6 依赖 Phase 3/4/5 全部完成（才能安全删除旧 UI）
- Phase 7 依赖全部完成
