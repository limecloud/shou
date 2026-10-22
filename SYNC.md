# Platform synchronization / 跨端对齐

Updated / 更新：2026-10-23。Windows implementation is planned / Windows 实现待开始。

[English implementation plan](docs/engineering/windows-native-plan.md) | [中文实施方案](docs/zh-CN/engineering/windows-native-plan.md)

## Baseline / 基线

macOS source reference / macOS 源码参考：`08d2f2faca3887765d1cdc2d1e7758ec5fd12bd5`。
This identifies source for comparison, not completed acceptance / 仅标识对齐参考源码，不代表完成验收。
Current work is uncommitted; refresh each row to the exact reviewed commit and resource digest before implementation / 当前变更未提交，实现前将各项更新为实际审查的提交与资源摘要。

## Feature ledger / 功能对账

| Capability / 能力 | Source / 规范源 | macOS | Windows | Difference / 差异 | Evidence / 证据 |
| --- | --- | --- | --- | --- | --- |
| Native UI / 原生界面 | [Boundaries](docs/architecture/monorepo-and-platforms.md) | SwiftUI/AppKit source | Planned | WinUI 3 native controls | Pending Windows runtime |
| Rule validation / 规则校验 | [Schema](packages/shou-contracts/rule.schema.json) | Swift source and fixtures | Planned | Independent C# parser | Pending shared fixtures |
| Storage scan / 空间扫描 | [Contract](docs/product/space-analysis.md) | Swift source | Planned | Native Windows handles | Pending Windows filesystem |
| Cleanup and confirmation / 清理与确认 | [Safety](docs/security/cleanup-safety.md) | Swift source | Planned | Windows identities and ACLs | Pending races and replay |
| History and recovery / 历史与恢复 | [Data](docs/architecture/data-model.md) | Swift source | Planned | Platform-local record format | Pending durable journal |
| Personal rules / 个人规则 | [Rules](docs/rules/rule-specification.md) | Swift source | Planned | Same schema, independent service | Pending semantic fixtures |
| Application cleanup / 应用清理 | [Contract](docs/product/application-uninstall.md) | macOS bundle workflow | Planned | Installer/registry ownership | Pending platform design |
| Startup items / 启动项 | [Contract](docs/product/startup-items.md) | macOS sources | Planned | Windows registration sources | Pending scope/control design |
| Privacy / 隐私 | [Contract](docs/engineering/privacy-cleaning.md) | macOS source | Planned | Windows profile access | Pending database safety |
| AI investigation / AI 调查 | [Contract](docs/product/embedded-ai.md) | Swift service | Planned | Independent .NET service | Pending provider and UI tests |
| Text and design / 文案与设计 | [Localization](docs/product/internationalization.md) | Chinese/English source | Planned | Generated Windows resources | Generator pending |
| Updates / 更新 | [Release](docs/engineering/releasing.md) | Sparkle integration | Planned | Velopack and Authenticode | Pending signed install/update |
| npm CLI / npm 命令分发 | [Distribution](docs/engineering/npm-distribution.md) | Published macOS-only 0.11.0 | Planned | Same public package, platform-native payloads | Pending platform routing and native tarball acceptance |

## Update rules / 更新规则

For each changed capability record / 每项变更记录：

1. Source commit, contract paths and content digests / 源提交、合同路径和内容摘要。
2. Windows implementation commit or `planned`, and the accountable module / Windows 实现提交或 `planned`，以及负责模块。
3. Exact differences or `not applicable`, with product and safety reasons / 具体差异或不适用，附产品与安全理由。
4. Executed commands, OS/build, CPU architecture, pass/fail result and evidence path / 实际命令、系统版本、CPU 架构、结果与证据路径。

`planned` does not mean supported. Safety changes block the affected Windows capability until its corresponding checks pass / 待实现不代表已支持；安全变更对应检查通过前，不开放受影响的 Windows 能力。
