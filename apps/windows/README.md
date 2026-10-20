# Shou Windows 原生客户端

C# / .NET 10 LTS / WPF Fluent / MVVM。规则、计划、排除与回执复用 Swift 核心，通过随包 `Engine/shou.exe --desktop-bridge` 通信。详细边界见 [Windows 实现文档](../../docs/zh-CN/engineering/windows.md)。

首版包括目录选择、分页扫描、候选审阅、规则导入与启停、全局排除增删、目录空间分析和历史恢复。界面目前为简体中文；大文件专用页面、应用卸载、启动项、隐私清理、Windows 生成源码安全证据与完整语言切换尚未接入。Rust/Swift 产物缺少原生 Git/构建活动证据时保持阻断。

Windows 原生回收站代码需要实机验证，开发版默认关闭清理与恢复，永久删除始终不可用。`SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1` 仅用于隔离夹具验证，不代表发布验收通过。

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

默认检查私有 ACL、完整身份、Unicode、预算、junction 拒绝、原子记录和跨进程锁。真实回收站与恢复检查只操作新生成的临时夹具：

```powershell
$env:SHOU_WINDOWS_EXPERIMENTAL_RECYCLE = "1"
$bin = (swift build --package-path "../.." -c release --show-bin-path).Trim()
& (Join-Path $bin "shou-windows-tests.exe") --recycle
```

记录 Windows 版本、卷格式、回收站设置、普通用户权限和失败/冲突/中断行为。无 Windows 图形会话的 CI 只运行默认检查，不声称回收站或 UI 验收通过。

macOS 可单独验证 WPF 编译和真实进程合同：

```sh
dotnet build "apps/windows/Shou.slnx" -c Release
dotnet run --project "apps/windows/Shou.Windows.Checks" -c Release -- --engine "/absolute/path/to/shou"
python3 -B "scripts/verify-desktop-bridge.py" --engine "/absolute/path/to/shou"
```

## 开发包

在 Windows 仓库根执行，显式提供官方 Swift 与 VC++ 可再分发 DLL 目录：

```powershell
./scripts/package-windows.ps1 -EngineExecutable "C:/build/release/shou.exe" -SwiftRuntimeDirectory "C:/official/swift/runtime", "C:/official/vc/redist/x64" -OutputDirectory "C:/artifacts/Shou-windows-dev"
```

脚本生成自包含 .NET 应用，按 PE 导入闭包复制 Swift/VC 依赖与 SwiftPM 资源，校验受限 PATH 下的能力发现，记录文件 SHA-256。Windows 11 提供 `winsqlite3.dll`。运行库再分发许可、签名、干净系统安装、升级和卸载仍需独立验收。

```text
Shou.exe
Engine/
  shou.exe
  *.dll
  *.resources/
files.sha256.json
```

该目录是开发产物，尚未提供正式安装器。
