# 第三方应用更新发现

[English](../../product/application-updates.md) | 简体中文

macOS 应用列表的行内明细和独立 CLI 提供用户主动发起的 Homebrew Cask 目录查询。它比较已观察的应用版本与公开目录版本，并提供官方目录入口。源码、测试、原生界面及分发状态分别记录于 [SYNC.md](../../../SYNC.md)；Windows 提供独立的注册身份匹配、官方稳定版发布目录查询、CLI 与行内 WinUI 入口，范围见下文。

## 来源和身份

首个来源为 `formulae.brew.sh` 的固定 HTTPS JSON API。内置[映射](../../../packages/shou-core/Sources/Resources/application-update-sources.json)按确切 bundle identifier 与应用包文件名识别六种稳定版应用：Visual Studio Code、Firefox、iTerm、Chrome、VLC 和 Postman。测试版、重命名包、系统应用及没有可核验元数据的对象不自动匹配。映射不证明应用通过 Homebrew 安装，也不证明本地应用包的开发者签名。

本地读取复用现有应用盘点及其有界、不跟随链接的元数据合同。检查前核对当前应用；GUI 同时绑定行内已观察的完整应用身份。网络成功或失败后再次读取本地身份，变化时拒绝发布该检查并要求重新扫描。

## 查询与隐私

展开明细不联网。“检查 Homebrew 目录”明确说明查询目标，由用户点击才发起请求；每次只发送映射的 cask 标识，不发送本地路径、已安装版本、用户名、应用清单或凭据。不执行 `brew`、Shell、下载包或应用更新器，不打开业务记录存储。

请求禁用 Cookie、缓存和持久凭据，使用系统 TLS 验证；拒绝重定向及交互认证。请求超时十秒、总请求期限十五秒；接收前及接收中限制响应不超过 1 MiB，只有 HTTP 200 与 JSON 类型进入解析。错误只保留固定原因码，不展示自由格式服务器错误或认证信息。取消后不发布迟到结果。

## 版本与结果

只比较最多八段、每段最多九位的点分 ASCII 数字版本，忽略数值相等的尾部零。`latest`、预发行版本、逗号构建后缀、非法数字及格式不明均保持未知。按当前 macOS／架构选择已知目录变体，并检查其 macOS 条件；不据此声明下载产物的架构、签名或安装兼容性已验证。

| `state` | 含义 |
| --- | --- |
| `newer_catalog_version` | 目录中存在数值更高的版本，可打开官方目录页面 |
| `same_catalog_version` | 版本数值一致，不承诺应用已经是最新或该渠道立即可升级 |
| `installed_version_newer` | 已安装版本高于目录版本，不建议降级 |
| `unsupported` | 无内置来源，不发起请求；引导使用应用自身更新器 |
| `unknown` | 网络、身份、平台条件、元数据或版本口径无法核验，不能误报没有更新 |

报告 `format_version=1`，保留观察时间、应用身份、来源、已安装／目录版本和固定原因。未知报告 `status=partial`／CLI 退出 `6`；其他状态表示本次查询已完成，不表示安装通过验证。应用在查询期间变化返回 `application_changed`，取消遵循既有取消合同。

“打开 Homebrew 页面”只打开固定来源的官方 cask 页面，不使用响应中的任意 URL；安装由应用或官方更新器接手。该入口不创建下载、替换、安装、管理员授权或长期更新许可。

## CLI

```sh
shou applications updates source --path "/Applications/Visual Studio Code.app" --json
shou applications updates check --path "/Applications/Visual Studio Code.app" --allow-network true --json
```

`source` 只读本地身份与映射；`check` 必须明确传入 `--allow-network true`。无映射时即使允许联网也不请求网络。两者使用[标准机器信封](../ai/agent-and-cli-contract.md)，不打开或创建清理存储。

## 实现与验证边界

Core 拥有映射、严格版本比较、平台条件、未知状态和身份复核；Platform 负责原生应用读取及固定来源的有界网络请求；UI 只负责行内呈现、取消和用户主动打开官方页面。复用[当前设计](../engineering/interface-design.md)，不新增顶级更新页面。

生成夹具覆盖来源／包名不匹配、相等／更高／更低版本、含糊格式、不同平台变体、系统条件、查询期间应用变化、取消、离线、错误响应、JSON 类型及响应大小。真实目录连通、GUI、辅助功能和安装后行为分别取证，不以模拟网络或构建通过代替。自动安装及其他更新来源属于后续独立能力。

## Windows 来源与差异

Windows 的首个来源为 `https://api.github.com/repos/microsoft/vscode/releases/latest`，只观察 Visual Studio Code 稳定发布。内置匹配限定 x64 的当前用户或计算机 64 位注册视图、确切卸载注册键、显示名称和 `Microsoft Corporation` 发布者；不匹配便携、Insiders、其他架构、改名或未知注册。注册匹配不证明安装来源或签名。匹配事实可与 [GitHub Desktop 的 Windows 编辑器目录](https://github.com/desktop/desktop/blob/development/app/src/lib/editors/win32.ts)核对；这里不执行其中的外部命令或复用其源码。

行内展开只显示本地来源，点击“检查版本目录”才查询固定公开端点。请求无认证、Cookie 或应用清单；拒绝重定向，十秒 HTTP／十五秒总期限，流式接收限制 1 MiB，仅接受 HTTP 200 和 JSON。Core 核对非 draft／非 prerelease、确切仓库发布页和纯数字标签，不使用返回的包地址。官方入口固定为 `https://code.visualstudio.com/updates`。该目录仅为发布版本观察，不证明某个 Windows 安装包适合当前系统。

```sh
shou applications updates source --application-id ID --json
shou applications updates check --application-id ID --allow-network true --json
```

调用前后独立重读完整应用盘点；盘点不完整或注册身份变化时拒绝结论。`source` 不联网，已识别但尚未查询的来源状态为 `not_checked`；`check` 的未知结果使用部分状态与退出 `6`。查询取消或应用行切换后，旧结果不能覆盖当前行。Windows 原生注册、WinUI 与包内 CLI 分别取证。
