Shou v0.7.0 improves storage scans and saved-result queries, adds reviewed history cleanup, and makes operation progress easier to follow.

- Stream macOS bulk metadata page by page, remove the wide-directory bulk cutoff, and batch catalog writes while retaining bounded directory readers, exact identity checks, cancellation and partial coverage.
- Index files allocated at least 1 MiB for faster saved large-file queries. Existing catalogs remain readable; rescan to create the new index. Cache directory sorting and filtering, and apply large selection changes as a batch.
- Reuse immutable bundled rule/schema validation while keeping workspace bindings isolated and external rule imports fully validated.
- Show measured percentages for stages with known work, detailed progress within permanent removal, and paths shortened only in the middle. Discovery retains live counts when its total is unknown. macOS and Windows share the progress contracts.
- Preview and explicitly confirm cleanup of local history records through the app or CLI. Unfinished and recoverable records are preserved by default. Including recoverable records discards Shou recovery links; target files and Trash items stay untouched, and completed plans cannot be replayed.
- Improve history summaries, result-page return and rescan actions. Separate system-managed scan gaps from user-access issues and retain per-directory completeness.
- Keep live and unlinked application helpers protected during uninstall checks and retain exact-location verification for receipt-bound restoration.

Local warm-cache measurements, workload details and limits are documented in the source tree. They do not promise the same speedup for every disk or complete protected-disk coverage.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Download the DMG and drag Shou.app to Applications, or use the ZIP containing the same app. Verify downloads with SHA256SUMS. Existing installations can use Check for Updates; Sparkle verifies signed archives and feeds.

The source tree includes the native Windows implementation and synchronized WPF progress/bridge checks. This release provides macOS installation assets; a Windows installer remains unavailable.

Permanent deletion cannot be undone. Moving items to Trash does not immediately free disk space. Removing recoverable history prevents further recovery or verification through Shou. This release is ad-hoc signed and is not Apple-notarized; updating may require granting the current app Full Disk Access again.

简体中文：v0.7.0 优化 macOS 空间扫描的批量元数据分页和目录写入，移除宽目录的批量读取上限；为至少占用 1 MiB 的文件增加索引，提升已保存大文件查询，并优化目录排序、筛选与批量选择。旧扫描目录保持可读，新索引需重新扫描生成。内置规则及 Schema 复用不可变校验结果，外部规则仍完整校验。

操作进度在工作总量已知的阶段展示实际百分比，永久删除展示当前项目内部进度，长路径仅在中间截断；发现阶段继续显示实时数量。历史记录支持预览后明确确认清理，默认保留未完成和可恢复记录；主动包含可恢复记录会丢弃 Shou 恢复关联，但不删除原文件或废纸篓项目，已执行计划仍禁止重放。改进历史摘要、结果返回与重新扫描入口，区分系统管理目录缺口和用户访问问题，并保留应用卸载时对存活及已解除链接辅助进程的保护。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅和 SHA256SUMS。Windows 代码及进度协议同步更新，尚无正式安装包。性能数据来自明确记录条件的本机测试，不代表所有磁盘或完整受保护目录覆盖。此版本未经过 Apple 公证，更新后可能需要重新授予磁盘访问权限。
