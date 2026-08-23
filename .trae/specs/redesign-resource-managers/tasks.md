# Tasks

- [x] Task 1: 公共资源卡片 Cell 基类（ResourceCardTableViewCell）
  - [x] 1.1 由现有 ModTableViewCell 升级出 ResourceCardTableViewCell 基类：三层卡片背景（半透明基底 + BackgroundManager 毛玻璃 + 0.5pt 边框/轻阴影）、12pt continuous 圆角、图标容器（40×40、10pt 圆角、类型语义色背景 + SF Symbol）、title3 名称 + subhead 副标题、右侧 accessory 区（开关 / chevron / 更新徽章插槽）
  - [x] 1.2 子类化：ModTableViewCell 改继承基类（保留加载器品牌色图标与开关）；DataPack/ResourcePack/World/Shader 卡片 Cell 均继承基类（随 Task 4-8 各界面接入时完成）
  - [x] 1.3 CMakeLists.txt 注册新文件

- [x] Task 2: 资源列表基类与三态视图（ResourceListViewController 模板）
  - [x] 2.1 抽取公共模板：搜索栏（胶囊形 L8 样式）、UITableView（卡片间距 4pt、无分隔线）、空状态视图（类型语义色 SF Symbol + 文案 + 可选引导按钮）、加载态、批量选择模式底部工具栏（全选/取消 + 批量操作按钮）
  - [x] 2.2 空/加载/错误三态切换方法与连锁进场动画（首屏 ≤10 项，每项延迟 50ms）
  - [x] 2.3 "去下载"引导按钮：跳转统一下载界面对应资源类型（Mod/数据包/资源包/光影）

- [x] Task 3: 修复 Mod 更新检测三处 bug
  - [x] 3.1 ModrinthAPI.projectForFileHash：改为 `GET /version_file/{sha1}?algorithm=sha1` 路径参数（修复永远 404）
  - [x] 3.2 新增 MurmurHash2（CF 指纹算法）本地实现（utils 或独立工具类）；CurseForgeAPI.projectForFileHash 保留接收指纹数字
  - [x] 3.3 ModUpdateService：CurseForge 反查改传本地计算的 MurmurHash2 指纹（不再传 filePath）
  - [x] 3.4 CurseForgeAPI 指纹响应解析：项目 ID 取 `exactMatches[0].file.modId`（修复现在取错字段）
  - [x] 3.5 沙箱验证：用真实 mod jar 计算双 hash，curl 验证两个反查 API 均能命中（可下 1 个 Modrinth mod 实测）

- [x] Task 4: Mod 管理界面重构 + 更新功能内置
  - [x] 4.1 UI 重构：接入基类；新增筛选 chips（全部/已启用/已禁用）与排序（名称/修改时间）行；批量选择整合到基类工具栏（批量启用/禁用/删除）
  - [x] 4.2 更新流程内置（参考 ZL2 ModsUpdateOperation/ModsConfirmOperation）：顶栏"检查更新"按钮 → 后台并发检测（修复后的 ModUpdateService，带内联 Loading）→ 确认弹窗（UIAlertController/自定义列表弹窗：名称、当前版本 → 新版本、来源彩色 pill、复选框默认全选）→ PLDownloadClient 并发下载替换旧文件 → 刷新列表 + 结果提示（成功 N / 跳过 N 无法识别 / 失败 N）
  - [x] 4.3 Cell 更新徽章：检测后可更新的 Mod 在 Cell 显示 `arrow.up.circle.fill` accent 徽章，更新完成后清除
  - [x] 4.4 删除 ModUpdateViewController.h/.m，移除 CMakeLists 注册与所有引用（入口改为内置流程）

- [x] Task 5: 数据包管理界面重构
  - [x] 5.1 移除 UISegmentedControl 本地/在线切换与在线搜索逻辑（参照 ShadersManagerViewController 移除模式）
  - [x] 5.2 接入基类 + ResourceCardTableViewCell（teal `doc.text.fill` 图标容器）；启用/禁用开关保留；空状态含"去下载"按钮

- [x] Task 6: 资源包管理界面重构（同 Task 5 模式，蓝 `photo.stack.fill`）

- [x] Task 7: 世界管理界面重构
  - [x] 7.1 移除在线搜索；绿 `globe.asia.australia.fill` 图标容器；保留导入/删除；空状态含"去下载"按钮

- [x] Task 8: 光影管理界面对齐规范
  - [x] 8.1 接入基类 + 卡片 Cell（紫 `paintbrush.fill`）；核对既有实现与规范差异（间距/字体/三态）

- [x] Task 9: 本地化与全局自检
  - [x] 9.1 新增/变更文案补全 zh-Hans / zh-Hant / en Localizable.strings
  - [x] 9.2 对照 Air-Design 第 14 章自检清单逐项核对六界面（颜色/字体/圆角/卡片/图标/交互/状态视图）
  - [x] 9.3 编译验证（CMake 目标无错误）+ 代码走查（无残留 ModUpdateViewController 引用、无硬编码白色文字）

# Task Dependencies
- Task 2、Task 5-8 依赖 Task 1（卡片基类）
- Task 4 依赖 Task 2（基类模板）与 Task 3（更新检测修复）
- Task 9 依赖全部任务完成
- Task 3 与 Task 1/2 可并行
