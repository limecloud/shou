Shou v0.6.0 improves macOS storage-analysis throughput with bounded parallel directory reads and exact metadata checks.

- Read independent directories with up to eight workers and batch regular-file metadata with `getattrlistbulk`. A serialized SQLite writer keeps saved results available for paging and large-file queries.
- Use the native streaming storage catalog through the shared filesystem interface, including the desktop's packaged read worker.
- Retain exact directory identity checks, sparse-file and hard-link accounting, no-follow traversal, privacy boundaries and explicit partial coverage for unreadable, changed, cloud or cross-filesystem entries.
- Preserve parent-task cancellation across directory workers. Progress updates are throttled, cancellation aborts publication, and time limits produce an explicitly partial catalog.
- Replace a local development installation only after staging and verifying the new app. The installer checks installed bytes and existing Shou records and does not retain another old application copy.
- Add generated-fixture metadata-equivalence, worker-cancellation and directory benchmark checks, with English and Chinese architecture and performance documentation. Actual throughput depends on the disk, metadata cache and directory layout.

The source tree also includes ongoing native Windows work using WPF and the shared Swift core. Release assets contain the macOS application and CLI; a Windows installer remains unavailable.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Download the DMG and drag Shou.app to Applications, or use the ZIP containing the same app. Verify downloads with SHA256SUMS. Existing installations can use Check for Updates; Sparkle verifies signed update archives and feeds.

Permanent deletion cannot be undone. Moving items to Trash does not immediately free disk space. Adding global exclusions upgrades the local configuration format; older releases cannot read the upgraded format.

This release is ad-hoc signed and is not Apple-notarized. If macOS blocks the initial launch, verify the download source and review System Settings → Privacy & Security. Updating an ad-hoc signed build may require adding the current installed app to Full Disk Access again.

简体中文：v0.6.0 优化 macOS 空间分析，使用最多八个目录读取工作线程和批量文件元数据读取，并由单一 SQLite 写入路径保存可分页结果。修复通过共享文件系统接口调用原生流式目录的分派，桌面端仍通过包内读取进程工作。保留目录身份复核、稀疏文件及硬链接计量、不跟随符号链接、隐私边界和覆盖缺口；父任务取消会传递到目录工作线程，进度限频，取消后不发布扫描，超时仅发布明确标识的部分结果。本地开发安装器先暂存并验证应用，再替换旧包，核对安装内容与既有记录，不保留额外旧应用副本。新增元数据等价、取消及目录基准检查和中英文说明；具体速度取决于磁盘、缓存与目录结构。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅及 SHA256SUMS。Windows 原生实现仍在开发，尚无正式安装包。此版本未经过 Apple 公证，更新后可能需要重新授予当前应用磁盘访问权限。
