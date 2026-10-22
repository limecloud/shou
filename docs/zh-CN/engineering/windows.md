# Windows 开发

[English](../../engineering/windows.md) | 简体中文

状态：架构已确定，实现尚未开始。当前没有可用的 Windows 构建、安装包或更新源。

Shou Windows 端采用 C#、.NET 10 LTS 与 Windows App SDK 的 WinUI 3。桌面和 CLI 直接调用同一套 C# 领域服务。代码编辑和纯 .NET 测试在 macOS 完成；Windows 构建和运行验证在 Windows 完成。

| 需要了解 | 阅读入口 |
| --- | --- |
| 架构、工程目录、实施阶段 | [Windows 原生实施方案](windows-native-plan.md) |
| 平台职责和共享资源 | [Monorepo 边界](../architecture/monorepo-and-platforms.md) |
| 产品和安全行为 | [PRD](../product/prd.md)、[清理安全](../security/cleanup-safety.md) |
| 运行、研发与发布时序 | [流程与时序](../architecture/workflows-and-sequences.md) |
| 功能对齐与验证 | [SYNC.md](../../../SYNC.md) |

首个交付物是 x64、ARM64 上经过签名、可独立运行的 WinUI 窗口，随后完成只读扫描和确定性 Core 测试。具有破坏性的能力须通过独立原生验收后才能开放。各阶段退出条件见实施方案。
