# Windows 原生实现

[English](../../engineering/windows.md) | 简体中文

## 技术决策

Windows 使用 C#、.NET 10 LTS 和 WPF，采用 MVVM 分离视图与交互状态，使用 WPF 的 Fluent 主题。共享 Swift 核心继续负责规则、排除、扫描编排、计划、执行状态机和回执；Windows 界面通过版本化 JSON 进程协议访问随包 `shou.exe`。Win32/COM 仅放在平台适配层，不在 C# 复制规则引擎。

该路线参考知伴项目的原生界面、结构化进程桥与真实子进程测试实践。Shou 独立实现文件身份、清理确认、回收站和恢复，不继承知伴的数学阅读、WebView2、Python、网络接收或模型运行依赖。

首个验证目标是 Windows 11 x64。ARM64、旧版 Windows、网络卷、云端占位目录和跨卷操作分别验收，不能从工具链支持推断产品支持。

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

原生回收站失败不得退回永久删除；恢复不得覆盖已有目标。变更前核验当前目录树和文件身份，先持久化意图，再执行操作并写回结果。未知结果保留为未知，不自动重试。Windows 原生文件竞态、回收站回执与系统行为必须独立实测。

## 桌面进程协议

桌面桥与公开 CLI 共用核心，但不伪造终端输入，也不增加 `--yes`。桌面确认绑定本次进程中的操作、计划或回执摘要、具体选择、一次性挑战和有效期；版本、摘要或选择变化即拒绝。公开 CLI 继续要求当前范围的终端确认。

启动随包程序时使用绝对路径、参数数组、UTF-8 JSON、有界输入输出和明确错误码；stdout 仅用于协议，stderr 同时排空并限制保留量。只读请求可在取消或期限到达时终止自有进程。清理、恢复等变更请求通过协议请求协作取消，让核心在项目边界停止并保存回执；不能把超时当作没有发生变更。

## 实现与验收顺序

1. 完成 Windows 构建、完整文件身份、私有记录存储和核心合同兼容。
2. 连接 WPF 界面，完成目录选择、规则、扫描、候选审阅和计划。
3. 用生成夹具验证明确确认、回收站、历史、恢复、取消及故障回执。
4. 完成空间分析、大文件与排除交互，未接入能力按实际发现禁用。
5. 在 Windows 执行原生系统与界面验收，再验证签名、升级和干净系统安装。

发布包必须随包交付 .NET、Swift 运行库、SQLite 依赖与资源，普通用户运行不依赖开发工具链。开发目录、交叉编译成功、macOS 桥测试和 Windows CI 配置都不能代替干净系统安装证据。

## 官方依据

- [WPF 概览](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)
- [WPF Fluent 主题](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net90)
- [MVVM Toolkit](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/)
- [Swift Windows 工具链](https://www.swift.org/install/windows/)
- [Windows 文件身份](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)
- [Windows SID](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-identifiers)

## 验证状态

实现和本次检查结果在交付前补充。未取得 Windows 原生运行证据前，不声明 Windows 清理、恢复或正式分发已通过验收。
