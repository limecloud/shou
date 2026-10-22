# AI 实现边界

[English](../../engineering/embedded-ai-implementation.md) | 简体中文

状态：macOS 桌面与 Swift CLI 已有调查源码；Windows 调查计划采用独立 .NET 服务。

## 当前模块

`packages/shou-ai` 负责路由、有界模型通信和调查编排；`packages/shou-core` 负责证据及规则、清理合同；`packages/shou-platform` 负责本地凭据和记录。macOS 桌面负责上下文入口、问答、状态呈现与设置；CLI 独立提供配置、测试、调查、继续与取消。

连接配置分别声明协议、API 根地址、模型和凭据引用。密钥不进入命令参数、调查输出和普通诊断。本地判断、可选结构化决策服务与主模型分别报告实际用量。离线规则和清理始终可用。

## 执行边界

AI 输出不可信。建议先成为禁用规则草稿，通过闭合解析器，独立预览，明确启用后重新扫描。模型输出不能绕过保护、确认、过期或原生身份核验。

取消撤销后续请求并保留真实任务状态。服务错误、不完整证据、不可用凭据和预算耗尽与正常完成分别表达。不能将证据静默重发到其他供应商。

## 验证

Swift 构建后运行 `python3 scripts/verify-ai-investigation.py`，检查生成夹具与本地模拟服务。Core 测试覆盖范围、供应商替换、撤销和私有凭据。这些检查仅证明实际模拟范围；真实服务兼容性、模型质量、原生交互、可访问性与分发按[验收矩阵](embedded-ai-acceptance.md)另行取证。

## Windows 实现

独立实现 .NET 编排与原生凭据适配，遵循相同的产品状态、披露和规则合同。Windows 运行时不依赖 Swift SDK。在 Windows 只读基础完成后实施，并在 [SYNC.md](../../../SYNC.md)登记对齐情况。
