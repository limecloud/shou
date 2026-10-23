Shou v0.12.0 improves macOS cleanup and introduces exact-version native packages behind the single `@limecloud/shou` npm entry.

- Review checked files and directories in Space Analysis and Large Files, then confirm the frozen selection with the primary delete action. The action bar shows selection count and estimated size.
- Permanent removal reports progress and reuses verified directory handles. Replaced roots, new entries and hard-link changes remain blocked. Ordinary permission/I/O failures retain partial results and allow independent selected targets to continue; unknown outcomes and journal failures stop further work.
- Share deterministic design tokens, localized text and project-location resources between independent native platform implementations. Architecture, workflows, sequence diagrams and developer instructions describe platform ownership and verification requirements.
- Install the CLI with `npm install --global @limecloud/shou@0.12.0` or `npx @limecloud/shou@0.12.0 --help`. The launcher selects the matching macOS ARM64 or x64 package at the exact same version, without a compiler or additional binary download.

Requires macOS 14 or later. The universal app and standalone CLI support Apple Silicon and Intel. Assets include DMG, ZIP, CLI archive, Sparkle-signed update feed and SHA256SUMS. The app is ad-hoc signed and is not Apple-notarized; updating may require granting Full Disk Access again. Permanent removal cannot be undone through Shou; moving files to Trash does not immediately free disk space.

Windows uses independent C#/.NET 10 and WinUI 3 source. Native runtime, UI, signing, installation and update acceptance remain pending. This release contains no Windows downloads or Windows npm payloads.

简体中文：Shou v0.12.0 改进 macOS 清理体验，并为统一的 `@limecloud/shou` npm 入口提供精确版本的原生平台包。

- 空间分析与大文件页通过勾选审阅文件和目录，操作栏显示数量与估算容量，主删除按钮确认冻结的当前选择。
- 永久删除显示进度并复用已核验目录句柄；根替换、新增内容和硬链接变化仍会阻断。普通权限／I/O 错误保留部分结果，继续处理独立目标；未知结果或日志失败停止后续操作。
- 两端独立原生实现共享确定性设计值、文案和项目目录资源；架构、流程、时序图与开发指南明确模块归属和验收要求。
- 使用 `npm install --global @limecloud/shou@0.12.0` 或 `npx @limecloud/shou@0.12.0 --help` 安装 CLI；启动器自动选择相同版本的 macOS ARM64／x64 平台包，无需编译或额外下载二进制。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、Sparkle 签名更新订阅与 SHA256SUMS。应用使用 ad-hoc 签名，未经 Apple 公证，升级后可能需要重新授予完全磁盘访问权限。永久删除无法通过 Shou 撤销，移入废纸篓不立即释放空间。

Windows 使用独立 C#/.NET 10 与 WinUI 3 实现，原生运行、界面、签名、安装及更新验收待完成。本次不提供 Windows 下载或 Windows npm 产物。
