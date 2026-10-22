# 仓库与平台边界

[English](../../architecture/monorepo-and-platforms.md) | 简体中文

状态：macOS 应用与 Swift CLI 已有源码实现；Windows 架构已定义，实现待开始。

## 架构决策

各操作系统分别拥有原生界面、领域实现与系统适配。macOS 桌面和 CLI 共用 Swift 服务；Windows 桌面和 CLI 共用 C# 服务。两端通过产品合同、声明式资源和验收案例保持行为一致。

```mermaid
flowchart TB
    Contract[产品与安全合同] --> MacCore[Swift Core]
    Contract --> WinCore[C# Core - 待实现]
    Resources[规则 Schema、目录、文案与设计 token] --> MacCore
    Resources --> WinCore
    MacUI[SwiftUI 与 AppKit] --> MacCore
    MacCLI[Swift CLI] --> MacCore
    MacUI --> MacPlatform[macOS 系统适配]
    MacCLI --> MacPlatform
    MacPlatform --> MacCore
    WinUI[WinUI 3 App - 待实现] --> VM[Presentation - 待实现]
    VM --> WinCore
    WinCLI[.NET CLI - 待实现] --> WinCore
    WinUI --> WinPlatform[Windows 系统适配 - 待实现]
    WinCLI --> WinPlatform
    WinPlatform --> WinCore
```

Core 声明自身需要的最小能力接口，Platform 实现这些接口，应用入口负责组装依赖。领域服务不依赖 UI 框架或具体适配器。两套原生实现分别落实同一份安全要求。

## 目录职责

| 路径 | 职责 | 状态 |
| --- | --- | --- |
| `apps/macos` | SwiftUI/AppKit 应用与 macOS 交互 | 已有源码 |
| `apps/cli` | macOS Swift 命令入口和终端确认 | 已有源码 |
| `packages/shou-core` | Swift 规则、扫描、计划与回执 | 已有源码 |
| `packages/shou-platform` | macOS 文件系统、访问、进程与持久化 | 已有源码 |
| `packages/shou-ai` | macOS 调查与模型通信 | 已有源码 |
| `packages/shou-contracts` | 语言无关的规则 Schema | 共享规范 |
| `apps/windows` | C# Core、Platform、Presentation、App 与 CLI | 规划中；当前只有 README |
| `tests/core` | Swift 领域与原生夹具回归 | 可执行 |
| `SYNC.md` | 跨端功能与安全验收 | 必须维护 |

Windows 目标工程树由实施方案定义。按实际能力增加接口与工程，不为未来功能预建空抽象，也不围绕 Swift 应用增加另一套构建系统。

## 共享资产

规则 Schema 的唯一来源为 `packages/shou-contracts/rule.schema.json`。内置规则与扫描位置 JSON 统一维护于 `packages/shou-core/Sources/Resources`，Windows 后续消费经过校验的生成副本。平台适用字段只描述数据范围，不代表对应平台已经支持运行。

文案当前唯一来源为 `packages/shou-core/Localizable.xcstrings`。Windows 资源生成器须转换稳定 key，并检查占位符、复数、回退与全部当前运行时语言。设计 token 将从确认过的 macOS 值提取为统一文件，再生成 Swift/XAML 资源。品牌资产放在 `assets/brand`。生成过程必须确定、可重复，并支持无差异校验。

共享验收案例描述输入证据、预期选择、阻断原因、确认与结果。文件身份、访问权限与竞态必须分别在原生环境验证。两个运行时不读取对方平台的本地记录。

## 变更流程

1. 阅读对应产品、安全与 Schema 合同。
2. 在 `SYNC.md` 记录 macOS 基线提交及逐项变化。
3. 在所属平台实现，从唯一来源生成共享资产。
4. 运行纯逻辑与受影响的原生检查，记录平台、架构、提交和证据。
5. 对各平台标明已实现、待实现、刻意差异或不适用，并写明理由。

即使 Windows 尚未实现，macOS 安全合同修复也必须登记对应对齐项。未完成验证的能力保持不可用。
