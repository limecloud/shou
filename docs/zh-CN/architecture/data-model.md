# 领域数据模型

[English](../../architecture/data-model.md) | 简体中文

状态：开发合同。[Swift 模型](../../../packages/shou-core/Sources/Models.swift)已实现当前实体；完整状态流转与中断验收仍待完成。

## 1. 实体关系

```mermaid
erDiagram
    Workspace ||--o{ RuleBinding : binds
    RuleDefinition ||--o{ RuleBinding : referenced_by
    Workspace ||--o{ ScanSnapshot : scanned_as
    ScanSnapshot ||--o{ Candidate : contains
    CleanupPreset ||--o{ RuleBinding : selects
    ScanSnapshot ||--o{ CleanupPlan : produces
    CleanupPlan ||--|{ PlanItem : contains
    CleanupPlan ||--o{ ExecutionReceipt : records
    ExecutionReceipt ||--|{ ItemReceipt : contains
    ItemReceipt ||--o{ FollowUpReceipt : followed_by
```

关系为概念表达；规则绑定可被多个方案引用，计划项目必须保留扫描来源和规则版本快照。

## 2. 核心实体

| 实体 | 关键字段 | 约束 |
| --- | --- | --- |
| Workspace | `id`、`root_ref`、本地路径、卷与根身份、访问凭据 | 凭据与路径不进入可分享规则；每个入口验证实际访问 |
| RuleDefinition | `id`、`version`、`schema_version`、来源、正文摘要、内容 | 同版本内容不可静默变化；草稿不等于启用 |
| RuleBinding | 工作区、规则版本、启用状态、排除与本地覆盖摘要 | 根引用在本机显式绑定；变更后旧计划失效 |
| CleanupPreset | 名称、规则绑定引用、选择偏好 | 保存选择逻辑，不保存通用删除许可 |
| ScanSnapshot | ID、`scope`、`treeComplete`、`completedPaths`、配置摘要、状态、统计 | 仅独立完整且符合策略的候选可生成可执行计划项目 |
| Candidate | ID、相对路径、项目线索、身份、占用、风险、证据 | 大目录可以无规则；无规则候选不能直接执行 |
| CleanupPlan | ID、合同版本、摘要、创建/过期时间、规则与配置摘要、状态 | 绑定具体候选、处理方式和完整清单，不动态扩展 |
| PlanItem | 候选引用、原路径、文件身份、目录清单摘要、动作 | 同一计划内不得重复或存在未解决的父子目标冲突 |
| Confirmation | 计划 ID 与摘要、入口、确认时间、范围 | 当前进程内一次性使用；不得把落盘布尔值当作授权 |
| ExecutionReceipt | 计划引用、执行 ID、入口、阶段、总体结果 | 执行意图先落盘，逐项追加结果；可表示部分成功 |
| ItemReceipt | 原路径、实际目标位置、前后身份、动作、错误 | 恢复与永久移除必须重新核验，不只信任路径 |
| FollowUpReceipt | 原项目引用、恢复/永久移除、时间、结果 | 独立确认；不修改原始执行事实 |

## 3. 规则状态

```mermaid
stateDiagram-v2
    [*] --> draft
    draft --> invalid: 校验失败
    invalid --> draft: 修订
    draft --> validated: 校验通过
    validated --> enabled: 用户审阅并启用绑定
    enabled --> disabled: 用户停用
    disabled --> enabled: 重新检查绑定后启用
    enabled --> draft: 新版本作为新草稿导入
```

图中的新版本不覆盖旧版本事实；启用新版本会使引用旧配置的待执行计划失效。校验通过只表示格式与边界满足要求，不证明业务上可删除。

## 4. 扫描与计划状态

扫描状态：`running`、`complete`、`partial`、`cancelled`、`failed`。

- `partial` 表示至少存在无法读取、超出预算或无法完整判断的范围。
- `cancelled` 与 `partial` 不得伪装成 `complete`。
- 状态表示所请求扫描模式的完成情况，不能单独授权候选；某个无关子树不完整时，已完整测量的候选仍可保留执行资格，目标本身不完整则不可进入计划。

| 快照字段 | 含义 |
| --- | --- |
| `scope` | `full` 检查工作区目录树；`cleanup` 仅沿已启用规则可能命中的路径前缀发现，并完整测量命中的目标 |
| `treeComplete` | 整个工作区目录树是否已检查；清理模式的 `complete` 状态不代表该值为真 |
| `completedPaths` | 独立完整子树的相对根路径；候选须具有全树完整事实，或自身子树的正向完整覆盖证据 |

这些字段以可选形式兼容已有记录。旧记录没有 `treeComplete` 时沿用原有整树状态解释；没有 `completedPaths` 不提供任何独立覆盖证据，旧 partial 快照不能因此获得执行资格。计划保留扫描模式与预算，用于重新计算当前策略；每个选中目标仍须具有未变化的完整清单。

经过校验的时间预算也适用于扫描、计划及执行阶段的候选分析，各阶段的候选分析采用单调时钟截止时间。持久化记录中的预算超出受支持范围时，在重新计算策略前拒绝处理。

空间分析需要 `full` 扫描。清理快照是稀疏证据，未出现的目录与未访问的字节属于未知，不是零。界面和机器调用方须明确限制，不能将其根汇总或面积图当作完整磁盘占用。

```mermaid
stateDiagram-v2
    [*] --> preview
    preview --> ready: 范围选择完成且通过策略
    ready --> stale: 过期或配置及对象变化
    ready --> executing: 当前摘要获明确确认且复核通过
    executing --> completed: 所有项目成功
    executing --> partial: 至少一项失败或跳过
    executing --> cancelled: 取消且仍有未处理项目
    executing --> interrupted: 崩溃或异常退出
    stale --> [*]
    completed --> [*]
    partial --> [*]
    cancelled --> [*]
    interrupted --> [*]
```

首版计划有效期建议 10 分钟，由安全原型确定最终值。有效期未过也必须复核对象；改变选择范围、动作、规则或排除时生成新摘要并重新确认。`partial`、`cancelled` 或 `interrupted` 不自动重试未完成项，需要新计划。

## 5. 项目执行状态

| 状态 | 含义 |
| --- | --- |
| `pending` | 尚未开始 |
| `trashed` | 已核验并移到废纸篓，记录实际位置 |
| `skipped` | 状态变化、受保护或用户取消导致未处理 |
| `failed` | 操作错误，记录错误类型与已知现场 |
| `unknown` | 中断导致无法确认结果，需要现场核对 |
| `restored` | 后续已核验并恢复 |
| `purged` | 后续已单独确认永久移除 |

`restored` 与 `purged` 是后续记录推导出的当前状态，不能覆盖初次清理记录。`unknown` 不能自动当作失败重试，也不能据旧路径永久删除。

执行进度属于临时状态：`stage`、`processedCount`、`itemCount` 和 `path` 描述实际工作，不构成新授权或持久结果。停止请求在安全的项目边界阻止新操作；正在进行的单次系统废纸篓操作可能先完成，随后须核对并记录最终回执。

## 6. 风险与解释

有效风险取规则声明、来源校验、保护策略与运行时证据中的较高等级：

- `review`：具有明确可重建依据，但仍需用户判断成本与当前用途。
- `high`：重建条件不足、用户自定义用途不明或存在明显代价。
- `blocked`：越界、受保护、状态不完整、已检测到活动等，不可进入执行集合。

首版没有“绝对安全”或自动执行风险等级。每个候选项记录：命中条件、规则来源、缺失证据、重建说明、保护/排除结果。

## 7. 路径与文件身份

- 规则包含相对路径；绝对路径只在本地绑定、预览与记录中出现。
- 工作区身份与文件身份使用平台提供的卷和对象标识，并记录可用的类型、大小、修改及元数据变化信息。
- 目录使用完整子项清单及其规范化摘要，不能仅检查顶层 `mtime`。
- 清单摘要不等于文件内容哈希，也不能证明内容可再生成。
- 不跨越卷、不跟随符号链接、不把 Unicode 大小写折叠的字符串比较当作文件系统身份。
- 对硬链接与 APFS 克隆的计量局限，在统计结果中保留说明。

## 8. 容量口径

| 字段 | 含义 | 限制 |
| --- | --- | --- |
| `logical_bytes` | 文件逻辑长度累计 | 稀疏文件等不等于实际占用 |
| `allocated_bytes_estimate` | 系统报告的分配大小估计 | 克隆、压缩、硬链接可能影响归因 |
| `trashed_bytes_estimate` | 本次成功移入废纸篓的原估计量 | 不代表已释放 |
| `purged_bytes_estimate` | 本次永久移除项目的原估计量 | 不保证全部转为可用空间 |
| `volume_available_before/after` | 操作前后系统报告的卷可用容量 | 受其他进程、快照与系统回收影响 |

机器合同一律使用整数 `bytes` 和 UTC 时间；UI 本地化显示，容量单位使用十进制，不混用 GB 与 GiB。

## 9. 持久化与保留

- 配置、规则和执行记录使用版本化格式，格式迁移失败不得覆盖旧数据。
- 扫描中间数据与已失效计划可按容量预算清理；执行记录单独管理。
- 首版历史默认保留策略在 M0 测量后确定，不因清理历史自动永久移除用户文件。
- 删除历史前需明确可能失去应用内恢复与归属核验入口；系统废纸篓中的文件不随之删除。
- 当前用户之外的账户无法通过默认配置访问记录；不把本地记录视为防恶意同用户进程的安全隔离。
