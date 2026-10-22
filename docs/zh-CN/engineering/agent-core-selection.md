# 模型集成决策

[English](../../engineering/agent-core-selection.md) | 简体中文

macOS 在 SwiftPM 固定 Swift AI SDK `0.20.0`。SDK 类型仅留在 `ShouAI`，领域证据、安全、计划和执行不依赖 SDK。macOS 14 部署行为和每个真实供应商分别验证。

必要能力包括 Responses、Chat Completions、Messages、自定义 API 根地址、有界工具调用、问询暂停与恢复、取消、凭据撤销和用量预算。先用本地模拟服务验证，再运行获得授权的真实调用。报告实际请求、工具和 token 用量，不编造缺失指标。

Windows 使用独立 .NET 调查服务，保持相同产品状态与安全语义。在该功能实施阶段选择并固定模型库，本文未选定具体 .NET 模型 SDK。

遵循[AI 架构](../architecture/embedded-ai.md)、[实现边界](embedded-ai-implementation.md)、[验收](embedded-ai-acceptance.md)和[Windows 方案](windows-native-plan.md)。
