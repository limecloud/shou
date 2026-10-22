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

AppData 只允许资源内置的精确缓存根注册，变更仅限内置规则声明的缓存子树及其后代；浏览器资料、VS Code 用户数据和任意个人规则均不能扩大授权。缓存根匹配与绑定复用按 Windows 大小写、分隔符等价关系处理。发现和目标公平预算复用 macOS 算法，底层由平台提供不跟随链接的读取。已匹配但未完整测量的目录可单独继续扫描，界面仅替换所选目录的证据。

项目清理使用标准本地 Git 安装检查跟踪状态，通过原生进程身份和已验证的工作目录检查构建活动。Git 使用有界管道、期限、Job Object 和清理后的 Git 环境变量，不从工作目录或 PATH 解析程序。进程参数不可读、仓库中缺少 Git、证据变化或不支持的进程布局继续阻断清理。这些适配仍需 Windows 原生运行验收。

原生回收站失败不得退回永久删除；恢复不得覆盖已有目标。变更前核验当前目录树和文件身份，先持久化意图，再执行操作并写回结果。未知结果保留为未知，不自动重试。Windows 原生文件竞态、回收站回执与系统行为必须独立实测。

回收站和恢复默认关闭。只有隔离原生验收进程显式设置 `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1` 时才开启，不能作为正式用户开关。永久删除默认开放。清理页分别提供回收站与永久删除按钮；启用验收开关后，历史页提供恢复，以及单独确认后永久删除记录中的回收站项目。每次变更仍需审阅当前范围，永久删除无法恢复。

永久删除先核验完整清单，再以原生句柄固定全部已审阅对象，检查原始卷、完整 File ID、SID 和元数据，之后按子到父调用 `SetFileInformationByHandle` 删除已知条目，不递归通配删除。只有刚删除条目的直接父目录会更新本次操作造成的时间和大小变化基线，其余元数据继续核验。新子项会阻止目录删除。回收站 purge 同时固定并清除该项目对应的 `$I` 元数据记录。中途部分删除保留 unknown/pending 日志状态，阻止重试。

## 桌面进程协议

桌面桥与公开 CLI 共用核心，但不伪造终端输入，也不增加 `--yes`。桌面确认绑定本次进程中的操作、计划或回执摘要、具体选择、一次性挑战和有效期；版本、摘要或选择变化即拒绝。公开 CLI 继续要求当前范围的终端确认。

启动随包程序时使用绝对路径、参数数组、UTF-8 JSON、有界输入输出和明确错误码；stdout 仅用于协议，stderr 同时排空并限制保留量。只读请求可在取消或期限到达时终止自有进程。清理、恢复等变更请求通过协议请求协作取消，让核心在项目边界停止并保存回执；不能把超时当作没有发生变更。

请求为单行 JSON，包含 `bridge_version: 1`、唯一 `request_id`、`operation` 与对象 `input`。事件保留版本和请求 ID，以 `kind` 区分 `progress`、`confirmation`、`result`，业务内容放在 `value`。结果继续使用公开 CLI 的 `api_version: "1.0"` 信封。确认只接受当前审阅的挑战与摘要，取消和 EOF 使其失效；输入限 1 MiB，单事件限 8 MiB，客户端总输出限 64 MiB，确认有效期为 120 秒。

已连接能力与配置、工作区注册、`system.scan`/`system.clean`、`scan`/`scan.results`/`scan.target`、计划、分页历史与后续操作、个人规则预览/导入、`rules.set`/`rules.location-set`、排除，以及空间扫描/目录/分页/空间图/上下文/删除。`storage.large-files` 提供绑定查询的游标、大小/类型筛选及逐文件保护条件；WPF 大文件页复用空间删除计划、精确确认和回执。候选每页最多 100 项，大文件每页最多 500 项。删除计划最多接受 5,000 条明确路径，与 macOS 共享核心一致。该桥仍是内部传输，公开 CLI 的终端确认独立保留。

`cleanup.review` 复用 macOS 的 `CleanupReview`，提供分类→规则→目录投影、重叠根去重、补扫证据替换，以及可选/推荐数量和容量汇总。搜索、分类/规则范围及仅推荐筛选每页最多返回 500 个来源，后续分页位置绑定扫描 ID、补扫映射和查询摘要。WPF 独立保存具体选择，使翻页、切换分类和搜索保留选择，并提供分组三态和全部已选容量。高风险、未完整测量及其他阻断项目不会自动推荐。投影不授予执行权限，`system.clean` 仍建立并重新核验计划，拒绝重叠选择。

Windows 默认空间测量通过原生目录游标流式写入私有 SQLite，不受删除清单条目上限截断。目录工作每次只加载有界分页，先索引直接同级目录再深入测量。完整 128 位 File ID、卷和 owner SID 在持久化后保持一致，硬链接按完整对象身份去重。读取失败、重解析点、目录变化、深度/时间预算和取消均保留明确覆盖缺口或阻止发布。大文件删除审阅使用有界内存、可取消和有期限的增量摘要，不受元数据文件 16 MiB 读取限制。这些适配仍待 Windows 原生运行验收。

## 完成页与重试同步

WPF 完成遮罩遵循共享桌面合同。成功清理只显示完成图标、回执提供的实际容量（无法测量时显示处理数量）、简短结果说明和“完成”，不会强制用户进入历史。部分完成、取消、失败或待核验时，才显示“已处理、已跳过、失败项、需核实”统计，详情默认收起，并提供“重新扫描”“查看操作记录”“关闭”。重新扫描会清空过期候选并使用当前证据重新扫描，再创建新计划；不会重放旧计划。遮罩和回执字段与 macOS 的 `CleanupResultView` 对齐，CLI 或 AI Agent 可以依据同一组状态理解两个桌面端。

## 当前开发范围

| 能力 | 实现状态 |
| --- | --- |
| 原生目录选择、分页扫描、候选审阅 | WPF 源码与共享核心桥已连接 |
| 规则草稿、启停、全局排除增删 | 已连接；导入默认停用 |
| 完整内置规则目录及缓存规则控制 | 无需先选择目录即可浏览；缓存、个人/项目规则分别绑定范围 |
| 清理发现与单目录继续扫描 | 共享公平发现、精确目标读取及 `scan.target` 已连接 |
| 清理分组、搜索和选择 | 共享分类/规则/目录、跨根去重、分组三态、推荐选择及跨页选择已连接 |
| 大文件专用界面 | 扫描/复用分析、大小/类型筛选、分页、跨页选择、审核删除和历史已连接 |
| 目录空间分析 | 原生游标与私有 SQLite 保存完整 Windows 身份；旧有界快照保持可读 |
| 历史与冲突保护恢复 | 已连接；回收站与恢复默认关闭 |
| 系统回收站 | 原生实现；仅隔离验收进程显式开启 |
| 永久删除 | 清单绑定的原生删除、CLI、桌面审阅和记录中回收站项目的 purge 均已连接并开放 |
| 应用、启动项、隐私、内置 AI 界面、完整本地化与更新 | 尚未连接；界面仍为简体中文 |
| 项目 Git 归属与构建活动证据 | Windows 适配已实现；未知事实继续阻断，原生运行验收待完成 |

能力开放与发布验收分开记录。永久删除在开发版可用，回收站与恢复需要显式验收开关，正式发布仍需 Windows 运行与分发证据。

## 实现与验收顺序

1. 完成 Windows 构建、完整文件身份、私有记录存储和核心合同兼容。
2. 连接 WPF 界面，完成目录选择、规则、扫描、候选审阅和计划。
3. 用生成夹具验证明确确认、回收站、永久删除、历史、恢复、取消及故障回执。
4. 完成空间分析、大文件与排除交互，未接入能力按实际发现禁用。
5. 在 Windows 执行原生系统与界面验收，再验证签名、升级和干净系统安装。

`scripts/build-windows.ps1` 构建生产核心和 WPF，执行进程测试及原生永久删除协议夹具。当前 Swift 6.2.3 Windows 编译器在 `shou-windows-tests` 出现 SIL 崩溃，脚本暂时跳过该 target，不能将 ACL/junction/锁/回收站/安全证据专项计为已执行。`scripts/package-windows.ps1` 发布自包含 .NET，从显式指定的官方运行库目录复制 PE 依赖闭包与 SwiftPM 资源，记录 SHA-256，并在受限运行库搜索路径下执行能力发现。Windows 11 提供 `winsqlite3.dll`。构建细节见 [Windows 说明](../../../apps/windows/README.md)。

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

2026-10-22 的当前对齐工作与已发布的 v0.10.0 ZIP 分开记录。在 macOS 主机已验证：

- 使用仓库本地 .NET SDK 完成 WPF Release 交叉编译，0 警告、0 错误；不代表 Win32 界面运行。
- 13 项进程检查覆盖传输、确认、取消与只读请求期限；共享发现、单目录补扫及结果替换检查在 macOS 隔离夹具上通过。
- 原生 C++ 文件通过 x64 和 ARM64 严格交叉编译语法检查；Windows Swift 分支及原生测试源码通过显式选择分支的补充主机类型检查，不代表 Windows Foundation/SDK 编译或原生行为。
- 历史 Windows 成功运行 [39695066200](https://github.com/limecloud/shou/actions/runs/39695066200) 使用 `windows-2022`、提交 `185cec99954bd2d516533d9d6c40327965af7135`，验证过生产构建、原生协议夹具、ZIP/运行库闭包和 WPF 布局加载，早于当前工作区变更。

当前 Windows Swift 生产/原生专项构建、完整原生安全夹具、新 Windows CI、WPF 按钮旅程/辅助功能、Windows 11 干净安装、签名与升级仍需证据。完整 Windows/macOS 对齐尚未完成，回收站与恢复保持默认关闭。

## 内置 AI 对齐

WPF 已接入共享 AI 调查服务，覆盖开关、连接与 Credential Manager、三个协议、Jev 优先、问答、停止、本地记录和逐条规则预览。独立 CLI 同步提供全部 12 个 AI 命令。现有 Windows CI 的 Check 阶段新增合成 AI 合同检查；本轮原生 CI 尚待运行，不据交叉构建宣称 Windows 完整验收。详见[实现与证据](embedded-ai-implementation.md)及[验收矩阵](embedded-ai-acceptance.md)。
