# Shou development instructions

请使用简体中文沟通。先读现有实现和对应规范，再做最小、完整、可验证的变更。

## Required reading

- [文档入口](docs/zh-CN/README.md)
- [系统架构](docs/zh-CN/architecture/system-design.md)
- [平台边界](docs/zh-CN/architecture/monorepo-and-platforms.md)
- [清理安全](docs/zh-CN/security/cleanup-safety.md)
- 界面设计与重构使用本仓库技能 [shou-native-design](.agents/skills/shou-native-design/SKILL.md)，以[原生界面设计](docs/zh-CN/engineering/interface-design.md)为当前布局事实源。旧截图和历史对齐记录不能约束用户已要求替换的新设计。
- 开发者工具与 AI 工作台另读[全量能力与领域边界](docs/zh-CN/engineering/developer-tool-capability-map.md)和[逐软件适配](docs/zh-CN/engineering/developer-tool-adapters.md)。已有软件适配不代表完整范围；专属功能必须按当前源码及实际能力逐项核实。
- Windows 工作另读[原生实施方案](docs/zh-CN/engineering/windows-native-plan.md)与 [SYNC.md](SYNC.md)。
- 远程 Windows 验收与云电脑费用管理使用仓库技能 [shou-windows-cloud-test](.agents/skills/shou-windows-cloud-test/SKILL.md)；本地开发期间保持云电脑关机，准备好后集中开机验收。

## Implementation boundaries

- macOS：SwiftUI/AppKit、Swift Core 与 Swift CLI。
- Windows：WinUI 3、.NET 10 LTS、独立 C# Core；按 WN01–WN06 实施，源码与实际验收状态以方案和对齐表为准。
- 两端共享产品与安全合同、规则 Schema、声明式资源和验收案例；领域与系统适配分别实现。
- Core 声明小型能力接口，Platform 实现；UI 不承载匹配、权限或删除策略。
- 文案、规则和设计资源使用唯一来源和确定性生成器，不手工修改生成副本。
- 设计值仅修改 `assets/design/tokens.json`；资源生成器同时维护 Windows XAML 与 `apps/macos/Sources/ShouDesign.generated.swift`，均由 `--check` 校验。
- 界面变更同时修复受影响的既有页面，遵循[界面风格基线](docs/zh-CN/engineering/interface-design.md#界面风格基线)：Radix 语义颜色、最小 12 的三档文字、0.5 边线、简洁文案及单次审阅。不得恢复中点分隔、冗余眉题和重复说明。
- 不增加未被当前功能需要的抽象、兼容层或迁移工程。
- `.agents/skills/` 中的技能仅服务本仓库，不安装到用户全局目录，不修改其他项目的技能或规范。

## Safety and verification

- 不改变默认永久清理和精确范围确认合同，不增加无人值守删除绕过。
- 仅使用生成的临时夹具验证删除，不能把真实个人数据作为回归样本。
- macOS 常规验证：`sh scripts/test.sh`，其中部分 CLI 检查会永久移除自行生成的临时夹具；规则目录的额外永久移除检查使用 `--native-trash-purge`，须明确授权。
- 文档检查：`python3 scripts/verify-docs.py`；文案检查：`python3 scripts/update-localizations.py --check`。
- Windows 共享资源检查：`python3 scripts/generate-windows-resources.py --check`；Mac 纯 .NET 检查：`sh scripts/test-windows-core.sh`。
- Windows 纯 .NET 测试、原生系统测试、UI、签名与安装分别取证，不能互相替代。
- 生成 MSI 的原生卸载验收使用 `scripts/windows/test-uninstall-fixtures.ps1 -RunGeneratedMsiFixtures`，仅安装／卸载本次生成的当前用户夹具；不接受现有产品身份，默认测试跳过，不能据此开放产品门禁。
- 生成计划任务的原生控制验收使用 `scripts/windows/test-startup-fixtures.ps1 -RunGeneratedStartupFixtures`；只处理本次生成、触发器及手动启动均禁用的当前用户任务，拒绝现有任务参数，默认跳过，不开放产品门禁。
- 功能、安全与共享资源变化同步更新中英文文档和跨端对齐表，准确区分实现、验证与待办。
- 未经用户主动要求，不创建分支，不执行 git commit、push 或 reset。
