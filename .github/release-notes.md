Shou v0.18.0 adds dedicated developer-tool and AI workspaces, MySQL administration, reviewed package upgrades and clearer desktop updates.

- Browse the shared 79-tool catalog, discover existing installations and inspect versions, installation sources and instances. Supported macOS adapters provide reviewed installation, instance lifecycle, configuration, bounded logs and generated-instance management. Catalog inclusion does not imply every tool or source is supported.
- Manage supported MySQL instances with dedicated schema, account, grant, export, configuration, error-log, slow-log and independent-instance tasks. Instance re-registration preserves data and binds the next start to the reviewed configuration; other database engines retain their own capability limits.
- Keep AI software separate from developer runtimes and Shou's optional cleanup investigation. Supported AI clients expose read-only configuration and extension metadata; full provider, MCP and Skills management remains pending.
- Review Homebrew/mise package upgrades on macOS and official WinGet upgrades on Windows. Frozen selections require current, single-use confirmation and record verified, failed, unknown and not-started outcomes. Real Windows installer/elevation/restart and ARM64 upgrade acceptance remain pending.
- macOS Settings now shows update results, the last check and synchronized automatic-update options. Sparkle displays the icon, versions and bilingual offline release notes. Windows offers an on-demand official-release dialog and architecture-matched ZIP download for manual replacement.
- Refine the native workspace with shared Radix semantic colors, readable typography, thin borders, compact wording and consistent controls across existing pages.

macOS supports 14+, Apple Silicon and Intel, with universal DMG/ZIP, standalone CLI, Sparkle-signed updates and checksums. The app uses an ad-hoc signature and is not Apple-notarized. Windows downloads remain unsigned, self-contained x64/ARM64 portable previews for Windows 11; public cleanup, uninstall and startup mutation gates stay closed. Windows developer services/installers and MySQL administration retain their documented implementation and acceptance gaps. Full accessibility, ARM64 tray interaction, signing, installation and automatic updating remain pending. GitHub publication stages macOS npm tarballs; npm registry publication is separate.

简体中文：Shou v0.18.0 新增独立开发者工具与 AI 工作台、MySQL 管理、受控软件包升级，并完善软件自身更新。

- 浏览共享的 79 项工具目录，发现已有安装，查看版本、来源和实例。macOS 已接入的适配支持审阅后的安装、实例启停、配置、有界日志和独立实例管理；目录收录不表示全部软件或来源均已支持。
- MySQL 提供数据库、账号、授权、导出、配置、错误日志、慢日志及独立实例任务。实例重新登记保留数据，将下次启动绑定到已审阅配置；其他数据库引擎按各自能力处理。
- AI 软件与开发运行时、Shou 可选的清理调查分别组织。已接入的 AI 客户端提供只读配置与扩展元数据；完整供应商、MCP 和 Skills 管理仍待完成。
- macOS 支持审阅 Homebrew／mise 软件包升级，Windows 接入官方 WinGet 升级。冻结选择经当前单次确认后执行，分别记录已核实、失败、未知和尚未开始的结果。Windows 真实安装器、提权、重启和 ARM64 升级验收仍待完成。
- macOS 设置显示更新结果、上次检查时间，并同步自动更新选项；Sparkle 展示图标、版本及离线双语说明。Windows 按需检查官方版本，下载匹配架构的 ZIP 后手动替换。
- 统一现有页面的 Radix 语义颜色、可读字号、细边线、简洁文案及原生控件样式。

macOS 支持 14+、Apple Silicon 与 Intel，提供通用 DMG／ZIP、独立 CLI、Sparkle 签名更新及校验和；应用为 ad-hoc 签名，未经 Apple 公证。Windows 继续提供 Windows 11 未签名 x64／ARM64 自包含便携预览，公开清理、卸载及启动项变更门禁保持关闭。Windows 开发服务、安装器与 MySQL 管理保留文档所列实现和验收缺口；完整辅助功能、ARM64 托盘、签名、安装及自动更新仍待完成。GitHub 流水线准备 macOS npm 包，registry 发布单独管理。
