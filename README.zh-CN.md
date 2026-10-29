<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>给 Mac，多留一点空间。</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

## macOS 首次打开

目前暂无 Apple 开发者证书，Mac 版本使用临时签名，尚未经过 Apple 公证。从本仓库的 [Releases](https://github.com/limecloud/shou/releases) 下载后，将 **Shou.app** 拖入**应用程序**。如果首次打开被 macOS 拦截，在“终端”执行：

```sh
xattr -dr com.apple.quarantine "/Applications/Shou.app"
open "/Applications/Shou.app"
```

`xattr` 只移除这个应用的下载隔离标记，不授予完全磁盘访问权限。扫描授权在应用首次使用引导中设置，详见[安装与权限](docs/zh-CN/product/installation-and-access.md)。

让现有 AI Agent 为你定制清理规则的原生 macOS 清理工具。告诉 Codex、Claude Code 或 WorkBuddy 哪些目录占空间、哪些内容要保留，由它追问、分析并编写可复用规则；Shou 在本地完成扫描、校验、预览与清理。

Shou v0.13.0 统一原生遍历、大清单分页和页面内清理进度，减少准备与执行的重复工作。npm CLI 使用统一安装入口和精确版本的原生平台包。详见[发布说明](https://github.com/limecloud/shou/releases/tag/v0.13.0)和[npm 分发](docs/zh-CN/engineering/npm-distribution.md)。

## 下载与安装

下载 Shou v0.13.0，支持 **macOS 14 及以上**。通用版本适用于 Apple Silicon 和 Intel Mac。打开磁盘映像，将 **Shou.app** 拖入 **Applications（应用程序）**。界面支持英文和简体中文。

[**Shou v0.13.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.13.0/Shou-0.13.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.13.0/Shou-0.13.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.13.0/shou-0.13.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

[Windows x64 · Preview](https://github.com/limecloud/shou/releases/download/v0.13.0/Shou-0.13.0-windows-x64.zip) · [Windows ARM64 · Preview](https://github.com/limecloud/shou/releases/download/v0.13.0/Shou-0.13.0-windows-arm64.zip)

v0.13.0 同时提供独立 WinUI 3/.NET 10 的 Windows 自包含便携预览包；解压后运行 Shou.Windows.App.exe。Windows 清理、卸载和启动项变更门禁仍关闭，ARM64 运行、签名、安装和更新另行验收，见[Windows 方案](docs/zh-CN/engineering/windows-native-plan.md)。

首次打开被拦截时，按文首的 `xattr` 步骤处理；也可在**系统设置 → 隐私与安全性 → 仍要打开**中放行本次应用。

首次启动会引导完成磁盘访问设置，并可直接安装 CLI 命令。也可以先使用可访问范围，之后随时在**设置 → 设置引导**继续配置。参见[安装与权限说明](docs/zh-CN/product/installation-and-access.md)。

## Shou 能做什么

| | |
| --- | --- |
| **AI Agent 定制清理** | 使用随包 Skill 分析个人缓存和构建产物，回答必要问题即可预览规则，无需手写 JSON。 |
| **应用卸载** | 按大小与状态比较应用，行内展开组件，多选后统一确认。个人数据需单独同意，废纸篓项可恢复。 |
| **启动项** | 按应用分组查看注册项，筛选状态和残留；确认后管理符合条件的代理、第三方系统守护项和原生登录项。 |
| **排除规则** | 在全局或单个项目中保护目录，个人规则修改后保存为禁用的新版本。 |
| **应用缓存清理** | 集中查看浏览器、聊天工具、编辑器等应用的缓存，覆盖 Chrome、Edge、Firefox、Codex、Claude、QQ、微信等。 |
| **开发工具与项目清理** | 查找 npm、Cargo、Xcode、Python、Go 缓存，以及 Rust target、Node.js 依赖、Swift 构建产物。 |
| **大文件清理** | 按容量与文件类型筛选已有扫描，快速查看、跨分页全选，并清理具体选择。 |
| **空间分析** | 分析磁盘或目录，通过列表与树图勾选文件和文件夹，直接删除并支持废纸篓恢复。 |
| **个人规则** | 让现有 Agent 为可重建目录制定规则，预览命中范围后复用；“高级”中保留手工导入与编辑入口。 |
| **历史与恢复** | 查看清理结果，恢复选中项目，或另行确认永久移除本次清理项。 |
| **在线升级** | 在设置页或 Shou 菜单中检查更新，安装前验证更新包签名。 |

## 三步整理空间

1. **扫描。** 应用缓存、自动发现的开发目录和记住的位置，一起扫描。
2. **审阅。** 查看推荐路径与重建代价，内置及已启用的个人规则自动参与。
3. **确认。** 一次确认后清理并释放空间；默认永久删除，移入废纸篓为可选方式。

无需先登记工作区或逐个选择项目。Agent 定制的规则确认启用一次，后续清理自动包含。发现方式和范围见[统一日常清理](docs/zh-CN/product/unified-cleanup.md)。永久删除无法撤销；移入废纸篓不立即释放空间。保护内容、排除项、运行中的应用和构建可能阻止相关目标清理。

## 文件由你决定

规则在本地运行，不执行 Shell 命令。无需账号、模型连接或云端扫描；规则和清理记录保存在本机。

## 让现有 Agent 定制清理

在**规则 → 通过 AI 定制**中选择 Codex 或 Claude Code 安装 Skill；使用 WorkBuddy 时导出 ZIP 并上传。复制请求，交给现有 Agent。它读取随包的 [Shou Skill](skills/shou-rule-authoring/SKILL.md)，分析指定目录，询问重建方式与保留项，自动校验、导入并预览禁用草稿。你决定何时启用和清理。

可选内置 AI 调查默认关闭。在「设置 → AI 调查」启用并配置连接后，可选择目录或已有扫描进行智能分析；原生检查器支持追问、服务用量和逐条禁用规则预览。启动调查会将限定范围的索引元数据和你的回答发送给所选服务；常规扫描与清理仍在本地完成。服务支持与验收边界见[使用与实现记录](docs/zh-CN/engineering/embedded-ai-implementation.md)。

也可在终端为所用客户端安装，或直接读取指令：

```sh
"/Applications/Shou.app/Contents/Helpers/shou" skills install --agent codex --json
"/Applications/Shou.app/Contents/Helpers/shou" skills read --json
```

Codex 中使用 `$shou-rule-authoring`，Claude Code 本机会话中使用 `/shou-rule-authoring`。各客户端操作见 [Skill 安装与分发](docs/zh-CN/ai/skill-distribution.md)。`Documents`、`Library`、`.codex`、`.colima`、`.nvm`、`.rustup`、`.local`、`go`、`.cargo` 都可能包含不同用途的数据，需要逐层分析，不能整目录套用通用删除规则。详见 [Agent 操作指南](docs/zh-CN/ai/coding-agent-integration.md)。

## 终端使用

应用内附独立 CLI，可管理规则、扫描、审阅计划和查询历史。清理与恢复始终需要交互确认。

安装应用后，在源码仓库中运行 `python3 "scripts/install-cli.py"`，即可创建终端入口 `~/.local/bin/shou`，随应用同步更新，不编辑 Shell 设置。详见 [CLI 安装说明](docs/zh-CN/engineering/development.md#本地-cli-安装入口)。

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## 文档与参与

源码构建、测试、规则示例和 CLI 用法见技术文档。欢迎通过 Issues 反馈问题和建议。

[Documentation](docs/zh-CN/README.md) · [Development](docs/zh-CN/engineering/development.md) · [Rules](docs/zh-CN/rules/rule-specification.md) · [CLI](docs/zh-CN/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

隐私清理提供独立的来源／时间范围流程，支持已适配的浏览历史与 Cookie 结构，单独确认退出登录影响并保存汇总回执。详见[支持范围](docs/zh-CN/engineering/privacy-cleaning.md)。

## 鸣谢

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

[Lark CLI](https://github.com/larksuite/cli) 与 [Vercel Skills](https://github.com/vercel-labs/skills) 为 Skill 分发与发现方式提供启发。

## 许可证

[Apache License 2.0](LICENSE).

空间分析支持本地卷与目录、列表和树图联动、文件及文件夹多选、废纸篓与恢复，以及明确确认后的永久删除。详见[空间分析](docs/zh-CN/product/space-analysis.md)。
