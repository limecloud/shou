Shou v0.5.0 adds saved large-file discovery, batch application uninstall, scoped browser privacy cleaning, and a first-use setup guide.

- Find large files by size and file type, preview results, and select matches across pages. Space analysis now keeps a SQLite catalog for paged results, with improved metadata measurement, scan progress, cancellation, and disk-capacity display.
- Compare application sizes and activity, expand associated components inline, select several apps, and confirm the exact batch once. Personal data requires separate consent. Choose permanent removal or Move to Trash; Trash receipts support separately confirmed restoration.
- Clean supported browser history and Cookies by time range through a separate manual workflow. Cookies require sign-out consent, and all privacy deletion requires irreversible-deletion confirmation. Running browsers and unsupported schemas remain unavailable; some current Firefox and Safari history schemas are unsupported. Receipts contain aggregate results. Privacy cleaning offers no restoration or forensic-erasure guarantee.
- Follow the first-use guide to install the app in Applications, review Full Disk Access, or continue with accessible folders. Optionally install the bundled CLI without changing shell settings. Scan results retain explicit coverage limits for inaccessible areas.
- Expand the built-in catalog to 210 rules, including 136 independently declared cache/log additions informed by a pinned Mole source review. The coverage manifest records mapped paths and remaining gaps; it does not claim compatibility with every application in the upstream inventory.
- Discover additional standard cache directories from installed-application identities when the application inventory is complete. Exact bundle-identifier paths retain activity, ownership, exclusion and fresh-evidence checks, while maintained narrower rules keep their scope.
- Use shared GUI and CLI contracts for batch uninstall, saved large-file queries, and privacy plans. Destructive CLI execution requires interactive terminal confirmation.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. Download the DMG and drag Shou.app to Applications, or use the ZIP containing the same app. Verify downloads with SHA256SUMS. Existing installations can use Check for Updates; Sparkle verifies signed update archives and feeds.

Permanent deletion cannot be undone. Moving items to Trash does not immediately free disk space. Adding global exclusions upgrades the local configuration format; older releases cannot read the upgraded format.

This release is ad-hoc signed and is not Apple-notarized. If macOS blocks the initial launch, verify the download source and review System Settings → Privacy & Security. Updating an ad-hoc signed build may require adding the current installed app to Full Disk Access again.

简体中文：v0.5.0 新增基于持久扫描目录的大文件筛选、跨页选择与预览；升级空间分析的分页、测量、进度和磁盘容量展示。应用卸载支持大小与活动摘要、内联关联组件和多应用一次确认，个人数据需单独同意，移到废纸篓后可分别确认恢复。新增独立的浏览器隐私清理流程，按时段清理受支持的历史记录和 Cookies；Cookies 需确认退出登录影响，删除无法恢复，也不保证彻底抹除痕迹。运行中的浏览器及不受支持的数据库结构会被拒绝，部分当前 Firefox、Safari 历史数据库不支持。首次使用提供安装、磁盘访问和可选 CLI 引导，也可先使用可访问目录。内置规则扩展至 210 条，保留明确的覆盖范围和缺口；在应用清单完整时，依据已安装应用身份发现额外的标准缓存目录，沿用活动、归属、排除和重新验证检查。支持 macOS 14+、Apple Silicon 与 Intel；此版本尚未经过 Apple 公证，更新后可能需要重新授予磁盘访问权限。
