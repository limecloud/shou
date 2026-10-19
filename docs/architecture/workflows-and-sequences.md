# 核心流程与时序

状态：设计草案。以下图描述目标行为，不代表已有实现。

## 1. 从占用发现到个人规则

```mermaid
flowchart TD
    Start[选择工作区] --> Access{当前入口有访问权限?}
    Access -->|否| Grant[引导系统授权或缩小范围]
    Grant --> Access
    Access -->|是| Scan[只读扫描与空间统计]
    Scan --> Complete{扫描完整?}
    Complete -->|否| Partial[展示部分结果与覆盖缺口]
    Partial --> Grant
    Complete -->|是| Classify[按项目与目录查看占用]
    Classify --> Known{已有合适规则?}
    Known -->|是| Evidence[查看命中依据与风险]
    Known -->|否| Draft[用户或现有 Agent 起草规则]
    Draft --> Validate{结构与语义通过?}
    Validate -->|否| Revise[根据明确错误修订]
    Revise --> Draft
    Validate -->|是| Import[导入禁用草稿并只读预览]
    Import --> Review{用途与范围明确?}
    Review -->|否| Exclude[保持禁用或排除目录]
    Review -->|是| Enable[用户审阅后启用]
    Enable --> Rescan[按启用版本重新扫描]
    Rescan --> Evidence
    Evidence --> Select[用户显式选择候选项]
    Select --> Plan[生成固定清理计划]
```

没有规则的大目录不会被隐藏，也不会仅凭体积成为可执行目标。完整扫描是计划前提；权限缺口需修复或通过更窄范围重新扫描。

## 2. 计划与执行决策

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
    Journal -->|是| Trash[逐项移到废纸篓并记账]
    Trash --> Result[展示成功、跳过、失败与未知项]
```

任一入口均调用相同策略。计划尚未过期也不能跳过复核；记录与文件操作不是跨系统事务，异常现场需要核对。

## 3. 桌面端清理时序

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
    User->>UI: 确认移到废纸篓
    UI->>Core: 当前摘要的一次性确认
    Core->>Store: 获取执行锁
    Core->>Platform: 复核根、目标与完整清单
    alt 状态变化或无法复核
        Platform-->>Core: 失效原因
        Core-->>UI: 拒绝执行或跳过变化项
    else 通过复核
        Core->>Store: 持久化执行意图
        loop 每个仍有效的计划项
            Core->>Platform: 受限移动到系统废纸篓
            Platform-->>Core: 实际位置、身份或失败
            Core->>Store: 写入逐项结果
            Core-->>UI: 更新进度
        end
        Core->>Store: 保存最终状态并释放锁
        Core-->>UI: 执行记录与可用下一步
    end
```

锁在所有出口释放；图省略了统一资源释放块。执行期间每个目标仍需紧邻操作复核，不能把批量开始时的一次检查当作全程有效。

## 4. CLI 独立清理时序

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
    User->>CLI: plan execute
    alt 无 TTY
        CLI-->>User: 退出 7，confirmation_required
    else 有 TTY
        CLI-->>User: 展示当前计划，要求明确确认
        User->>CLI: 确认
        CLI->>Core: 绑定当前计划摘要执行
        Core->>FS: 复核并逐项处理
        FS-->>Core: 实际结果
        Core-->>CLI: 执行记录
        CLI-->>User: 文本或 JSON 最终结果
    end
```

此流程不启动桌面端。外部 Agent 的规则导入与预览时序见 [Agent 操作指南](../ai/coding-agent-integration.md)。

## 5. 立即释放空间与恢复

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

## 6. 中断与恢复核对

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

## 7. 状态一致性要求

- 用户改变排除、规则或动作后，当前预览与确认不能继续沿用。
- 取消尽快停止启动新项，已经完成的移动保留在历史中。
- 批次不是全有或全无事务，部分成功必须直说。
- 历史是操作事实；当前是否可恢复由现场核验决定。
- 成功路径与异常路径都必须在 CLI 和 GUI 中有对应表示，不能只在日志里记录。
