Shou v0.11.0 adds optional built-in AI investigation, application-grouped startup management, expanded cleanup rules and Windows cleanup refinements.

- Built-in AI investigation is off by default. Configure compatible Responses, Chat Completions or Anthropic Messages connections independently from structured decisions. Local answers and Jev decisions run before disclosed main-model escalation. The native inspector retains scope, questions, cancellation, findings and per-service request/token usage.
- Start an investigation from Smart Cleanup, Space Analysis, Large Files or Rules. Tools read bounded saved-index metadata; they cannot run Shell commands or delete files. Suggestions import as independent disabled rules and reuse existing preview, explicit enablement, fresh scan and cleanup confirmation.
- Group macOS startup registrations by verified application identity, filter enabled/disabled/leftover states, and inspect registrations inline. Eligible agents, third-party system daemons and native login items have confirmed controls; system daemons require macOS administrator authorization. Unsupported or uncertain registrations remain explicit.
- Expand developer cleanup to Gradle, Flutter/Dart, CMake, Maven, Node.js outputs, Python analysis caches, pnpm and browser-automation runtimes. Add an inspectable built-in rule catalog and targeted rule scans. Project markers, source/credential protection, activity checks and high-risk selection still apply.
- Improve application Trash handling and cross-volume selection, and carry reviewed large-file and cache cleanup through the Windows desktop bridge. Windows AppData access is limited to validated standard cache children; profile roots, credentials, source and environments remain protected. Add directory measurement, hashing and native artifact-evidence checks, plus a portable AI runtime, Windows Credential Manager storage and a WPF investigation workspace.
- Add Windows startup inventory and confirmation for eligible current-user scheduled tasks, read-only registered-application inventory, personal-rule authoring and revision, and exact history-item inspection and follow-up selection. Keep inventory separate from application uninstall capability. Create Windows space indexes with explicit private ownership, including under elevated build accounts.
- Preserve AI findings and pending questions on interruption, make connection removal recoverable, and support private local credential storage independently for model and decision services. macOS CI and universal packaging explicitly select Swift 6.2.3 for the bundled AI SDK.

Ordinary scans and cleanup remain local and require no model connection. Starting AI investigation sends only the disclosed bounded metadata and user answers to the selected services; file contents are not exposed by these tools. Credentials use macOS Keychain or an explicitly selected authentication source. AI output and confidence never authorize cleanup.

AI evidence includes synthetic protocol/routing/cancellation checks and selected macOS 15.8.1 Apple Silicon fixture/live-provider observations. It does not establish decision accuracy, broad provider compatibility, macOS 14 hardware, Windows AI, complete accessibility coverage or desktop recovery after restart. Startup state-changing checks use isolated fixtures and injected executors; real administrator-authorized changes to installed registrations remain a separate acceptance task. Full-disk analysis coverage and native Windows UI/clean-system acceptance remain bounded by the documented evidence.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Assets include DMG, ZIP, CLI archive, signed update feed and SHA256SUMS. The unsigned Windows 11 x64 portable ZIP bundles .NET/Swift runtimes: extract the complete ZIP and run Shou.exe. Windows Recycle Bin/restoration remain disabled by default; Windows native AI/UI acceptance, installation and upgrades remain separate checks; there is no installer or automatic update.

Permanent removal and owner-tool cleanup cannot be undone through Shou. Moving items to Trash does not immediately free disk space. The macOS app is ad-hoc signed and not Apple-notarized; updating may require granting Full Disk Access again. Existing macOS installations can use Check for Updates with signed archive/feed verification.

The separately published npm package `@limecloud/shou@0.11.0` is an immutable macOS CLI build from commit `7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc`. It predates these release repairs; the repaired GitHub artifacts include the later changes. npm does not permit replacing an existing version.

简体中文：v0.11.0 新增可选内置 AI 调查、按应用分组的启动项管理，扩展清理规则并改进 Windows 清理。

- 内置 AI 默认关闭；兼容 Responses、Chat Completions、Anthropic Messages 的主模型与结构化决策可独立配置。本地处理与 Jev 决策优先，确需主模型时说明原因。原生检查器保留固定范围、追问、取消状态、已有发现与分服务请求／Token 用量。
- 从智能清理、空间分析、大文件或规则进入调查。工具仅查询有上限的已有索引元数据，不执行 Shell 或删除文件；建议逐条导入为禁用规则，继续复用预览、明确启用、重新扫描和清理确认。
- macOS 启动项按已验证的应用身份分组，支持启用／停用／残留筛选与行内详情。符合条件的代理、第三方系统守护项和原生登录项提供确认后的控制；系统守护项需要 macOS 管理员授权，不支持或不确定的注册项明确显示边界。
- 扩展 Gradle、Flutter/Dart、CMake、Maven、Node.js 产物、Python 分析缓存、pnpm 及浏览器自动化运行库，新增内置规则浏览和指定规则扫描；保留项目标记、源文件／凭据保护、活动检查和高风险选择要求。
- 改进应用移入废纸篓及跨卷选择，Windows 桌面桥接同步大文件与缓存清理审阅，并补充目录计量、哈希及原生产物证据。AppData 仅允许经验证的标准缓存子目录，配置根目录、凭据、源文件和环境仍受保护；新增可移植 AI 运行时、Windows 凭据管理器存储和 WPF 调查界面。
- 补充 Windows 启动项盘点与符合条件的当前用户计划任务确认控制、已注册应用只读盘点、个人规则创建与修订，以及精确历史项检查和后续选择。应用盘点不代表已支持卸载。Windows 空间索引显式设置私有所有权，覆盖提升权限的构建账号场景。
- AI 中断时保留已有发现与待回答问题，连接配置支持可恢复删除，主模型与决策服务独立支持私有本地凭据。macOS CI 与通用包构建显式选择 Swift 6.2.3，以支持内置 AI SDK。

常规扫描、清理无需模型连接且在本地执行；启动 AI 调查才会向所选服务发送已披露的有限元数据与用户回答，工具不读取文件内容。凭据通过 macOS 钥匙串或明确指定的认证来源读取；模型输出和置信度不构成删除授权。

AI 证据包含模拟协议／路由／取消检查，以及 macOS 15.8.1 Apple Silicon 上指定服务和生成夹具的观察，不代表决策准确性、所有服务、macOS 14 硬件、Windows AI、完整无障碍或重启后桌面恢复验收。启动项变更自动化使用隔离夹具和注入执行器，真实管理员授权及修改已安装注册项仍需独立验收；整盘覆盖和 Windows 实机／全新系统交互保留文档中的边界。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅和 SHA256SUMS。Windows 11 x64 为未签名便携 ZIP，内含 .NET／Swift 运行库，完整解压后运行 Shou.exe；回收站／恢复默认关闭，Windows 原生 AI／界面、安装升级仍需独立验收，暂无安装器或自动更新。永久移除及工具清理无法通过 Shou 撤销，移入废纸篓不立即释放空间。macOS 版本使用 ad-hoc 签名、未经 Apple 公证，更新后可能需要重新授予磁盘访问权限。

独立发布的 npm 包 `@limecloud/shou@0.11.0` 固定来自提交 `7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc`，是本轮发布修复之前的 macOS CLI。修复后的 GitHub 产物包含后续更新；npm 不允许覆盖已存在版本。
