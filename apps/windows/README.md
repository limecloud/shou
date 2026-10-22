# Shou Windows 原生客户端

C# / .NET 10 LTS / WPF Fluent / MVVM。规则、计划、排除与回执复用 Swift 核心，通过随包 `Engine/shou.exe --desktop-bridge` 通信。详细边界见 [Windows 实现文档](../../docs/zh-CN/engineering/windows.md)。

当前源码包括目录选择、分页扫描、单目录继续扫描、候选审阅、完整内置规则目录、个人规则导入与启停、全局排除、空间分析、独立大文件页和历史管理。清理结果复用 macOS 的分类→规则→目录投影、跨根去重、推荐选择、搜索和分层容量，三态与选择跨页保留。大文件支持大小与类型筛选、跨页选择、复用空间分析结果，以及单独确认后的删除。默认空间测量流式写入私有 SQLite，保存完整 Windows 身份并正确计量硬链接；大文件复核使用可取消、有期限的流式 SHA-256。Windows 已实现项目 Git 跟踪和按工作目录检查构建活动的原生适配；无法验证的事实继续阻断清理，原生运行验收仍待完成。可选内置 AI 提供默认关闭的 WPF 调查界面、独立连接、追问与逐条草稿预览，凭据存入 Windows 凭据管理器；原生 AI 交互仍需实机验收。启动项新增注册表、启动文件夹、登录／开机任务与可选服务盘点；确切当前用户任务支持确认后的启停和定义回读，其他来源保留系统管理入口，原生交互待验收。应用卸载、隐私清理、完整语言切换与更新尚未对齐。

回收站和恢复默认关闭；仅隔离原生验收可显式设置 `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1`。永久删除默认开放，且与回收站项目 purge 均需单独范围确认，无法恢复。AppData 只为资源内置的精确缓存根开放注册，只允许声明的缓存子树参与变更，浏览器资料、VS Code 用户数据和其他 AppData 位置继续受保护。完整 Windows 界面、原生安全边界、安装升级与无障碍体验仍需实机验收。

个人规则新增三步创建向导、保存前只读预览、完整 JSON 新版本编辑和独占导出。声明、边界和版本校验继续由共享核心负责；新版本保持停用，旧绑定保留。修改字段或配置变化后须重新校验／预览。规则页提供内置／个人来源筛选、保存当前工作区启用的规则选择和重新扫描，以及全局／工作区／项目排除；项目模式留空可保护整个项目，继承的全局排除单独展示。使用保存的选择不会自动启用已停用的规则。这些界面仍待 Windows 实机验收。

应用页新增只读盘点：当前用户／全机的 32／64 位卸载注册及当前用户 MSIX 包，支持搜索、来源筛选、版本和发布者、安装程序登记的大小估计、来源覆盖及 Windows“已安装的应用”入口。CLI `applications list` 读取同一事实源。注册大小不代表实测占用；MSIX 大小和卸载可用性保持未知。该入口没有接入直接卸载、应用数据归属或孤立残留清理，当前原生盘点仍待 Windows 运行验收。

历史支持逐项勾选、全选可操作项、清空及已选容量，恢复／永久删除仅确认所选子集，每次最多 500 项。独立“核验位置”窗口只读检查记录的原始与回收站位置，显示内容变化、缺失、冲突、未结束状态及无法核验原因，支持重新检查和关闭取消；核验不重试操作，也不解除未知结果的限制。清理、空间与大文件的大小列按原始数值排序。Windows CLI 帮助及 capabilities 同步展示已实现的启动项命令。这些交互仍待 Windows 实机验收，回收站和恢复保持默认关闭。

“扫描范围”页列出自动项目、额外目录和内置缓存，提供搜索、来源筛选、可用状态、包含目录及复制路径。停止包含仅适用于额外目录，需确认当前路径和配置版本；文件、规则定义及历史保留，绑定、预设与该工作区排除解除。确认期间配置变化会拒绝注销。

空间分析补充前进／后退、面包屑、完整目录名称搜索、分页和选择可见项目；父子选择复用共享核心，部分勾选与容量不重复计数，导航和搜索保留选择，新扫描清空。名称搜索覆盖当前目录的全部直接子项，续页绑定扫描、目录及查询；输入修改后需按 Enter 或“搜索”更新结果。逐项保护原因、覆盖详情、复制完整路径与资源管理器定位已接入。首次结果和浏览每页最多 200 项，选择最多 5,000 个不重叠范围，超限展开整体拒绝。

空间和大文件页共用本地只读预览：UTF-8／UTF-16 文本最多读取开头 256 KiB，PNG／JPEG／GIF／BMP 最多 4 MiB；目录、PDF／Office、其他不支持格式和可执行文件显示扫描快照信息。预览读取核验文件身份并拒绝链接和云端占位项，关闭窗口会取消；不运行关联程序或将内容发送给 AI。大文件页另支持复制完整路径和资源管理器选中文件。当前预览覆盖尚未达到 macOS Quick Look；Windows 原生交互仍待验收。

## 下载

[Shou v0.10.0 · Windows 11 x64 便携 ZIP](https://github.com/limecloud/shou/releases/download/v0.10.0/Shou-0.10.0-windows-x64.zip)。完整解压后运行 `Shou.exe`，保留同目录的 `Engine` 和资源文件。包内包含 .NET、Swift 与所需 VC 运行库，无需安装开发工具；使用 Release 中的 `SHA256SUMS` 校验下载。便携包未签名，暂无安装器及 Windows 自动更新。

2026-10-22 核查时，v0.11.0 发布流水线失败，尚无对应 Release；当前已发布下载仍为 v0.10.0，不包含本轮未提交功能。具体构建故障、修复状态及功能差异见 [Windows 验证状态](../../docs/zh-CN/engineering/windows.md#验证状态)。

版本 ZIP 由对应标签的跨平台发布流水线构建，发布前须通过包校验与进程协议检查。

## 构建

在 Windows x64、PowerShell 7 中安装官方 Swift 6.2.3 Windows 工具链（含匹配的 Visual Studio C++/Windows SDK）、.NET SDK 10.0.401 和 Python 3.12。Python 仅用于开发验证，应用运行不需要 Python。

仓库根执行：

```powershell
./scripts/build-windows.ps1
```

在 `apps/windows` 运行界面：

```powershell
$bin = (swift build --package-path "../.." -c release --show-bin-path).Trim()
dotnet run --project "Shou.Windows" -- --engine (Join-Path $bin "shou.exe")
```

`--engine` 必须是 CLI 的绝对路径。正常包使用应用旁的 `Engine/shou.exe`，不搜索系统 PATH，不申请管理员权限。

## 原生夹具验证

原生专项源码覆盖私有 ACL、完整身份、Unicode、预算、junction 拒绝、原子记录、跨进程锁、Git 跟踪、项目进程工作目录、流式空间索引及超过 16 MiB 文件的摘要与删除。夹具在用户目录下新建随机隔离目录，避免依赖受保护 AppData 中的临时目录。当前 Swift 6.2.3 Windows 工具链存在该专项 target 的 SIL 编译崩溃，构建脚本仍暂时跳过它；成功的进程协议检查不能代替这些专项。恢复专项编译后，真实回收站与恢复检查需在 Windows 会话中单独运行，只操作新生成的临时夹具：

```powershell
$bin = (swift build --package-path "../.." -c release --show-bin-path).Trim()
$env:SHOU_WINDOWS_EXPERIMENTAL_RECYCLE = "1"
& (Join-Path $bin "shou-windows-tests.exe") --recycle
```

记录 Windows 版本、卷格式、回收站设置、普通用户权限和失败/冲突/中断行为。当前 CI 执行生产引擎的永久删除协议夹具和进程检查，不声称完整原生专项、回收站或 UI 操作验收通过。

macOS 可单独验证 WPF 编译和真实进程合同：

```sh
dotnet build "apps/windows/Shou.slnx" -c Release
dotnet run --project "apps/windows/Shou.Windows.Checks" -c Release -- --engine "/absolute/path/to/shou"
python3 -B "scripts/verify-desktop-bridge.py" --engine "/absolute/path/to/shou"
```

给该集成脚本增加 `--native-trash --native-permanent`，可用新生成的目录验证回收站、历史、恢复、直接永久删除及记录中回收站项目的单独 purge；不会选中真实工作区文件。macOS 上通过此闭环仍不能替代 Windows 原生证据。

## 便携包

在 Windows 仓库根执行，显式提供官方 Swift 与 VC++ 可再分发 DLL 目录：

```powershell
./scripts/package-windows.ps1 -EngineExecutable "C:/build/release/shou.exe" -SwiftRuntimeDirectory "C:/official/swift/runtime", "C:/official/vc/redist/x64" -OutputDirectory "C:/artifacts/Shou-windows-dev"
```

打包需要工具链中的 `llvm-readobj`。脚本生成自包含 .NET 应用，按 PE 导入闭包复制 Swift/VC 依赖与 SwiftPM 资源，校验受限 PATH 下的能力发现，记录文件 SHA-256。Windows 11 提供 `winsqlite3.dll`。运行库再分发许可、签名、干净系统安装、升级和卸载仍需独立验收。

```text
Shou.exe
Engine/
  shou.exe
  *.dll
  *.resources/
files.sha256.json
```

GitHub Windows CI 在编译与原生协议检查后调用 `scripts/release-windows.ps1`，发现官方运行库、打包 ZIP 并在移位后的中文路径下验证文件清单、受限 PATH、版本、资源、WPF 布局加载与原生桌面协议。主干检查保留 ZIP 资产，版本发布将该 ZIP 与 macOS 资产汇总到同一个 Release；统一 `SHA256SUMS` 覆盖两个平台。暂无正式安装器。
