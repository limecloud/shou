# Windows 原生实现

[English](../../engineering/windows.md) | 简体中文

## 技术决策

Windows 使用 C#、.NET 10 LTS 和 WPF，采用 MVVM 分离视图与交互状态，使用 WPF 的 Fluent 主题。共享 Swift 核心继续负责规则、排除、扫描编排、计划、执行状态机和回执；Windows 界面通过版本化 JSON 进程协议访问随包 `shou.exe`。Win32/COM 仅放在平台适配层，不在 C# 复制规则引擎。

该路线参考知伴项目的原生界面、结构化进程桥与真实子进程测试实践。Shou 独立实现文件身份、清理确认、回收站和恢复，不继承知伴的数学阅读、WebView2、Python、网络接收或模型运行依赖。

首个验证目标是 Windows 11 x64。ARM64、旧版 Windows、网络卷、云端占位目录和跨卷操作分别验收，不能从工具链支持推断产品支持。

已审阅知伴的 `AgentProcessClient.cs`（参数数组、同时排空管道、有界严格 JSON）、`WorkspaceClient.cs`（能力发现）、`zhiban_io.c`（原生锁与持久记录）及其 Windows 验收文档。该项目同样把 macOS 交叉构建与 Windows 运行、分发验收分开记录。

## 工程职责

| 位置 | 职责 |
| --- | --- |
| `apps/windows/Shou.Windows` | WPF 页面、原生目录选择、明确确认、扫描与历史交互 |
| `apps/windows/Shou.Windows.Services` | 有界进程通信、合同验证、能力发现和类型化界面模型 |
| `apps/windows/Shou.Windows.Checks` | 真实进程管道、确认拒绝和共享核心集成测试 |
| `apps/cli` | 独立 CLI 与桌面桥；装配当前平台实现 |
| `packages/shou-core` | 唯一领域实现与语言无关状态语义 |
| `packages/shou-platform` | Windows 文件系统、私有存储与原生操作适配 |
| `packages/windows-native` | 最小 Win32/COM C 接口，供 Swift 调用 |

## 文件系统与安全

Windows 文件证据保存卷序列号、完整 128 位 File ID 与所有者 SID，不能截断为 POSIX inode/UID。旧 macOS 记录保持可读，Windows 不使用 macOS 根目录重挂载兼容规则。记录根使用当前用户私有 ACL、稳定的跨进程锁、原子替换和持久写入。

扫描不跟随 junction、符号链接、挂载点或未知重解析点，不读取云端占位文件以触发下载。权限拒绝、预算耗尽和不完整遍历必须保留为部分结果，不能据此授权未完整测量的目标。

首版拒绝大小写敏感目录，避免将其误报为大小写不敏感。仅接受固定本地驱动器路径，拒绝 UNC/设备路径、替代数据流与保留设备名。系统目录、用户资料根、敏感目录、已配置的 OneDrive 根和 Shou 记录受保护。

原生回收站失败不得退回永久删除；恢复不得覆盖已有目标。变更前核验当前目录树和文件身份，先持久化意图，再执行操作并写回结果。未知结果保留为未知，不自动重试。Windows 原生文件竞态、回收站回执与系统行为必须独立实测。

## 桌面进程协议

桌面桥与公开 CLI 共用核心，但不伪造终端输入，也不增加 `--yes`。桌面确认绑定本次进程中的操作、计划或回执摘要、具体选择、一次性挑战和有效期；版本、摘要或选择变化即拒绝。公开 CLI 继续要求当前范围的终端确认。

启动随包程序时使用绝对路径、参数数组、UTF-8 JSON、有界输入输出和明确错误码；stdout 仅用于协议，stderr 同时排空并限制保留量。只读请求可在取消或期限到达时终止自有进程。清理、恢复等变更请求通过协议请求协作取消，让核心在项目边界停止并保存回执；不能把超时当作没有发生变更。

请求为单行 JSON，包含 `bridge_version: 1`、唯一 `request_id`、`operation` 与对象 `input`。事件保留版本和请求 ID，以 `kind` 区分 `progress`、`confirmation`、`result`，业务内容放在 `value`。结果继续使用公开 CLI 的 `api_version: "1.0"` 信封。确认只接受当前审阅的挑战与摘要，取消和 EOF 使其失效；输入限 1 MiB，单事件限 8 MiB，客户端总输出限 64 MiB，确认有效期为 120 秒。

已连接 `capabilities`、`configuration`、`workspace.add`、`scan`、`scan.results`、`plan`、`plan.execute`、`history`、`history.restore`、`rules.import`、`rules.set`、`exclusions.set`、`storage.scan`、`storage.directory`。候选每页最多 100 项。该桥属于桌面内部传输，公开 CLI 的终端确认独立保留。

## 当前开发范围

| 能力 | 实现状态 |
| --- | --- |
| 原生目录选择、分页扫描、候选审阅 | WPF 源码与共享核心桥已连接 |
| 规则草稿、启停、全局排除增删 | 已连接；导入默认停用 |
| 目录空间分析 | 有界内存遍历与导航；尚无流式 SQLite catalog |
| 历史与冲突保护恢复 | 已连接；变更能力默认关闭 |
| 系统回收站 | 原生实验实现；仅隔离 Windows 验证设置 `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1` |
| 永久删除 | Windows 不可用，直接调用平台接口也拒绝 |
| 应用、启动项、隐私、大文件专用 UI、完整本地化 | 尚未连接；首版界面为简体中文 |
| Rust/Swift 生成源码归属与活动证据 | Windows 不可用，相关内置候选保持阻断 |

尚未取得 Windows 运行证据的原生实现不能直接授权正式清理，因此保留此开发门槛。

## 实现与验收顺序

1. 完成 Windows 构建、完整文件身份、私有记录存储和核心合同兼容。
2. 连接 WPF 界面，完成目录选择、规则、扫描、候选审阅和计划。
3. 用生成夹具验证明确确认、回收站、历史、恢复、取消及故障回执。
4. 完成空间分析、大文件与排除交互，未接入能力按实际发现禁用。
5. 在 Windows 执行原生系统与界面验收，再验证签名、升级和干净系统安装。

`scripts/build-windows.ps1` 构建核心和 WPF，执行原生生成夹具、进程测试和真实协议集成。`scripts/package-windows.ps1` 发布自包含 .NET，从显式指定的官方运行库目录复制 PE 依赖闭包与 SwiftPM 资源，记录 SHA-256，并在受限运行库搜索路径下执行能力发现。Windows 11 提供 `winsqlite3.dll`。构建细节见 [Windows 说明](../../../apps/windows/README.md)。

普通用户运行不应依赖开发工具链。开发目录、交叉编译成功、macOS 桥测试和 Windows CI 配置不能代替干净系统安装证据；运行库再分发许可、签名、安装器、升级与卸载仍需验收。

Windows GitHub 工作流分别检查静态资源、Swift/WPF 原生构建和生成夹具及真实进程合同。`scripts/build-windows.ps1 -Stage Build` 与 `-Stage Check` 对应构建和验证，省略 `-Stage` 时两者都会执行。.NET SDK 以 `apps/windows/global.json` 为准，Swift 与 Python 版本在工作流中声明。任一检查失败都不会上传开发产物，同一引用的新运行会取消旧运行。

## 官方依据

- [WPF 概览](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)
- [WPF Fluent 主题](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net90)
- [MVVM Toolkit](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/)
- [Swift Windows 工具链](https://www.swift.org/install/windows/)
- [Windows 文件身份](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)
- [Windows SID](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-identifiers)
- [IFileOperation](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ifileoperation)
- [LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex)

## 验证状态

已在 macOS arm64、Swift 6.2.3、.NET SDK 10.0.401 验证：

- WPF 完整 solution 编译通过，0 警告、0 错误；这只验证编译，不代表 Windows 界面和交互通过。
- 11 项真实进程桥测试通过，覆盖 UTF-8、输出限额、严格 JSON、超时、确认和变更协作取消。
- 真实 Swift 协议通过 105 目录分页、停用导入与启用、排除、空间导航、拒绝/外来挑战/错误摘要/EOF 确认，以及生成夹具上的 macOS 废纸篓→历史→恢复闭环。
- 核心回归 191/191 通过，包含完整 Windows 身份与 SID 语义、旧记录兼容、卷变化绑定拒绝和未知结果回执及防重试。
- 文档配对与本地链接检查通过。

本环境未执行 Windows Swift/C++ 编译、原生 ACL/junction/锁/回收站夹具、PowerShell 构建打包脚本、Windows CI、WPF 界面与辅助功能、Windows 11 干净安装、签名和升级。因此回收站能力保持默认关闭，不能将当前实现声明为已验收的 Windows 清理、恢复或正式发布版本。
