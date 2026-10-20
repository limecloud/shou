# Shou 文档

[English](../README.md) | 简体中文

本文档集建立 Shou 的产品、设计与工程基线：**让现有 AI Agent 通过必要问询，把用户的清理需求变成可审阅、可复用的规则，Shou 在本地完成验证与执行。** 用户无需手写规则。

## 状态与约定

- 更新日期：2026-10-21。
- 当前状态：开发阶段，已提供原生应用、规则引擎与 CLI 源码，尚未完成完整发布验收。
- macOS 使用 Swift 原生界面，Windows 使用 C#/WPF 原生界面；CLI 与桌面双入口、monorepo，以及不接入模型、不开发 Agent 是已确认约束。Windows 当前为开发实现，原生验收待完成。
- macOS 14+、模块拆分、规则字段、命令名和里程碑是首版设计基线，允许通过记录决策调整。
- 所有性能、兼容性与安全指标均为验收目标，不能作为已完成能力对外宣传。
- 文档中的示例项目与路径均为虚构。

## 阅读路径

| 目标 | 阅读顺序 |
| --- | --- |
| 安装并开启完整扫描 | [安装与磁盘访问权限](product/installation-and-access.md) |
| 了解为什么做 | [PRD](product/prd.md) → [统一日常清理](product/unified-cleanup.md) → [用户故事](product/user-stories-and-use-cases.md) |
| 对照实际占用问题 | [开发者空间场景](product/developer-space-scenarios.md) → [规则规范](rules/rule-specification.md) |
| 检查启动项来源 | [启动项发现](product/startup-items.md) → [CLI 合同](ai/agent-and-cli-contract.md) |
| 卸载应用与审阅关联文件 | [应用卸载](product/application-uninstall.md) → [安全设计](security/cleanup-safety.md) |
| 开始界面设计 | [macOS 产品体验](product/macos-experience.md) → [参考设计](engineering/reference-design.md) → [流程与时序](architecture/workflows-and-sequences.md) |
| 规划多语言支持 | [国际化规范](product/internationalization.md) → [验收与测试](engineering/acceptance-and-testing.md) |
| 实现核心能力 | [系统架构](architecture/system-design.md) → [数据模型](architecture/data-model.md) → [规则规范](rules/rule-specification.md) |
| 理解工程与平台 | [Monorepo 与平台边界](architecture/monorepo-and-platforms.md) → [系统架构](architecture/system-design.md) |
| 让已有 Agent 操作 | [Agent 操作指南](ai/coding-agent-integration.md) → [CLI 合同](ai/agent-and-cli-contract.md) → [清理安全设计](security/cleanup-safety.md) |
| 安装 Agent 技能 | [Skill 安装与分发](ai/skill-distribution.md) |
| 规划研发与验收 | [实施计划](engineering/implementation-plan.md) → [验收与测试](engineering/acceptance-and-testing.md) |
| 本地构建与验证 | [开发指南](engineering/development.md) |
| 实现 Windows 原生客户端 | [Windows 技术栈、实现与验收](engineering/windows.md) |

## 核心共识

1. **Agent 定制清理优先**：内置规则提供起点，随包 Skill 引导现有 Agent 询问、分析并制定个人规则，可复用个人规则与自动发现是产品核心，用户无需管理工作区；启用后的规则参与后续智能清理。
2. **规则独立更新**：在现有格式与匹配能力内，修改规则不要求应用发版；引擎新增能力仍需升级应用。
3. **对现有 Agent 友好**：Codex、Claude Code、WorkBuddy 等可通过 CLI 和公开格式协助添加规则；Shou 不接入任何模型、不开发 Agent、不自动上传数据。
4. **用户掌握执行权**：固定规则可以一键进入清理确认；规则通过校验不等于获得清理授权，核心仍绑定具体计划和确认。
5. **原生优先**：SwiftUI、AppKit、系统文件选择器、菜单、快捷键与辅助功能形成一致体验。
6. **数据口径诚实**：占用、移到废纸篓与可用容量变化分开呈现；扫描不完整时明确说明。
7. **围绕可审阅闭环扩展**：桌面固定规则走扫描 → 清理推荐项目 → 一次确认，并明确选择废纸篓或永久动作；自定义选择与 CLI/Agent 保留预览、计划和回执，应用卸载共用回执与恢复，启动项发现与当前用户 LaunchAgent 受限控制共用来源核验。
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

- [空间分析与显式删除](product/space-analysis.md)

- [参考功能对照与实现门槛](engineering/reference-capability-map.md)

- [隐私清理与来源合同](engineering/privacy-cleaning.md)
- [操作进度与反馈](product/operation-progress.md)
- [Mole 软件清单与规则覆盖](engineering/mole-rule-coverage.md)
