Shou v0.13.0 improves cleanup responsiveness and adds Windows portable preview builds.

- Shared native directory readers and operation-local indexes reduce repeated work across analysis, rules, cleanup and history inspection. Final identity, activity, exact-scope and per-file mutation checks remain enforced.
- Large cleanup manifests use digest-verified pages; progress/result writes update compact metadata. On the generated 20,026-entry workload, three paired Release runs reduced median preparation by 63%, execution by 43% and total time from 17.06 s to 9.17 s. These measurements used a busy host and warm caches, rather than a full-disk benchmark.
- Cleanup stays in the main content area with flat animation, measured percentages, one shortened path and direct stopping. Storage analysis defaults to the startup disk; storage exhaustion has a distinct diagnostic and preserves earlier analyses.
- Windows downloads include self-contained WinUI 3/.NET 10 app and CLI ZIPs for x64 and ARM64. Extract the app archive and run `Shou.Windows.App.exe`; use the separate `shou-cli` archive for terminal access. Per-archive `BUILD.json` and `SHA256SUMS` identify the exact source and bytes.

macOS requires version 14 or later and supports Apple Silicon and Intel. Assets include universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. The app uses an ad-hoc signature and is not Apple-notarized. Permanent deletion cannot be undone through Shou.

Windows downloads are unsigned portable previews requiring Windows 11. Public cleanup, application uninstall and startup mutation gates remain closed. x64 CI checks native behavior and application startup; ARM64 is cross-built, with ARM64 runtime, full UI/accessibility, signing, installer and update acceptance pending. Windows npm packages remain private development artifacts; GitHub publication does not publish packages to npm.

简体中文：Shou v0.13.0 优化清理响应，并增加 Windows 便携预览版构建与发布。

- 分析、规则、清理与历史检查共用原生目录读取和操作内索引，减少重复工作；身份、活动、精确范围及逐项变更核验继续保留。
- 大清单分页并验证摘要，进度和结果仅更新精简元数据。20,026 条生成夹具的三轮 Release 配对中，准备耗时中位数降低 63%、执行降低 43%，全流程从 17.06 秒降至 9.17 秒。测试使用繁忙主机和暖缓存，不代表全盘性能。
- 清理在主内容区显示平面动画、实际百分比、单行缩略路径与直接停止；空间分析默认启动盘，存储耗尽独立诊断并保留之前分析。
- Windows 提供 x64／ARM64 的 WinUI 3/.NET 10 自包含应用与 CLI ZIP；应用解压后运行 `Shou.Windows.App.exe`，终端使用单独的 `shou-cli` 包。归档内 `BUILD.json` 与 `SHA256SUMS` 记录确切源码及文件摘要。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和；应用使用 ad-hoc 签名，未经 Apple 公证。永久删除无法通过 Shou 撤销。

Windows 下载为未签名便携预览，要求 Windows 11。清理、应用卸载和启动项变更的公开门禁仍关闭。x64 CI 核验原生行为和应用启动；ARM64 当前交叉构建，ARM64 运行、完整界面／辅助功能、签名、安装及更新另行验收。Windows npm 产物仍为私有开发模式，GitHub 发布不会自动发布 npm 包。
