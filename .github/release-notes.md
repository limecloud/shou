Shou v0.19.0 fixes macOS application eligibility, simplifies shared developer-tool installation review and improves Windows scan compatibility.

- Fix application activity inspection when macOS reports a live process without its usual executable path. The fallback verifies kernel-cached process identity; unreadable or unverified live processes still block uninstall. Application pages show disk-access guidance, specific activity failures and accurate size estimates.
- Combine installed and available versions, sources and paths in one developer-tool installation list. Services sharing an installation open the same uninstall review, which lists all affected instances and requires them to be stopped and verified before confirmation.
- Keep tool context and log-review actions visible while scrolling, improve available-height log views and align catalog switches, loading states and compact-window layouts across native pages.
- Let Windows scan supported built-in per-user cache roots provisioned by SYSTEM or Administrators after exact known-folder, identity and ACL checks. These roots remain read-only and cannot enter cleanup plans; custom locations and mutation ownership requirements remain strict. Native x64 tests run in release CI; this increment has no new Windows 11 UI or ARM64 runtime acceptance.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. The app uses an ad-hoc signature and is not Apple-notarized. Windows downloads remain unsigned, self-contained x64/ARM64 portable previews for Windows 11; public cleanup, uninstall and startup mutation gates stay closed. Windows developer services/installers, MySQL administration and package upgrades retain their documented acceptance gaps. Full accessibility, ARM64 tray interaction, signing, installation and automatic updating remain pending. GitHub publication stages macOS npm tarballs; npm registry publication is separate.

简体中文：Shou v0.19.0 修复 macOS 应用卸载资格判断，简化开发工具共享安装审阅，并改善 Windows 扫描兼容性。

- 修复 macOS 活动进程常规路径查询失败导致应用批量不可卸载的问题。回退链路核验内核缓存中的进程身份，无法读取或核实的存活进程继续阻断卸载。应用页补充磁盘访问引导、具体活动失败原因和准确的容量展示。
- 将已安装版本、可用版本、来源和路径合并为一张工具安装列表。共用安装的服务进入同一份卸载审阅，列出全部受影响实例，全部停止并核验后才能确认。
- 工具上下文和日志审阅操作在滚动时保持可见，日志使用可用高度；同步优化目录开关、加载状态及小窗口布局。
- Windows 对 SYSTEM／Administrators 预配的受支持内置用户缓存根，在精确 Known Folder、身份及 ACL 核验后允许只读扫描。这些根不能进入清理计划，自定义位置及变更的所有者要求继续保持严格。发布 CI 执行原生 x64 测试；该增量尚无新的 Windows 11 界面或 ARM64 运行验收。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和；应用为 ad-hoc 签名，未经 Apple 公证。Windows 继续提供 Windows 11 未签名 x64／ARM64 自包含便携预览，公开清理、卸载及启动项变更门禁保持关闭。Windows 开发服务、安装器、MySQL 管理及软件包升级保留文档所列验收缺口；完整辅助功能、ARM64 托盘、签名、安装及自动更新仍待完成。GitHub 流水线准备 macOS npm 包，registry 发布单独管理。
