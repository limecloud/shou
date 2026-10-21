Shou v0.9.0 adds concurrent Smart Cleanup, reviewed tool-cache and application-leftover cleanup, and bounded local record maintenance. It also improves large cleanup journals, hard-link removal and scan scheduling.

- Scan up to four independent cleanup locations concurrently, with stable result order, cumulative progress, cancellation and explicit partial results. Storage readers and ready finalizers share at most eight scheduler slots.
- Maintain derived scan records with a default seven-day/256 MiB policy while protecting active plans, history dependencies and recovery evidence. Add paged history summaries and reviewed record collection in desktop settings and the CLI.
- Offer identity-bound graceful application closing and scoped retry. Recheck owners and helpers before continuing, while retaining successful results and unrelated selection.
- Preview and explicitly confirm fixed local Docker build-cache, Homebrew, Conda and unused Rust-toolchain cleanup. Commands have bounded time and output; Rust current/default/override toolchains are protected, and project pins still require review. Tool cleanup uses its own plans and receipts.
- Review orphan application leftovers using exact bundle associations and fresh absence checks. Unknown or incomplete ownership blocks removal; personal data needs separate consent. Reuse shared deletion journals and Trash recovery.
- Extend the agent rule workflow from uncovered-directory evidence through measured incremental benefit, disabled import, explicit enablement and persisted desktop reuse. Unknown directories do not become cleanup targets automatically.
- Add eight fixed Windows cache scopes, project discovery, select all and one-confirmation cleanup across roots, with scoped retry and shared receipts.
- Store large cleanup manifests as verified immutable receipt dependencies, reducing repeated full-manifest serialization. Preserve legacy inline receipts and recovery checks. Handle hard links across selected targets while continuing to reject unrelated metadata changes.

The source tree records generated-fixture performance comparisons and their limits. Results do not establish a speedup for every disk or complete disk coverage. Incomplete application registration, unsaved-document close dialogs and actual Windows desktop interaction retain separate acceptance limits. Personal owner-tool data was not used for destructive acceptance tests.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Download the DMG and drag Shou.app to Applications, or use the ZIP containing the same app. Verify downloads with SHA256SUMS. Existing installations can use Check for Updates; Sparkle verifies signed archives and feeds. Windows source and CI are included; this release does not provide a Windows installer.

Permanent removal and owner-tool cleanup cannot be undone through Shou. Moving items to Trash does not immediately free disk space. The app is ad-hoc signed and not Apple-notarized; updating may require granting Full Disk Access again.

简体中文：v0.9.0 新增最多四个位置并发的智能清理，保持结果顺序、累计进度、取消和部分结果；空间扫描的读取与就绪汇总任务共用最多八个调度槽，避免汇总线程无界增长。

新增默认七天／256 MiB 的派生记录维护策略，保护活动计划、历史依赖与恢复证据，提供分页历史摘要以及设置／CLI 维护入口。支持核验应用身份后温和退出、重新检查进程并仅重试相关范围；工具清理可预览并确认本地 Docker 构建缓存、Homebrew、Conda 缓存及闲置 Rust 工具链，使用固定命令、时间／输出上限和独立回执，项目工具链固定配置仍需人工审查。

应用残留通过精确 bundle 关联及新鲜缺席证据单独审查，未知或不完整归属会阻止清理，个人数据需要额外同意。Agent 规则流程覆盖未覆盖目录发现、增量收益预览、默认禁用导入、明确启用及桌面复用。Windows 同步八类固定缓存、项目发现、全选、跨根单次确认和限定范围重试。

大清理清单改为经完整性校验的不可变回执依赖，减少重复序列化，同时保留旧记录与恢复兼容；修复跨目标硬链接永久删除，并继续拒绝外部元数据变化。性能数据及条件见源码文档，不代表所有磁盘加速或完整磁盘覆盖；未保存文档退出交互、应用登记覆盖及 Windows 实机交互仍有独立验收边界，未对个人工具数据执行破坏性验收。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅和 SHA256SUMS；Windows 尚无安装包。永久移除及工具清理无法通过 Shou 撤销。此版本未经过 Apple 公证，更新后可能需要重新授予磁盘访问权限。
