# Shou 文档

[English](../README.md) | 简体中文

本文档集建立 Shou 的产品、设计与工程基线：**通过 AI 调查主要占用，把用户的清理需求变成可审阅、可复用的规则，Shou 在本地完成确定性验证与执行。** 当前工作区已有内置调查首版，外部 Agent 和 CLI／Skill 继续可用；下一轮优先完善 AI 开关、Jev 优先路由和原生交互。

## 状态与约定

- 更新日期：2026-10-22。
- 当前状态：开发阶段，已提供原生应用、规则引擎与 CLI 源码，尚未完成完整发布验收。
- macOS 使用 Swift 原生界面，Windows 使用 C#/WPF 原生界面；CLI 与桌面双入口、monorepo 和共享确定性 Core 是已确认约束。内置 AI 首版已接入 SDK 和指定真实服务，总开关、Jev 优先路由及多页面体验尚待实施；Windows 原生验收单独跟踪。
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
| 理解扫描性能 | [空间扫描性能与并发](engineering/storage-scan-performance.md) |
| 设计外部 Agent 的空间发现体验 | [空间分析与 Agent 协作设计](engineering/space-analysis-agent-design.md) |
| 设计 AI 用户体验 | [用户故事、用例与开关／界面合同](product/embedded-ai.md) → [架构、路由、流程与时序](architecture/embedded-ai.md) → [验收矩阵](engineering/embedded-ai-acceptance.md) |
| 核对 AI 实施状态 | [首版实现与真实服务证据](engineering/embedded-ai-implementation.md) → [接入调研及协议设计](engineering/embedded-ai-investigation.md) |
| 选择清理专用 Agent Core | [同类软件、Swift SDK 对比与原型验收](engineering/agent-core-selection.md)（保留选型证据，当前使用 Swift AI SDK） |
| 实现 Windows 原生客户端 | [Windows 技术栈、实现与验收](engineering/windows.md) |

## 下一版本

内置清理专用 AI 按[实施计划 AI01–AI10](engineering/implementation-plan.md)推进，其中 AI07–AI10 覆盖总开关、Jev 优先、页面交互和专项验收。[0.9.0 交付计划与进度](engineering/next-version-0.9.0.md)继续记录既有实现、验证与剩余交付门槛。

## 核心共识

1. **AI 调查与个人规则优先**：内置规则提供起点，下一阶段内置 Agent 承接大占用调查、必要问询和独立规则建议；外部 Agent／Skill 路径继续支持，启用后的规则参与后续智能清理。
2. **规则独立更新**：在现有格式与匹配能力内，修改规则不要求应用发版；引擎新增能力仍需升级应用。
3. **清理专用 AI 与开放接口**：内置 Agent 接入用户选择的模型，仅使用受限调查工具；Codex、Claude Code、WorkBuddy 等继续通过 CLI 和公开格式添加规则。用户主动启用内置调查并了解提供方与发送范围，普通扫描与清理可离线工作。
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
