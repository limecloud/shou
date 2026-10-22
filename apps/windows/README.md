# Shou Windows 原生客户端

C# / .NET 10 LTS / WPF Fluent / MVVM。规则、计划、排除与回执复用 Swift 核心，通过随包 `Engine/shou.exe --desktop-bridge` 通信。详细边界见 [Windows 实现文档](../../docs/zh-CN/engineering/windows.md)。

当前源码包括目录选择、分页扫描、单目录继续扫描、候选审阅、完整内置规则目录、个人规则导入与启停、全局排除、空间分析、独立大文件页和历史管理。清理结果复用 macOS 的分类→规则→目录投影、跨根去重、推荐选择、搜索和分层容量，三态与选择跨页保留。大文件支持大小与类型筛选、跨页选择、复用空间分析结果，以及单独确认后的删除。默认空间测量流式写入私有 SQLite，保存完整 Windows 身份并正确计量硬链接；大文件复核使用可取消、有期限的流式 SHA-256。Windows 已实现项目 Git 跟踪和按工作目录检查构建活动的原生适配；无法验证的事实继续阻断清理，原生运行验收仍待完成。可选内置 AI 提供默认关闭的 WPF 调查界面、独立连接、追问与逐条草稿预览，凭据存入 Windows 凭据管理器；原生 AI 交互仍需实机验收。启动项新增注册表、启动文件夹、登录／开机任务与可选服务盘点；确切当前用户任务支持确认后的启停和定义回读，其他来源保留系统管理入口，原生交互待验收。应用数据与孤立残留、自动更新及 Windows 原生验收仍未对齐。

设置页已接入跟随系统／简体中文／English、系统／浅色／深色外观、减少动态效果，以及扫描范围、规则、AI、本地数据、随包终端、支持与手动发布页入口。1005 条应用文案和 XAML 标签已接入中英目录，内置引擎文案复用共享资源；路径及个人规则保留原文。保存后外观立即应用，语言需确认后重新打开，运行操作或有待处理 AI 工作时不可重开。界面偏好独立保存至 `%LOCALAPPDATA%/Shou.Desktop/preferences.json`；高对比度和系统关闭动画设置优先。目录检查、隔离偏好检查与宿主构建通过，双语言布局、键盘和屏幕阅读器仍待 Windows 实机验收。

规则页与设置页的“使用外部 AI…”提供 Codex／Claude Code Skill 安装、项目父目录选择、WorkBuddy ZIP 导出、复制请求和资源位置。安装与导出分别绑定预览内容及明确确认，保留个人修改和受管旧版备份；ZIP 跨平台生成，不依赖 `ditto`。仅使用本机随包资源，不启动或配置外部 AI；设置页另提供用户 CLI 命令安装；Windows 客户端发现与实际上传仍待验收。

“设置 → 安装 CLI 命令”经预览和默认取消的确认后，创建 `%LOCALAPPDATA%/Shou/CLI/shou.exe`，调用当前完整发行目录中的引擎，保留参数、工作目录、标准流和退出码。安装不修改 PATH；可使用完整路径运行，无需管理员权限。相同安装不变，不覆盖已有不同内容；移动应用后需重新安装入口。原生启动器仅依赖 Kernel32，无需在用户入口旁复制 Swift／.NET 运行库。宿主安装夹具与交叉编译已通过，Windows 原生转发、控制台、WPF 安装和发行包探针仍待验收。

浏览器隐私页已接入标准 Chrome、Chromium、Edge、Brave 和 Firefox 配置的历史／Cookie 汇总扫描、四种时间范围、明确来源选择与脱敏回执。来源默认不选，Cookie 需要单独确认退出登录影响，最终审阅还需确认永久删除。隐私操作复用共享核心的来源白名单、身份复核、事务及过期计划保护，使用独立授权，不扩大普通缓存清理的 AppData 范围。生成夹具协议及宿主构建已通过，Windows 原生 ACL、数据库句柄和界面验收仍待完成；支持范围见[隐私清理](../../docs/zh-CN/engineering/privacy-cleaning.md)。

候选目录支持右键菜单及可通过键盘访问的定位、复制路径、空间分析、AI 审阅与排除操作。路径及排除范围取自该行来源工作区，跨根扫描不依赖页首所选目录；排除后清空旧结果并要求重新扫描。打开 AI 页不会自行发送请求。空间分析提供独立的回收站和永久删除按钮，共用确认及回执处理；回收站仍按核心能力启用，默认关闭。新增生成夹具已在 macOS 验证空间回收站取消、确认及确切恢复，Windows 实机交互和恢复仍待验收。

清理页新增“关闭占用应用并刷新…”：从当前扫描的受阻内置规则推导应用，审阅确切进程后只请求正常关闭，允许应用保留保存提示或拒绝退出。随后复核活动并局部重扫，保留其他目录的选择；取消或刷新失败会清除受影响的旧证据。文件清理仍需另行确认，不会自动执行。CLI `system close-owners --scan-id <id>` 使用同一服务。Windows 原生窗口行为及 WPF 交互尚待验收。

“工具存储”页新增 Docker 本机构建缓存、Conda 缓存和非当前 Rust 工具链的主动检查、影响审阅、逐项永久清理、停止和回执。固定操作由所属工具执行，不进入回收站；取消或失败后须先核实实际结果。执行绑定审阅的工具文件身份，不经过 shell，不自动重试；Docker 固定连接支持的本机命名管道，保留镜像、容器与卷。CLI `tools scan/plan/execute/history` 已开放。自定义安装根及远端 Docker 不在当前范围，Homebrew 为 macOS 专属。Windows 原生及界面验收仍待完成。

回收站和恢复默认关闭；仅隔离原生验收可显式设置 `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1`。永久删除默认开放，且与回收站项目 purge 均需单独范围确认，无法恢复。AppData 只为资源内置的精确缓存根开放注册，只允许声明的缓存子树参与变更，浏览器资料、VS Code 用户数据和其他 AppData 位置继续受保护。Windows 当前有 23 个固定缓存位置，新增 Chromium、Obsidian、GitHub Desktop 和 Insomnia；笔记库、仓库、请求数据库和账户存储均保留，应用运行或无法核验时阻断清理。完整 Windows 界面、原生安全边界、安装升级与无障碍体验仍需实机验收。

个人规则新增三步创建向导、保存前只读预览、完整 JSON 新版本编辑和独占导出。声明、边界和版本校验继续由共享核心负责；新版本保持停用，旧绑定保留。修改字段或配置变化后须重新校验／预览。规则页提供内置／个人来源筛选、保存当前工作区启用的规则选择和重新扫描，以及全局／工作区／项目排除；项目模式留空可保护整个项目，继承的全局排除单独展示。使用保存的选择不会自动启用已停用的规则。这些界面仍待 Windows 实机验收。

应用页支持当前用户／全机的 32／64 位卸载注册及当前用户 MSIX 盘点，提供搜索、来源筛选、版本／发布者、登记大小估计、来源覆盖及 Windows 设置入口。最多明确选择 20 个应用，审阅所属安装器与数据影响后一次确认卸载，并保存逐项回执。MSI 独立核验产品元数据，EXE 绑定审阅身份，MSIX 交给包管理器；整个应用保持普通权限，必要时由 Windows 展示安装器本次 UAC。停止只结束等待，结果不明时不继续下一项、不自动重试。CLI `applications installer scan/plan/show/execute/history` 使用同一流程；只读 `applications list` 保持不打开清理存储。登记大小不代表实测占用；原生卸载与界面仍待 Windows 验收。

“应用数据与残留”单独检查 16 类应用的 17 个默认个人数据根，可仅查看声明登记来源未发现的残留，也可审阅已登记应用的数据。默认不勾选、不授予个人数据同意；同意后仍需逐项选择并再次确认永久清理，不能恢复。执行前重新核验完整登记来源、应用活动、目录身份、内容、排除规则及期限，逐项结果进入共享历史，关闭窗口后刷新历史。CLI 提供 `applications data scan/plan/show/execute`。普通缓存清理继续保留这些完整数据根；该目录流程不处理 MSIX，已登记包使用下述独立操作。未登记 MSIX 残留、自定义／便携安装、其他账户和未声明应用尚未覆盖，不能视为完整应用残留对齐。Windows 原生权限、链接与界面仍待实机验收。

“清空所选 MSIX 数据…”只处理明确选择的 1–20 个当前用户已登记包，由 Windows 官方应用数据 API 清空整包的本地、漫游、临时数据和设置，保留安装。另行确认展示应用名、版本、包系列和数据根，个人数据同意默认不勾选；系统内置／未知来源、依赖包、Shou 自身和仍在运行的包受保护。文件清理排除规则不限制整包操作，需要保留任何内容时应取消。计划 120 秒过期，整组及逐项复核、启动前持久化意图；停止只结束等待，结果不明时不继续、不自动重试。独立记录不报告释放空间。CLI 为 `applications package-data scan/plan/show/execute/history`，执行需 `CLEAR MSIX <plan-id>`。Windows Check 仅运行拒绝协议和七项原生输入／启动前取消夹具，不调用包 API 或清理已安装数据；正向包 API、WTS 活动、ACL、双语言 WPF／发行探针仍待 Windows 验收。

历史支持逐项勾选、全选可操作项、清空及已选容量，恢复／永久删除仅确认所选子集，每次最多 500 项。独立“核验位置”窗口只读检查记录的原始与回收站位置，显示内容变化、缺失、冲突、未结束状态及无法核验原因，支持重新检查和关闭取消；核验不重试操作，也不解除未知结果的限制。清理、空间与大文件的大小列按原始数值排序。Windows CLI 帮助及 capabilities 同步展示已实现的启动项命令。这些交互仍待 Windows 实机验收，回收站和恢复保持默认关闭。

“回收扫描记录…”先显示可回收数量、容量与保留范围，由用户确认后再重新检查并执行。没有候选或有核验问题时不能回收，默认按钮为“取消”。仅处理 Shou 的过期或超限派生记录，活跃计划、最新扫描、清理历史、恢复数据与用户文件保留。取消或通信失败不自动重试。

“扫描范围”页列出自动项目、额外目录和内置缓存，提供搜索、来源筛选、可用状态、包含目录及复制路径。停止包含仅适用于额外目录，需确认当前路径和配置版本；文件、规则定义及历史保留，绑定、预设与该工作区排除解除。确认期间配置变化会拒绝注销。

空间分析补充前进／后退、面包屑、完整目录名称搜索、分页和选择可见项目；父子选择复用共享核心，部分勾选与容量不重复计数，导航和搜索保留选择，新扫描清空。名称搜索覆盖当前目录的全部直接子项，续页绑定扫描、目录及查询；输入修改后需按 Enter 或“搜索”更新结果。逐项保护原因、覆盖详情、复制完整路径与资源管理器定位已接入。首次结果和浏览每页最多 200 项，选择最多 5,000 个不重叠范围，超限展开整体拒绝。

空间和大文件页共用只读预览：UTF-8／UTF-16 文本最多读取开头 256 KiB，PNG／JPEG／GIF／BMP 最多 4 MiB；PDF、Office／ODF、RTF、常见音视频及 TIFF／WebP／HEIC 接入 Windows 已注册的系统预览组件。组件在独立工作进程或 COM 宿主中运行，预览绑定扫描身份，生命周期内固定文件及祖先句柄，拒绝链接、占位项、文件替换和并发写入；优先只读流，兼容仅接受文件路径的组件。启动限时 10 秒，成功显示后持续至关闭；关闭会结束自有工作进程。未安装组件、超时或其他不支持格式会保留文件信息，不启动文件关联应用，不向 AI 提供内容。大文件页另支持复制路径和资源管理器选中文件。原生流夹具已加入 Windows Check，包探针检查隐藏预览窗口的创建和释放；两者均不激活已安装组件。真实 PDF／Office／媒体组件、键盘焦点及辅助功能仍待 Windows 实机验收，不能据此认定与 Quick Look 完全对齐。

清理、空间分析和大文件页显示所在磁盘的总量／当前用户可用空间及使用比例。清理跟随所选目录，空间分析跟随当前目录，大文件跟随已应用的扫描根；按实际路径查询以支持挂载卷和用户配额。视图加载、路径变化、应用重新激活与清理完成会刷新，也可手动刷新。容量不可用时明确提示，不用扫描估算值替代；移入回收站不会立即释放磁盘空间。Windows 原生容量与界面仍待验收。

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

正常关闭应用另有独立 C++ 产品，不依赖上述 Swift 专项。在普通用户的交互式 Windows 会话中执行：

```powershell
./scripts/build-windows.ps1 -NativeClosingFixtures
```

工具 runner 同样提供独立生成夹具，可另行执行 `./scripts/build-windows.ps1 -NativeToolFixtures`。它只启动自己生成的 rustup.exe，覆盖工具身份变化、选项拒绝、取消、输出上限、失败退出和后台子进程超时，不调用已安装的工具。默认 Build 构建夹具，默认 Check 只检查协议输入和能力发现；普通用户的原生运行结果与 WPF 工具页布局仍需 Windows 验收。

卸载另有独立生成夹具，普通用户 Windows 会话可执行 `./scripts/build-windows.ps1 -NativeUninstallFixtures`。它仅启动私有目录内复制生成的 EXE，注册重定向只作用于夹具进程；覆盖注册／操作／镜像变化拒绝、取消、退出码和超时后继续运行，不调用已安装卸载器、MSI 卸载或 MSIX 变更。默认 Check 不启动卸载器。管理员返回未运行，不能计为通过；真实 MSI／MSIX、UAC 及 WPF 卸载交互仍需单独验收。

默认 Build 会构建 `shou-windows-closing-checks`，默认 Check 仅验证关闭请求的输入／能力边界；该开关额外运行独占生成的测试窗口，验证身份变化与整组预检拒绝、取消、正常关闭和拒绝退出。它不会选择真实 VS Code 进程，不会强制结束任何应用。管理员会话会报告正向验收未执行并使检查失败，应改用普通用户会话。WPF 包探针另检查局部失效和无关选择保留；这些源码与交叉编译均不能替代 Windows 实机结果。

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
