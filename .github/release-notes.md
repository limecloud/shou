Shou v0.10.0 expands Space Analysis with Simple and Detailed views, nested space maps, scoped extension statistics, and local context copying for your existing AI agent.

- Switch between Simple and Detailed views using the same saved analysis. The remembered display preference does not persist deletion selections or trigger another disk scan.
- Explore a native directory tree alongside extension totals and a nested map. Allocated and logical bytes remain distinct; parent percentages, extension colors and directory focus help investigate space without implying that files are safe to delete.
- Read directory pages directly from the saved catalog and bound multilevel map queries. Small files can appear as extension aggregates, with omitted entries available through directory paging. Synthetic map groups cannot be used as deletion targets.
- Copy the current analysis, scope, focus, selection and coverage into a local agent request. The new `analysis context` and `analysis map` CLI commands reuse saved evidence; Shou does not upload the report or run a model. Existing validation, disabled rule import, preview and explicit enablement remain the route to reusable cleanup rules.
- Add corresponding Windows desktop bridge operations and WPF tree, extension table and map views, including reviewed space-removal confirmation and receipts.
- Review personal cleanup rules independently on macOS and Windows. Each preview shows matches, protections and estimated additional benefit; enable and rescan only the chosen rule before the existing deletion confirmation. Refresh external configuration changes when returning to the app. The agent handoff now asks for investigation of major consumers, separate cleanup decisions and receipt-based verification.

Map sizes are estimates from the saved scan. Parent and child totals overlap, extension detection uses filenames, and partial measurements remain lower bounds. Refresh when current measurements are required. Displayed colors, aggregate tiles and AI context do not authorize deletion. A native directory-read stall observed during full-disk analysis remains under investigation; folder-scan results do not establish full-disk acceptance. Native Windows interaction and complete disk coverage are not established by build and protocol checks. The existing protected-root guard still rejects AppData-based standard cache roots; those scopes are not accepted as working native cleanup coverage in this release.

Requires macOS 14 or later. The universal app and independent CLI support Apple Silicon and Intel. This release provides DMG, ZIP, CLI archive, signed update feed and SHA256SUMS; an unsigned Windows 11 x64 portable ZIP includes the .NET/Swift runtimes. Extract the complete ZIP and run Shou.exe; no developer toolchain is needed. Recycle Bin/restoration stay disabled by default. Windows installation, automatic updates, signing and full native UI acceptance remain separate limits. Existing installations can use Check for Updates; Sparkle verifies signed archives and feeds.

Permanent removal and owner-tool cleanup cannot be undone through Shou. Moving items to Trash does not immediately free disk space. The app is ad-hoc signed and not Apple-notarized; updating may require granting Full Disk Access again.

简体中文：v0.10.0 扩展空间分析，新增简洁／详细视图、嵌套空间图、当前范围的扩展名统计，以及复制给现有 AI Agent 的本地分析上下文。

- 两种视图复用同一次扫描，记住显示偏好；切换不会重新扫描，也不会持久保存删除选择。
- 详细视图组合原生目录树、扩展名统计与嵌套空间图，分别显示分配空间和逻辑大小，支持父级占比、类型颜色与目录定位。颜色和大小不代表可以清理。
- 目录分页直接读取已保存的目录索引，多层空间图查询有数量上限；小文件可聚合为扩展名分组，省略项目仍可分页调查。合成分组不能直接成为文件删除目标。
- 复制当前扫描、范围、焦点、选择与覆盖信息，交给用户已有的 Agent；新增 `analysis context`、`analysis map` CLI 查询，复用扫描证据，不上传报告或内置模型。定制规则仍需校验、禁用导入、预览和明确启用。
- Windows 同步桌面桥接查询及 WPF 目录树、扩展名表和空间图，并接入空间删除确认与回执。
- macOS、Windows 支持逐条审阅个人规则，预览命中、保护项和新增收益估计，仅启用并重新扫描选定规则，再进入原有删除确认；返回应用时同步外部配置变化。Agent 交接同步要求调查占用大项、拆分独立清理决策，并依据执行回执核验结果。

图中大小为扫描时的估计，父子大小不能相加，类型依据文件名扩展名，部分测量为下限；需要当前数据时应刷新。整盘分析中观察到的原生目录读取停滞仍在排查，目录扫描结果不代表整盘验收通过。构建及协议检查不代表 Windows 实机交互或完整磁盘覆盖验收。现有保护根目录校验仍拒绝基于 AppData 的标准缓存范围，本版不将其声明为可用的原生清理覆盖。

支持 macOS 14+、Apple Silicon 与 Intel，提供 DMG、ZIP、独立 CLI、签名更新订阅和 SHA256SUMS；Windows 11 x64 提供未签名便携 ZIP，内含 .NET／Swift 运行库，完整解压后运行 Shou.exe，无需开发工具；回收站／恢复默认关闭，暂无安装器或 Windows 自动更新，完整原生界面验收仍有独立边界。永久移除及工具清理无法通过 Shou 撤销。此版本未经过 Apple 公证，更新后可能需要重新授予磁盘访问权限。
