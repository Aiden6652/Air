# Checklist

## Phase 1：数据层
- [x] PLTaskStage 五态枚举（Pending/Running/Completed/Failed/Skipped）与全部属性（title/iconName/status/message/progress/rateBytesPerSec/completedFileCount/totalFileCount）定义完整，progress 支持 -1 不确定语义
- [x] PLTaskStage 快照序列化/反序列化实现（snapshotDictionary/initWithSnapshotDictionary:）
- [x] DownloadTaskItem.stages/currentStageIndex 属性就位，旧快照（无 stages）解析不崩溃且回退纯进度展示
- [x] DownloadTaskManager 阶段上报 API（setTaskWithId:stages: / updateTaskWithId:stageAtIndex:* / currentStageIndex:）实现并触发既有通知与快照持久化
- [x] PLTaskStages.h 统一阶段常量（原版6步/+Fabric3步/+Forge3步/整合包6步/单文件1步）定义且含 SF Symbol 图标名

## Phase 2：统一进度页 + 下载中心
- [x] 进度页布局：标题+类别图标 / 阶段列表（五态图标，仅运行中展开 message+进度条+速率+百分比+双维度+ETA）/ 总进度汇总条 / 底部按钮区
- [x] 不确定进度（-1）显示流动动画且不显示百分比
- [x] 按钮按任务能力动态显示：运行中且 supportsResume→暂停；已暂停→继续；运行中→取消；失败→重试+查看详情；最小化始终可用
- [x] 失败详情展开：完整错误（domain/code/底层错误/retryCount/maxRetryCount/当前阶段名）
- [x] iPhone pageSheet 全屏模态 / iPad formSheet 约 560pt 居中卡片，内容超高内部滚动
- [x] 最小化后任务后台继续；从下载中心点击卡片可重新打开同一任务进度页（DownloadTasksViewController:1185 → presentForTaskId:）
- [x] 安装类任务自动弹出；同屏仅一个进度页，新任务替换内容（PLTaskProgressViewController:453 原地替换 + DownloadTaskManager:1390 自动弹出）
- [x] 下载中心卡片显示当前阶段名与"3/6"阶段计数；下载中心按钮显示进行中任务数徽标
- [x] 下载中心既有交互（暂停/恢复/取消/重试/切源/移除/历史页）不回归（本次改造未触碰下载中心卡片操作逻辑）

## Phase 3：安装类流程
- [x] 原版下载 6 阶段在统一进度页正确逐步推进（清单→JSON→客户端→库→资源→验证），库/资源阶段显示当前文件名与双维度计数
- [x] Fabric/Quilt 安装：原版6步完成后正确追加加载器3步（获取profile/下载库/写入JSON）
- [x] Forge/NeoForge 直装：合并阶段正确（原版6步+下载安装器/解析依赖/安装）
- [x] DownloadViewController 私有 InstallerProgressViewController 类及全部引用删除，编译无残留（CI 构建通过验证）
- [x] 取消安装能终止底层流程并清理（沿用既有取消语义）
- [x] LauncherRightPanelViewController/LauncherNavigationController 的旧 present DownloadProgressViewController 逻辑删除，iPhone/iPad 入口行为一致（全局搜索仅剩 1 处说明性注释）

## Phase 4：资源下载
- [x] Mod/Shader/资源包/数据包下载在下载中心可见（单阶段任务，含速率/进度/文件名），完成进入历史页（ModService:569 / ShaderService:374 / ResourcePackService:413 / DataPackService:461）
- [x] SHA1 校验失败按既有镜像/退避节奏重试（沿用 PLDownloadClient），失败详情可在进度页查看
- [x] ForgeInstallViewController 不再 dlopen WorkflowUIServices 私有框架；installer jar 下载在下载中心显示（ForgeInstallViewController:1164）
- [x] JRE 下载在下载中心显示，工具栏无 progressViewMain 依赖（LauncherPrefManageJREViewController:187）
- [x] ProfileSettingsViewController Fabric API/OptiFine 安装走统一进度页（ProfileSettingsViewController:1455/1618/1757）

## Phase 5：整合包
- [x] 整合包导入 6 阶段在统一进度页逐步推进，依赖下载阶段显示"3/10 个文件 · 2.4MB"（ModpackImportService:829）
- [x] 依赖 mod 下载失败（非404）时导入失败并显示失败文件列表（不再静默成功）
- [x] 404/server-only 跳过文件在成功结果中明确列出
- [x] CurseForge 依赖文件带 SHA1 校验（可获取时，BMCLAPI filesByFileID）
- [x] CurseForge 光影/资源包/数据包类文件路由到 shaderpacks/resourcepacks/datapacks（不再全进 mods/，按 classId 分发）
- [x] Modrinth files[] 非标准前缀嵌套文件（如 config/jei/jei.cfg）落到正确路径 gameDir/config/jei/jei.cfg（relativeUnder 取 lastPathComponent）
- [x] 同加载器+MC版本的两个整合包 versionId 不同（短hash后缀），版本 JSON 不互相覆盖，profile 分别指向
- [x] MCBBS 整合包（mcbbs.packmeta/MCBBS manifest.json）可导入，launchInfo 的 minMemory/javaArguments/launchArguments 写入 profile
- [x] MMC 整合包 instance.cfg 的 jvmArgs/maxMemory/minMemory/joinServerOnLaunch 写入 profile
- [x] 导入取消后：gameDirAbsolute、主 versions 目录本次创建的 version JSON、tmpInstallerPath 均被清理
- [x] 在线整合包下载（Modrinth/CurseForge）复用 ModpackImportService 统一流程（DownloadViewController:4573）；CurseForge 无 API Key 时在线路径仍可用（BMCLAPI 直链）

## Phase 6：清理与适配
- [x] DownloadProgressCardView / DownloadProgressViewController 文件与 CMakeLists 条目删除，全局无残留引用
- [x] progressViewMain 及复用点全部删除
- [x] 废弃的 installModpackFromFile: 旧路径删除
- [x] iPhone SE 小屏 / iPad 分屏 1/3 宽 / 横竖屏布局正常；深色模式颜色正常（代码走查：全部使用 systemBackground/labelColor 等动态颜色）

## Phase 7：本地化与构建
- [x] 全部新增文案在项目所有语言 strings 文件中有对应条目（zh-Hans/zh-Hant/en 各 48 key：18 阶段标题 + 30 进度页文案；代码引用 30 个 taskProgress key 全覆盖，脚本比对无缺失）
- [x] GitHub Actions 构建成功，产物 ipa/tipa/dSYM 生成（run 32248491900：com.air-devs.air-ios.ipa / com.air-devs.air-ios-trollstore.tipa / AngelAuraAmethyst.dSYM）
- [ ] 真机验证：原版安装、Forge 安装、整合包导入（含失败与跳过路径）、Mod 下载、下载中心全交互、最小化后恢复，iPhone 与 iPad 各过一遍（需用户手动安装 IPA 验证）
