# 参考功能对照与分阶段实现标准

[English](../../engineering/reference-capability-map.md) | 简体中文

状态：基于源码的功能对照，2026-10-21。本文对照 [MangoDisk](https://github.com/harry0703/MangoDisk)、开源 [Mole CLI](https://github.com/tw93/mole) 与 Shou 当前工作树，定义实现优先级和验收门槛，不代表功能对等或可发布。已有大文件与永久删除验收保持原记录范围。本轮仅更新文档，实际测试记录见[验收与测试](acceptance-and-testing.md)。

以下矩阵及分阶段门槛保留 **0.9.0 实现前基线**，不是当前功能清单。N01–N09 的现状、实际检查与原生／发布门槛以 [0.9.0 跟踪文档](next-version-0.9.0.md)为准。

## 证据约定

| 证据 | 能够支持的结论 | 边界 |
| --- | --- | --- |
| MangoDisk 源码 | 所检查 checkout 的 Owner、算法、操作、保护与界面接线 | 完整源码入口不能证明已安装版本成功执行过该操作 |
| Mole 源码与上游差异 | 固定提交上的 CLI 命令、Skill 分发和清理选择器变化 | 开源 CLI checkout 不能验证独立发行的原生 Mole 应用及其测试应用目录 |
| 本机 Shou 记录清单 | 复核时六类记录的文件数量与序列化长度 | 开发实例数据，不代表典型用户增长、磁盘实际分配或性能跑分 |
| REA 包清单与属性列表 | 已安装包身份、资源和声明元数据 | 包事实不能证明交互、权限、扫描、变更或恢复 |
| REA 被动运行观察 | 精确绑定的已安装参考进程／窗口暴露清理入口、存储／隐私／系统侧栏、扫描按钮和扫描方式控件；42 个可访问性节点，未截断且无报告缺口 | 未提供操作步骤，不能证明菜单交互、扫描、结果、清理或恢复 |
| 对已安装参考应用的 CUA 交互 | 已观察的清理类别 → 规则 → 路径层级、部分选择与固定底部选择／操作区域 | 未触发参考应用清理，不能证明删除或恢复语义 |
| 对 Shou 的 CUA 交互 | 可访问范围引导、大文件筛选与选择、精确永久确认取消、生成夹具废纸篓清理及历史恢复；其他旅程保留各自记录的范围 | 不代表自动取得完全磁盘访问、完整文件系统覆盖、GUI 永久执行或缺失领域已实现 |
| Shou 源码 | 当前能力边界与实现 Owner | 新旧实现均需相应的 Core、CLI 和原生 GUI 验收 |

下文源码路径均相对于对应列所指的仓库根目录。数量描述所检查的目录，不代表成功任务数或机器覆盖率。除非另有链接的验收记录，Shou“已实现”均指源码实现事实。

本地运行证据：`.build/mangodisk-rea-cleanup-runtime.json`，证据 ID 为 `ev_d10f9814fdd19dd882d7b38fdd2ac46d1cb05aadbf769f85b69eac0f75e5a8be`。原助手编译超时后使用隔离预编译助手恢复观察，对助手源码和可执行文件校验 SHA-256，原目标身份检查继续生效。本地产物与源码结论、CUA 观察分别记录。

## 本轮对照基线

| 对象 | 检查版本 |
| --- | --- |
| MangoDisk | 本地源码版本 1.2.0，提交 `032e1e140dec2e28d0bef3232f3f2197cbd4a4d9` |
| Mole CLI | 上游提交 `84dc779dc651ff1f0509a2054b6e25b8fb5d2ac5`，日期 2026-10-21 |
| Shou | 当前本地工作树，包含另有验收记录的硬链接永久删除修复 |
| 已有 Mole 规则映射 | 仍固定在 `7b2a196061e1be7fae4ba422cd9102313fcb321d`；本轮未将映射升级到新提交，也未声称按新提交复验通过 |

上游比较显示，规则映射基线之后新增 25 次提交、变化 60 个文件，涉及 `lib/clean/app_caches.sh`、`caches.sh`、`user.sh`、卸载处理及 Mole Skill。源码和比较元数据保存在 `.build/reference-review-20261021/`。未执行参考项目的清理脚本。本轮没有三款软件在相同数据集上的跑分，也没有新增参考 GUI 验收，因此不能给出速度倍数或运行对等结论。

## 实现前功能基线

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
| AI 辅助 | 参考界面存在带模块上下文的 `MdAiWorkspace` 集成 | Shou 通过 `apps/macos/Sources/AgentRuleSetupView.swift` 接入外部编码 Agent 的规则工作流，自身不托管模型会话或 Agent。内置 AI 不属于 Shou 的产品范围 |
| 设置、排除与更新 | 独立设置、语言、主题与更新流程 | 已实现设置／排除及 `apps/macos/Sources/AppUpdater.swift` 中的 Sparkle；本轮完善安装与访问引导。引导可见不会授予访问权限 |

## 实现前日常清理差距

主要差距是可回收来源、重复工作和失败后的解决路径。增加导航页面不能解决这些问题。

| 范围 | 参考依据 | Shou 差距与下一步边界 |
| --- | --- | --- |
| 智能清理扫描 — P0 | MangoDisk 的 `cleanup/scan.rs` 编译扫描计划，按硬件与设备类型限制并发，最多四个 worker；保守设备类型降低并发 | `KnownLocations.scanKnownLocations` 逐个根扫描，`NativeFileSystem.inspectTree` 使用递归名称／stat 读取。`NativeStorageMeasurement` 的批量元数据与 1–8 个 worker 属于空间分析，尚未覆盖这条清理路径。先合并根任务、减少重复 I/O，再优化有界并发 |
| 二次扫描复用 — P1 | MangoDisk 的 `storage/index/cache.rs` 校验配置指纹、变更版本和文件系统 token；平台层使用 macOS FSEvents 与可支持 Windows 卷上的 USN 证据 | Shou 保存扫描／catalog，但没有对应的变更追踪复用合同。需要可验证复用及变更历史不可用时的回退；保存了结果不能证明结果仍然有效 |
| Shou 自身记录增长 — P0 | 本机实例只读清点 | 六类文件合计 2,992,132,938 序列化字节：587 份扫描（2,458,527,693 字节）、43 份计划（121,738,909）、100 份空间条目页（343,096,059）、23 份历史（59,501,382）、六份空间计划（8,689,225）、22 份空间扫描（579,670）。`HistoryRetention` 只清历史／后续操作，`LocalStore.removeHistoryRecord` 不清其他集合。需对派生记录增加过期／配额回收和引用保护，历史改为分页摘要；当前 `AppModel.refresh` 会通过 `Engine.history()` 读取完整回执 |
| 工具管理的大空间来源 — P1 | MangoDisk 的 `cleanup/cleaners/` 包含 Docker 构建缓存、Conda 缓存、闲置 Rust 工具链、模型存储、Codex 归档会话和 Xcode 专属处理；Mole 的 `lib/clean/brew.sh` 预览并执行参数一致的 `brew cleanup --prune=30` | Shou 规则只匹配目录，不能调用所属工具或选择单个磁盘映像文件。声明 BuildX 路径不等于回收 Docker 引擎构建缓存。目录仍用声明式个人规则；依赖工具／版本／引用知识的来源增加类型明确、操作固定的适配器 |
| 失败后的继续操作 — P0 | MangoDisk 的 `src/pages/cleanup/cleanup-application-close.ts` 按应用归并规则，并将重试限制在剩余失败目标 | Shou 已有卸载“请求退出”和完成页“重新扫描”，但退出请求不会等待确认关闭并恢复受影响选择，结果重试会重新扫描当前模块。智能清理需补齐归并关闭 → 验证 → 刷新受影响目标 → 审阅重试，保留其他选择和成功结果 |
| 孤儿残留与隐私深度 — P1/P2 | MangoDisk 有独立 `applications/leftovers/` 与逐来源 `privacy/`；Mole 的 `clean` 包含已卸载应用残留 | Shou 卸载时能关联组件，但没有独立孤儿清单；隐私覆盖部分历史／Cookie schema，未覆盖参考的完整活动／账号状态集合。需要精确的所属应用缺失证据，逐来源补能力，避免删除宽泛父目录 |
| 外部 Agent 定制 — P1 | 最新 Mole 已有 `skills/mole/SKILL.md`、`llms.txt`、Codex／Claude 插件入口及 `npx skills add` 分发；MangoDisk 的 `clean` 提供 human／JSON／JSONL、apply、dry-run 与明确的非交互确认选项 | CLI 或 Skill 本身已经不是独有差异。Shou 已有更细的发现／schema 合同，以及桌面复用的版本化个人规则导入／预览／启用。应完成未覆盖占用发现 → 外部 Agent 制定规则 → 验证收益 → 后续复用，减少反复交接；模型与 Agent 执行保持在 Shou 外部 |
| Windows 产品覆盖 — P1 | MangoDisk 有 93 份 Windows 文件系统 TOML，另有 128 份 macOS 与 31 份项目产物定义；不同规则模型不能按数量直接比较 | 按 `BuiltinTemplate.supportedPlatforms` 实际计算，macOS 有 210 个模板，Windows 只有六个项目模板，没有固定 Windows 缓存位置模板。`DesktopBridge` 将 applications／startup／privacy 声明为 false。交叉编译与桥接检查不能代表真实 Windows 文件系统／GUI 验收 |
| 界面语言 — P2 | MangoDisk 包含 11 份 UI locale 目录 | Shou 的 `Localization.swift` 仅开放中文和英文。11 种 README 不代表软件支持 11 种语言；需补齐共享 Core／macOS／Windows 消息和各端切换验收后再扩大支持声明 |
| 发行身份 — P1 | Shou 自身打包与安装合同 | 未显式提供 Developer ID 时，本地包使用 ad-hoc 签名。已有 Sparkle，但 Developer ID 签名、公证、干净机器更新／权限验收仍需独立完成；本地签名身份变化可能令隐私授权失效 |

### 规则覆盖仍不完整

已有 [Mole 覆盖报告](mole-rule-coverage.md) 记录 844 个测试应用条目，其中 83 个映射到 Shou 明确的缓存／日志声明，761 个仍只有清单。本轮离线映射自测通过。这些是映射，并非 844 款应用兼容性测试；基于已安装 bundle 的动态缓存发现可以补充，但不能证明应用专属配置、工具管理存储或孤儿残留已经覆盖。上游 README 明确开源 CLI 和原生 Mole 应用独立下载，不能将原生应用的测试目录当成 CLI 源码验收结果。

### 架构方向

保留共享确定性 Core 与原生桌面／CLI 适配层。对需要领域知识的来源，在路径规则旁增加固定能力的清理策略：发现 → 类型明确的选择 → 精确预览 → 现有审阅／授权 → 领域执行 → 结果验证。例如 MangoDisk 的 Docker 处理固定本机 default context，区分预览与 builder prune，并限制时间和输出。这适合作为适配器边界，不应据此允许导入 JSON 执行任意命令。

日常桌面操作应是一个任务、适当确认和可见结果；内部 scan／plan／execute 合同不要求用户经过多个独立页面。外部 Agent 的确认传递是单独的体验决策：Shou 公共 CLI 当前要求控制终端确认破坏性操作，Windows bridge 使用单次请求 challenge，本轮对照不改变这两个合同。

精确重复文件和孤儿残留对释放空间的价值比偏好开关或资源仪表盘更直接。通用二进制瘦身、广泛系统优化和监控保持可选；托管模型或 Agent 不属于 Shou 的产品范围。

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
| P0：日常清理可靠性与成本 | 智能清理调度、记录回收、轻量历史、关闭应用／失败目标恢复与已有删除回归 | 相同夹具覆盖及优化前后冷／热耗时；有界并发与取消；配额测试保留活跃计划和恢复事实；关闭 → 验证 → 限定重试；部分失败时计数／选择／结果一致；保留原生永久删除和支持范围内恢复回归 |
| P1：有效回收与定制 | 选定工具适配器、持久化 Agent 规则、独立孤儿发现、可验证扫描复用、Windows 缓存覆盖与发行身份 | 每个适配器预览／执行一致、本机所属范围、时间／输出预算与验证；外部 Agent → 禁用草稿 → 预览 → 授权启用 → 桌面复用；精确孤儿关联和所属应用缺失；变更历史失效；真实 Windows 夹具删除／GUI；签名公证后的干净安装和更新／权限验收 |
| P2：存储与隐私广度 | 精确重复、选定隐私来源和更多界面语言，保持已有大文件合同 | 重复文件完整内容一致、替换检测和保留选择；大文件身份／分页／计量回归；逐来源隐私 schema／时间范围与影响同意、原生变更验证；各端完整翻译与切换 |
| P3：可选扩展 | 经产品选择后实现资源监控／菜单栏、通用二进制优化、可恢复系统偏好与选定维护 | 监控要求指标来源、采样周期、不可用状态和资源开销；二进制变更要求架构／签名身份、中断处理、写后验证和恢复策略；偏好要求恢复基线与恢复验证，提权维护要求真实不可取消状态。内置 AI 保持在产品范围之外 |

每项选定能力均需正反例，覆盖权限、运行中应用、身份变化、受保护后代、不支持 schema、时间／输出预算、变更前后取消、部分失败与验证未知。破坏性验收使用可丢弃的生成夹具。成功构建、目录计数、包清单或可见页面均不能替代原生端到端证据。

更新状态时，分别保留源码存在、构建成功、Core 测试、CLI 合同、原生 GUI 交互和操作／恢复验证事实，并参照[清理交互与架构决策](reference-design.md)、[系统架构](../architecture/system-design.md)及实际[验收记录](acceptance-and-testing.md)。

## 鸣谢

MangoDisk 可读取的源码为能力盘点、扫描调度、领域边界与分阶段验收标准提供了参考。Mole 公开源码为 CLI／Skill 对比和所属工具清理边界提供了参考；独立的 [Mole 覆盖报告](mole-rule-coverage.md) 保留固定版本规则来源、鸣谢和许可证信息。此处明确致谢，不代表关联关系、运行能力对等或复用任一完整目录。Shou 保持独立原生实现、规则、Core 合同与安全边界。

## 0.9.0 实现增量

当前工作树已实现记录回收／历史摘要、有界并发位置扫描、关闭应用／限定重试、专属工具清理器、Agent 规则发现与新增收益、八类 Windows 缓存和独立孤儿残留。检查与原生环境门槛见[交付跟踪](next-version-0.9.0.md)。重复文件、FSEvents／USN、更多隐私类型、Developer ID 分发及 844 软件规则映射缺口仍未因此完成。
