# Shou 文档

[English](../README.md) | 简体中文

本文档集建立 Shou 的产品、设计与工程基线，帮助后续实现围绕同一个问题推进：**让用户把自己真正需要清理的目录，变成可审阅、可复用的清理规则。**

## 状态与约定

- 更新日期：2026-10-19。
- 当前状态：开发阶段，已提供原生应用、规则引擎与 CLI 源码，尚未完成完整发布验收。
- Swift 原生开发、macOS 原生设计、CLI 与桌面双入口、monorepo 与未来 Windows 支持，以及不接入模型、不开发 Agent 是已确认约束。
- macOS 14+、模块拆分、规则字段、命令名和里程碑是首版设计基线，允许通过记录决策调整。
- 所有性能、兼容性与安全指标均为验收目标，不能作为已完成能力对外宣传。
- 文档中的示例项目与路径均为虚构。

## 阅读路径

| 目标 | 阅读顺序 |
| --- | --- |
| 了解为什么做 | [PRD](product/prd.md) → [用户故事](product/user-stories-and-use-cases.md) |
| 对照实际占用问题 | [开发者空间场景](product/developer-space-scenarios.md) → [规则规范](rules/rule-specification.md) |
| 检查启动项来源 | [启动项发现](product/startup-items.md) → [CLI 合同](ai/agent-and-cli-contract.md) |
| 卸载应用与审阅关联文件 | [应用卸载](product/application-uninstall.md) → [安全设计](security/cleanup-safety.md) |
| 开始界面设计 | [macOS 产品体验](product/macos-experience.md) → [参考设计](engineering/reference-design.md) → [流程与时序](architecture/workflows-and-sequences.md) |
| 规划多语言支持 | [国际化规范](product/internationalization.md) → [验收与测试](engineering/acceptance-and-testing.md) |
| 实现核心能力 | [系统架构](architecture/system-design.md) → [数据模型](architecture/data-model.md) → [规则规范](rules/rule-specification.md) |
| 理解工程与平台 | [Monorepo 与平台边界](architecture/monorepo-and-platforms.md) → [系统架构](architecture/system-design.md) |
| 让已有 Agent 操作 | [Agent 操作指南](ai/coding-agent-integration.md) → [CLI 合同](ai/agent-and-cli-contract.md) → [清理安全设计](security/cleanup-safety.md) |
| 规划研发与验收 | [实施计划](engineering/implementation-plan.md) → [验收与测试](engineering/acceptance-and-testing.md) |
| 本地构建与验证 | [开发指南](engineering/development.md) |

## 核心共识

1. **个人规则优先**：内置规则提供起点，用户自己的工作区和规则才是产品核心。
2. **规则独立更新**：在现有格式与匹配能力内，修改规则不要求应用发版；引擎新增能力仍需升级应用。
3. **对现有 Agent 友好**：Codex、Claude Code、WorkBuddy 等可通过 CLI 和公开格式协助添加规则；Shou 不接入任何模型、不开发 Agent、不自动上传数据。
4. **用户掌握执行权**：规则通过校验不等于获得清理授权；每次执行都绑定具体计划和确认。
5. **原生优先**：SwiftUI、AppKit、系统文件选择器、菜单、快捷键与辅助功能形成一致体验。
6. **数据口径诚实**：占用、移到废纸篓与可用容量变化分开呈现；扫描不完整时明确说明。
7. **围绕可审阅闭环扩展**：工作区 → 扫描 → 个人规则 → 预览 → 确认 → 清理记录；应用卸载共用回执与恢复，启动项发现与当前用户 LaunchAgent 受限控制共用来源核验。
8. **双入口独立可用**：桌面端与 CLI 共享业务逻辑，各自完成核心任务；CLI 执行不依赖打开桌面端。
9. **平台边界前置**：采用 `apps/`、`packages/`、`scripts/`、`docs/` 分层；共享 Swift 核心不依赖 AppKit、Darwin 或 Win32，平台能力独立适配。
10. **国际化**：英文为公开文档默认语言，提供多语言 README 和简体中文技术文档；界面、CLI 与规则显示文案遵循统一的本地化规范。

## 文档职责

- PRD 定义用户价值、范围与需求优先级。
- 规则规范定义匹配行为；AI 与 CLI 合同定义机器接口。
- 数据模型定义领域实体及状态；流程文档展示它们如何协作。
- 安全文档定义各入口都必须满足的约束。
- 实施计划管理阶段与未决事项；验收文档定义验证证据。

修改合同字段、状态、风险或默认行为时，必须同步上述关联文档。Mermaid 图应在支持 Mermaid 的 Markdown 查看器中阅读。
