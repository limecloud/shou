# Shou 文档

[English](../README.md) | 简体中文

Shou 提供空间分析、可审查清理与可复用规则。AI 调查是可选能力，确定性服务负责校验、确认和执行。

## 当前平台状态

| 范围 | 状态 |
| --- | --- |
| macOS | SwiftUI/AppKit 应用、Swift 领域服务和独立 CLI 已有源码；验收以实际证据为准 |
| Windows | C# / .NET 10 LTS / WinUI 3 架构已定义；应用、CLI 与分发待实现 |
| 运行时语言 | 简体中文、英文 |
| 文档 | 11 种 README 语言；英文、简体中文技术文档 |

## 用户与产品协作入口

| 目标 | 阅读入口 |
| --- | --- |
| 安装并启用扫描 | [安装与访问](product/installation-and-access.md) |
| 理解产品范围 | [PRD](product/prd.md) → [日常清理](product/unified-cleanup.md) → [用户故事](product/user-stories-and-use-cases.md) |
| 探索空间占用 | [空间分析](product/space-analysis.md) → [开发者场景](product/developer-space-scenarios.md) |
| 管理应用与启动项 | [应用清理](product/application-uninstall.md)、[启动项](product/startup-items.md) |
| 理解 AI 与规则 | [AI 用户旅程](product/embedded-ai.md)、[规则规范](rules/rule-specification.md) |
| 理解安全与结果 | [清理安全](security/cleanup-safety.md)、[进度与结果](product/operation-progress.md) |

## 工程师与 AI 开发入口

| 任务 | 必读文档 |
| --- | --- |
| 确认模块归属 | [系统架构](architecture/system-design.md) → [平台边界](architecture/monorepo-and-platforms.md) |
| 实现业务流程 | [流程与时序](architecture/workflows-and-sequences.md) → [数据合同](architecture/data-model.md) |
| 开发 Windows | [Windows 概览](engineering/windows.md) → [原生实施方案](engineering/windows-native-plan.md) → [SYNC.md](../../SYNC.md) |
| 构建与验证 macOS | [开发指南](engineering/development.md) → [验收规范](engineering/acceptance-and-testing.md) |
| 规划交付 | [实施计划](engineering/implementation-plan.md)、[能力职责](engineering/capability-plan.md)、[清理交付](engineering/cleanup-delivery.md) |
| 实现原生界面 | [界面设计](engineering/interface-design.md)、[macOS 体验](product/macos-experience.md)、[国际化](product/internationalization.md) |
| 改进扫描性能 | [扫描性能](engineering/storage-scan-performance.md)、[空间调查](engineering/space-analysis-agent-design.md) |
| 开发 AI | [AI 架构](architecture/embedded-ai.md) → [实现边界](engineering/embedded-ai-implementation.md) → [验收](engineering/embedded-ai-acceptance.md) |
| 接入外部 Agent | [CLI 合同](ai/agent-and-cli-contract.md)、[Agent 集成](ai/coding-agent-integration.md)、[Skill 分发](ai/skill-distribution.md) |
| 维护规则 | [Schema](../../packages/shou-contracts/rule.schema.json)、[规则覆盖](engineering/rule-coverage.md) |
| 发布 | [签名、打包与更新](engineering/releasing.md) |
| 通过 npm 分发 CLI | [统一 npm 入口与平台包](engineering/npm-distribution.md) |

## 文档约定

PRD 拥有产品范围，规则规范拥有匹配语义，安全约束所有入口，数据合同拥有身份与状态，CLI 文档拥有公开机器接口，原生实施方案拥有模块和工具链决策。每项事实在所属文档维护，其他文档通过链接引用。

改代码前先读相关合同，以最小完整链路实现，从唯一来源更新共享资源，记录实际测试、提交、系统、架构和限制。中英文技术文档与平台对齐表同步维护。源码、构建成功、运行行为和发布验收分别标明。
