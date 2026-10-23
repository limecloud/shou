# Shou for Windows

English | 简体中文

Status / 状态：implementation in progress; native acceptance pending / 实现进行中，原生验收待完成。

C# · .NET 10 LTS · WinUI 3 · Windows App SDK

Startup discovery / 启动项发现：`startup list` and the WinUI startup page share a bounded, read-only service for six Run/RunOnce registry sources, two local Startup folders and visible local boot/logon scheduled tasks and current-user packaged startup declarations. Arguments are discarded, effective state remains unknown and controls remain unavailable. The source/filter/page/refresh contracts and current exclusions are in the [English contract](../../docs/product/startup-items.md#windows-startup-contract) / [中文合同](../../docs/zh-CN/product/startup-items.md#windows-启动项合同)。CLI 与原生页面共用有界只读发现；不返回参数，不推断实际启动启用、应用进程或残留状态，不打开清理存储。计划任务与打包启动声明只读发现已接入；打包任务实际激活状态、控制及 Windows 实测仍待完成。

Scheduled-task status / 计划任务状态：recognized boot/logon tasks expose nullable `scheduled_task` with task `enabled` and engine `state` after double reads and definition rechecks. WinUI details and CLI share these observations; status gaps preserve the registration with partial coverage. This does not establish startup conditions or application process activity. Native COM/permission/UI acceptance remains pending / 计划任务增加独立开关与引擎状态观察，状态缺失保留注册并报告缺口，不推断实际启动条件或应用活动；原生 COM、权限与界面待验收。

The desktop and CLI share an independent C# Core. Source includes bounded storage scanning, workspace/exclusion configuration, versioned rules, persisted enabled-rule scans and draft previews, plan creation/queries, read-only history inspection, native identity/private-store adapters, presentation state and generated resources. Core confirmation, item-journal orchestration and history are tested with simulated ports. The CLI assembles native file-use, project-tool activity and relative-handle removal adapters, but `plan execute` remains disabled pending native acceptance. Core, Presentation and CLI logic tests run on macOS. WinUI runtime, native filesystem/process/terminal behavior and signed distribution require separate Windows acceptance. No Windows release package is available.

WinUI source includes storage browsing, location discovery, built-in preferences, personal-rule import, scan-folder registration, exact-version enable/disable, exclusion previews, explicit cleanup selection/review and read-only history inspection. Configuration and the CLI use the same Core service. Writes are serialized, actual state is reloaded after any write response, and changes invalidate old cleanup evidence. The CLI provides `rules catalog`, read-only `system locations` and `system scan` with batch registration and sequential shared budgets. The GUI scans a selected location or all registered locations under shared sequential budgets and provides cross-location category/rule/path filters, preserved global selection, explicit recommendations and combined plan review. A single current confirmation, all-source preflight and item journals are implemented in Core; native execution acceptance remains pending; the cleanup button is disabled. Presentation tests and a C# reference check with temporary XAML stubs do not establish XAML compilation or native UI behavior.

Windows 桌面与 CLI 直接共用独立 C# Core。当前源码包括有界扫描、工作区与排除配置、版本化规则、持久化启用规则扫描与草稿预览、计划创建与查询、只读历史核对、原生身份与私有存储适配、页面状态和生成资源。Core 确认、逐项日志与历史已用模拟接口测试；CLI 已组装文件占用、项目工具活动和相对句柄移除适配，但 `plan execute` 保持关闭，等待原生验收。Core、Presentation 和 CLI 逻辑测试可在 macOS 运行；WinUI 运行、原生文件系统／进程／终端行为与签名分发须在 Windows 分别验收。当前没有 Windows 发行包。

WinUI 源码已包含空间浏览、位置发现、内置规则偏好、个人规则导入、扫描目录登记、具体版本启停、排除预览、明确选择后的清理审阅和只读历史核对。界面配置与 CLI 使用同一 Core 服务，写入串行化，任何写入响应后均重读实际状态，变更清除旧清理证据。CLI 提供 `rules catalog`、只读 `system locations` 与整批登记后顺序共享预算的 `system scan`；界面可扫描所选位置或全部已配置位置，共享顺序预算，按类别、规则与路径汇总，筛选保留跨位置选择，并提供明确推荐选择及合并计划审阅。Core 已绑定一次当前摘要确认、全部来源预检与逐项日志，原生执行验收仍待完成，清理按钮禁用。页面状态测试及使用临时 XAML 替身的 C# 引用检查不能证明 XAML 编译或原生界面行为通过。

## Development / 开发

Application registration browsing / 应用注册浏览：`applications summary` and the WinUI applications page share `ApplicationCatalog` and bounded registry/current-user MSIX discovery. Search, sorting, pages, source gaps and unmeasured installer estimates are implemented in source. Registry paths and package identities do not authorize deletion; uninstall and native acceptance remain pending. See [English contract](../../docs/product/application-uninstall.md#windows-application-discovery-and-uninstall-boundaries) / [中文合同](../../docs/zh-CN/product/application-uninstall.md#windows-应用发现与卸载边界)。

Uninstall preparation / 卸载准备：CLI `applications inspect`, `applications plan` and `applications plan show` share installation-identity review and fifteen-minute plans with the applications page. Preparing a plan requires explicit installer-data acknowledgement and matching reinspection. Bounded installation-directory activity checks block active or unknown states. Core/Platform/CLI and WinUI also have current confirmation, durable intent, MSI/MSIX invocation and outcome-query source. WinUI includes stop-and-wait and normal-close protection; GUI and CLI share a disabled execution gate. Native acceptance, residual cleanup and restore remain pending / CLI 与应用页共用安装身份审阅及十五分钟计划；准备计划必须单独允许安装程序数据影响并重新核对摘要，活动或未知状态阻断计划。Core／Platform／CLI 与 WinUI 另有当前确认、先写意图、系统调用及结果查询源码；WinUI 包含停止等待与正常关闭保护，GUI 和 CLI 共用关闭的执行门禁。原生验收、残留和恢复待完成。

Use the SDK pinned in `global.json`. From the repository root / 使用 `global.json` 固定的 SDK，在仓库根目录执行：

```sh
python3 "scripts/generate-windows-resources.py" --check
sh "scripts/test-windows-core.sh"
sh "scripts/build-windows-cli.sh" win-arm64
sh "scripts/build-windows-cli.sh" win-x64
```

On Windows, keep build outputs on a local Windows disk / Windows 上将构建产物保存在本地磁盘：

```powershell
./scripts/windows/test.ps1
./scripts/windows/build.ps1 -Runtime win-arm64 -Launch
./scripts/windows/build.ps1 -Runtime win-x64
```

These are development commands. Build success does not establish release or cleanup acceptance / 以上为开发命令，构建成功不代表通过发布或清理验收。

Generated MSI acceptance is separately opt-in with `& "./scripts/windows/test-uninstall-fixtures.ps1" -RunGeneratedMsiFixtures`. It creates fresh current-user packages and preserves logs, hashes and records; it accepts no existing product/package input and leaves the public execution gate disabled. Cases skip by default and have not run on Windows yet. See [native fixture guidance](../../docs/engineering/windows.md#native-uninstall-acceptance-with-generated-msi-packages) / 生成 MSI 的卸载验收使用上述独立命令明确启用；只处理本次生成的当前用户安装包，保留日志、哈希与记录，不接受现有产品或包输入，保持产品执行门禁关闭。用例默认跳过，Windows 实际运行待验证，见[原生夹具指南](../../docs/zh-CN/engineering/windows.md#生成-msi-的原生卸载验收)。

- [Implementation plan](../../docs/engineering/windows-native-plan.md) / [原生实施方案](../../docs/zh-CN/engineering/windows-native-plan.md)
- [CLI and records](../../docs/engineering/windows.md) / [CLI 与记录](../../docs/zh-CN/engineering/windows.md)
- [Platform boundaries](../../docs/architecture/monorepo-and-platforms.md) / [平台边界](../../docs/zh-CN/architecture/monorepo-and-platforms.md)
- [Feature synchronization / 功能对齐](../../SYNC.md)

Scheduled-task switch source / 计划任务开关源码：Core, Platform, Presentation, CLI and WinUI share exact-task review, current confirmation, leased intent and result lookup. The public gate stays disabled pending native acceptance; browsing still opens no storage / 独立控制链路提供确切任务审阅、当前确认、租约下先写意图及结果查询，公共门禁关闭，等待原生验收；浏览仍不打开存储。See [English contract](../../docs/product/startup-items.md#scheduled-task-switch-review-and-control) / [中文合同](../../docs/zh-CN/product/startup-items.md#计划任务开关审阅与控制)。

Generated startup acceptance / 生成启动任务验收：`& "./scripts/windows/test-startup-fixtures.ps1" -RunGeneratedStartupFixtures` creates only random, current-user tasks with disabled triggers/demand starts and no runnable fixture executable. Six cases exercise native switches and Core journals; exact teardown preserves evidence, and public execution stays disabled. Mac checks compile and skip these cases / 独立入口仅创建随机当前用户任务，禁用触发器及手动启动，不运行任务；六项用例覆盖系统开关与领域记录，精确清理后保留证据，公共门禁关闭。Mac 仅编译并跳过，Windows 实测待完成。See [English guide](../../docs/engineering/windows.md#native-startup-control-acceptance-with-generated-tasks) / [中文指南](../../docs/zh-CN/engineering/windows.md#生成计划任务的原生控制验收)。
