Shou v0.11.0 for macOS adds optional built-in AI investigation, application-grouped startup management and expanded cleanup rules.

- Built-in AI investigation is off by default. Configure compatible Responses, Chat Completions or Anthropic Messages connections independently from structured decisions. Local answers and Jev decisions run before disclosed main-model escalation. The native inspector retains scope, questions, cancellation, findings and per-service request/token usage.
- Start an investigation from Smart Cleanup, Space Analysis, Large Files or Rules. Tools read bounded saved-index metadata; they cannot run Shell commands or delete files. Suggestions import as independent disabled rules and reuse preview, explicit enablement, fresh scans and cleanup confirmation. Interrupted investigations retain findings and pending questions; connection removal is recoverable.
- Group macOS startup registrations by verified application identity, filter enabled/disabled/leftover states and inspect registrations inline. Eligible agents, third-party system daemons and native login items have confirmed controls; system daemons require macOS administrator authorization. Unsupported or uncertain registrations remain explicit.
- Expand developer cleanup to Gradle, Flutter/Dart, CMake, Maven, Node.js outputs, Python analysis caches, pnpm and browser-automation runtimes. Add an inspectable built-in rule catalog and targeted rule scans. Project markers, source/credential protection, activity checks and high-risk selection still apply.
- Improve application Trash handling and cross-volume selection. Add reviewed external-agent Skill setup and preserve separate confirmation for cleanup and configuration changes.

Ordinary scans and cleanup remain local and require no model connection. Starting AI investigation sends only the disclosed bounded metadata and user answers to the selected services; file contents are not exposed by these tools. Credentials use macOS Keychain or an explicitly selected authentication source. AI output and confidence never authorize cleanup.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Assets include DMG, ZIP, CLI archive, signed update feed and SHA256SUMS. Windows compilation and release packages are paused for reconstruction; v0.11.0 publishes macOS only.

Permanent removal and owner-tool cleanup cannot be undone through Shou. Moving items to Trash does not immediately free disk space. The macOS app is ad-hoc signed and not Apple-notarized; updating may require granting Full Disk Access again. Existing macOS installations can use Check for Updates with signed archive/feed verification.

AI evidence includes synthetic protocol/routing/cancellation checks and selected macOS 15.8.1 Apple Silicon fixture/live-provider observations. It does not establish decision accuracy, broad provider compatibility, macOS 14 hardware, complete accessibility coverage or desktop recovery after restart. Startup mutation checks use isolated fixtures and injected executors; changes to real installed registrations remain a separate acceptance task.

The separately published npm package `@limecloud/shou@0.11.0` is an immutable macOS CLI build from commit `7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc`. It predates these release repairs; the repaired GitHub artifacts include the later changes. npm does not permit replacing an existing version.

简体中文：Shou v0.11.0 为 macOS 新增可选内置 AI 调查、按应用分组的启动项管理，并扩展清理规则。

- 内置 AI 默认关闭；兼容 Responses、Chat Completions、Anthropic Messages 的主模型与结构化决策可独立配置。本地处理与 Jev 决策优先，确需主模型时说明原因。原生检查器保留固定范围、追问、取消状态、已有发现与分服务请求／Token 用量。
- 从智能清理、空间分析、大文件或规则进入调查。工具仅查询有上限的已有索引元数据，不执行 Shell 或删除文件；建议逐条导入为禁用规则，继续复用预览、明确启用、重新扫描和清理确认。AI 中断时保留已有发现与待回答问题，连接配置支持可恢复删除。
- macOS 启动项按已验证的应用身份分组，支持启用／停用／残留筛选与行内详情。符合条件的代理、第三方系统守护项和原生登录项提供确认后的控制；系统守护项需要 macOS 管理员授权，不支持或不确定的注册项明确显示边界。
- 扩展 Gradle、Flutter/Dart、CMake、Maven、Node.js 产物、Python 分析缓存、pnpm 及浏览器自动化运行库，新增内置规则浏览和指定规则扫描；保留项目标记、源文件／凭据保护、活动检查和高风险选择要求。
- 改进应用移入废纸篓及跨卷选择，新增经审阅的外部 Agent Skill 配置；清理与配置变更继续分别确认。

常规扫描、清理无需模型连接且在本地执行；启动 AI 调查才会向所选服务发送已披露的有限元数据与用户回答，工具不读取文件内容。凭据通过 macOS 钥匙串或明确指定的认证来源读取；模型输出和置信度不构成删除授权。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅和 SHA256SUMS。Windows 编译与发行包暂停，准备重构；v0.11.0 仅发布 macOS 版本。永久移除及工具清理无法通过 Shou 撤销，移入废纸篓不立即释放空间。macOS 版本使用 ad-hoc 签名、未经 Apple 公证，更新后可能需要重新授予磁盘访问权限。

AI 证据包含模拟协议／路由／取消检查，以及 macOS 15.8.1 Apple Silicon 上指定服务和生成夹具的观察，不代表决策准确性、所有服务、macOS 14 硬件、完整无障碍或重启后桌面恢复验收。启动项变更自动化使用隔离夹具和注入执行器，真实已安装注册项的变更仍需独立验收。

独立发布的 npm 包 `@limecloud/shou@0.11.0` 固定来自提交 `7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc`，是本轮发布修复之前的 macOS CLI。修复后的 GitHub 产物包含后续更新；npm 不允许覆盖已存在版本。
