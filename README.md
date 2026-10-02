<div align="center">
  <img src="Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png" alt="Air 图标" width="120" style="border-radius: 24px;">
</div>

<h1 align="center">Air</h1>
<p align="center"><sub>Amethyst iOS 重制版</sub></p>

<div align="center">
  <img alt="构建状态" src="https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions/workflows/development.yml/badge.svg?branch=main">
  <img alt="下载量" src="https://img.shields.io/github/downloads/herbrine8403/Amethyst-iOS-MyRemastered/total?label=Downloads&style=flat">
  <img alt="版本" src="https://img.shields.io/github/v/release/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <img alt="许可证" src="https://img.shields.io/github/license/herbrine8403/Amethyst-iOS-MyRemastered?style=flat">
  <a title="Crowdin" target="_blank" href="https://crowdin.com/project/amethyst-ios-remastered"><img alt="Crowdin" src="https://badges.crowdin.net/amethyst-ios-remastered/localized.svg">
</div>

---

一款为 iOS / iPadOS 打造的高质量 Minecraft: Java 版启动器，基于官方 Amethyst 项目深度重构。它带来了更精致的移动端体验：完善的模组管理、智能渲染器选择、以及深度的平台整合。

---

## 目录

- [核心特性](#核心特性)
- [快速开始](#快速开始)
  - [设备要求](#设备要求)
  - [侧载准备](#侧载准备)
  - [安装](#安装)
  - [开启 JIT](#开启-jit)
- [AI 助手与工具](#ai-助手与工具)
- [贡献者](#贡献者)
- [参与翻译](#参与翻译)
- [第三方组件](#第三方组件)
- [赞助](#赞助)

## 核心特性

- **现代化 UI 重制** —— 界面为当代审美深度打磨，视觉更精致耐看。
- **资源管理与下载** —— 浏览、启用、禁用、删除模组 / 光影包 / 资源包等资源，内置 Modrinth 与 CurseForge 下载支持。
- **整合包导入** —— 直接在启动器界面导入 ZIP 格式整合包。
- **智能下载源** —— 可在 Mojang 官方、BMCLAPI 镜像等源之间即时切换，获得最佳下载速度。
- **完整中文本地化** —— 界面全量汉化，原生级中文体验。
- **账户不受限** —— 支持本地账户、演示模式与第三方认证；无需微软账户也能下载并游玩。
- **多账户管理** —— 在微软 / 本地 / 第三方认证账户之间无缝切换。
- **自动选择渲染器** —— 设为「自动」时，自动挑选最优渲染后端（包括 MobileGlues、MoltenVK 等）。
- **自动选择 JVM** —— 根据游戏版本自动匹配正确的 Java 运行时（Java 8 / 17 / 21 / 25）。
- **支持 Minecraft 26.X** —— 对 Minecraft 26.x 提供实验性支持。
- **自定义鼠标指针** —— 可在设置中自定义虚拟鼠标的指针皮肤。
- **自定义新闻源** —— 可自行配置启动器首页的新闻订阅地址。
- **TouchController 支持** —— 通过 UDP 本地代理与 XCFramework 双通道与 TouchController 模组通信，在 iOS 上提供完整的触屏操控。
- **AI 助手（已内置）** —— 可直接用自然语言让 AI 代管启动器：排查崩溃与日志、安装游戏版本 / 加载器 / 模组 / 光影 / 资源包 / 数据包、管理实例与设置、查看下载进度、浏览图片截图……详见 [AI 助手与工具](#ai-助手与工具)。
- **自定义应用图标** —— （开发中）
- ……还有更多等你探索！

> [!NOTE]
> 本重制版暂无移植到 Android 的计划。Android 生态已有 [Zalith Launcher](https://github.com/ZalithLauncher/ZalithLauncher)、[Fold Craft Launcher](https://github.com/FCL-Team/FoldCraftLauncher)、ShardLauncher 等优秀启动器。Android 官方版本请前往 [Amethyst-Android](https://github.com/AngelAuraMC/Amethyst-Android)。

## 快速开始

完整文档请参考 [Amethyst 官方 Wiki](https://wiki.angelauramc.dev/wiki/getting_started/INSTALL.html#ios) 或 [Bilibili 教程](https://b23.tv/KyxZr12)。以下是精简版指南。

### 设备要求

| 档位 | iOS 版本 | 支持设备 |
|------|-------------|-------------------|
| **最低** | iOS 14.0+ | iPhone 6s 及以上、iPad 第 5 代及以上、iPad Air 2 及以上、iPad mini 4 及以上、所有 iPad Pro、iPod touch 第 7 代 |
| **推荐** | iOS 14.5+ | iPhone XS 及以上（不含 XR / SE 第 2 代）、iPad 第 10 代及以上、iPad Air 第 4 代及以上、iPad mini 第 6 代及以上、iPad Pro（不含 9.7 英寸） |

> [!CAUTION]
> iOS 14.0–14.4.2 存在已知的严重兼容问题，**强烈建议升级到 iOS 14.5 或更高版本。** iOS 17.x 与 18.x 虽已支持，但首次配置 JIT 需要借助电脑（参见 [官方 JIT 指南](https://wiki.angelauramc.dev/wiki/faq/ios/JIT.html#what-are-the-methods-to-enable-jit)）。iOS 26.x 可以安装，但尚未做专门适配，可能出现不可预期的行为。

### 侧载准备

请优先选择支持永久签名与自动开启 JIT 的工具：

1. **TrollStore** *（推荐）* —— 永久签名、自动 JIT、可提升内存上限。仅兼容部分 iOS 版本。[从官方仓库下载](https://github.com/opa334/TrollStore)
2. **AltStore / SideStore** *（备选）* —— 需要定期重新签名；初次配置需要电脑与 Wi-Fi。仅兼容**开发证书**（必须包含 `com.apple.security.get-task-allow` 权限才能开启 JIT），不支持分发证书签名服务。

> [!WARNING]
> 请只从官方或可信渠道下载侧载工具与 IPA 文件。因使用非官方软件导致的设备问题，作者不承担责任。越狱设备可以永久签名，但不建议把日常用机越狱。

### 安装

<details>
<summary><b>正式版（TrollStore）</b></summary>

1. 从 [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) 下载 `.tipa` 包。
2. 在系统分享菜单中用 TrollStore 打开该文件，即可完成安装。
</details>

<details>
<summary><b>正式版（AltStore / SideStore）</b></summary>

1. 从 [Releases](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases) 下载 `.ipa` 包。
2. 按侧载工具的标准流程导入 IPA 完成安装。
</details>

<details>
<summary><b>每夜构建（开发测试）</b></summary>

> [!CAUTION]
> 每夜构建可能包含崩溃、无法启动等严重问题，仅供开发与测试使用。

1. 打开 [GitHub Actions](https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/actions) 页面，下载最新的 IPA 产物。
2. 将 IPA 导入侧载工具（AltStore、SideStore 等）安装。
</details>

### 开启 JIT

JIT（即时编译）是流畅游玩的关键。请根据你的环境选择：

| 工具 | 需要外部设备 | 需要 Wi-Fi | 自动开启 | 说明 |
|------|:---:|:---:|:---:|-------|
| TrollStore | 否 | 否 | 是 | 首选；无需额外操作 |
| AltStore | 是 | 是 | 是 | 需要局域网内运行 AltServer |
| SideStore | 仅首次 | 仅首次 | 否 | 首次配置完成后即可脱离设备/网络 |
| StikDebug | 仅首次 | 仅首次 | 是 | 首次配置完成后即可脱离设备/网络 |
| Jitterbug | 是（不开 VPN） | 是 | 否 | 需要手动触发 |
| 越狱设备 | 否 | 否 | 是 | 系统级自动支持 |

## AI 助手与工具

Air 内置了 AI 助手（侧边栏入口），它不只是聊天——**可以真正动手操控启动器**。

用自然语言描述需求即可，例如「帮我装 1.20.1 + Fabric，再装个 Sodium」「游戏崩了，看看日志」「把内存调到 4G」。AI 会自动选择合适的工具执行，并在必要时先向你确认。

AI 能看到当前实例、日志、文件、设置与下载中心，所以它能自己排查问题、自己下载安装，而不只是给你文字建议。

### 工具分类

#### 实例与游戏

| 工具 | 权限 | 说明 |
|------|------|------|
| `list_instances` | 只读 | 列出已创建的游戏目录（实例），含版本、加载器、模组/资源包数量 |
| `list_game_versions` | 只读 | 获取 Minecraft 正式版列表（默认源 BMCLAPI，失败自动回退官方） |
| `create_instance` | 受控写入 | 新建游戏目录并切换为当前目录 |
| `install_game_version` | 受控写入 | 下载并安装指定原版 Minecraft（版本 JSON + 库 + 资源） |
| `install_loader` | 受控写入 | 安装模组加载器；Fabric / Quilt 全自动，Forge / NeoForge / OptiFine 需图形安装器 |

#### 资源搜索与安装（Modrinth）

| 工具 | 权限 | 说明 |
|------|------|------|
| `search_mods` | 外部网络 | 搜索模组 |
| `search_resourcepacks` | 外部网络 | 搜索资源包 |
| `search_shaders` | 外部网络 | 搜索光影包 |
| `search_datapacks` | 外部网络 | 搜索数据包 |
| `search_modpacks` | 外部网络 | 搜索整合包 |
| `search_worlds` | 外部网络 | 搜索世界存档 |
| `install_mod` | 受控写入 | 下载并安装模组到 `mods/`（自动匹配实例 MC 版本） |
| `install_resourcepack` | 受控写入 | 下载并安装资源包 |
| `install_shader` | 受控写入 | 下载并安装光影包 |
| `install_datapack` | 受控写入 | 下载并安装数据包 |

#### 日志与诊断

| 工具 | 权限 | 说明 |
|------|------|------|
| `read_latest_log` | 只读 | 读取实例最近一次启动日志（`logs/latest.log`） |
| `read_crash_report` | 只读 | 读取最新一份崩溃报告 |
| `read_logs` | 只读 | 一次并行读取多份日志（游戏日志 / 启动器日志 / 上次日志 / 崩溃报告） |
| `match_known_errors` | 只读 | 对照内置规则库识别已知错误类型，给出通俗解释与修复建议 |
| `check_downloads` | 只读 | 查询下载中心全部任务的实时状态（进度、速度、来源） |

#### 文件

| 工具 | 权限 | 说明 |
|------|------|------|
| `list_files` | 只读 | 列出指定目录内容 |
| `read_file` | 只读 | 读取文本文件 |
| `grep_files` | 只读 | 用正则搜索文件内容 |
| `write_file` | 受控写入 | 写文本文件（原子写入、自动建父目录） |
| `edit_file` | 受控写入 | 精确替换文本（仅当匹配唯一时生效） |
| `delete_file` | 危险写入 | 删除文件（仅限文本类，需确认） |
| `list_roots` | 只读 | 列出 AI 当前可访问的根目录（容器 + 已授权外部目录） |
| `view_image` | 只读 | **看图**：把图片直接送进对话（模型真能看到像素），并附尺寸与黑边摘要，可判断 UI 大小、四周黑边、内容是否铺满屏幕 |

#### 路径授权（容器外目录）

| 工具 | 权限 | 说明 |
|------|------|------|
| `folder_request_access` | 外部网络 | 弹窗申请授权一个 App 容器外的目录，使其可被读写 |
| `folder_list_authorized` | 只读 | 列出已授权的外部目录 |
| `folder_revoke_access` | 危险写入 | 撤销某个已授权目录 |

#### 设置

| 工具 | 权限 | 说明 |
|------|------|------|
| `list_settings` | 只读 | 列出所有支持的设置键与取值说明 |
| `get_setting` | 只读 | 读取指定设置键的当前值（全局值 + 实例生效值） |
| `set_setting` | 受控写入 | 修改全局设置或实例设置（如渲染器、内存、JVM 参数） |

#### 联网与 GitHub

| 工具 | 权限 | 说明 |
|------|------|------|
| `fetch_url` | 只读 | 对任意 http/https URL 发起 GET 请求，查看网页/API/文档（HTML 自动转纯文本） |
| `github_tree` | 只读 | 一次性列出 GitHub 仓库的完整源码文件树 |
| `github_read_files` | 只读 | 批量读取仓库内多个文件（一次最多 20 个） |
| `github_search_code` | 只读 | 在仓库内按关键词搜索代码 |
| `github_set_token` | 外部网络 | 保存 GitHub PAT（仅存本机，用于推送认证） |
| `github_push` | 外部网络 | 把文件内容以 commit 形式推送到指定仓库分支 |

#### 任务与交互

| 工具 | 权限 | 说明 |
|------|------|------|
| `ask` | 只读 | 向用户弹出选择向导收集决策（支持自定义输入与取消） |
| `todo_create` | 受控写入 | 新建待办事项（多步任务的执行清单） |
| `todo_list` | 只读 | 列出全部待办事项 |
| `todo_update` | 受控写入 | 更新待办：勾选完成 / 取消完成 / 改标题描述 |
| `todo_delete` | 受控写入 | 删除待办事项 |
| `sleep` | 只读 | 等待指定秒数（用于等后台下载推进） |

### 权限分级与安全模式

每个工具都带有权限级别，配合三种安全模式使用：

| 权限级别 | 含义 |
|----------|------|
| 只读 | 仅查看，无副作用，始终允许 |
| 受控写入 | 修改启动器/实例内的文件或设置 |
| 危险写入 | 删除文件等高风险操作，所有模式都要求确认 |
| 外部网络 | 发起网络请求或访问外部资源 |

| 安全模式 | 行为 |
|----------|------|
| 安全 | 仅执行只读操作 |
| 询问 | 涉及修改/网络的操作执行前先向你确认 |
| 完全（YOLO） | 执行前不询问（谨慎使用） |

### 支持的 AI 提供商

兼容 OpenAI 协议（`/chat/completions`）的服务均可使用：在 AI 侧边栏的「提供商配置」中填入 API 地址、密钥与模型名即可。支持流式输出与多模态图片（若模型支持视觉，`view_image` 返回的截图会以真图送入）。

> [!TIP]
> 把「安全模式」设为「询问」，可以在 AI 修改文件或发起网络请求前逐一确认，兼顾便利与安全。

## 贡献者

- [@yitenchen123](https://github.com/yitenchen123) —— 项目维护者
- [@EternityQwQ](https://github.com/EternityQwQ) —— 添加 Metal 通用模组支持，让启动器可用 Metal 渲染 Minecraft
- [@LanRhyme](https://github.com/LanRhyme) —— ShardLauncher 作者；iOS 26 兼容性与日志改进
- [@WeiErLiTeo](https://github.com/WeiErLiTeo) —— 模组下载整合、TouchController 优化、双指长按唤出键盘
- [@Li2548](https://github.com/Li2548) —— 上游同步

## 参与翻译

如果你想为本项目贡献翻译，请前往 [Crowdin](https://crowdin.com/project/amethyst-ios-remastered)。

## 第三方组件

| 组件 | 用途 | 许可证 | 来源 |
|-----------|---------|---------|--------|
| Caciocavallo | AWT 运行时框架 | GPL-2.0 | [GitHub](https://github.com/PojavLauncherTeam/caciocavallo) |
| jsr305 | 代码注解支持 | BSD-3 | [Google Code](https://code.google.com/p/jsr-305) |
| Boardwalk | 核心功能适配 | Apache-2.0 | [GitHub](https://github.com/zhuowei/Boardwalk) |
| GL4ES | OpenGL 到 GLES 转译 | MIT | [GitHub](https://github.com/ptitSeb/gl4es) |
| Mesa 3D | 3D 图形库 | MIT | [GitLab](https://gitlab.freedesktop.org/mesa/mesa) |
| MetalANGLE | Metal 到 OpenGL ES 转译 | BSD-2 | [GitHub](https://github.com/khanhduytran0/metalangle) |
| MoltenVK | Vulkan 到 Metal 转译 | Apache-2.0 | [GitHub](https://github.com/KhronosGroup/MoltenVK) |
| openal-soft | 跨平台 3D 音频 | LGPL-2.0 | [GitHub](https://github.com/kcat/openal-soft) |
| Azul Zulu JDK | Java 运行时（8/17/21/25） | GPL-2.0 | [官网](https://www.azul.com/downloads/?package=jdk) |
| LWJGL3 | Java 游戏开发库 | BSD-3 | [GitHub](https://github.com/PojavLauncherTeam/lwjgl3) |
| LWJGLX | LWJGL2 兼容层 | -- | [GitHub](https://github.com/PojavLauncherTeam/lwjglx) |
| DBNumberedSlider | UI 滑块控件 | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/DBNumberedSlider) |
| fishhook | 动态库重绑定 | BSD-3 | [GitHub](https://github.com/khanhduytran0/fishhook) |
| shaderc | Vulkan 着色器编译 | Apache-2.0 | [GitHub](https://github.com/khanhduytran0/shaderc) |
| NRFileManager | 文件管理工具 | MPL-2.0 | [GitHub](https://github.com/mozilla-mobile/firefox-ios) |
| AltKit | AltStore 集成 | -- | [GitHub](https://github.com/rileytestut/AltKit) |
| UnzipKit | ZIP 压缩包处理 | BSD-2 | [GitHub](https://github.com/abbeycode/UnzipKit) |
| DyldDeNeuralyzer | 库校验绕过 | -- | [GitHub](https://github.com/xpn/DyldDeNeuralyzer) |
| MobileGlues | 第三方渲染器 | LGPL-2.1 | [GitHub](https://github.com/MobileGL-Dev/MobileGlues) |
| LTW | OpenGL Core 到 ES 封装 | LGPL-3.0 | [GitHub](https://github.com/MojoLauncher/LTW) |
| authlib-injector | 第三方认证 | AGPL-3.0 | [GitHub](https://github.com/yushijinhun/authlib-injector) |

另感谢 [MCHeads](https://mc-heads.net) 提供 Minecraft 头像服务、[Modrinth](https://modrinth.com) 提供模组分发、[BMCLAPI](https://bmclapidoc.bangbang93.com) 提供 Minecraft 下载镜像。

## 赞助

如果你觉得本项目有价值，欢迎通过 [Ko-Fi](https://ko-fi.com/herbrine8403)、[爱发电](https://afdian.com/a/herbrine8403) 或 [微信赞赏码](donate.png) 支持开发。

## Star 历史

<a href="https://www.star-history.com/?type=date&repos=herbrine8403%2FAmethyst-iOS-MyRemastered">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&theme=dark&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=herbrine8403/Amethyst-iOS-MyRemastered&type=date&legend=top-left&sealed_token=q1uFKbS7fO8owrcjy_kYTkCnnl8PNgHAgBSrWop8Y3ULDdvwOwDfORslSVVXABSTwrsdu14OM3fshRaNbXouxMU5IenXF0T5r5L6rxKIN2n29T6Fv4UYyA" />
 </picture>
</a>
