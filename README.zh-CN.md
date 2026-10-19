<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>给 Mac，多留一点空间。</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

原生 macOS 清理工具，把应用缓存、开发项目和不断变大的文件夹整理清楚。看清空间去向，确认清理范围，把适合自己的清理方式留到下次。

## 下载与安装

下载 Shou v0.3.0，支持 **macOS 14 及以上**。通用版本适用于 Apple Silicon 和 Intel Mac。打开磁盘映像，将 **Shou.app** 拖入 **Applications（应用程序）**。界面支持英文和简体中文。

[**Shou v0.3.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.3.0/Shou-0.3.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.3.0/Shou-0.3.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.3.0/shou-0.3.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

此版本使用 ad-hoc 签名，尚未经过 Apple 公证。如 macOS 阻止首次打开，请先确认下载来源，再查看**系统设置 → 隐私与安全性 → 仍要打开**。

## Shou 能做什么

| | |
| --- | --- |
| **应用卸载** | 审阅应用与明确关联的文件，再确认卸载。个人数据需单独同意，移入废纸篓的组件可恢复。 |
| **启动项** | 查看启动项定义；对当前用户 LaunchAgents 在二次确认后启用或停用，其余来源在 macOS 登录项设置中管理。 |
| **排除规则** | 在全局或单个项目中保护目录，个人规则修改后保存为禁用的新版本。 |
| **应用缓存清理** | 集中查看浏览器、聊天工具、编辑器等应用的缓存，覆盖 Chrome、Edge、Firefox、Codex、Claude、QQ、微信等。 |
| **开发工具与项目清理** | 查找 npm、Cargo、Xcode、Python、Go 缓存，以及 Rust target、Node.js 依赖、Swift 构建产物。 |
| **空间分析** | 通过矩形树图和目录列表逐层查看大小，找到空间占用来源。 |
| **个人规则** | 为自己的可重建目录编写规则，先预览命中范围，再保存复用。 |
| **历史与恢复** | 查看清理结果，恢复选中项目，或另行确认永久移除本次清理项。 |
| **在线升级** | 在设置页或 Shou 菜单中检查更新，安装前验证更新包签名。 |

## 三步整理空间

1. **扫描。** 选择常用软件清理，或添加开发工作区。扫描本身不删除文件。
2. **审阅。** 查看具体路径、大小、风险和重新生成的条件，只选择自己确认的项目。
3. **确认。** 将选中项移入废纸篓；需要时从历史记录恢复。

移入废纸篓不会立即释放磁盘空间。永久移除需要单独确认，且无法撤销。保护内容和排除规则会阻止清理；正在运行的应用或构建任务可能阻止其缓存被清理。

## 文件由你决定

规则在本地运行，不执行 Shell 命令。无需账号、模型连接或云端扫描；规则和清理记录保存在本机。

## 终端使用

应用内附独立 CLI，可管理规则、扫描、审阅计划和查询历史。清理与恢复始终需要交互确认。

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## 文档与参与

源码构建、测试、规则示例和 CLI 用法见技术文档。欢迎通过 Issues 反馈问题和建议。

[Documentation](docs/zh-CN/README.md) · [Development](docs/zh-CN/engineering/development.md) · [Rules](docs/zh-CN/rules/rule-specification.md) · [CLI](docs/zh-CN/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## 鸣谢

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## 许可证

[Apache License 2.0](LICENSE).
