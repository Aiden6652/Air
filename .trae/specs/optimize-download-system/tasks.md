# Tasks

## Phase 0：参考仓库准备
- [x] Task 0.1: 创建 ThirdParty 目录并将 ZalithLauncher2 以 git 子模块形式克隆（`ThirdParty/ZalithLauncher2`，浅克隆 depth=1，.gitmodules + gitlink 提交到索引）

## Phase 1：统一下载客户端（基础设施）
- [x] Task 1.1: 新建 `PLMirrorCenter` 镜像配置中心
  - [x] 收敛 BMCLAPI/MCIM/官方根 URL 常量到一处（消除 4+ 处硬编码）
  - [x] 实现 `URLsForOriginal:resourceType:`：按资源类型（gameFile/assetSearch/assetDownload/modLoader）与用户策略返回按优先级排序的候选 URL 列表
  - [x] BMCLAPI 映射覆盖 Mojang 全系 + Forge/NeoForge/Fabric/Quilt maven（参考 ZL2 `BMCLAPI.kt` 的 REPLACE_MIRROR_HOLDERS）
  - [x] MCIM 映射覆盖 Modrinth/CurseForge API 与 CDN（参考 ZL2 `MCIMMirror.kt`）
- [x] Task 1.2: 新建 `PLDownloadClient` 统一下载器
  - [x] 镜像列表顺序尝试；单镜像内指数退避重试（默认 3 次，1s/2s/4s）
  - [x] SHA1 校验 + 无 sha1 时 zip 完整性校验兜底；失败删除残留文件
  - [x] 速率统计器（每秒采样）与跨镜像/重试的进度回退（参考 ZL2 `withSpeedReport`/`sizeCallback(-bytes)`）
  - [x] 全部候选失败返回聚合 NSError（suppressErrors 附加）

## Phase 2：下载任务系统增强
- [x] Task 2.1: 真断点续传
  - [x] 暂停改用 `cancelByProducingResumeData:`，resumeData 写入磁盘缓存目录
  - [x] 恢复改用 `downloadTaskWithResumeData:`；落实/修正 `supportsResume` 语义
- [x] Task 2.2: 任务持久化与历史
  - [x] 进行中任务序列化到 JSON，启动时恢复为"已暂停"状态
  - [x] 已完成任务写入下载历史（上限 200 条，LRU 清理）
- [x] Task 2.3: 全局并发上限（任务级信号量，默认 3，可后续做成偏好项）

## Phase 3：整合包并发下载改造
- [x] Task 3.1: `ModpackImportService` 下载并发化
  - [x] `downloadModFiles:` 改 dispatch_group + 信号量限流（默认 12），移除同步信号量等待与 `NSThread sleep`
  - [x] `downloadFileFromURL:` 改异步或迁移到 PLDownloadClient
- [x] Task 3.2: 校验与容错
  - [x] 启用 Modrinth `files[].hashes.sha1` 校验
  - [x] 404/NotFound 跳过计入警告；失败文件列表支持完成后单独重试下载
- [x] Task 3.3: CurseForge 整合包链接延迟获取（下载前并发解析 projectID/fileID → URL）

## Phase 4：镜像源策略统一与迁移
- [x] Task 4.1: 偏好设置拆分（fileDownloadSource/assetSearchSource/assetDownloadSource/fetchModLoaderSource，值：official_first/mirror_first）+ 旧 `general.download_source` 自动迁移
- [x] Task 4.2: 业务方切换到 PLMirrorCenter/PLDownloadClient：MinecraftResourceDownloadTask、ModService、ShaderService、ResourcePackService、DataPackService、ModpackImportService、FabricUtils、ForgeDirectInstaller、NeoForgeVersionFetcher；删除 MCIMMirror
- [x] Task 4.3: 修正不一致：`download_source=mcim`（迁移后 mirror_first）时 Forge 父 JSON 的镜像走向；Fabric/Quilt 补 BMCLAPI 镜像（fabric-meta/quilt-meta/maven）
- [x] Task 4.4: 设置页 UI 增加分类镜像策略选择（本地化全语言）

## Phase 5：校验与增量下载全覆盖
- [x] Task 5.1: Mod/Shader/ResourcePack/DataPack 下载启用 sha1 校验（Modrinth API 已返回 hashes；下载入口 `PLSha1FromPrimaryFile` 提取 files[0].hashes.sha1 透传）
- [x] Task 5.2: 下载前检查已存在文件（PLDownloadClient 增量命中：sha1 或 zip 完整性通过即跳过，失败旧文件原子替换保护）

## Phase 6：UI/UX 增强
- [x] Task 6.1: DownloadProgressCardView 显示实时速率；多文件任务双维度进度文案（"42/100 个文件 · 18.3MB/96MB"）；整合包聚合卡片（rawTask=nil 不占并发槽位）
- [x] Task 6.2: 下载历史页（DownloadHistoryViewController，基于 DownloadHistoryStore 持久化，支持清空）
- [x] Task 6.3: 全语言本地化文案（zh-Hans/zh-Hant/en 等，新增键：速率、历史、镜像策略、失败重试等）

## 验证
- [x] Task 7.1: 提交到 GitHub 远程分支触发 Actions 构建（macOS 14 / Xcode 15.4），确认无编译错误（run #1619 成功，产物 ipa/tipa/dSYM 已上传）
- [ ] Task 7.2: 按 checklist.md 逐项自检并在真机/TrollStore 流程验证关键场景

# Task Dependencies
- Phase 1（Task 1.1/1.2）是所有后续阶段的前置
- Task 2.x 依赖 Task 1.2（复用速率/重试）；Task 2.1 与 2.2 可并行
- Task 3.1/3.2 依赖 Task 1.2；Task 3.3 独立可并行
- Task 4.2 依赖 Task 1.1 + 1.2 + Phase 2/3 完成后统一切换（避免中间态）
- Task 5.x 依赖 Task 1.2；Task 6.1 依赖 Task 2.2（历史）与速率统计（1.2）
- Task 7.x 为最终验证，依赖全部完成
