# 下载界面深度重构 —— 进度追踪文档

> 本文档记录 `redesign-download-ui` 重构的整体进度、已完成交付物、当前所处阶段与下一步实施指引。
> 完整需求与验收标准以 `spec.md` / `tasks.md` / `checklist.md` 三份文件为准，本文件仅作进度快照，实施细节请以 `tasks.md` 为准。

- **改动分支**: `feature/optimize-download-system`
- **最近已推送 commit**: `d79c9881`
- **上次更新**: 本文件创建时（Phase 1 + Phase 2 完成）
- **注意**: 本沙箱为 Linux，无 iOS SDK，无法本地编译验证；需每次推送后由 GitHub Actions（macOS 14 / Xcode 15.4）构建验证。

---

## 一、总体目标（回顾）

将当前 **7 套互不关联的下载进度 UI** 收敛为 **2 套**：

1. **下载中心**（DownloadTasksViewController，增强）
2. **统一进度页**（PLTaskProgressViewController，新建，ZL2 阶段化风格）

并全量业务接入下载中心、修复整合包导入缺陷（P0/P1/P2）。详细需求见 `spec.md`。

---

## 二、已完成阶段

### ✅ Phase 1：数据层——阶段化任务模型（Task 1.1–1.4 全部完成）

| 交付物 | 说明 |
|--------|------|
| `Natives/PLTaskStage.{h,m}` | 阶段模型：`title`/`iconName`/`status`（五态：Pending/Running/Completed/Failed/Skipped）/`message`/`progress`(-1 不确定~1)/`rateBytesPerSec`/`completedFileCount`/`totalFileCount`；`snapshotDictionary` 序列化；`+stageWithTitle:iconName:` 便捷构造 |
| `Natives/PLTaskStages.h` | 统一阶段定义常量：原版 6 步、+Fabric/Quilt 3 步、+Forge/NeoForge 3 步、整合包 6 步、单文件 1 步；含 SF Symbol 图标名；`PLTaskStagesVanilla/FabricExtra/ForgeExtra/VanillaWithFabric/VanillaWithForge/Modpack/SingleFile` 组合函数；`PLTaskStageTitleDisplay()` 本地化渲染兜底 |
| `DownloadTaskItem` 扩展 | 新增 `stages`/`currentStageIndex`/`currentStage`；快照兼容旧快照（无 stages 回退空数组，不崩溃） |
| `DownloadTaskManager` 阶段上报 API | `setTaskWithId:stages:`、`updateTaskWithId:stageAtIndex:status:`、`...progress:message:`、`...rate:`、`...fileCount:totalFileCount:`、`updateTaskWithId:currentStageIndex:`；走既有通知与持久化 |
| `Natives/CMakeLists.txt` | 注册 `PLTaskStage.m`（与后续 `PLTaskProgressViewController.m`） |

### ✅ Phase 2：统一进度页 + 下载中心增强（Task 2.1–2.4 全部完成）

| 交付物 | 说明 |
|--------|------|
| `Natives/PLTaskProgressViewController.{h,m}` | 统一进度页（1287 行）：顶部标题+类别图标；阶段步骤列表（五态图标，仅运行中阶段展开 message/进度条+速率+百分比/双维度"12/38 个文件·45MB/180MB"/ETA）；不确定进度（-1）用 `PLFlowIndicatorView`（CAGradientLayer 流动动画）不显示百分比；总进度汇总条；底部按钮区（最小化/暂停/继续/取消/重试/查看详情，按能力动态显示）；失败展开完整错误；`+presentForTaskId:` 单实例切换；iPhone pageSheet / iPad formSheet 560pt |
| `DownloadTasksViewController` 增强 | 卡片显示当前阶段名+阶段计数("3/6")；点击卡片打开统一进度页 |
| 下载中心按钮徽标 | `LauncherRightPanelViewController`/`LauncherNavigationController` 的下载中心按钮加红色进行中任务数徽标 |
| 自动弹出机制 | `DownloadTaskItem.autoPresentDetail` 标记，由 `DownloadTaskManager.postUpdateForTask:` 主队列出口统一触发；同屏仅单个进度页，新任务原地替换 |

---

## 三、当前进度

**已到 Phase 2 结束，Phase 3 尚未开始。**

- Phase 1、2 代码已全部提交并推送至远程分支 `feature/optimize-download-system`（commit `d79c9881`）。
- Phase 3–7 均为未开始状态（tasks.md 中 `[ ]`）。

> ⚠️ Phase 1/2 尚未经 GitHub Actions 真实编译验证，下次会话应先推送触发一次构建，确认这两个阶段无编译错误再进入 Phase 3，避免错误向上游扩散。

---

## 四、下一步实施指引

### 顺序与依赖

```
Phase 3 ─┐
Phase 4 ─┼─ 各自依赖 Phase 1+2，互不阻塞，可并行
Phase 5 ─┘
   │
   ▼（三者完成才可）
Phase 6：旧 UI 清理（删 6 套旧界面）
   │
   ▼
Phase 7：本地化 + 构建验证
```

### Phase 3：安装类流程接入（原版/加载器）—— 下一优先项

- **Task 3.1**: `MinecraftResourceDownloadTask` 桥接，按原版 6 步上报阶段，`autoPresentDetail=YES`
- **Task 3.2**: `DownloadViewController.m` 删除私有 `InstallerProgressViewController`（行 456-840 约 400 行）及全部引用；原版/Fabric/Forge/NeoForge 直装改为"注册任务+阶段上报+自动弹统一进度页"
- **Task 3.3**: `FabricUtils`/`ForgeDirectInstaller`/`NeoForgeDirectInstaller` 回调签名不变，由 DownloadViewController 侧桥接为阶段上报
- **Task 3.4**: 清理 `LauncherRightPanelViewController`/`LauncherNavigationController` 的旧 present 逻辑

**Phase 3 关键注意点**（sub-agent 实施时务必遵守，先读懂再改）：
1. 实施前通读 `Natives/DownloadViewController.m` 现有安装逻辑与私有 `InstallerProgressViewController`（阶段步骤参考其布局/文案，删代码时连引用一起删）
2. `MinecraftResourceDownloadTask` 内部多个 `NSProgress`（progressList），按其父子进度映射到对应阶段的双维度计数与 message
3. 阶段上报都走 `DownloadTaskManager` 六大 API + `DownloadTaskItem.autoPresentDetail = YES` 自动弹出
4. 安装器 `reportProgress:` 回调保持签名，桥接动作放在调用方（DownloadViewController）
5. 阶段标题用 `PLTaskStages.h` 常量 + `NSLocalizedString`（`taskStage.title.*` key），文案代码兜底中文
6. **不要**在 Phase 3 删除旧 UI 文件（DownloadProgressCardView 等），留到 Phase 6；但 Phase 3 起不再 present 它们

### Phase 4：资源下载接入（Mod/Shader/资源包/数据包/JRE/Forge 安装器）

- Task 4.1: 四大 Service 注册单阶段任务，桥接进度/速率；`DownloadViewController` 与各 Manager VC 入口自动弹统一进度页；删除 `DownloadProgressCardView` 调用
- Task 4.2: `ForgeInstallViewController` 删 dlopen `WFWorkflowProgressView`（消除审核风险），installer jar 下载注册任务
- Task 4.3: `LauncherPrefManageJREViewController` JRE 下载注册任务，移除 progressViewMain
- Task 4.4: `ProfileSettingsViewController` Fabric API/OptiFine 安装走统一进度页

**Phase 4 注意**：single-stage 用 `PLTaskStagesSingleFile()`；单文件下载只有阶段级进度/速率，无多文件维度。

### Phase 5：整合包导入重构与修复（参考 ZL2）

- Task 5.1: `ModpackImportService` 按整合包 6 阶段上报；删除 ModpackImportViewController 自定义进度卡
- Task 5.2 (P0-1): downloadModFiles 失败不再静默——非 404 失败使导入失败并显示失败文件列表；404/server-only 跳过文件在成功结果列出
- Task 5.3 (P0-2): CurseForge 依赖文件补 SHA1（BMCLAPI 指纹 / filesByFileID；无 API Key 回退 zip EOCD）
- Task 5.4 (P0-3): CurseForge 按项目类型分发目录（shaderpacks/resourcepacks/datapacks，参考 ZL2 CurseForgePack.kt versionFolder）
- Task 5.5 (P1): Modrinth 非标准前缀嵌套子目录路径重复 bug（lastPathComponent）
- Task 5.6 (P1): versionId 唯一化（追加 modpack 短 hash 后缀）
- Task 5.7 (P1): MCBBS 格式支持（参考 ZL2 MCBBSPack.kt）
- Task 5.8 (P1): instance.cfg 完整解析（参考 ZL2 MultiMCConfiguration.kt）
- Task 5.9 (P2): 取消清理残留
- Task 5.10 (P2): 在线整合包路径统一复用 ModpackImportService（依赖 5.1–5.4 先完成）

### Phase 6：旧 UI 清理与双端打磨

- 删除 `DownloadProgressCardView.{h,m}`、`DownloadProgressViewController.{h,m}` 及 CMakeLists 条目，全局搜无残留
- 删 `progressViewMain` 及复用
- 删废弃的 `installModpackFromFile:` 旧路径
- iPhone SE/iPad 分屏/横竖屏/深色模式走查

### Phase 7：本地化与构建验证

- 全语言 strings 补全（`taskStage.title.*`、`taskProgress.*` 等 key）
- 推送 GitHub 触发 Actions 构建，修复编译错直至 ipa/tipa/dSYM 生成
- 按 checklist.md 自检 + 真机/TrollStore 验证

---

## 五、验证建议

- 每次阶段完成即推送，让 Actions 尽早暴露编译问题（linux 沙箱无法本地编译 ObjC/UIKit）。
- checklist.md 是逐条验收依据；Phase 3 起每完成一个阶段对 Phase 对应检查点自检并勾选。
- 本地化 strings 统一在 Phase 7 一次处理，中间阶段代码内用中文兜底即可。