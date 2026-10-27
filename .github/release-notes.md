Shou v0.20.0 simplifies everyday navigation, introduces a toolbox entry and gives software updates a dedicated page.

- Focus the main navigation on Cleanup, Applications, Space Analysis and Monitor. Toolbox, History and Settings remain directly accessible; cleanup rules and project cleanup move into Cleanup Options.
- Open AI Workbench or Developer Tools from Toolbox before starting their inventories. Tool navigation shows name, status and an arrow; service switches stay beside the exact instances in details.
- Separate installed applications, software updates and startup items. macOS software updates use Homebrew or mise; Windows uses the verified WinGet source in a persistent page with a fixed review/action area. Checks start only on request, and upgrade execution retains its exact-selection confirmation and navigation protection.
- Simplify the cleanup welcome page with application, space and privacy entries, concise copy and fewer decorative effects. Keep shared English/Chinese text and platform navigation aligned.
- Include the macOS privacy-discovery fix from [PR #1](https://github.com/limecloud/shou/pull/1): inaccessible browser roots no longer hide independently accessible sources. Coverage gaps remain visible, and cleanup still requires exact source validation and confirmation.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. The app uses an ad-hoc signature and is not Apple-notarized. Windows downloads remain unsigned, self-contained x64/ARM64 portable previews for Windows 11; public cleanup, uninstall and startup mutation gates stay closed. Windows developer services/installers, MySQL administration and package upgrades retain their documented acceptance gaps. The new Windows navigation and update page have not received a new Windows 11 Computer Use acceptance; full accessibility, ARM64 tray interaction, signing, installation and automatic updating remain pending. GitHub publication stages macOS npm tarballs; npm registry publication is separate.

简体中文：Shou v0.20.0 简化日常导航，新增工具箱入口，并将软件更新整理为独立页面。

- 主导航聚焦清理、应用、空间分析和监控；工具箱、操作记录和设置保持直接可达。清理规则与项目清理从“清理选项”进入。
- 从工具箱选择 AI 工作台或开发者工具后才启动对应盘点。工具导航统一展示名称、状态及箭头，服务启停位于右侧确切实例行。
- 应用管理、软件更新和启动项分为独立任务。macOS 软件更新使用 Homebrew／mise 来源；Windows 使用经过核实的 WinGet 来源，页内保留检查结果和固定审阅操作区。仅在用户主动请求后检查，升级继续绑定确切选择、单次确认和执行期间导航保护。
- 简化清理首页，提供应用、空间分析与隐私入口，精简文案和装饰动效，同步中英文文案与两端导航。
- 纳入 [PR #1](https://github.com/limecloud/shou/pull/1) 的 macOS 隐私发现修复：浏览器目录不可访问时保留其他可访问来源，明确展示覆盖缺口；清理仍须确切来源核验和确认。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和；应用为 ad-hoc 签名，未经 Apple 公证。Windows 继续提供 Windows 11 未签名 x64／ARM64 自包含便携预览，公开清理、卸载及启动项变更门禁保持关闭。Windows 开发服务、安装器、MySQL 管理及软件包升级保留文档所列验收缺口；本次新导航与软件更新页尚无新的 Windows 11 Computer Use 验收，完整辅助功能、ARM64 托盘、签名、安装及自动更新仍待完成。GitHub 流水线准备 macOS npm 包，registry 发布单独管理。
