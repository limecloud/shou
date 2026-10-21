# 核心流程与时序

[English](../../architecture/workflows-and-sequences.md) | 简体中文

当前桌面导航、自动发现及个人规则复用以此为准：[统一日常清理](../product/unified-cleanup.md)。

macOS 空间分析读取池、catalog 写入器、后序汇总及取消时序见[空间扫描性能](../engineering/storage-scan-performance.md)。

状态：当前流程合同。以下图描述已实现的桌面快速路径、桌面详情路径、CLI/Agent 合同及仍待验收的边界。


桌面默认一次范围确认后永久清理；废纸篓为可选动作，选择废纸篓后不会静默转为永久删除。CLI 保持已有默认，显式 `--mode permanent` 可直接清理。两种动作共用根与目标核验、排除项、修改互斥和逐项日志。

## 1. 从占用发现到个人规则

桌面默认入口扫描常用应用／开发工具固定缓存位置及自动发现及记住的项目，无需选择目录。CLI 的 `system scan` 默认只扫描固定位置，`--include-projects true` 纳入自动发现及记住的项目。两者默认使用清理模式，项目发现只探测固定的常见开发目录；仍可显式扫描项目，空间浏览使用完整模式。

```mermaid
flowchart TD
    Start[扫描常用软件] --> Inventory[盘点明确的固定根]
    Inventory --> Register[生成证据前注册全部可用根]
    Register --> Scan[按根有界扫描]
    Scan --> State{目标子树完整?}
    State -->|否| Issue[阻止受影响目标并保留完整兄弟目标]
    Issue --> Results
    State -->|是| Activity[应用活动与保护检查]
    Activity --> Results[分别展示可审阅与被阻止结果]
    Results --> Select[在单一根中选择候选项]
    Select --> Preview[生成具体计划并确认]
    Preview --> Recheck[逐项复核文件与应用状态]
    Recheck --> Receipt[记录移入、跳过、失败或未知]
    Receipt --> Restore[单独确认并恢复可核验项目]
```

移入废纸篓仅报告处理量估计，不作为已释放空间。即使整体扫描为 partial，也只有独立完整目标可以进入计划；旧记录缺少覆盖证据不能授权不完整目标，清理模式完成不代表全树已测量。

```mermaid
flowchart TD
    Start[额外目录或 Agent 规则分析范围] --> Access{当前入口有访问权限?}
    Access -->|否| Grant[引导系统授权或缩小范围]
    Grant --> Access
    Access -->|是| Scan[完整模式只读空间扫描]
    Scan --> Complete{扫描完整?}
    Complete -->|否| Partial[展示部分结果与覆盖缺口]
    Partial --> Grant
    Partial --> Classify
    Complete -->|是| Classify[按项目与目录查看占用]
    Classify --> Known{已有合适规则?}
    Known -->|是| Evidence[查看命中依据与风险]
    Known -->|否| Skill[读取随包规则制定 Skill]
    Skill --> Questions[现有 Agent 追问用途与保留项等未明信息]
    Questions --> Draft[Agent 根据回答和证据编写规则]
    Draft --> Validate{结构与语义通过?}
    Validate -->|否| Revise[根据明确错误修订]
    Revise --> Draft
    Validate -->|是| Import[导入禁用草稿并只读预览]
    Import --> Review{用途与范围明确?}
    Review -->|否| Exclude[保持禁用或排除目录]
    Review -->|是| Enable[用户审阅后启用]
    Enable --> Rescan[按启用版本重新扫描]
    Rescan --> Evidence
    Evidence --> Target{目标子树完整?}
    Target -->|否| Grant
    Target -->|是| Select[用户显式选择候选项]
    Select --> Plan[生成固定清理计划]
```

完整扫描展示没有规则的大目录，但不会仅凭体积赋予执行资格；清理快照只包含规则指向的证据。目标证据不完整时须修复权限或重扫受影响范围；无关范围的缺口不使完整兄弟目标失效。

## 2. 桌面快速路径与详情审阅

初始界面以**开始扫描**为中央主操作，相邻菜单提供扫描方式，页头展示当前磁盘容量。标准扫描完成后，符合条件的内置及已启用个人规则候选会自动选中。类别三态复选框与路径详情调整同一份选择，固定底栏展示数量、容量估计和**清理并释放空间**动作。不可变计划的创建与重新核验在该动作内部完成，用户无需进入内部计划页面；扫描并清理的快捷动作仍保留在扫描菜单。

```mermaid
flowchart TD
    Open[打开 Shou] --> Entry[开始扫描与扫描方式菜单]
    Entry --> Scan[扫描固定位置与自动发现及记住的项目]
    Scan --> Matches[按应用、浏览器、开发工具和项目分组展示已核验匹配]
    Matches --> Auto[自动选中符合条件的内置候选]
    Auto --> Recommended[固定底栏清理并释放空间]
    Matches --> Details[查看详情]
    Details --> Adjust[调整类别和具体路径]
    Adjust --> Selected[清理已选项目]
    Recommended --> Action{废纸篓或永久移除?}
    Selected --> Action
    Action --> Trash[创建 action=trash 并确认一次]
    Action --> Permanent[创建 action=permanent 并展示不可逆确认]
    Trash --> Verify[重新核验文件与策略]
    Permanent --> Verify
    Verify --> Execute[运行对应执行器]
    Execute --> Result[展示逐项结果、估算值与后续操作]
```

这条路径统一处理内置与已启用个人规则，同时保留具体范围审阅入口。执行动作在操作点明确显示：**移入废纸篓**可通过该批次记录恢复；**永久移除**不可逆，并始终绑定当前选中的计划。

## 3. 计划与执行决策

```mermaid
flowchart TD
    Plan[固定计划] --> Policy{保护与排除检查通过?}
    Policy -->|否| Blocked[拒绝并说明原因]
    Policy -->|是| Entry{执行入口}
    Entry -->|桌面| Sheet[原生确认 sheet]
    Entry -->|CLI| TTY{存在交互终端?}
    TTY -->|否| Required[返回 confirmation_required]
    TTY -->|是| Prompt[显示计划与风险并等待明确确认]
    Sheet --> Consent{用户确认当前摘要?}
    Prompt --> Consent
    Consent -->|否| Stop[结束且不处理文件]
    Consent -->|是| Recheck{权限、配置、对象与清单仍有效?}
    Recheck -->|否| Stale[计划失效，重新预览]
    Recheck -->|是| Journal{执行意图成功持久化?}
    Journal -->|否| Failure[停止，显示记录写入错误]
    Journal -->|是| Action{计划动作}
    Action -->|trash| Trash[TrashExecution：逐项移到废纸篓并记账]
    Action -->|permanent| Purge[PermanentExecution：按绑定清单永久移除]
    Trash --> Result[展示成功、跳过、失败与未知项]
    Purge --> Result
```

任一入口均调用相同策略。计划尚未过期也不能跳过复核；记录与文件操作不是跨系统事务，异常现场需要核对。

永久删除使用仅在一次执行中存活的 `PermanentRemovalContext`。POSIX 适配层先固定共享文件的描述符，核对完整元数据，再以 `unlinkat` 删除所选名称，并从同一描述符读取删除后的状态。只认可链接数恰好减一及伴随的 ctime 变化，其他字段必须不变。后续条目及同批选中目标仅按这些实际观测结果修正原始清单的核验。执行结束即丢弃上下文，先前清理不会授权过期计划。Windows 保持原生核验，仍拒绝不支持的硬链接目标。

```mermaid
flowchart TD
    Verify[复核所选目标与完整清单] --> Entry[核验下一条清单条目]
    Entry --> Shared{共享的普通文件？}
    Shared -->|是| Pin[固定描述符并核对完整元数据]
    Pin --> Unlink[移除所选文件名称]
    Unlink --> Observe[从同一描述符读取删除后状态]
    Observe --> Expected{仅链接数减一且 ctime 改变？}
    Expected -->|是| Record[将实际变化记入本次执行上下文]
    Expected -->|否| Stop[停止并记录部分完成结果]
    Record --> Entry
    Shared -->|否| Remove[核验并移除已知条目]
    Remove --> Entry
    Entry -->|目标完成| Result[记录结果并作废桌面端旧扫描]
```

## 4. 桌面端清理时序

```mermaid
sequenceDiagram
    actor User as 用户
    participant UI as SwiftUI 界面
    participant Core as 共享核心
    participant Store as 本地存储
    participant Platform as 平台文件适配
    User->>UI: 选择候选并预览
    UI->>Core: 创建具体计划
    Core->>Core: 去重、保护、规则与清单绑定
    Core->>Store: 保存不可变计划
    Core-->>UI: 计划摘要、路径和风险
    User->>UI: 选择移到废纸篓或永久移除
    UI-->>User: 展示动作专属确认和确切路径
    UI->>Core: 当前摘要的一次性确认
    Core->>Store: 获取执行锁
    Core->>Platform: 复核根、目标与完整清单
    alt 状态变化或无法复核
        Platform-->>Core: 失效原因
        Core-->>UI: 拒绝执行或跳过变化项
    else 通过复核
        Core->>Store: 持久化执行意图与动作
        loop 每个仍有效的计划项
            alt 废纸篓动作
                Core->>Platform: 受限移动到系统废纸篓
                Platform-->>Core: 实际废纸篓位置、身份或失败
            else 永久移除动作
                Core->>Core: 仅修正本次实际移除的硬链接变化
                Core->>Platform: 携带执行上下文，复核并永久移除原始路径
                Platform->>Platform: 固定共享 inode，核对 unlink 前后元数据
                Platform-->>Core: 已移除、跳过、失败或未知
            end
            Core->>Store: 写入逐项结果
            Core-->>UI: 更新进度
        end
        Core->>Store: 保存最终状态并释放锁
        Core-->>UI: 执行记录与可用下一步
        UI->>UI: 每次尝试清理后作废旧扫描证据
    end
```

锁在所有出口释放；图省略了统一资源释放块。执行期间每个目标仍需紧邻操作复核，不能把批量开始时的一次检查当作全程有效。

## 5. CLI 独立清理时序

```mermaid
sequenceDiagram
    actor User as 终端用户
    participant CLI as Shou CLI
    participant Core as 共享核心
    participant FS as 平台文件适配
    User->>CLI: scan，查询结果，plan create
    CLI->>Core: 生成并保存计划
    Core-->>CLI: 计划 ID 与摘要
    User->>CLI: plan show
    CLI-->>User: 路径、规则、容量估计与风险
    User->>CLI: 执行 action=trash 或 permanent 的计划
    alt 无 TTY
        CLI-->>User: 退出 7，confirmation_required
    else 有 TTY
        CLI-->>User: 请求输入 TRASH 或 PURGE <plan-id>
        User->>CLI: 确认完整短语
        CLI->>Core: 绑定当前计划摘要执行
        Core->>FS: 复核并逐项处理
        FS-->>Core: 实际结果
        Core-->>CLI: 执行记录
        CLI-->>User: 文本或 JSON 最终结果
    end
```

此流程不启动桌面端。外部 Agent 的规则导入与预览时序见 [Agent 操作指南](../ai/coding-agent-integration.md)。

## 6. 立即释放空间与恢复

```mermaid
flowchart TD
    Receipt[本次清理记录] --> Current{记录对应对象仍在废纸篓?}
    Current -->|否或无法核验| Unknown[说明不可恢复或需现场核对]
    Current -->|是| Choice{用户选择}
    Choice -->|恢复| Destination{原位置可用?}
    Destination -->|否| ConflictChoice{选择其他位置?}
    ConflictChoice -->|是| Other[核验新位置与权限]
    ConflictChoice -->|否| Keep[保留在废纸篓]
    Destination -->|是| ConfirmRestore[确认具体恢复范围]
    Other --> ConfirmRestore
    ConfirmRestore --> Restore[核验后恢复，不覆盖现有文件]
    Choice -->|永久移除| Permanent[展示具体项目与不可恢复说明]
    Permanent --> ConfirmPurge{单独明确确认?}
    ConfirmPurge -->|否| Keep[保留在废纸篓]
    ConfirmPurge -->|是| Verify[重新核验身份与清单]
    Verify --> Purge[仅永久移除核验通过的本次项目]
    Restore --> FollowUp[新增后续操作记录]
    Purge --> FollowUp
    FollowUp --> Measure[区分处理容量与卷可用容量变化]
```

选择其他位置后仍需重新验证目标位置与权限；取消不触发恢复。永久移除不提供恢复承诺，也不清空其他废纸篓内容。

## 7. 中断与恢复核对

```mermaid
sequenceDiagram
    participant Client as CLI 或桌面端
    participant Core as 共享核心
    participant Store as 执行记录
    participant FS as 文件系统
    Client->>Core: 查询中断的执行 ID
    Core->>Store: 读取已落盘意图与逐项结果
    Core->>FS: 核对原位置、已记录废纸篓位置与身份
    FS-->>Core: 已完成、未执行或仍未知
    Core->>Store: 追加核对结果
    Core-->>Client: 真实状态与建议下一步
    Note over Client,FS: 不自动重放旧计划；未知项不按旧路径删除
```

## 8. 状态一致性要求

- 用户改变排除、规则或动作后，当前预览与确认不能继续沿用。
- 取消在安全项目边界停止启动新项；单次系统废纸篓调用可能先完成，已经发生的移动须核验并保留在历史中。
- 批次不是全有或全无事务，部分成功必须直说。
- 历史是操作事实；当前是否可恢复由现场核验决定。
- 成功路径与异常路径都必须在 CLI 和 GUI 中有对应表示，不能只在日志里记录。

永久执行时，项目在调用平台能力前先进入 `purging`，只有结果持久化后才进入 `purged`。取消或意外失败会将批次保留为 `cancelled` 或 `partial`；未经核验的项目绝不会显示为已永久移除，也不会仅凭旧路径自动重试。


## 空间分析直接删除

空间分析支持本地卷或目录发现，以及明确选中文件和目录后的直接删除，独立于清理规则工作区。桌面列表和树图共用导航与去重选择；确认及执行时核验当前完整清单和排除配置，复用既有执行日志与历史。详见[空间分析架构、流程与时序](../product/space-analysis.md)。

默认空间统计与删除清单分离：只读 Worker 流式生成私有 SQLite 索引，保留全部已测量文件，逐目录汇总容量与完整性；桌面和 CLI 按需查询目录，不再受删除清单 100 万条上限截断。`StorageScan` 引用索引并记录 `measured_entry_count`，节点提供 `is_complete`，部分容量为已统计下限。删除仍重新获取所选目标的完整清单并独立核验。旧 JSON 与分页记录继续可读。

安装、权限引导、可访问范围扫描与更新身份遵循[安装流程与权限时序](../product/installation-and-access.md)。

## 应用批量与隐私领域

应用卸载以增量摘要 → 行内组件 → 多应用选择 → 一次确认 → 批量预检 → 逐组件执行 → 共享历史为主流程；筛选不清空其他应用选择。默认永久卸载，废纸篓为独立可选动作。完整流程图、时序图及个人数据边界见[应用卸载](../product/application-uninstall.md)。

隐私以来源／时间范围扫描 → 空初始选择 → Cookie 独立同意 → 精确计划 → 永久确认 → 全计划预检 → 按来源数据库事务 → 汇总回执为主流程。各来源独立提交，部分成功不回滚其他已提交来源；无恢复入口。完整架构图、流程图和时序图见[隐私清理](../engineering/privacy-cleaning.md)。

## 空间清理进度与返回

```mermaid
flowchart LR
    List[选中项目] --> Review[独立只读核验进度页]
    Review -->|获得完整当前清单| Confirm[确认当前清理范围]
    Review -->|权限、预算或身份异常| Issues[原因与重试页]
    Confirm --> Execute[独立清理进度页]
    Execute --> Result[完成、部分完成或停止结果]
    Issues -->|返回| List
    Issues -->|重新扫描| Scan[刷新测量]
    Result -->|返回| Updated[回到原位置并移除已删除项]
    Result -->|存在异常| Scan
```

初次扫描用于导航。确认前允许目录在身份和所有者不变的前提下正常变化；核验会重新获取完整清单和大小，交由用户确认。普通文件仍核对初次扫描元数据。确认后必须严格匹配完整清单。读取不完整时保留具体覆盖原因，不发布删除计划。失败也进入有返回与重试入口的结果页。

```mermaid
sequenceDiagram
    participant UI as 桌面端
    participant Core as 共享核心
    participant FS as 平台文件系统
    UI->>Core: 核验所选路径
    Core->>FS: 读取当前完整清单
    FS-->>Core: 当前身份、条目与覆盖事实
    Core-->>UI: 当前确认范围或可处理的失败原因
    UI->>Core: 执行已确认摘要
    Core->>FS: 复核完整清单后删除
    FS-->>UI: 节流后的当前条目进度
    Core-->>UI: 持久化回执
    UI->>UI: 结果页返回原位置
```

## 操作记录清理与扫描问题处理

操作记录默认只呈现项目、日期、结果与已处理大小；执行 ID、逐项路径、恢复和核验操作放在详情中。清理已结束记录会删除本地 JSON 回执及关联后续记录，保留恢复所需、结果未知和未结束记录。单独删除记录需要明确确认恢复入口丢失；正在执行或尚有后续意图的记录仍保留。只删除记录，不移动或清空实际文件和废纸篓。已执行计划保留消费状态，不能通过清空记录重放。

CLI 使用 `shou history cleanup-preview --json` 预览、`shou history clear` 在终端确认；指定 `--execution-id` 可清理单条，`--include-recoverable true` 明确允许丢弃恢复入口。Windows 通过 `history.cleanup-preview` 与带本次确认挑战的 `history.clear` 调用同一核心。记录删除顺序是主回执在前、关联后续记录在后，避免中断后让已恢复的项目再次成为可恢复项。

扫描提示只针对当前目录。其他目录的不可读状态不污染完整项目目录的浏览。系统管理位置如 `.fseventsd`、`.Spotlight-V100`、`.DocumentRevisions-V100` 使用普通范围说明，默认折叠具体路径；核心仍保留覆盖事实，不把它们伪装为已测量。用户目录的访问问题提供完成设置和 Finder 入口，变化或临时读取失败可重新扫描当前文件夹。完整磁盘访问权限不能覆盖 Unix 所有权或系统保护，软件不会为读取系统目录而修改系统权限。

只有访问／读取问题会被归为系统管理范围；资源限制和扫描期间变化始终提供处理入口，包括直接扫描系统根目录的情况。清理后返回页面提供统计刷新，不把待刷新大小误报为权限问题。Windows 使用同一覆盖分类和当前目录完整性，提供资源管理器及当前文件夹重扫入口，默认桥接扫描使用共用的磁盘索引测量路径。

```mermaid
flowchart LR
    H[操作记录摘要] --> D[按需展开详情]
    H --> P[预览可清理记录与大小]
    P --> C[确认仅删除记录]
    C --> L[获取变更锁并复核状态]
    L --> R[删除主回执再删除关联后续记录]
    L --> K[保留恢复所需或未结束记录]
    S[当前目录覆盖问题] --> M{原因}
    M -->|系统管理| I[普通范围说明]
    M -->|用户目录权限| A[完成设置或 Finder]
    M -->|目录变化| F[重新扫描当前文件夹]
```

## 0.9.0 日常与定制清理

```mermaid
flowchart TD
    Start[一键标准扫描] --> Prepare[注册可用根]
    Prepare --> Workers[最多四个独立位置扫描]
    Workers --> Review[一张清理结果列表]
    Review --> Running{所属应用运行中?}
    Running -->|是| Close[保存工作并确认正常退出]
    Close --> Verify[验证退出 仅刷新受影响根]
    Verify --> Review
    Running -->|否| Confirm[一次确认当前选择]
    Confirm --> Execute[逐项复验与持久日志]
    Execute --> Result[完成 部分完成 取消 需核实]
    Result --> Back[返回原任务]
    Result --> Retry[仅刷新剩余所选路径]
    Retry --> Review
    Review --> Custom[外部 Agent 调查未覆盖占用]
    Custom --> Draft[校验并导入禁用草稿]
    Draft --> Benefit[对比已启用规则的新增收益]
    Benefit --> Choice[用户选择是否启用]
    Choice --> Start
```

```mermaid
sequenceDiagram
    actor User as 用户
    participant UI as 桌面或 CLI
    participant Core as ToolCleanupService
    participant Native as NativeCleanupTools
    participant Store as 本地记录
    User->>UI: 检查工具空间
    UI->>Core: scan
    Core->>Native: 固定只读预览
    Native-->>Core: 有界输出与可执行文件身份
    Core->>Store: 保存目标和证据
    User->>UI: 确认一个目标及其影响
    UI->>Core: 计划和确认摘要
    Core->>Native: 重做预览并对比证据
    Core->>Store: 执行意图和已消耗计划
    Core->>Native: 进程组内执行固定清理
    Native-->>Core: 退出 超时 或取消
    Core->>Native: 尽可能复验工具当前占用
    Core->>Store: 完成 部分完成 或 unknown 回执
    Core-->>UI: 明确结果 禁止盲目重放
```

孤儿残留先验证完整的标准应用目录、系统注册与运行状态；执行前及每个删除边界再次检查缺失所属应用、所有权、排除项和完整文件清单。个人数据单独选择。永久删除与废纸篓复用逐项日志，废纸篓恢复仍需单独确认。派生记录维护不会移除这些日志或用户文件。

```mermaid
sequenceDiagram
    participant Core as 共享执行服务
    participant Journal as ReceiptJournal
    participant Store as 本地记录
    participant FS as 原生文件系统
    Core->>Journal: 完整清单和 pending 回执
    Journal->>Store: 持久化不可变大清单
    Journal->>Store: 发布引用清单的小回执
    Core->>FS: 复验身份和内容
    Core->>Journal: 保存 moving 或 purging 意图
    Journal->>Store: 仅更新状态
    Core->>FS: 执行明确选择
    FS-->>Core: 已验证结果或未知结果
    Core->>Journal: 保存结果
    Note over Journal,Store: 清单变化才写新版本；结果写失败保留原执行意图
    Journal->>Store: 发布最终状态和分页摘要
```

独立个人规则的“大占用下钻 → 逐条停用草稿 → 原生审阅 → 所选规则新扫描 → 确认与回执核验”流程及时序见[空间分析与 Agent 协作设计 W09](../engineering/space-analysis-agent-design.md)。外部配置变化使旧清理证据失效，不会自动启用其他规则；日常清理复用已经明确启用的选择。
