# Air 下载功能优化（对标 ZalithLauncher2）Spec

## 背景：ZL2 参考仓库

ZL2 已作为 git 子模块克隆至 `ThirdParty/ZalithLauncher2`（https://github.com/ZalithLauncher/ZalithLauncher2.git），供后续开发参考。其下载相关核心源码位于 `ZalithLauncher/src/main/java/com/movtery/zalithlauncher/` 下的 `utils/network/`、`coroutine/`、`game/download/`、`game/version/download/`、`game/addons/mirror/`、`setting/` 等包。

## Why

Air 的下载体系由各业务模块（游戏本体 / Mod / 整合包 / 光影 / 资源包 / 加载器安装器）各自为政：每个 Service 独立创建 NSURLSession + delegate，镜像 URL 硬编码且策略割裂，任务系统无持久化、"断点续传"名存实亡（suspend/resume 而非 resumeData），整合包 Mod 下载实为串行（同步信号量阻塞）。对标 ZL2 的现代化下载框架（镜像列表统一汇聚、规划-执行分离、两级重试、进度回退、按资源类型独立配置镜像、速率监测框架），需要一次系统性重构，在保持现有 UI 交互习惯的前提下大幅提升下载可靠性、速度与可维护性。

---

## 一、Air vs ZL2 深度对比分析

### 1. 架构总览对比

| 维度 | Air（现状） | ZL2 | 差距结论 |
|------|------------|-----|---------|
| 下载抽象 | 无统一抽象，各 Service 各造 NSURLSession+delegate（ModService/ShaderService/ModpackImportService/MinecraftResourceDownloadTask 各一套） | 四层抽象：OkHttp→`downloadFromMirrorList()`→DownloadTask→并发下载器→TaskFlowExecutor | Air 缺少统一汇聚点，代码重复严重 |
| 镜像模型 | 单一 `general.download_source`（official/bmclapi/mcim），全有或全无 | 4 个独立设置：`fetchModLoaderSource`/`fileDownloadSource`/`assetSearchSource`/`assetDownloadSource`，均为 OFFICIAL_FIRST/MIRROR_FIRST | ZL2 粒度更细，且是"优先级列表"而非"单选" |
| 故障转移 | 无。镜像挂了直接失败 | 所有下载走镜像列表顺序尝试，单镜像内重试 2 次，失败聚合异常 | Air 无韧性 |
| 并发模型 | 各 Service 独立 `HTTPMaximumConnectionsPerHost`（24/16/16/6）；整合包实际串行 | Semaphore(64) 全局并发 + 两轮下载重试 | Air 整合包并发严重退化 |
| 断点续传 | 假的：`suspend`/`resume` 挂起调度，App 重启字节全丢 | 无跨进程断点续传，但单文件失败重试不丢进度统计；增量下载（已存在文件 SHA1 通过即跳过） | Air 需先做真 resumeData + 持久化 |
| 任务持久化 | 无（内存字典，重启即失） | 任务本身不持久化，但版本清单有缓存 | Air 需补任务持久化 + 下载历史 |
| 文件校验 | 仅游戏本体有 SHA1；Mod/光影/资源包/整合包均无 | 全部 SHA1；无 SHA1 时 zip/jar/7z 完整性校验兜底 | Air 大面积缺失 |
| 进度统计 | 单任务字节数；镜像切换/重试时进度可能倒退或虚高 | 双维度（文件数+字节数）、100ms 采样、跨镜像重试进度回退机制 | ZL2 明显更精细 |
| 速率显示 | 无 | `withSpeedReport` 统一框架，每秒采样，StateFlow 驱动 UI | Air 缺失 |
| 取消清理 | 取消后残留部分文件 | 单文件失败删残留；整合包取消清理缓存+已复制文件；覆盖安装备份回滚 | Air 缺失 |

### 2. 分模块对比

#### 2.1 游戏本体下载

- **Air**（[MinecraftResourceDownloadTask.m](file:///workspace/Natives/MinecraftResourceDownloadTask.m)）：
  - `replaceURLWithDownloadSource:forceSource:` 做单一主机替换（BMCLAPI/MCIM/官方）
  - 24 连接并发，SHA1 校验，递归重试 3 次（无退避）
  - 失败/取消后字节丢失，无增量下载（已存在文件不校验直接重下或跳过逻辑不统一）
- **ZL2**（`BaseMinecraftDownloader.kt` + `MinecraftDownloader.kt`）：
  - "规划-执行"分离：`loadClientJarDownload`/`loadAssetsDownload`/`loadLibraryDownloads` 只规划任务列表
  - 版本清单本地缓存一天；`mergeUnlistVersions` 合并隐藏版本
  - Semaphore(64) 并发 + 两轮下载；下载前先校验已存在文件（SHA1/zip 完整性），通过即跳过（增量）
  - assets 强制官方优先（减轻镜像压力）；跳过 org.lwjgl（移动端自带）
- **差距**：Air 缺增量校验、镜像列表故障转移、清单缓存、两轮重试。

#### 2.2 下载任务系统

- **Air**（[DownloadTaskManager.m](file:///workspace/Natives/DownloadTaskManager.m)）：
  - 单例内存字典管理任务；`supportsResume` 标志是装饰品（pause/resume 用 `suspend`/`resume`）
  - 无持久化、无下载历史、无全局并发上限、无优先级
  - `retryHandler` 由业务方注册，未注册则重试按钮无效
- **ZL2**（`TaskFlowExecutor.kt` + `Task.kt`）：
  - 多阶段（Phase）任务流，支持运行中 `addPhases` 动态追加（整合包解析后追加依赖下载阶段）
  - SupervisorJob 任务隔离；4 个 StateFlow（stage/progress/message/rate）驱动 UI
- **差距**：Air 需实现真断点续传（`cancelByProducingResumeData:` + `downloadTaskWithResumeData:`）、任务持久化、全局并发上限。

#### 2.3 Mod / 光影 / 资源包 / 数据包下载

- **Air**（[ModService.m](file:///workspace/Natives/ModService.m)、[ShaderService.m](file:///workspace/Natives/ShaderService.m)、[ResourcePackService.m](file:///workspace/Natives/ResourcePackService.m)、[DataPackService.m](file:///workspace/Natives/DataPackService.m)）：
  - 均走 Modrinth API（经 [MCIMMirror.m](file:///workspace/Natives/MCIMMirror.m) 重写，仅支持 MCIM，不支持 BMCLAPI）
  - 无 SHA1 校验（注释称"由 JAR 格式校验保证"，但实际未做 zip 完整性检查）
  - 重试重建 task 从 0 下载
- **ZL2**（`platform/` 包）：
  - 平台抽象层 `AbstractPlatformSearcher`（Modrinth/CurseForge 双平台）
  - 镜像源策略：`assetSearchSource`（API 查询）与 `assetDownloadSource`（文件下载）分开配置，顺序尝试
  - CurseForge 特有优化：MurmurHash2 指纹匹配本地文件、分页并发加载（chunk 20 页、并发 10）
  - 本地文件更新检查：Modrinth(sha1) 与 CurseForge(MurmurHash) **并发查询**，先返回者胜
- **差距**：Air 缺 SHA1 校验、BMCLAPI mod 镜像、双平台并发查询、更新检查的指纹匹配。

#### 2.4 整合包

- **Air**（[ModpackImportService.m](file:///workspace/Natives/ModpackImportService.m)）：
  - **致命缺陷**：`downloadFileFromURL:` 用 `dispatch_semaphore_wait(FOREVER)` 同步阻塞，`downloadModFiles:` for 循环串行调用 → 100+ Mod 的整合包下载极慢（`HTTPMaximumConnectionsPerHost=6` 完全浪费）
  - 重试间隔用 `[NSThread sleepForTimeInterval:1.0]` 阻塞线程
  - 无 SHA1 校验（Modrinth `files[].hashes.sha1` 未用）；失败文件不阻断导入仅记录警告；installer 失败降级为占位 JSON
  - CurseForge 强依赖 API key
- **ZL2**（`ModpackImporter.kt` + `ModDownloader.kt`）：
  - Semaphore(64) 并发 + 两轮重试；404 容错跳过
  - CurseForge 链接**延迟获取**（lambda 下载前才解析，复用并发优势）
  - 支持 4 种格式（Modrinth/CurseForge/MCBBS/MultiMC）；移动网络确认；取消清理
- **差距**：Air 需将串行改为并发（信号量限流）、加 SHA1、404 容错、失败汇总交互优化。

#### 2.5 镜像源管理

- **Air**：
  - 三套镜像逻辑分散：`MinecraftResourceDownloadTask.replaceURLWithDownloadSource`（游戏本体：BMCLAPI+MCIM+官方）、`MCIMMirror.rewriteURL`（Mod：MCIM+官方）、`ModpackUtils`/`NeoForgeVersionFetcher`（加载器：BMCLAPI+官方）
  - MCIM 根 URL 硬编码；BMCLAPI 根 URL 在 4+ 处重复硬编码
  - 无健康检查、无自动故障转移；`download_source=mcim` 时 Forge 父 JSON 回退官方（不一致）
- **ZL2**（`BMCLAPI.kt` + `MCIMMirror.kt` + `AllSettings.kt`）：
  - BMCLAPI 覆盖 Mojang 全系 + Forge/NeoForge/Fabric maven + Maven Central(腾讯云)；MCIM 覆盖两大 CDN
  - 中国大陆地域门控（时区判断）；assets 强制官方优先
  - `MirrorSource` 通用顺序尝试执行器
- **差距**：Air 需要统一的镜像配置中心（单一来源、按资源类型策略、故障转移）。

#### 2.6 加载器安装器下载

- **Air**（[FabricUtils.m](file:///workspace/Natives/installer/FabricUtils.m)、[ForgeDirectInstaller.m](file:///workspace/Natives/installer/ForgeDirectInstaller.m) 等）：同步信号量下载、无重试、Fabric/Quilt 无镜像
- **ZL2**（`Download.FabricLike.kt`、`Download.ForgeLike.kt`）：Fabric meta/maven 均有 BMCLAPI 镜像；mojmap 下载带重试；installer 内已有 jar 从下载列表移除（去重）
- **差距**：Air 需为 Fabric/Quilt 补 BMCLAPI 镜像映射，下载走统一客户端获得重试能力。

### 3. Air 问题清单（按优先级）

**P0（阻断核心体验）**
1. 假断点续传 + 无任务持久化（App 重启任务全丢）
2. 整合包 Mod 串行下载（同步信号量阻塞，并发配置形同虚设）
3. 镜像策略割裂（单一 download_source 无法覆盖所有资源类型，无故障转移）
4. 整合包无 SHA1 校验（损坏文件到 MC 加载才崩溃）

**P1（影响可靠性）**
5. Mod/光影/资源包/数据包无 SHA1 校验
6. ForgeDirectInstaller 无重试、同步阻塞
7. 镜像 URL 硬编码分散（MCIM 一处、BMCLAPI 4+ 处）
8. 重试无退避、无进度回退（进度统计跨重试不准）

**P2（体验优化）**
9. 无下载速率显示、无双维度聚合进度（文件数+大小）
10. 无下载历史
11. Fabric/Quilt 无镜像
12. CurseForge 无指纹匹配更新检查、无分页并发
13. 无全局并发上限

---

## What Changes

以 ZL2 架构为蓝本，在 Air（Objective-C / NSURLSession 体系）中分六阶段落地：

### Phase 1：统一下载客户端（基础设施，最优先）
- 新建 `PLDownloadClient`：封装"镜像列表顺序尝试 + 单镜像重试(退避) + SHA1/zip 校验 + 速率统计 + 进度回退"的单一汇聚点，所有业务方逐步迁移
- 新建 `PLMirrorCenter`：统一镜像 URL 映射（BMCLAPI 全量覆盖含 Fabric maven、MCIM CDN），根 URL 常量收敛到一处；对外提供 `URLsForOriginal:resourceType:` 返回按优先级排序的候选列表

### Phase 2：下载任务系统增强
- 真断点续传：`cancelByProducingResumeData:` + `downloadTaskWithResumeData:`，resumeData 持久化到磁盘
- 任务持久化（进行中任务 + 下载历史）到 JSON 文件，App 重启恢复
- 全局并发上限（信号量，默认同时 3 个任务级下载）；移除装饰性 `supportsResume` 语义或落实之

### Phase 3：整合包并发下载改造
- `downloadModFiles:` 改为并发（dispatch_group + 信号量限流 8-16），废除同步信号量阻塞与 `NSThread sleep`
- 启用 Modrinth `files[].hashes.sha1` 校验；404 容错跳过；失败汇总交互优化（失败文件可单独重试）
- CurseForge 下载链接延迟获取（纳入并发队列）

### Phase 4：镜像源策略统一
- 偏好设置拆分为按资源类型的镜像策略（文件下载/资源搜索/资源下载/加载器），值改为 官方优先/镜像优先
- 保留 `general.download_source` 作为兼容默认值（**BREAKING**：设置项语义变化，需迁移逻辑）
- Mod 下载补 BMCLAPI 镜像支持；`download_source=mcim` 时 Forge 父 JSON 走 MCIM 的一 致性修正

### Phase 5：校验与增量下载全覆盖
- Mod/光影/资源包/数据包下载启用 Modrinth sha1 校验；无 sha1 时 zip 完整性校验兜底
- 下载前校验已存在文件，通过即跳过（增量下载）

### Phase 6：UI/UX 增强
- 下载卡片显示实时速率（统一速率采样器）
- 多文件任务双维度进度（"120/350 个文件 · 45.2MB/128MB"）
- 下载历史页（复用持久化）

**BREAKING**：`general.download_source` 偏好语义变更（Phase 4），需写迁移代码；`DownloadTaskItem.supportsResume` 语义变更（Phase 2）。UI 交互习惯（任务卡片、暂停/取消按钮位置）保持不变。

## Impact

- Affected specs: 无其他 spec 受影响（`optimize-jit-acquisition` 与本变更无交集）
- Affected code:
  - 新增：`Natives/PLDownloadClient.{h,m}`、`Natives/PLMirrorCenter.{h,m}`、`Natives/PLDownloadHistoryStore.{h,m}`
  - 重构：`Natives/DownloadTaskManager.{h,m}`、`Natives/MinecraftResourceDownloadTask.{h,m}`、`Natives/ModpackImportService.m`、`Natives/ModService.m`、`Natives/ShaderService.m`、`Natives/ResourcePackService.m`、`Natives/DataPackService.m`、`Natives/MCIMMirror.{h,m}`（并入 PLMirrorCenter 后废弃）、`Natives/installer/*`（Fabric/Forge/NeoForge 下载部分）
  - UI：`DownloadProgressCardView.m`、`DownloadTasksViewController.m`、`LauncherPreferences.{h,m}`（镜像设置项）
  - 本地化：`Natives/resources/zh-Hans.lproj/Localizable.strings` 等全语言新增下载相关文案
- 构建影响：纯 OC 代码变更，无新系统库依赖；在 GitHub Actions macOS 14 + Xcode 15.4/16 上验证

---

## ADDED Requirements

### Requirement: 统一镜像列表下载客户端
系统 SHALL 提供单一下载入口 `PLDownloadClient`，接收按优先级排序的 URL 候选列表与可选 sha1，内部完成顺序尝试、退避重试（默认 3 次、指数退避）、SHA1/zip 完整性校验、速率统计与进度回退，全部候选失败时返回聚合错误。

#### Scenario: 首选镜像故障自动转移
- **WHEN** 用户下载某文件且首选镜像返回 5xx 或超时
- **THEN** 客户端在同一任务内自动尝试下一候选 URL，进度不回退不跳变，最终成功后正常完成

#### Scenario: SHA1 校验失败触发重试
- **WHEN** 下载完成但 SHA1 与期望不符
- **THEN** 删除残留文件并以退避间隔重试，重试次数耗尽后尝试下一镜像

### Requirement: 真断点续传与任务持久化
系统 SHALL 通过 `cancelByProducingResumeData:` 暂停下载并将 resumeData 持久化，重启后经 `downloadTaskWithResumeData:` 恢复；进行中任务与已完成历史 SHALL 持久化到磁盘并在 App 重启后恢复展示。

#### Scenario: App 被杀后恢复下载
- **WHEN** 用户暂停一个 50% 进度的下载后完全退出 App 再打开
- **THEN** 任务列表仍显示该任务为已暂停，点击继续后从 50% 附近续传而非从 0 开始

### Requirement: 整合包并发下载
整合包依赖文件 SHALL 以并发方式下载（可配置限流，默认 ≥8 并发），禁止同步信号量阻塞与线程 sleep；SHALL 启用 SHA1 校验，404 视为跳过而非失败。

#### Scenario: 大型整合包下载提速
- **WHEN** 用户导入含 100 个 Mod 的 Modrinth 整合包
- **THEN** 下载阶段以并发方式进行，整体耗时显著低于串行基线（同等网络下文件级并发 ≥8）

#### Scenario: 部分文件损坏被拦截
- **WHEN** 某个 Mod 文件下载后 SHA1 不匹配且重试耗尽
- **THEN** 该文件记入失败列表并在导入完成时明确提示，其余文件不受影响

### Requirement: 按资源类型配置镜像策略
系统 SHALL 支持为文件下载、资源搜索、资源下载、加载器获取分别配置"官方优先/镜像优先"策略，并从旧 `general.download_source` 自动迁移；镜像 URL 映射 SHALL 收敛到单一配置中心。

#### Scenario: 旧设置无缝迁移
- **WHEN** 用户从旧版本升级且 `general.download_source=mcim`
- **THEN** 新设置项自动初始化为对应的镜像优先策略，用户无感知

### Requirement: 校验与增量下载全覆盖
所有资源类型（Mod/光影/资源包/数据包）下载 SHALL 在 API 提供哈希时执行 SHA1 校验；目标文件已存在且校验通过时 SHALL 跳过下载。

#### Scenario: 重复下载相同 Mod
- **WHEN** 用户对已下载且文件完好的 Mod 再次发起同版本下载
- **THEN** 任务立即完成且不产生网络流量

### Requirement: 下载速率与双维度进度展示
下载任务卡片 SHALL 实时显示下载速率；多文件聚合任务 SHALL 同时展示文件数与字节数进度。

#### Scenario: 查看整合包下载进度
- **WHEN** 整合包依赖下载进行中
- **THEN** 卡片显示类似"42/100 个文件 · 18.3MB/96MB · 2.1MB/s"的信息

## MODIFIED Requirements

### Requirement: 下载任务管理
`DownloadTaskManager` 在保留现有注册/进度/状态筛选 UI 的基础上，SHALL 增加全局并发上限（默认同时 3 个任务级下载）、真暂停/恢复语义（resumeData）与任务持久化；`supportsResume` 属性 SHALL 与实际能力一致。

## REMOVED Requirements

### Requirement: MCIMMirror 独立镜像重写
**Reason**: 镜像逻辑收敛到 `PLMirrorCenter` 统一配置中心，避免三套割裂策略。
**Migration**: `MCIMMirror` 的公开方法由 `PLMirrorCenter` 等价替代，调用方（ModService/ShaderService/ResourcePackService/DataPackService/ModpackImportService 等）在 Phase 4 全部切换后删除旧类。
