# 资源管理界面全面重构 Spec

## Why

资源管理界面（Mod / 数据包 / 资源包 / 光影 / 世界）目前是系统 Cell + 不一致搜索栏的简陋状态，与下载界面的毛玻璃卡片风格严重割裂；且 Mod 检测更新功能因三处 API bug 完全不可用，更新还是独立窗口，体验割裂。需参照 ZL2 与 Air-Design 规范全面重构，让用户长期使用时保持界面美观、直观、易用。

## What Changes

- 抽取公共资源卡片 Cell（`ResourceCardTableViewCell`）与资源列表基类（`ResourceListViewController`），统一毛玻璃卡片 + 三态视图（空/加载/错误）+ 批量选择模式
- **Mod 管理界面重构**：新增状态筛选（全部/已启用/已禁用）与排序；批量操作增强；**检测更新功能内置**（顶栏按钮 → 检测 → 确认弹窗多选 → 下载替换 → 刷新，参考 ZL2 ModsManagerScreen）
- **修复 Mod 更新检测三处 bug**（详见 ADDED Requirements），本地新增 MurmurHash2 指纹计算
- **BREAKING**：删除独立的 `ModUpdateViewController`（功能并入 Mod 管理界面）
- **移除资源管理界面自带的在线下载入口**：DataPacks / ResourcePacks / Worlds 的 UISegmentedControl 本地/在线切换及在线搜索逻辑全部移除（参照 ShadersManagerViewController 已完成的移除模式）；空状态提供"去下载"引导按钮跳转统一下载界面
- 六个管理界面全部按 Air-Design 规范刷新：图标容器 + 类型语义色、labelColor 系列文字、chevron 暗示、空状态引导、连锁进场动画

## Impact

- Affected code:
  - `Natives/ModsManagerViewController.m`（重构 + 更新集成）
  - `Natives/ModTableViewCell.h/.m`（升级为 ResourceCard 基类）
  - `Natives/ModUpdateService.m/.h`（修复反查调用）
  - `Natives/installer/modpack/ModrinthAPI.m`（修复 version_file URL）
  - `Natives/installer/modpack/CurseForgeAPI.m`（修复指纹解析 + 新增指纹计算支持）
  - `Natives/ModUpdateViewController.h/.m`（**删除**）
  - `Natives/DataPacksManagerViewController.m`、`Natives/ResourcePacksManagerViewController.m`、`Natives/WorldsManagerViewController.m`（移除在线入口 + UI 重构）
  - `Natives/ShadersManagerViewController.m`（UI 刷新对齐规范）
  - `Natives/CMakeLists.txt`（新文件注册 / 删除文件移除）
- 参考：`ThirdParty/ZalithLauncher2/.../ModsManagerScreen.kt`（更新集成模式）、`ModUpdater.kt`（检测算法）、`ShadersManagerViewController.m`（在线入口移除模式）

## ADDED Requirements

### Requirement: 资源卡片 Cell 公共基类

系统 SHALL 提供 `ResourceCardTableViewCell`（可由现有 `ModTableViewCell` 升级），所有资源管理列表项 SHALL 使用该基类，统一实现 Air-Design 6.2 三层卡片背景（半透明基底 + BackgroundManager 毛玻璃 + 边框/阴影）、图标容器（类型语义色 2.4 + SF Symbol 8.2）、主/副文字层级（title3/body + subhead/caption1）、启用开关或 chevron。

#### Scenario: 任意资源列表滚动

- **WHEN** 用户在任一资源管理界面滚动列表
- **THEN** 所有条目为 12pt 圆角毛玻璃卡片（L2 标准卡片），图标带类型语义色容器，亮色壁纸下文字清晰可读（labelColor 系列）

### Requirement: 资源列表基类与三态视图

系统 SHALL 提供 `ResourceListViewController` 基类（或等效公共模板），统一搜索栏样式、空状态（图标 + 文案 + 引导按钮）、加载态、批量选择模式工具栏。

#### Scenario: 列表为空

- **WHEN** 某资源目录下无文件
- **THEN** 界面显示居中空状态（类型语义色 SF Symbol 图标 + 说明文案），Mod/数据包/资源包/光影显示"去下载"引导按钮，点击跳转统一下载界面对应资源类型

### Requirement: Mod 更新检测（内置 + 修复）

系统 SHALL 在 Mod 管理界面内置更新检测（参考 ZL2），并修复以下三处 bug：

1. **Modrinth 文件反查 URL**：`projectForFileHash:` SHALL 使用 `GET /v2/version_file/{sha1}?algorithm=sha1`（hash 为路径参数），而非当前的 `?hash=` 查询参数（现永远 404）
2. **CurseForge 文件反查指纹**：SHALL 新增本地 MurmurHash2 指纹计算（对 mod jar 文件字节流），`ModUpdateService` 传递指纹数字而非文件路径（现 `[filePath longLongValue]` 恒为 0，永不命中）
3. **CurseForge 指纹响应解析**：项目 ID SHALL 取 `exactMatches[0].file.modId`，而非 `exactMatches[0].id`（那是文件 ID）

#### Scenario: 检测到可更新 Mod

- **WHEN** 用户在 Mod 管理界面点击"检查更新"按钮且存在可更新 Mod
- **THEN** 弹出确认列表（每项含名称、当前版本 → 新版本、来源 pill、复选框），默认全选；确认后并发下载新版本替换旧文件（经 PLDownloadClient），完成后自动刷新列表并提示成功数

#### Scenario: 无可用更新

- **WHEN** 全部 Mod 均为最新
- **THEN** 界面内提示"所有 Mod 均为最新版本"，不打断用户

#### Scenario: 本地 Mod 与远端不匹配

- **WHEN** 某本地 Mod 无法通过双源反查命中远端项目
- **THEN** 该 Mod 被静默跳过并在结果摘要中说明"跳过 N 个无法识别的 Mod"

### Requirement: 移除资源管理界面自带下载入口

DataPacks / ResourcePacks / Worlds 管理界面 SHALL 移除 UISegmentedControl 本地/在线切换与在线搜索逻辑（Modrinth 搜索），资源获取统一由下载界面承担；空状态 SHALL 提供"去下载"按钮跳转。

#### Scenario: 用户需下载资源包

- **WHEN** 用户在资源包管理界面想获取新资源包
- **THEN** 界面无在线搜索入口；用户通过空状态/工具栏"去下载"按钮进入统一下载界面

### Requirement: Mod 管理筛选与批量操作

Mod 管理 SHALL 提供状态筛选（全部/已启用/已禁用 chip 或下拉）、排序（名称/修改时间）、批量选择（全选/取消、批量启用/禁用/删除，沿用现有选择模式并整合进基类工具栏）。

#### Scenario: 批量禁用

- **WHEN** 用户进入选择模式勾选多个 Mod 并点击"禁用"
- **THEN** 所选 Mod 文件批量重命名为 `.disabled` 后缀，列表即时刷新，工具栏显示操作结果

## MODIFIED Requirements

### Requirement: Mod 管理界面视觉

Mod 管理列表项 SHALL 从当前样式升级为 Air-Design L2 标准卡片：图标容器（加载器品牌色或 Mod 语义色橙色 `puzzlepiece.fill`）、名称（title3 Semibold）、文件名/版本（subhead）、更新徽章（检测到更新后于 Cell 内显示 `arrow.up.circle.fill` accent 色）、右侧启用开关；长按进入选择模式（保留），批量操作显示于底部工具栏。

### Requirement: 数据包/资源包/世界/光影管理界面视觉

四个界面 SHALL 统一为：搜索栏（胶囊形 L8，只搜本地）+ 毛玻璃卡片列表（图标容器 + 类型语义色：数据包 teal `doc.text.fill`、资源包蓝 `photo.stack.fill`、世界绿 `globe.asia.australia.fill`、光影紫 `paintbrush.fill`）+ 主/副文字（名称 + 版本/大小/日期）+ 三态视图。数据包/资源包列表项保留启用/禁用开关；世界保留删除与导入。

## REMOVED Requirements

### Requirement: 独立 Mod 更新窗口

**Reason**: 更新功能与 Mod 管理割裂（独立 push 的 ModUpdateViewController），且因三处 API bug 完全不可用；ZL2 模式（内置检测 → 确认弹窗 → 替换 → 刷新）体验更优。
**Migration**: `ModUpdateViewController.h/.m` 删除，检测/确认/下载/替换逻辑由 `ModsManagerViewController` + `ModUpdateService`（修复后）承担；`ModUpdateService` 保留并修复，`ModUpdateResult` 模型保留。
