# Windows development

English | [简体中文](../zh-CN/engineering/windows.md)

Status: architecture approved; implementation has not started. Windows builds, installers and update feeds are not available.

Shou for Windows uses C#, .NET 10 LTS and WinUI 3 from Windows App SDK. The GUI and CLI call the same C# domain services directly. Source editing and portable tests run on macOS; Windows builds and runtime checks run on Windows.

| Need | Read |
| --- | --- |
| Architecture, project layout and implementation stages | [Windows native implementation plan](windows-native-plan.md) |
| Platform ownership and shared resources | [Monorepo boundaries](../architecture/monorepo-and-platforms.md) |
| Product and safety behavior | [PRD](../product/prd.md), [cleanup safety](../security/cleanup-safety.md) |
| Runtime, development and release sequences | [Workflows and sequences](../architecture/workflows-and-sequences.md) |
| Feature parity and verification | [SYNC.md](../../SYNC.md) |

The first deliverable is a signed, self-contained WinUI shell on both x64 and ARM64, followed by a read-only scan and deterministic Core tests. Destructive capabilities require their own native acceptance before being enabled. See the plan for stage exit criteria.
