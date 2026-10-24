# 快速复用与驱动

## 开始即用

仓库 helper 为 `.agents/skills/shou-windows-cloud-test/scripts/wuying.py`，从仓库根目录执行，不依赖第三方 Python 包。先执行 `status`；它从技能外的 `account.json` 和 `active-desktop.json` 读取元数据，核对地域、桌面、用户、办公网络及按量计费。不存在的历史实例会拒绝，不自动重购。

省钱默认：**在 Mac 完成本地实现和对齐后，才开机集中测试**。本次要求释放时不能沿用历史保留偏好；选择保留一天时读取本次 `retain_until`。在本地改代码、比对 Mac 或修改技能时无需先 `start`。下面的开机命令仅在 Windows 验收准备完成后执行。关机保留不自动展期，也不代表已创建定时释放任务。

```sh
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" status
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" start
```

`start`/`stop` 最多等待 45 秒，超时后用 `status` 继续观察；不要因还在转换中重复投递。新建或用户明确选择另一台之后才使用 `adopt <本次ID> --cloud-root 'C:/Users/Public/ShouTest-<run>' --evidence-run '<run>'`，登记经过核对的实例。创建参数仍以当前官方 metadata 和模板为准，见 [CLI 参考](aliyun-cli.md)。

## 本地客户端连接

使用已安装新版无影：控制台／登录应用 bundle ID `com.aliyun.wuying.osx`；**连接后实际远程窗口属于另一个进程 `com.aliyun.wuying.viewer`**。点击连接后若主列表不变，刷新应用清单并选择 viewer；不要反复点击连接或误判连接失败。

1. 组织／用户来自技能外的 `account.json`，优先已有登录，不让用户重复输入。
2. 密码只读 macOS 钥匙串 `keychain_service`/`keychain_account` 指向的现有条目，读取到内存后直接填入本地客户端，随即清除变量；不输出、不传进日志或源码。不要改变密码、持久凭证或权限。
3. 通过 CUA 最新截图操作。无影 AX 通常只提供顶层窗口；截图坐标依当前窗口及分辨率，**不能沿用上次坐标或假定 Retina 要除二**。
4. 保存 CUA 的原始远程截图，可另做窗口裁剪。不要用 UI 自动化绕过被拒绝控制的本地终端。

## 同步未提交工作区

先固定 HEAD，在 Windows 本地盘取得该提交的完整源码；随后覆盖当前工作树 overlay。overlay 包括相对 HEAD 的 staged/unstaged 和未忽略的新文件，保存完整文件摘要；有删除项时 helper 拒绝，必须明确同步，避免旧文件被悄悄保留。

```sh
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" overlay "/absolute/shou" "/tmp/shou-overlay.zip"
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" upload "/tmp/shou-overlay.zip" "overlay.zip"
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" run "/tmp/shou-prepare.ps1"
```

`upload` 采用 12,000 字符 base64 小块、最多三个并发、每次独立随机目录，最后校验完整 SHA256。远程路径仅允许相对当前测试根，不能覆盖根外文件。准备脚本解压到该 HEAD 目录后，逐文件核对 `UI-OVERLAY-MANIFEST.json`；记录本次源码摘要，不伪造 Git provenance。

## 复用工具并测试

从 `active-desktop.json.cloud_root` 取得当前根。先探测已有 `dotnet/dotnet.exe`、`python/tools/python.exe`、源码及 `artifacts`，复用工具和用户 NuGet 缓存。SDK 按 `apps/windows/global.json`，不每轮全量下载；2026-10-24 测试 SDK 为 10.0.402，Python 为官方 NuGet python 3.13.9。下载地址与 SDK 校验要求见 [CLI 参考](aliyun-cli.md)。

`run` 默认 `shou-test` 用户会话；仅工具准备可加 `--system`。以当前脚本参数为准调用：

```powershell
$env:PATH="$Root/dotnet;$Root/python/tools;"+$env:PATH
$env:DOTNET_ROOT="$Root/dotnet"
& "$Source/scripts/windows/build.ps1" -Runtime win-x64 -ArtifactsRoot "$Root/artifacts/win-x64"
& "$Source/scripts/windows/test.ps1" -ArtifactsRoot "$Root/artifacts/tests"
& "$Source/scripts/windows/verify-publish.ps1" -PublishRoot "$Root/artifacts/win-x64/publish" -Version $ExpectedVersion
```

长作业宜写为远程本地脚本再 `Start-Process`，用阶段文件、日志、最终退出码观察，避免 API 窗口超时。检查每个退出码，`InvocationStatus=Success` 可同时包含 `ExitCode=1`。GUI 及当前用户注册表／MSIX 验收必须在已登录的用户会话。构建成功和启动／正常关闭检查无法检出所有页面装载失败；还要检查各页、错误状态栏和 `application.jsonl`。

发布检查后，在解锁的用户桌面运行 `powershell.exe -NoProfile -STA -File "$Source/scripts/windows/test-desktop-e2e.ps1" -PublishRoot "$Root/artifacts/win-x64/publish" -ArtifactsRoot "$Root/artifacts/e2e"`。它使用本次生成的隔离记录／项目，实际驱动首次扫描和各页只读旅程，保存截图、状态、命令、故障恢复及 `verification.json`。失败立即导出对应控件树和日志，再定位原因；不忽略步骤或接受未执行结果。原生变更、UI 视觉对齐、签名与安装仍为独立验收。

日志现位于 `%LOCALAPPDATA%/Shou/Diagnostics`；E2E 使用自己生成的 `Diagnostics` 目录。`collect-diagnostics.ps1 -OutputRoot <证据目录> -TestResultsRoot <本轮TRX目录> -PublishRoot <产物目录>` 读取带 XML 命名空间的实际 TRX 计数，避免 PowerShell 对 Counters 做 `ConvertTo-Json` 得到空数组。缺日志、丢失事件和跳过原生用例必须明确记录；不复制用户 Data 中的私有执行记录来替代普通诊断日志。

2026-10-24 本轮发现工具栏重挂可能抛 `0x80070057`，导致工具栏仍留正文且页面报错；共享 AccentBrush 存在也不代表 Fluent 控件真正采用橙色。后续必须用实际窗口排除这两类问题，不能把当前产物当作 UI 对齐基线完成版。

## 导出与省钱

```sh
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" download "build.log" "/absolute/evidence/build.log"
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" stop
python3 ".agents/skills/shou-windows-cloud-test/scripts/wuying.py" status
```

`download` 每块 6,000 字节、最多三个并发；只读分块有限重试，检查输出未截断、块长度、总长度及完整 SHA256。先检查本地可用空间，分块即时落盘；失败保留部分文件，但不称完整。截图使用 CUA。先下载当前失败截图、精简回执和日志，再导出全部 TRX，避免重复收集目录中的同一 TRX 拖延关机。

计费截止前预留证据导出窗口。每次开机先记录硬截止时间；测试或导出受阻时，按预算及时 `StopCharging`，下一次集中开机续取磁盘证据。云端已打包不等于本地已下载，必须分别标记。不要因为安装程序或 E2E 卡住继续空等：先保存 UI 树、截图、进程命令和有界日志；安装程序显示帮助窗口通常表示参数错误，不能判为安装或卸载通过。

关机前关闭应用并保存产物，`stop` 明确使用 `StopCharging`；只有 API 返回 `Stopped` 才算已关机。SDK／源码／NuGet 缓存留盘，下次 `start` 后直接构建。存储仍收费，不承诺永久 ¥5。释放不在 helper 默认动作中，需按当前用户要求精确执行 `DeleteDesktops`，并清晰记录最终状态。
