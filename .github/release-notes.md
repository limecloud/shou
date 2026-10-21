Shou v0.8.0 makes the macOS interface more compact and keeps rule-scan progress consistent across worker stages and scan locations.

- Use the native window title and toolbar for page names and common actions. Remove repeated headings and reduce spacing across cleanup, applications, startup, privacy, history and settings.
- Keep page explanations in information popovers and put scan-coverage details beside the relevant results. Compact storage navigation and disk-capacity displays leave more room for files and the space map.
- Preserve cumulative discovered-item counts through worker sealing, transfer, rule matching and snapshot saving. Common-location scans share one fixed phase total, so counts and percentages do not restart at each location.
- Keep failed-location diagnostics and partial coverage explicit. Progress measures processing phases rather than disk coverage; cancellation does not mark unprocessed phases complete.
- Reject regressive progress callbacks in the macOS session and update numeric progress directly to avoid overlapping rolling digits. Synchronize the Windows progress presentation with the shared cumulative values.
- Add regression checks for worker-stage resets, multiple locations, failed reads and cancellation, plus desktop-bridge progress checks. Update the English and Chinese interface, storage and operation-progress documentation.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Download the DMG and drag Shou.app to Applications, or use the ZIP containing the same app. Verify downloads with SHA256SUMS. Existing installations can use Check for Updates; Sparkle verifies signed archives and feeds.

The source tree includes the native Windows implementation and synchronized WPF progress/bridge checks. This release provides macOS installation assets; a Windows installer remains unavailable.

Permanent deletion cannot be undone. Moving items to Trash does not immediately free disk space. This release is ad-hoc signed and is not Apple-notarized; updating may require granting the current app Full Disk Access again.

简体中文：v0.8.0 精简 macOS 页面布局，统一使用原生窗口标题和工具栏，移除重复标题并缩小留白；页面说明移入信息弹窗，扫描覆盖详情靠近对应结果，空间分析导航与磁盘容量展示更加紧凑。

修复规则扫描在工作进程封存、传输、规则匹配和保存阶段切换时，已发现数量与进度回退的问题。常用位置扫描使用固定的整体阶段总量，跨位置累计数量与百分比；保留读取失败和部分覆盖诊断，取消不会将尚未处理的阶段标记完成。进度代表处理阶段，不代表磁盘覆盖率。macOS 忽略回退的进度回调，数字直接更新以避免滚动数字重叠；Windows 同步使用共享累计进度。

新增阶段切换、多位置、读取失败、取消与桌面桥接进度回归检查，并更新中英文界面、空间分析和操作进度文档。支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅和 SHA256SUMS。Windows 尚无正式安装包。此版本未经过 Apple 公证，更新后可能需要重新授予磁盘访问权限。
