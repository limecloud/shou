# 清理 AI 架构

[English](../../architecture/embedded-ai.md) | 简体中文

状态：macOS 已有 Swift 调查实现。Windows 遵循相同产品合同，独立采用 .NET 实现，当前待开始。

## 职责归属

```mermaid
flowchart TB
    MacUI[macOS 上下文界面] --> Swift[Swift 调查服务]
    MacCLI[Swift CLI] --> Swift
    WinUI[WinUI Presentation - 待实现] --> Dotnet[.NET 调查服务 - 待实现]
    WinCLI[.NET CLI - 待实现] --> Dotnet
    Contract[证据、状态与规则合同] --> Swift
    Contract --> Dotnet
    Swift --> MacCredentials[macOS 凭据适配]
    Dotnet --> WinCredentials[Windows 凭据适配 - 待实现]
    Swift --> Routing[本地判断与所选服务]
    Dotnet --> Routing
    Routing --> Draft[逐条禁用规则草稿]
    Draft --> Parser[确定性规则校验]
    Parser --> Preview[独立预览与明确启用]
    Preview --> Scan[重新扫描与确认清理]
```

调查服务负责目标、有界证据、问答、路由、预算和检查点。Core 负责规则与清理安全，Platform 负责凭据、本地记录和系统事实。SDK 类型不进入 Core，各平台桌面与 CLI 直接共用自己的调查服务。

## 路由流程

```mermaid
flowchart TD
    Entry[明确的上下文入口] --> Gate{AI 已启用且连接已授权?}
    Gate -->|否| Settings[解释配置需求，不发送请求]
    Gate -->|是| Scope[绑定目标、范围与证据预算]
    Scope --> Local{确定性本地结果足够?}
    Local -->|是| Result[报告证据与真实零服务用量]
    Local -->|否| Policy{策略启用决策服务?}
    Policy -->|是| Decision[调用配置的结构化决策服务]
    Decision --> Sufficient{足够且未超出范围?}
    Sufficient -->|是| Result
    Sufficient -->|否| Main[授权允许时调用所选主模型]
    Policy -->|否| Main
    Main --> Missing{缺少用户意图?}
    Missing -->|是| Questions[保存问题并等待]
    Questions --> Scope
    Missing -->|否| Result
    Result --> Draft[生成逐条禁用建议]
```

Jev 是当前可选结构化决策适配器。仅主模型策略不能调用决策服务；已关闭服务的不可用凭据不能阻断已授权主模型。不得在供应商之间静默转发证据；解释升级原因，并分别记录真实用量。

## 调查时序

```mermaid
sequenceDiagram
    actor User as 用户
    participant UI as 原生界面或 CLI
    participant Service as 本平台调查服务
    participant Evidence as 有界本地证据
    participant Provider as 所选模型服务
    participant Store as 私有检查点
    User->>UI: 选择目标、范围与连接
    UI->>Service: 携带授权和取消令牌启动
    Service->>Evidence: 读取允许的元数据
    Evidence-->>Service: 有界事实与限制
    Service->>Provider: 必要时发送已披露证据
    Provider-->>Service: 工具请求、问题或建议
    alt 需要用户意图
        Service->>Store: 保存等待检查点
        Service-->>UI: 聚焦问题
        User->>UI: 回答或取消
        UI->>Service: 按原范围和连接继续
    else 证据充分
        Service-->>UI: 独立建议与用量
    end
    UI->>Service: 将选中建议导入为禁用规则
    Service-->>UI: 返回规则 ID，供独立预览
```

## 状态与取消

领域状态为 `running`、`waiting`、`complete`、`limited`、`cancelled` 和 `failed`。UI 另外表达关闭、未配置、就绪、停止中与过期。未知或不完整证据不能变成确定的清理结论。

保存原范围、目标、连接身份、过期时间、问题、答案与实际用量。继续前重新验证。中断的运行记录不代表可恢复的等待记录。取消撤销后续通信与工具工作，保留已完成证据并记录真实终态。

## 连接与通信

协议、API 根、模型与凭据引用分别配置。macOS 使用固定适配器支持 Responses、Chat Completions 与 Messages；.NET 服务须独立建立对应证据。远程地址要求 HTTPS，本地回环 HTTP 用于生成夹具。凭据保存在私有本地或系统凭据存储，明确执行请求、响应、超时、重定向和预算限制。

保存与编辑配置不发送网络请求，独立测试动作说明目标和效果。删除连接将其移出活跃选择，但保留调查引用；恢复与凭据行为分别验证。机器输出与诊断隐藏密钥。

## 规则闭环

```mermaid
flowchart LR
    Suggestion[独立建议] --> Import[禁用草稿]
    Import --> Validate[闭合解析器]
    Validate --> Preview[只读精确范围预览]
    Preview --> Enable[明确启用]
    Enable --> Scan[重新扫描]
    Scan --> Select[用户可调整的选择]
    Select --> Confirm[精确动作确认]
    Confirm --> Execute[既有确定性执行器]
    Execute --> Verify[回执与剩余范围核验]
```

模型没有删除授权。保护路径、排除、活跃应用、不完整目标、过期证据与日志失败始终由确定性服务约束。导入内容与项目元数据均视为不可信输入。

## 验证

使用生成夹具检查协议、范围、凭据隔离、供应商替换、撤销、问答、预算、注入、独立草稿和离线清理。原生交互与真实模型质量分别验证。Windows 源码、纯 .NET 测试、系统 API、UI 与签名分发按[实施方案](../engineering/windows-native-plan.md)分别验收。见[产品旅程](../product/embedded-ai.md)和[验收](../engineering/embedded-ai-acceptance.md)。
