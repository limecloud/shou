# 本机 CLI 与 Windows 测试操作

## 本地认证

2026-10-24 已验证官方 CLI 3.5.2，路径 `~/.local/share/shou-cloud-test/tools/aliyun`，OAuth profile 为 `shou-cloud-test`。认证配置在 `~/.aliyun/config.json`，不能输出其内容或复制进 Skill；账号元数据与钥匙串 service 从 Skill 外的 `account.json` 读取。用户已经授权 official-cli，仍需检查当前认证是否有效；只在实际过期时重新登录。

CLI 优先；Computer Use 仅用于登录后的远程桌面、应用交互及截图。无影提供网页远程桌面，现有会话入口以控制台实际返回为准。

## 无影 API

本次无影桌面 API 使用 `2020-09-30`。CLI 默认 `ecd` 元数据版本 `2023-06-27` 只含部分渠道接口；已验证下面的 RPC 直发方式可处理桌面接口：

```sh
"$HOME/.local/share/shou-cloud-test/tools/aliyun" ecd DescribeDesktops \
  --profile shou-cloud-test --version 2020-09-30 --force \
  --RegionId cn-guangzhou --DesktopId.1 "$SHOU_DESKTOP_ID"
```

`SHOU_DESKTOP_ID` 必须来自本次创建/确认的资源清单。`--force` 用于跳过过旧的本地 API 元数据校验，不扩大云端权限。先核对当前官方接口，不盲目用于未知操作。

购买使用当前 `CreateDesktops`/报价接口的实际参数和返回值，按模板复核镜像、规格、系统盘、数据盘、计费与网络。先尝试已验证的只读/帮助接口；若需要网页完成协议或特定产品表单，使用用户授权。模板没有固化购买参数全集，不能据此杜撰请求。

远程命令：

```text
RunCommand
  DesktopId.1 = 本次精确实例
  Type = RunPowerShellScript
  ContentEncoding = PlainText
  CommandContent = PowerShell 脚本文本
  Timeout = 有界秒数
  EndUserId = shou-test（用户已登录后）

DescribeInvocations
  InvokeId = 上一步返回值
  IncludeOutput = true
  IncludeInvokeDesktops = true
  ContentEncoding = PlainText
```

检查总体 `InvocationStatus`、每台实例的 `ExitCode`、`Dropped` 和实际输出；投递成功不代表脚本成功。用本地 `subprocess.run([...])` 等参数数组传递多行脚本，避免 shell 插值。先读出执行用户、session、环境，再测试用户注册来源。无 `EndUserId` 的 SYSTEM 命令可准备工具，但不能替代当前用户验收。

## 工具准备与测试

- 以本次源码 `apps/windows/global.json` 为准固定 .NET SDK，下载官方 ZIP 并校验官方 SHA512。本次使用 10.0.402。
- Python 以仓库要求为准。本次 python.org 下载超时后，官方 NuGet `python` 3.13.9 包可用：`https://api.nuget.org/v3-flatcontainer/python/3.13.9/python.3.13.9.nupkg`，解压使用 `tools/python.exe`。本次重定向到 nuget.azure.cn；后续按实际网络选择，不把本次超时当作永久地域限制。
- 全部文件与产物落到本次独立的 `C:\Users\Public\ShouTest-<timestamp>`；应用数据使用本次用户私有测试目录。不要以个人资料做删除样本。

已验证的标准入口（变量由本次流程设置，使用当前版本）：

```powershell
& "$Source/scripts/windows/test.ps1" -ArtifactsRoot "$Root/artifacts/tests"
if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed' }
& "$Source/scripts/windows/build.ps1" -Runtime win-x64 -ArtifactsRoot "$Root/artifacts/win-x64"
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
& "$Source/scripts/windows/verify-publish.ps1" -PublishRoot "$Root/artifacts/win-x64/publish" -Version $ExpectedVersion
if ($LASTEXITCODE -ne 0) { throw 'Publish verification failed' }
```

上例不能代替各脚本当前参数与前置条件检查。MSI 与启动任务生成夹具分别使用仓库专用脚本，仅在明确 opt-in、PowerShell/Git provenance/工具链要求满足时运行；源码 ZIP 不能提供 Git checkout 来源证明。默认跳过必须原样报告。

## 导出和释放

本地证据目录约定：`~/.local/share/shou-cloud-test/evidence/<run-id>/`。保留主测试日志、构建/启动验证、TRX、能力、工具链、截图、操作退出码和资源清单。优先实时保存较小的主要日志，避免所有证据只留在最终大包。

通过命令输出分块导出时检查 `Dropped`，每个成功分块立即按 offset 落盘；有限重试并遵守预算。全部下载完成再验证总长度和 SHA256。部分 ZIP 恢复只接受各条目完整解压且 CRC 验证的文件，恢复包另命名，不声称原包完整或原 SHA 通过。

`DeleteDesktops` 使用精确 `DesktopId.1` 和本次地域。先核对实例归属、本次清单与 `PostPaid`，将释放放在异常清理路径中；提交后轮询 `DescribeDesktops`，保存回执及 `Desktops: []`。读取 `DescribeNetworkPackages`、`DescribeSnapshots` 复核本次附属收费项，按需释放本次资源，不扩大到其他资源。

API 网络错误时用户偏好是立即释放，不无限重试导出。释放失败时优先恢复 API 或控制台释放并继续确认；不能把关机、网页断开或提交请求描述为停止计费。

估算按起止时间与实际报价计算，并注明磁盘/网络等额外项；最终以阿里云入账为准。账单延迟返回空记录不等于费用为零。

旧的 `~/.local/share/shou-cloud-test/cloud.py` 等单次脚本硬编码了已销毁实例，仅是历史记录，不能直接用于下次运行。

## 关机保留与计费

2026-10-24 已核对官方 [开关机说明](https://help.aliyun.com/zh/wuying-workspace/user-guide/start-stop-or-release-cloud-computers)和 [StopDesktops metadata](https://api.aliyun.com/meta/v1/products/Ecd/versions/2020-09-30/apis/StopDesktops/api.json)：

```text
StopDesktops
  RegionId = 当前精确地域
  DesktopId.1 = 已核对的保留实例
  StoppedMode = StopCharging
```

`StopCharging` 回收 CPU／内存计算资源，停止对应费用，磁盘继续收费；`KeepCharging` 保留计算资源，仍正常计费，不用于省钱关机。断开远程客户端不是关机。开机 `StartDesktops` 使用相同实例／地域；计算资源回收后，库存不足可能导致下次开机暂时失败，磁盘与工具缓存保留。

当前模板 6 核 12GB、80GiB 系统盘、0 数据盘的运行参考价为 ¥1.117864/小时，磁盘约 ¥0.02776/小时（¥0.66624/天，按 30 天约 ¥19.99）。该数字仅为 2026-10-24 报价参考，实际分类、价格、已购买网络和账单重新核对。关机保留一天将时间写入本地 active 文件；保持原总预算约束，不自动续留。

省钱流程：本地开发前先关机 → Mac 完成实现、资源生成与可移植验证 → 打好带当前改动及摘要的同步包 → 开机集中完成 Windows 原生构建、功能操作与截图 → 导出后按最新选择关机或释放。可复用 SDK、Python、NuGet 缓存和产物，减少每次重新购买与下载的等待费。
