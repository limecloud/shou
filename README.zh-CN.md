# Shou · 收

[English](README.md) · 简体中文 · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

**Tidy up. That's it. / 收好，就好。**

A native macOS cleaner with inspectable, reusable cleanup rules for your apps and development projects.

原生 macOS 清理工具。把适合自己的清理方式，变成看得懂、能预览、可复用的规则。

采用原生多平台 monorepo：macOS 优先交付，Windows 纳入后续正式目标；共享业务核心与规则合同，各平台保持原生桌面体验。

> 当前处于产品与技术设计阶段，尚无可下载的应用。下文功能与命令均为规划，实际进展见[实施计划](docs/zh-CN/engineering/implementation-plan.md)。

## 为什么做 Shou

一台 500 GB 的 Mac，多个项目的构建产物、依赖缓存和临时目录，就可能把空间一点点占满。每天重新找目录、判断能不能删，是重复且容易出错的工作。

常规清理规则很难覆盖每个人的项目布局、自研软件与工作习惯。真正占空间的目录，往往恰好没有现成规则。

Shou 希望把这个过程变成：

**找到占用 → 解释用途 → 定义规则 → 预览影响 → 确认清理 → 下次复用。**

在现有规则格式能够表达的范围内，规则更新无需应用发版；引擎新增能力仍需升级。用户可以自己编写，也可以让现有 AI Agent 协助生成；Shou 负责校验、扫描、预览和执行边界。

## 产品方向

| 能力 | 预期体验 |
| --- | --- |
| 项目空间分析 | 在用户选择的工作区中，按项目查看缓存、构建产物和其他大目录 |
| 个人清理规则 | 为自研应用、特殊工具链、个人目录定义规则，无需等待应用发版 |
| 可解释预览 | 显示具体路径、命中原因、大小口径、风险和重新生成的代价 |
| CLI 工作流 | 终端内独立完成规则管理、扫描、预览、确认清理与历史查询 |
| Agent 友好 | Codex、Claude Code、WorkBuddy 等现有 Agent 可通过 CLI 与 JSON 合同协助添加规则 |
| 复用清理方案 | 保存已审阅规则的组合，后续重新扫描、确认后清理 |
| 原生 Mac 体验 | Swift、SwiftUI 与必要的 AppKit 集成，遵循 macOS 桌面交互习惯 |

首版优先解决开发者工作区清理。应用卸载、通用缓存规则和启动项管理分阶段推进。

重点覆盖 Rust `target`、Node.js 项目缓存、需审阅的 `node_modules`，以及个人确认可重建的 `dist`、`dist-electron` 等输出。依赖、缓存、源码与交付物分别判断，不按目录名自动删除。详见[开发者空间场景](docs/zh-CN/product/developer-space-scenarios.md)。

## 清理应当看得见

- 默认只扫描用户授权的目录，规则无法扩大系统权限。
- AI 生成的规则先作为草稿，经过校验和预览后才能启用。
- 扫描、生成计划与执行分离；执行前展示本次具体影响并获取确认。
- 默认移到废纸篓；需要立即腾出空间时，单独确认永久移除本次清理项。
- 移到废纸篓的容量与磁盘实际可用容量分开显示，不把前者当作已释放空间。
- 源码、凭据、数据库和项目交付物不因为目录名像缓存就自动成为可清理项。

安全边界、不可恢复操作与技术限制见[清理安全设计](docs/zh-CN/security/cleanup-safety.md)。

## 技术方向

- **语言**：Swift，采用 Swift 6 并发检查。
- **界面**：SwiftUI 为主，AppKit 补充原生表格、文件交互等能力。
- **核心**：可移植 Swift 业务核心；GUI 与 CLI 共用规则、扫描、计划和执行领域模型，系统文件操作通过平台适配提供。
- **双入口**：桌面端和 CLI 都能独立完成核心闭环，不要求 CLI 唤起桌面端才能清理。
- **规则**：版本化 JSON 声明式格式，不执行规则附带的 Shell 或脚本。
- **数据**：本地保存配置、规则、计划与执行记录；首版无强制账号或云端服务。
- **产品边界**：不接入任何模型，不开发 Agent；通过公开 CLI 和规则格式，让已有 Agent 更容易操作 Shou。
- **系统基线**：首版设计目标为 macOS 14+，正式支持范围在原型验证后锁定。
- **工程组织**：`apps/` 放产品入口，`packages/` 放共享核心、平台适配和合同；不引入 JavaScript workspace。
- **Windows**：后续使用原生桌面入口消费共享合同；不将 SwiftUI 当作 Windows UI，Windows 文件安全与安装需独立验收。
- **国际化**：英文为公开文档默认语言，提供多语言 README 和完整简体中文技术文档；首版应用与 CLI 以英文、简体中文为目标，其他语言经翻译审阅和交互验证后启用。

## 文档

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md)

| 文档 | 内容 |
| --- | --- |
| [产品 PRD](docs/zh-CN/product/prd.md) | 背景、目的、收益、范围、需求和指标 |
| [用户故事与用例](docs/zh-CN/product/user-stories-and-use-cases.md) | 个人项目、自定义规则、AI 协作和异常场景 |
| [开发者空间场景](docs/zh-CN/product/developer-space-scenarios.md) | Rust、Node.js、构建输出与闲置项目的空间管理 |
| [macOS 产品体验](docs/zh-CN/product/macos-experience.md) | 信息架构、原生交互、页面与状态设计 |
| [国际化规范](docs/zh-CN/product/internationalization.md) | 语言覆盖、资源、术语、CLI locale 与翻译验收 |
| [系统架构](docs/zh-CN/architecture/system-design.md) | 模块边界、技术选型、权限和架构图 |
| [Monorepo 与平台边界](docs/zh-CN/architecture/monorepo-and-platforms.md) | 仓库分层、可移植 Swift 核心与 Windows 路线 |
| [流程与时序](docs/zh-CN/architecture/workflows-and-sequences.md) | 扫描、规则导入、确认、执行和恢复 |
| [数据模型](docs/zh-CN/architecture/data-model.md) | 规则、候选项、计划、授权和执行记录 |
| [规则规范](docs/zh-CN/rules/rule-specification.md) | 规则格式、匹配语义与示例 |
| [AI 与 CLI 合同](docs/zh-CN/ai/agent-and-cli-contract.md) | 命令、JSON 输出、错误和 AI 边界 |
| [现有 Agent 操作指南](docs/zh-CN/ai/coding-agent-integration.md) | Codex、Claude Code 等通过 CLI 添加规则的操作闭环 |
| [清理安全设计](docs/zh-CN/security/cleanup-safety.md) | 文件保护、权限、删除、恢复与威胁模型 |
| [实施计划](docs/zh-CN/engineering/implementation-plan.md) | 里程碑、工作拆分、决策和待验证事项 |
| [验收与测试](docs/zh-CN/engineering/acceptance-and-testing.md) | 产品验收、安全测试、性能和发布门槛 |

## 鸣谢

- [Mole](https://github.com/tw93/mole)：开发者终端工作流与多语言项目展示带来的启发。
- [Pulse](https://pulse.egoist.dev/)：原生 macOS 信息组织与空间概览带来的启发。
- [BuhoCleaner](https://www.drbuho.com/buhocleaner)：磁盘浏览与清理结果分组展示带来的启发。

感谢以上项目在产品与设计上的启发。鸣谢不代表项目关联或代码依赖关系。

## 开发与贡献

仓库目前包含设计文档、规则合同草案、规则示例与许可证，尚未建立 Xcode 工程或 CLI。构建、运行和测试命令将在工程初始化后补充。

欢迎通过 [Issues](https://github.com/limecloud/shou/issues) 提供具体的空间占用案例。建议描述工具链、目录用途、能否重新生成及期望保留条件；分享路径时请去除用户名、客户名和项目敏感信息。

欢迎完善翻译。语言版本须保持命令、标识符、安全约束与产品状态一致；README 翻译不代表应用已支持对应语言。详见[国际化规范](docs/zh-CN/product/internationalization.md)。

## 许可证

[Apache License 2.0](LICENSE)。
