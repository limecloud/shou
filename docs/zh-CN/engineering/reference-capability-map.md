# 参考功能对照与分阶段实现标准

[English](../../engineering/reference-capability-map.md) | 简体中文

状态：基于源码的功能对照，2026-10-20。本文对照 [MangoDisk](https://github.com/harry0703/MangoDisk) 与 Shou，并定义可选实现阶段的验收门槛，不代表功能对等、运行验收通过或可发布。本轮已实现大文件 Core、CLI 与原生 GUI 查询、选择及审阅后移除，并通过限定范围的本地验收；其余功能领域仍按下表分别列出。实际测试记录见[验收与测试](acceptance-and-testing.md)。

## 证据约定

| 证据 | 能够支持的结论 | 边界 |
| --- | --- | --- |
| MangoDisk 源码 | 所检查 checkout 的 Owner、算法、操作、保护与界面接线 | 完整源码入口不能证明已安装版本成功执行过该操作 |
| REA 包清单与属性列表 | 已安装包身份、资源和声明元数据 | 包事实不能证明交互、权限、扫描、变更或恢复 |
| REA 被动运行观察 | 精确绑定的已安装参考进程／窗口暴露清理入口、存储／隐私／系统侧栏、扫描按钮和扫描方式控件；42 个可访问性节点，未截断且无报告缺口 | 未提供操作步骤，不能证明菜单交互、扫描、结果、清理或恢复 |
| 对已安装参考应用的 CUA 交互 | 已观察的清理类别 → 规则 → 路径层级、部分选择与固定底部选择／操作区域 | 未触发参考应用清理，不能证明删除或恢复语义 |
| 对 Shou 的 CUA 交互 | 可访问范围引导、大文件筛选与选择、精确永久确认取消、生成夹具废纸篓清理及历史恢复；其他旅程保留各自记录的范围 | 不代表自动取得完全磁盘访问、完整文件系统覆盖、GUI 永久执行或缺失领域已实现 |
| Shou 源码 | 当前能力边界与实现 Owner | 新旧实现均需相应的 Core、CLI 和原生 GUI 验收 |

下文源码路径均相对于对应列所指的仓库根目录。数量描述所检查的目录，不代表成功任务数或机器覆盖率。除非另有链接的验收记录，Shou“已实现”均指源码实现事实。

本地运行证据：`.build/mangodisk-rea-cleanup-runtime.json`，证据 ID 为 `ev_d10f9814fdd19dd882d7b38fdd2ac46d1cb05aadbf769f85b69eac0f75e5a8be`。原助手编译超时后使用隔离预编译助手恢复观察，对助手源码和可执行文件校验 SHA-256，原目标身份检查继续生效。本地产物与源码结论、CUA 观察分别记录。

## 功能对照矩阵

MangoDisk 导航覆盖存储、隐私和系统任务，源码入口为 `src/lib/models/shell/application-shell.ts`。Shou 原生导航由 `apps/macos/Sources/ShouApp.swift` 管理。导航入口仅是完整能力的一部分。

| 能力 | MangoDisk 源码与边界 | Shou 状态与实现边界 |
| --- | --- | --- |
| 深度清理 | `src-tauri/crates/mangodisk-core/src/cleanup/models.rs` 定义十类；`src-tauri/crates/mangodisk-core/rules/filesystem/macos/` 含 128 份 TOML 定义，`src-tauri/crates/mangodisk-core/rules/project-artifacts/` 含 31 份 | 已实现，覆盖更窄：`packages/shou-core/Sources/Resources/builtin-rules.json` 含 210 条规则、660 个路径模式，绑定 65 个明确 macOS 位置，见 [Mole 来源与覆盖映射](mole-rule-coverage.md)；`packages/shou-core/Sources/BuiltinCatalog.swift` 管理目录。计数不能与参考的类别或规则模型直接等同 |
| 空间分析 | `src-tauri/crates/mangodisk-core/src/storage/analysis/service.rs` 及界面提供目录分析、树／矩形树图／旭日图、结果缓存与变更入口 | 已实现树／矩形树图、SQLite 目录 catalog、进度及审阅后移除。Owner：`packages/shou-core/Sources/StorageOperations.swift`、`packages/shou-core/Sources/StorageCatalog.swift`、`apps/macos/Sources/StorageSession.swift`、`apps/macos/Sources/StorageViews.swift`。未实现旭日图 |
| 大文件 | `src-tauri/crates/mangodisk-core/src/storage/large_files/service.rs` 提供独立阈值清单、缓存与移除流程 | 已实现保存索引筛选、稳定分页、原生独立入口、跨页显式全选、快速查看及共享审阅移除。Core 6/6、安装版 CLI 34/34 通过，生成 GUI 夹具完成废纸篓清理与恢复；范围见验收记录 |
| 精确重复文件 | `src-tauri/crates/mangodisk-core/src/storage/duplicates/service.rs` 使用大小分组、采样排除、完整 BLAKE3 与哈希缓存 | 未实现。大小或采样相同不能标为精确重复 |
| 隐私清理 | `src-tauri/crates/mangodisk-core/src/privacy/` 区分浏览器活动／账号状态、应用活动和系统活动，并提供来源专属计划与策略 | 已提供 `PrivacyService`、`PrivacyDatabase`、`NativePrivacySources` 和共享 CLI／GUI 入口源码：标准 Chromium 历史／Cookie、可支持结构的 Firefox 与 Safari 历史；其他类型及浏览器私有聚合明确标记不支持。Cookie 退出登录同意与永久删除独立确认，见[隐私合同](privacy-cleaning.md)；实际验收另行记录 |
| 启动项 | `src-tauri/crates/mangodisk-core/src/startup/` 区分清单、策略、聚合和控制证据 | 已实现清单及受限的当前用户 LaunchAgent 控制，见 `packages/shou-platform/Sources/NativeStartupControl.swift`。登录项和内嵌 helper 等不支持直接控制的来源跳转原生设置。`apps/macos/Sources/StartupInventoryView.swift` 区分定义、配置状态与运行状态 |
| 应用卸载 | `src-tauri/crates/mangodisk-core/src/applications/uninstall/` 管理应用身份、关联、计划、预检、执行与历史 | 已实现增量摘要、行内组件、跨应用选择、批量预检和共享回执，Owner 为 `ApplicationsSession`、`ApplicationUninstallBatch` 与 `packages/shou-core/Sources/ApplicationUninstall.swift`：应用、缓存、日志、偏好、应用支持、保存状态、容器、组容器、WebKit、HTTP storage。除应用／缓存／日志外，其他组件需要额外个人数据同意。桌面／批量默认永久删除，另提供废纸篓；旧单应用 CLI 默认废纸篓 |
| 孤儿残留 | `src-tauri/crates/mangodisk-core/src/applications/leftovers/service.rs` 提供独立孤儿清单 | 未实现。已安装应用的关联组件不等于独立孤儿扫描 |
| 通用二进制瘦身 | `src-tauri/crates/mangodisk-core/src/applications/binary_optimization/macos_universal_binaries.rs` 处理独立二进制优化操作 | 未实现。普通缓存清理不能修改可执行文件架构 |
| 系统优化 | `src-tauri/crates/mangodisk-core/src/system_settings/catalog.rs` 与 `src-tauri/crates/mangodisk-platform/src/macos/system_settings.rs` 提供 71 项 macOS 偏好定义及对应平台处理 | 未实现。偏好变更不代表性能已经提升 |
| 系统维护 | `src-tauri/crates/mangodisk-core/src/system_maintenance/catalog.rs` 与 `src-tauri/crates/mangodisk-platform/src/macos/system_maintenance.rs` 定义十项 macOS 任务 | 未实现。工具可用不代表诊断出必须执行的维护 |
| 资源监控／菜单栏 | `src/pages/tray-panel/index.vue` 与平台资源提供者展示 CPU、GPU、内存、磁盘、网络与进程信息 | 未实现。磁盘容量摘要不等于持续资源监控 |
| 历史与恢复 | `src-tauri/crates/mangodisk-core/src/history/` 支持多个操作领域 | 已实现清理／卸载回执、检查与独立恢复，见 `apps/macos/Sources/HistoryView.swift`、`apps/macos/Sources/HistoryInspectionView.swift` 及 Core 记录。新增变更领域必须明确历史和恢复语义 |
| AI 辅助 | 参考界面存在带模块上下文的 `MdAiWorkspace` 集成 | Shou 通过 `apps/macos/Sources/AgentRuleSetupView.swift` 接入外部编码 Agent 的规则工作流，自身不托管模型会话或 Agent。内置 AI 属于产品决策，不预设为待补实现 |
| 设置、排除与更新 | 独立设置、语言、主题与更新流程 | 已实现设置／排除及 `apps/macos/Sources/AppUpdater.swift` 中的 Sparkle；本轮完善安装与访问引导。引导可见不会授予访问权限 |

## 隐私：必须保留来源粒度

参考隐私模型适合用于划定领域边界，不能据此承诺所有浏览器等量支持。`src-tauri/crates/mangodisk-core/src/privacy/models.rs` 区分浏览器活动、浏览器账号状态、应用活动与系统活动，并区分就绪、空、所属程序运行中、需要权限、不支持 schema、不支持与不可用。Shou 不能将不支持或不可访问来源写成空结果或成功。

| 范围 | 源码行为 | 实现要求 |
| --- | --- | --- |
| 会话与计划 | `src-tauri/crates/mangodisk-core/src/privacy/service.rs` 使用扫描会话、不透明选择 token、过期计划与确认要求；首次变更前验证整个计划指纹，再逐项复核 | 将扫描 → 明细 → 选择 → 计划 → 预检 → 执行 → 验证 → 历史作为一个领域合同。仅有数量和删除按钮不构成实现 |
| 运行中的所属程序 | 计划标明浏览器／应用，并将关闭请求限定在计划自身 source ID 内 | 明确关闭或跳过受影响来源，不能结束无关进程或将占用中的存储当作已清理 |
| 高影响数据 | `src-tauri/crates/mangodisk-core/src/privacy/service/policy.rs` 将 Cookie／站点存储列为手动且影响登录状态，将密码／自动填充和编辑器本地历史列为手动且可能丢失数据 | 区分影响类型，要求明确的高影响确认；不能混入普通缓存便捷选择 |
| 浏览器数据库 | `src-tauri/crates/mangodisk-core/src/privacy/browser_database/schema.rs` 与 `src-tauri/crates/mangodisk-core/src/privacy/browser_database.rs` 存在按 schema 的实际变更，包括 Chromium 密码移除 | 按浏览器、数据类型与 schema 定义支持。较旧的“仅聚合”合同注释不能覆盖可执行实现；同为浏览器不等于等量支持 |
| Safari | 所检查的 `src-tauri/crates/mangodisk-platform/src/macos/privacy.rs` 提供历史、上次会话与缓存；Cookie、密码、自动填充、站点权限和站点存储提供者缺失 | 不能从共享数据类型模型推导 Safari 隐私全覆盖 |
| 时间范围 | 所检查服务中的站点权限、已保存密码、自动填充、常访问站点和网站图标仅允许全部时间 | 拒绝不支持的时间筛选，不能展示执行时忽略的范围 |
| 原生活动 | macOS 适配层处理当前剪贴板状态、最近文档／应用／网络和 Shell 历史，不提供剪贴板历史；若干文档／应用最近项目来源使用原生接口 | 逐来源建模，不能用整目录删除替代原生最近项目或隐私操作 |
| 敏感明细 | 参考模型将活动明细限制于当前会话，并禁止持久化和日志记录 | 记录内容不得进入日志、进度和持久回执，仅保留结果所需最小操作事实 |

受保护组容器查询可能在内核阻塞，参考 macOS 适配层记录了这一限制，并在部分 Office 探测前先观察 SharedFileList。Shou 实现需有界、隔离的读取，以及真实的取消／超时状态，不能假设每个文件系统调用都能立即取消。

## 系统优化：可恢复的偏好变更

所检查目录与 macOS 适配层均包含 71 个设置 ID，覆盖范围包括 Finder、Dock、面板、桌面元数据、Mission Control、窗口、键盘、文档／打印、Safari、TextEdit、Photos、个性化广告、AirDrop、活动监视器、App Store、文本替换、声音、Time Machine、睡眠与安全偏好。这是偏好管理目录，没有基准测试证明加速。

`src-tauri/crates/mangodisk-core/src/system_settings/service.rs` 管理计划过期，在变更前保存按设置合并的恢复基线，比较预期值，并在错误可能已造成变更时保留恢复信息。平台适配层写后读回验证。所检查的操作中仅显示隐藏文件会立即重启 Finder；其他需要重启应用的变更有独立门槛。

`src/pages/system-optimization/index.vue` 提供预设、分类、待应用变更、风险确认和恢复。Shou 若实现同类能力，必须保留准确前后值、说明重启影响、检测外部变更并验证恢复。没有这些合同的开关列表不满足该领域标准。

## 系统维护：按任务定义结果

参考 macOS 目录包含以下十项任务。可用性扫描主要检查所需工具是否存在，不能据此声称诊断出十类故障或建议全部执行。

| 任务 | 实际操作边界 |
| --- | --- |
| Spotlight 重建 | `mdutil -E /` 发起重建，成功启动不代表索引完成 |
| LaunchServices 刷新 | 固定 `lsregister` 垃圾回收及本地／用户域注册命令 |
| Quick Look 缓存 | 固定 `qlmanage` 缓存重置与重置命令 |
| 图标缓存 | Quick Look 重置，必要时重启图标服务进程 |
| Finder 重启 | 重启后检查进程可用性 |
| Core Audio 重启 | 重启后检查进程可用性 |
| 用户权限 | 为当前用户调用 `diskutil resetUserPermissions`，命令成功不等于独立验证所有 ACL |
| 旧覆盖项 | 移除指定旧偏好键并读回 |
| 启动磁盘检查 | `diskutil verifyVolume /` 只验证，不包含修复 |
| DNS 缓存 | 固定缓存刷新命令与 mDNSResponder 信号 |

Owner：`src-tauri/crates/mangodisk-core/src/system_maintenance/catalog.rs`、`src-tauri/crates/mangodisk-core/src/system_maintenance/service.rs`、`src-tauri/crates/mangodisk-platform/src/macos/system_maintenance.rs`。服务并发上限为二，冲突资源串行；排队任务可取消，提权任务开始后不能强制停止。Shou 若实现，必须按每项任务实际验证信号报告已启动、已验证、失败、取消和可能已变更状态。

## 分阶段实现与验收门槛

以下阶段是顺序建议，不代表完成声明或系统设置变更授权。只加入明确选定的产品能力，不为未实现领域增加导航空壳。CLI 与 GUI 复用 Core 用例，避免各自实现独立引擎。

| 阶段 | 范围 | 退出阶段所需证据 |
| --- | --- | --- |
| P0：现有旅程基线 | 安装引导、准确访问状态、标准扫描、空间分析与现有清理／卸载／启动项边界 | 首次安装／更新与语言行为；未知访问与拒绝访问区分；有界扫描、取消与部分结果；支持恢复的操作以生成夹具完成审阅 → 确认 → 变更 → 回执 → 恢复。只读启动项证据与受限控制分别验收 |
| P1：存储能力补全 | 验收本轮大文件实现，确定精确重复和孤儿残留范围，只按明确规则扩展清理覆盖 | 大文件阈值边界、稳定文件身份、完整测量、硬链接计量、取消、过期计划拒绝和 GUI／CLI 一致性。精确重复要求完整内容相同、替换检测与明确保留选择；孤儿判断要求已安装 Owner 缺失及精确关联证据 |
| P2：独立高影响领域 | 隐私、可恢复系统偏好与选定维护任务 | 逐来源能力矩阵、不可用／不支持状态、明确影响同意、限定所属程序关闭、过期计划、预检、原生执行、逐任务验证和持久结果。偏好要求恢复基线与恢复验证，提权维护要求真实不可取消状态 |
| P3：可选扩展 | 经产品选择后实现资源监控／菜单栏与通用二进制优化 | 监控要求指标来源、采样周期、不可用状态和资源开销；二进制变更要求架构／签名身份、中断处理、写后验证和明确恢复策略。内置 AI 仍为独立产品决策 |

每项选定能力均需正反例，覆盖权限、运行中应用、身份变化、受保护后代、不支持 schema、时间／输出预算、变更前后取消、部分失败与验证未知。破坏性验收使用可丢弃的生成夹具。成功构建、目录计数、包清单或可见页面均不能替代原生端到端证据。

更新状态时，分别保留源码存在、构建成功、Core 测试、CLI 合同、原生 GUI 交互和操作／恢复验证事实，并参照[清理交互与架构决策](reference-design.md)、[系统架构](../architecture/system-design.md)及实际[验收记录](acceptance-and-testing.md)。

## 鸣谢

MangoDisk 可读取的源码为能力盘点、领域边界与分阶段验收标准提供了参考。此处明确致谢，不代表关联关系、运行能力对等或复用完整目录。Shou 保持独立原生实现、规则、Core 合同与安全边界。
