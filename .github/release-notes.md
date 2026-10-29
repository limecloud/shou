Shou v0.21.0 improves system authorization and lets independent cleanup items finish when another item fails.

- Reuse one administrator authorization within the current session across supported scans, application removal, file cleanup, recovery, startup control and developer configuration operations. Credentials stay in the system authentication window.
- Fix macOS authorization failing after password verification. The application now reads the elevated process identity through an interface available to ordinary users, while retaining process, executable and session checks.
- Validate and execute each selected item in turn. Known item failures are reported separately; unknown outcomes, cancellation and record failures still stop further changes. The reviewed selection remains the authorization scope.
- Keep applications with incomplete metadata available for app-only review. Simplify permission guidance, cleanup results and settings, with concise shared English/Chinese text.
- Align Windows authorization and independent-item execution in the platform layer. Windows downloads remain portable previews with public cleanup, uninstall, startup and privacy mutation gates closed.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. The app uses an ad-hoc signature and is not Apple-notarized; Full Disk Access may need to be granted again after replacement. Windows x64/ARM64 downloads are unsigned, self-contained previews for Windows 11. Native fixture checks, interactive preview journeys, UAC, ARM64 interaction, signing, installation and updates are separate acceptance scopes. npm registry publication is verified separately from GitHub assets.

简体中文：Shou v0.21.0 改进系统授权，支持清理时逐项执行并报告结果。

- 支持在当前会话中复用一次管理员授权，用于已接入的扫描、应用卸载、文件清理、恢复、启动控制及开发工具配置。密码只在系统认证窗口输入。
- 修复 macOS 输入密码后仍无法完成授权的问题。改用普通用户可读取的系统接口核实管理员进程，继续校验进程身份、可执行路径及会话。
- 按所选项目依次核验和执行，单项已知失败单独报告；结果不确定、用户取消或记录失败时停止后续操作。授权范围仍绑定本次审阅的确切选择。
- 缺少完整元数据的应用仍可单独审阅应用包。精简权限引导、清理结果和设置，同步中英文文案。
- Windows 在平台层对齐统一授权与逐项执行。便携预览的公开清理、卸载、启动项及隐私变更门禁保持关闭。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和。应用为 ad-hoc 签名，未经 Apple 公证，替换后可能需要重新授予完全磁盘访问权限。Windows 提供 Windows 11 未签名 x64／ARM64 自包含便携预览。原生夹具、预览版界面旅程、UAC、ARM64 交互、签名、安装与更新分别验收；npm registry 与 GitHub 附件分别验证。
