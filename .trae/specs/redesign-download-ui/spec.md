# 下载界面深度重构（redesign-download-ui）Spec

## Why

当前启动器存在 **7 套互不关联的下载进度 UI**（底部悬浮卡片 DownloadProgressCardView、全屏多文件页 DownloadProgressViewController、DownloadViewController 私有的 InstallerProgressViewController、下载中心 DownloadTasksViewController、Forge 安装器私有 API 圆形进度 WFWorkflowProgressView、整合包导入自定义进度卡、工具栏 4pt 细进度条 progressViewMain），数据源割裂（KVO textProgress / KVO progress / manager 通知 / 手动推送各自为政），Mod/Shader/资源包下载与整合包导入完全旁路下载中心。用户无法知道下载卡在哪一步，无法从下载中心进入任何详情，进度界面冗杂混乱。

同时整合包导入存在已知缺陷：mod 下载失败被静默吞掉（用户看到"导入成功"但 mods 缺失）、CurseForge 文件无 SHA1 校验且全部错误塞入 mods/、不支持 MCBBS 格式、versionId 冲突互相覆盖、Modrinth 嵌套子目录路径重复 bug 等。

本 spec 参考 ZalithLauncher2（ZL2，`ThirdParty/ZalithLauncher2`）的阶段化任务流与进度 UI 设计，将 7 套界面收敛为 2 套（下载中心 + 统一进度页），全量业务接入下载中心，并修复整合包导入缺陷。

## What Changes

### UI 层（收敛为 2 套）

- **保留并增强下载中心**（DownloadTasksViewController）：任务卡片显示当前阶段名；点击卡片进入该任务的统一进度页；从历史页亦可进入
- **新建统一下载/安装进度页**（PLTaskProgressViewController）：ZL2 风格阶段步骤列表（三态图标、仅当前阶段展开详情），并增强：当前文件名、双维度进度（文件数+字节）、ETA、总进度汇总条、错误详情展开、按任务能力动态显示的暂停/恢复/取消/重试按钮、最小化按钮
- **删除 6 套旧界面**：
  - DownloadProgressCardView（底部悬浮卡片）
  - DownloadProgressViewController（全屏多文件进度页）
  - InstallerProgressViewController（DownloadViewController.m 内私有类，行 456-840）
  - WFWorkflowProgressView（ForgeInstallViewController 中 dlopen 的 Apple 私有类，顺带消除 App Store 审核风险）
  - ModpackImportViewController 的自定义进度卡（showProgressCardWithTitle: 等私有实现）
  - LauncherNavigationController 工具栏 4pt progressViewMain（JRE 下载复用处一并迁移）
- **入口统一**：安装类流程（原版/Forge/Fabric/NeoForge/整合包）开始时自动弹出统一进度页（iPhone 全屏模态 / iPad formSheet 居中卡片约 560pt 宽）；最小化后任务后台继续，从下载中心可重新打开；工具栏保留下载中心按钮并增强显示聚合进度

### 数据层（阶段化任务模型，参考 ZL2 Task.kt 四元组）

- **新增 PLTaskStage 模型**：`title`、`iconName`、`status`（Pending/Running/Completed/Failed/Skipped 五态，比 ZL2 三态多 Failed/Skipped）、`message`（动态详情文案）、`progress`（-1 不确定 ~ 1，ZL2 同款语义）、`rateBytesPerSec`、`completedFileCount/totalFileCount`（双维度）
- **DownloadTaskItem 扩展**：新增 `stages` 数组（NSArray<PLTaskStage *>）与 `currentStageIndex`；快照持久化（snapshotDictionary/initWithSnapshotDictionary）同步扩展
- **DownloadTaskManager 扩展**：新增阶段上报 API（整体替换 stages / 更新指定 index 阶段的状态/进度/速率/文件计数）；沿用 DownloadTaskManagerDidUpdateTaskNotification 通知机制
- **统一阶段定义**（收敛现有硬编码在 DownloadViewController 4 处的阶段列表）：
  - 原版：获取版本清单 → 下载版本 JSON → 下载客户端 → 下载库文件 → 下载资源文件 → 验证完整性
  - +Fabric/Quilt：原版 6 步 + 获取加载器 profile → 下载加载器库 → 写入版本 JSON
  - +Forge/NeoForge：原版 6 步 + 下载安装器 → 解析依赖 → 安装加载器
  - 整合包：解析整合包 → 解压文件 → 下载依赖文件 → 安装加载器 → 下载游戏文件 → 完成配置
  - Mod/Shader/资源包/数据包等单文件下载：单阶段"下载文件"
- **错误信息增强**：DownloadTaskItem.errorInfo 展示于统一进度页（可展开完整错误 + 已重试次数 retryCount/maxRetryCount）

### 业务全量接入下载中心

- ModService / ShaderService / ResourcePackService / DataPackService：下载时向 DownloadTaskManager 注册任务（单阶段），上报进度/速率/文件信息（含已有 SHA1 校验成果）
- MinecraftResourceDownloadTask（原版/加载器安装链路）：注册任务并把内部多 NSProgress 进度桥接为阶段上报（替换 InstallerProgressViewController 的手动推送）
- ModpackImportService：导入全程按整合包阶段定义上报（替换自定义 progress 回调的 UI 直连）
- FabricUtils / ForgeDirectInstaller / NeoForgeDirectInstaller：安装器内部 reportProgress 阶段回调桥接到对应任务阶段
- ForgeInstallViewController 的 installer jar 下载（原 WFWorkflowProgressView）：改为注册下载中心任务
- LauncherPrefManageJREViewController 的 JRE 下载（原 progressViewMain）：改为注册下载中心任务
- LauncherRightPanelViewController / LauncherNavigationController 中各自维护 progressVC 的重复入口代码统一收敛

### 整合包导入修复（参考 ZL2）

**P0（直接对应"导入有问题"反馈）**：
1. 修复 mod 下载失败被静默吞掉：`importModpack:` 在 downloadModFiles 返回 NO 且 failedDownloadFiles 非空时返回 NO 并携带失败详情；成功但有跳过文件（404/server-only）时在成功结果中明确列出
2. CurseForge mod 文件补 SHA1 校验：经 BMCLAPI 文件指纹（或 CurseForgeAPI filesByFileID，无 API Key 时回退 zip EOCD 兜底）设置 expectedSHA1
3. CurseForge mod 按项目类型分发目录：不再全塞 mods/，按项目类别分发到 shaderpacks/resourcepacks/datapacks（参考 ZL2 CurseForgePack.kt versionFolder 路由）

**P1（格式覆盖与冲突）**：
4. 新增 MCBBS 整合包格式支持（mcbbs.packmeta / MCBBS 风格 manifest.json：addons 识别 game/forge/fabric/neoforge/quilt/optifine，launchInfo 提取 minMemory/javaArguments/launchArguments）（参考 ZL2 MCBBSPack.kt）
5. instance.cfg 完整解析：至少提取 jvmArgs/maxMemory/minMemory/joinServerOnLaunch 写入 profile（参考 ZL2 MultiMCConfiguration.kt）
6. versionId 唯一化：自动生成的 versionId 追加 modpack 短 hash 后缀（如 `fabric-loader-0.15.7-1.20.1-a1b2c3d4`），消除多整合包间及与单独安装加载器的版本 JSON 物理覆盖；profile lastVersionId 同步指向
7. 修复 Modrinth 非标准前缀嵌套子目录路径重复 bug（config/jei/jei.cfg 被放到 config/jei/jei/jei.cfg）

**P2（健壮性）**：
8. 取消时清理残留：主 versions 目录下本次创建的 version JSON、tmpInstallerPath 临时 jar、进行中的 MinecraftResourceDownloadTask
9. 在线下载路径与本地导入统一：ModrinthAPI/CurseForgeAPI 的 `downloader:submitDownloadTasksFromPackage:` 在线路径改为下载 zip 后复用 ModpackImportService 统一导入流程，消除双轨维护（在线 CurseForge 无 API Key 时亦可用 BMCLAPI 直链工作）

### 不做的事（明确排除）

- 不引入"暂停/恢复"到 ZL2 没有的场景（仅保留 DownloadTaskManager 已支持 supportsResume 的任务的暂停/恢复）
- 不做移动网络提示（NWPathMonitor 蜂窝检测）——留待后续
- 不改 DownloadTaskManager 的并发槽位/断点续传/镜像体系（上一轮 optimize-download-system 已完成）
- 不做通知中心/小组件进度展示

## Impact

- **Affected specs**: `optimize-download-system`（其 Task 6.1 DownloadProgressCardView 双维度展示、Task 6.2 下载历史页的载体变更；DownloadHistoryStore/历史页保留）
- **Affected code**:
  - 新增：`Natives/PLTaskStage.{h,m}`、`Natives/PLTaskProgressViewController.{h,m}`
  - 修改：`Natives/DownloadTaskItem.{h,m}`（stages 字段+快照）、`Natives/DownloadTaskManager.{h,m}`（阶段上报 API）、`Natives/DownloadTasksViewController.m`（卡片增强+点击进详情）、`Natives/DownloadViewController.m`（删除私有 InstallerProgressViewController 约 400 行，安装逻辑改上报阶段）、`Natives/ModService.m`、`Natives/ShaderService.m`、`Natives/ResourcePackService.m`、`Natives/DataPackService.m`（注册任务）、`Natives/MinecraftResourceDownloadTask.{h,m}`（阶段桥接）、`Natives/ModpackImportService.{h,m}`（阶段上报+P0/P1/P2 修复）、`Natives/ModpackImportViewController.m`（删除自定义进度卡）、`Natives/installer/FabricUtils.m`、`Natives/installer/ForgeDirectInstaller.m`、`Natives/installer/NeoForgeDirectInstaller.m`、`Natives/installer/ForgeInstallViewController.m`（删 WFWorkflowProgressView）、`Natives/installer/modpack/ModrinthAPI.m`、`Natives/installer/modpack/CurseForgeAPI.m`（路径统一）、`Natives/LauncherNavigationController.{h,m}`（删 progressViewMain）、`Natives/LauncherRightPanelViewController.m`（删 progressVC 维护）、`Natives/LauncherPrefManageJREViewController.m`（JRE 下载接入）、`Natives/ProfileSettingsViewController.m`（Fabric API/OptiFine 安装改统一入口）、`Natives/CMakeLists.txt`（新增/移除源文件）、本地化 strings 文件（全语言）
  - 删除：`Natives/DownloadProgressCardView.{h,m}`、`Natives/DownloadProgressViewController.{h,m}`
- **BREAKING**：无用户可见数据迁移（任务快照新增 stages 字段向后兼容：旧快照无 stages 时回退纯进度展示）

## ADDED Requirements

### Requirement: 统一进度页（PLTaskProgressViewController）

系统 SHALL 提供唯一的下载/安装进度展示页面，任何注册到 DownloadTaskManager 的任务均可通过该页面查看进度详情。

#### Scenario: 安装流程自动弹出
- **WHEN** 用户开始安装流程（原版/Forge/Fabric/NeoForge/整合包导入）
- **THEN** 统一进度页自动弹出（iPhone 全屏模态，iPad formSheet 约 560pt 宽居中卡片），显示阶段步骤列表

#### Scenario: 阶段步骤展示（ZL2 风格）
- **WHEN** 任务包含多个阶段
- **THEN** 页面纵向列出全部阶段，每阶段一行：状态图标（✓已完成/◐运行中/○未开始/✕失败/-跳过）+ 阶段标题；仅"运行中"阶段展开详情区（当前文件名 message、进度条+速率+百分比一行、双维度"12/38 个文件 · 45MB/180MB"、ETA"剩余约 1 分 20 秒"）；不确定进度（-1）显示流动动画不显示百分比

#### Scenario: 超越 ZL2 的增强信息
- **WHEN** 任务运行中
- **THEN** 页面底部显示总进度汇总条（全部阶段加权百分比）；有速率时显示实时速率

#### Scenario: 最小化后台继续
- **WHEN** 用户点击"最小化"按钮
- **THEN** 进度页关闭，任务继续后台运行；下载中心对应卡片仍实时刷新；从下载中心点击该任务卡片可重新打开进度页

#### Scenario: 操作按能力动态显示
- **WHEN** 任务处于不同状态
- **THEN** 运行中且 supportsResume 显示"暂停"；已暂停显示"继续"；运行中显示"取消"；失败显示"重试"与"查看详情"（展开完整错误信息+重试次数）；不支持的能力不显示对应按钮

#### Scenario: 失败错误详情
- **WHEN** 任务失败且用户点击"查看详情"
- **THEN** 展开显示完整错误描述（错误域名/码、底层错误、已重试次数/上限、当前所处阶段名），便于定位卡在哪一步

### Requirement: 阶段化任务模型（PLTaskStage）

系统 SHALL 为下载任务提供阶段化进度模型。

#### Scenario: 阶段定义与上报
- **WHEN** 业务方注册安装类任务
- **THEN** 可通过 DownloadTaskManager 一次性设置阶段列表（标题/图标），随流程推进逐个更新阶段状态（Pending→Running→Completed/Failed/Skipped）、进度（-1~1）、速率、文件计数与动态 message

#### Scenario: 快照持久化兼容
- **WHEN** 应用重启恢复任务快照
- **THEN** 旧版快照（无 stages 字段）可正常解析，任务回退为纯进度展示不崩溃

### Requirement: 下载中心为唯一任务入口

#### Scenario: 全量任务可见
- **WHEN** 任意下载/安装业务进行中（含 Mod/Shader/资源包/数据包/整合包导入/原版/加载器/JRE）
- **THEN** 下载中心列表实时显示对应任务卡片，卡片上显示当前阶段名（如"下载资源文件"）与进度

#### Scenario: 卡片进入详情
- **WHEN** 用户点击下载中心任务卡片
- **THEN** 打开该任务的统一进度页；返回后列表刷新

### Requirement: 整合包导入修复

#### Scenario: 下载失败不再静默
- **WHEN** 依赖 mod 文件下载失败（非 404）
- **THEN** 导入以失败告终并显示失败文件列表；404/服务端不存在的文件跳过并在结果中明确列出跳过清单

#### Scenario: CurseForge 校验与目录路由
- **WHEN** 导入 CurseForge 整合包
- **THEN** 依赖文件带 SHA1 校验（可获取时）；光影/资源包/数据包类文件分别路由到 shaderpacks/resourcepacks/datapacks 目录而非全部进 mods/

#### Scenario: MCBBS 格式支持
- **WHEN** 用户导入含 mcbbs.packmeta 或 MCBBS 风格 manifest.json 的整合包
- **THEN** 成功识别并导入，launchInfo 中的 minMemory/javaArguments/launchArguments 写入 profile

#### Scenario: versionId 唯一
- **WHEN** 导入两个使用相同加载器+MC 版本的整合包
- **THEN** 两者 versionId 不同（自动追加短 hash 后缀），版本 JSON 不互相覆盖，profile 分别指向各自 versionId

## MODIFIED Requirements

### Requirement: 下载进度展示（原：7 套分散界面）

（完整替换为上文"统一进度页 + 下载中心"两套；原 DownloadProgressCardView/DownloadProgressViewController/InstallerProgressViewController/WFWorkflowProgressView/ModpackImportViewController 进度卡/progressViewMain 的展示职责全部由统一进度页承接，交互职责（取消等）由统一进度页与下载中心承接。）

## REMOVED Requirements

### Requirement: DownloadProgressCardView 底部悬浮进度卡片
**Reason**: 与统一进度页职责重叠，无操作能力，自动消失行为不可控
**Migration**: 其 6 处调用点（DownloadViewController 原版预装/直装/Mod/Shader/资源包下载、ProfileSettingsViewController Fabric API/OptiFine 安装）全部改为注册下载中心任务 + 自动弹出统一进度页

### Requirement: DownloadProgressViewController 全屏多文件进度页
**Reason**: KVO 直连 MinecraftResourceDownloadTask 数据源旁路 manager，与下载中心割裂，无操作能力
**Migration**: 多文件列表能力并入统一进度页的"当前文件 message + 双维度计数"；LauncherRightPanelViewController/LauncherNavigationController 的 present 入口删除

### Requirement: InstallerProgressViewController（DownloadViewController 私有）
**Reason**: 阶段步骤唯一载体但硬编码 4 处、无操作能力、push 全屏与 iPad 布局不符
**Migration**: 阶段定义移入数据层统一常量；进度驱动改为 DownloadTaskManager 阶段上报；展示由统一进度页承接

### Requirement: WFWorkflowProgressView（Apple 私有类）
**Reason**: dlopen 私有框架有审核风险且与下载中心完全割裂
**Migration**: Forge 安装器 jar 下载注册为下载中心任务

### Requirement: ModpackImportViewController 自定义进度卡
**Reason**: 与统一进度页重叠且旁路 manager
**Migration**: ModpackImportService 按整合包阶段定义上报，统一进度页展示

### Requirement: 工具栏 progressViewMain 4pt 进度条
**Reason**: 无文字无操作，与下载中心按钮功能重叠
**Migration**: 下载中心按钮增强显示聚合进度（有任务时按钮徽标显示进行中任务数/聚合百分比）；JRE 下载等复用点改注册下载中心任务
