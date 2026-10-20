# 核心流程与时序

[English](../../architecture/workflows-and-sequences.md) | 简体中文

当前桌面导航、自动发现及个人规则复用以此为准：[统一日常清理](../product/unified-cleanup.md)。

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
                Core->>Platform: 受限永久移除原始路径
                Platform-->>Core: 已移除、跳过、失败或未知
            end
            Core->>Store: 写入逐项结果
            Core-->>UI: 更新进度
        end
        Core->>Store: 保存最终状态并释放锁
        Core-->>UI: 执行记录与可用下一步
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
