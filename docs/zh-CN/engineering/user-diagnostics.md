# 用户诊断与终端支持

[English](../../engineering/user-diagnostics.md) | 简体中文

macOS 与 Windows 设置的“支持 → 运行诊断”与 `shou diagnostics` 共用只读服务。报告可预览、复制，中英双语跟随应用或 `--locale`。入口沿用[当前工作台](interface-design.md)。源码、专项检查及原生验收分别记录于 [SYNC.md](../../../SYNC.md)；Windows 使用独立 C# Core、Win32 观察、Presentation 与 WinUI 入口；原生检查与界面证据单独记录。

## 报告范围

报告版本为 `format_version=1`，包括观察时间、应用版本、平台／架构／数字系统版本、CPU 数、物理内存与主目录所在卷的总量和可用量。

| 检查 | 观察及限制 |
| --- | --- |
| `disk_capacity` | 元数据读取失败或数值不可信时保持未知；可用空间小于 1 GiB 或不超过卷容量 10% 时提示关注，不触发清理 |
| `disk_access` | macOS 复用访问哨兵，只尝试打开而不读取内容；Windows 标为不适用，各路径的访问由扫描单独验证 |
| `local_records` | 只核对目录类型、当前所有者、私有权限和拒绝跟随链接的祖先句柄；不创建目录，不枚举内容，不验证写权限或修复配置 |

检查状态为 `normal`、`attention`、`unknown`、`not_configured`、`not_applicable`。存在未知观察时报告 `status=partial`，CLI 退出 `6`；其余为 `complete`，不表示所有检查正常、磁盘健康或所有扫描完整。未配置本地记录与实际故障分开呈现。

报告不含个人绝对路径、用户名、主机名、会话正文、文件内容、凭据、进程参数或环境变量。仅输出建模字段，不导出自由格式系统异常；不联网、不上传、不启动子进程、不改变权限。具体扫描失败、活动未知和逐项结果仍由所属结果与历史解释。

```sh
shou diagnostics --locale zh-CN
shou diagnostics --json
shou completion --shell bash
shou completion --shell zsh --json
```

JSON 使用[标准 CLI 信封](../ai/agent-and-cli-contract.md)。诊断无需打开业务存储；即使本地记录尚未创建或配置位置是文件，也能输出相应状态并保留原状。

## Shell 补全与验证

macOS 的 `completion --shell bash|zsh` 与 Windows 的 `completion --shell bash|zsh|powershell` 从公开命令发现生成静态脚本，支持子命令、参数、枚举及含空格的文件路径；JSON 返回 `shell` 与 `script`。该命令不安装脚本、不编辑启动配置、不打开记录存储。用户自行按所用 Shell 的方式加载；升级命令面后重新生成。补全过程不运行 Shou、不扫描目录树、不发起变更，文件名使用 Shell 自身补全。PowerShell 只从语法树读取字面命令与参数，不求值输入。未知 Shell 或参数显式拒绝。

诊断使用生成夹具检查缺失目录、文件冲突、链接、不私有目录、取消、低容量与未知状态，核对内容／修改时间／权限保留及导出隐私。补全执行真实 Bash 回调，检查命令发现一致性、前置语言、枚举、空格路径和不可信参数。Bash 与可用的 Zsh 分别检查语法；已安装 0.15.0 在 macOS／Zsh 5.9 的 7 项 PTY／Tab 键交互已通过，包含空格路径及不可信字面文本，补全没有调用 Shou 或求值输入。精确产物摘要及原始回执见 [SYNC.md](../../../SYNC.md#installed-zsh-completion-2026-10-26--已安装版-zsh-补全)。Windows PowerShell 另有 x64／ARM64 各八项原生控制台按键与 PSReadLine 用例通过，确切源码及回执见 [SYNC.md](../../../SYNC.md#windows-powershell-keyboard-completion-2026-10-26--windows-控制台补全)。诊断原生界面仍需单独验收。
