# 发布与在线升级

[English](../../engineering/releasing.md) | 简体中文

## 版本与产物

将 `apps/macos/Info.plist` 中的 `CFBundleShortVersionString`、`CFBundleVersion` 及 `ShouCLI.version` 设置为发布版本。Git 标签为 `v` 加该版本号。每次发布递增构建版本，供 Sparkle 比较更新。

发布产物包括通用 DMG、应用 ZIP、独立 CLI 归档、经过签名的 `appcast.xml` 和 `SHA256SUMS`。最低系统为 macOS 14。ZIP 与 DMG 包含同一应用；CLI 归档包含运行所需的规则、Schema 和本地化资源。v0.24.1 同时提供 Windows x64／ARM64 自包含便携预览 ZIP，macOS npm 原生包由流水线准备；实际 npm registry 发布单独取证。

## 签名

应用通过 `SUPublicEDKey` 内嵌 Sparkle Ed25519 公钥。将匹配的 base64 私钥种子保存到仓库 Secret `SPARKLE_PRIVATE_KEY`，禁止提交私钥。请保留受保护备份，已安装版本会用该公钥验证后续更新。

流水线将 Secret 写入权限为 `0600` 的临时文件，签名后移除临时副本。Sparkle 要求签名订阅，并在解压前验证下载包。应用从 GitHub 最新 Release 的 `appcast.xml` 获取更新；包地址与校验信息均指向明确版本的 Release。

Sparkle 更新签名与 Apple Developer ID 签名、公证分别管理。发布工作流使用以下仓库 Secrets；常规分支／PR 检查继续使用临时签名，不读取发布凭据。

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE` | 包含证书链和私钥的 PKCS#12 文件，单行 base64 |
| `APPLE_CERTIFICATE_PASSWORD` | PKCS#12 导出密码 |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: <组织> (<团队 ID>)` |
| `APPLE_TEAM_ID` | 十位 Apple 开发者团队标识 |
| `APPLE_ID` | 有公证权限的 Apple 账户 |
| `APPLE_PASSWORD` | 该账户生成的 App 专用密码，不能使用登录密码 |

`scripts/apple-signing.py run --notarize -- <命令>` 将证书导入私有临时钥匙串，按本次导入证书的唯一指纹签名，结束时恢复钥匙串列表并清理临时凭据。Sparkle framework 内的可执行文件、XPC 和 Updater 与 CLI／应用按从内到外的顺序签名，保留原有 entitlements，并验证团队、Hardened Runtime 和可信时间戳。App 公证通过并装订票据后才生成 ZIP／DMG；DMG 再单独签名、公证及装订。Sparkle 签名与 SHA-256 基于最终字节生成。两个架构的 npm CLI 在平台包摘要生成前完成签名及所属 App 的公证；原始 CLI 不支持装订票据，需要系统联机获取对应代码的公证票据。

公证提交 ID 和结果保存在构建附件中；等待超时或状态不明时沿原 ID 查询，不自动重新提交。`.github/workflows/macos-signing.yml` 仅供 `main` 手动构建、签名和公证通用 App／DMG，上传验证附件，不创建 Release、不签发 Sparkle 更新，也不发布 npm 包。现有公开下载的签名状态以对应版本实际产物为准。

## 验证与发布

1. 执行 `sh scripts/test.sh --native-trash-purge` 并检查实际日志。该参数显式启用原生规则目录夹具的清理、恢复与永久移除。默认规则目录检查仅恢复、不永久移除；部分 CLI 检查会独立永久移除其自行生成的夹具。任何检查均不得指向个人数据。
2. 在已设置上述 Apple 凭据的受控环境执行 `python3 scripts/apple-signing.py run --notarize -- sh scripts/release-macos.sh v0.24.1 /absolute/path/to/private-key-file`。构建两种 CPU 架构，测试 Release 核心和包内 CLI，检查 DMG、ZIP、独立 CLI、公证票据和更新签名，并验证篡改包与订阅被拒绝。缺少签名／公证配置时停止，不退回临时签名。
3. 审阅源码、文档、运行资源与 Release Notes。提交、推送或发布前，取得用户要求的递交确认。
4. 推送版本标签。`.github/workflows/release.yml` 在 Apple Silicon 与 Intel 上运行全量测试（含超过 10 万个文件的原生清理及恢复）、启用优化的授权索引传输／catalog 回归和发布构建，再生成并验证通用发布包。只有成功的任务才能进入发布阶段。手动重跑要求标签已存在。
5. 发布任务核对上传后的 SHA-256，在草稿中完成附件上传后公开发布，拒绝覆盖已经发布的版本。发布后确认下载链接，并从已安装应用检查更新。

Windows 发布任务按确切源码构建 x64 与 ARM64 的 WinUI 和独立 CLI。x64 运行 Core／Presentation／原生 Platform／CLI 检查，并启动窗口及正常关闭；ARM64 交叉构建不计作 ARM64 运行验收。`package-windows.py` 验证 PE 架构、自包含 .NET 10、Windows App SDK 资源、版本、依赖声明、归档字节及 SHA-256；各 ZIP 内的 `BUILD.json` 绑定源码、能力限制与实际原生检查状态。两个 Windows 构建与 macOS 任务全部成功后才合并附件和校验和并公开发布。

Windows 下载是未签名便携预览：应用为 `Shou-<version>-windows-<arch>.zip`，CLI 为 `shou-cli-<version>-windows-<arch>.zip`。解压应用并运行 `Shou.Windows.App.exe`，无需另装 .NET 或 Windows App SDK。当前不提供安装器或自动更新，清理、卸载及启动项变更的公开门禁保持关闭。按[Windows 原生方案](windows-native-plan.md)完成双架构运行、Authenticode、Velopack 与干净系统验收后再声明完整 Windows 支持。

手动准备可设置 `prepare_only=true`，并用 `source_commit` 指定完整 40 位源码 SHA；同样执行验证与签名打包，跳过公开发布，保持现有标签和附件。非准备模式拒绝源码覆盖。正常发布版本保持不可变；用户明确要求同版本替换时，先保留原标签、Release 元数据及全部附件字节，验证完整候选后，再将这些确切字节作为人工例外晋升并记录。已安装 `0.19.0` 的用户不会检测到另一个 `0.19.0` 更新；npm 版本不能覆盖。

## npm 渠道

公开 CLI 包保持 `@limecloud/shou`，v0.24.1 引用同版本的 `shou-darwin-arm64` 与 `shou-darwin-x64` 平台包。平台选择、原生 tarball 检查与发布顺序遵循 [npm 分发方案](npm-distribution.md)。npm 独立管理 CLI 渠道，与桌面更新分开。Windows 平台包通过原生验收后再纳入新版本。

## 桌面更新行为

Shou 自身更新从设置“关于 Shou → 检查更新…”进入，与其他已安装应用的[更新发现](../product/application-updates.md)分开。macOS 使用 Sparkle 原生窗口展示图标、当前／最新版本、可滚动的版本说明、跳过版本和安装入口；开启自动检查时可稍后提醒。设置页显示检查结果与上次检查时间，自动检查和自动下载安装选项与 Sparkle 同步。默认不自动下载安装；关闭自动检查时，自动安装选项不可用。Shou 有操作执行时会延后安装重启。

发布说明唯一来源为 `.github/release-notes.md`。`scripts/render-update-notes.py` 将段落、标题和列表转换为转义后的离线 HTML；发布脚本将说明嵌入签名订阅，产物检查要求内容与事实源一致。说明不执行 HTML／脚本，也不加载远程图片。此变化仅对后续使用新流水线生成的订阅生效，不会修改既有 Release 附件。

Windows 的设置入口由用户点击后才请求固定官方 GitHub 最新稳定版本接口，原生对话框展示检查状态、版本和纯文本说明。Core 按数值比较版本，并要求匹配系统架构、仓库、版本标签及精确 ZIP 文件名；预览版本、重定向、超限或无对应架构附件均拒绝。用户选择“下载更新”后才由浏览器打开对应官方 ZIP；便携版仍需退出应用、手动替换目录，设置与记录保存在目录外。不支持自动替换、后台提醒或降级，不把手动下载描述为已完成安装。

本地安装演练使用 `python3 scripts/prepare-update-acceptance.py /path/to/Shou.app --fixture-key`，创建隔离应用身份、数据目录和临时测试密钥，通过 localhost 提供签名更新。临时公钥仅写入两个测试副本，私钥在签名后移除，不读取生产私钥或钥匙串。默认仅将副本版本改为 `0.0.9`，用于验证同一候选构建的更新链路；传入 `--installed-app /path/to/previous/Shou.app` 才是实际旧版兼容性验证。也可沿用明确传入私钥文件的原有调用方式。发布后还需验证正式订阅可用及“已是最新版本”行为。

## v0.24.1 发布目标

本次版本为 `0.24.1`：Git 标签为 `v0.24.1`，macOS 应用、Swift CLI、`@limecloud/shou` 和两个 macOS 平台子包都报告该版本。Windows 的版本唯一来源为 `apps/windows/Directory.Build.props`，同为 `0.24.1`；GitHub 提供便携预览，Windows npm 产物仍为私有开发模式。版本更新后必须重建，不能仅改 npm 元数据。

Windows 的逐项范围与缺口以 [SYNC.md](../../../SYNC.md) 和[Windows 实施阶段](windows-native-plan.md#实施阶段)为准。Windows 11 的 x64、ARM64 各自需要真实运行、受控生成夹具、WinUI、签名、干净安装及更新证据；仅 Mac 测试和交叉构建不能证明完整原生支持；便携预览仅公开已验证的构建与明确受限能力。未完成的能力在文档与机器能力发现中准确标明，不能通过版本号宣称支持。

发布流水线分别在 Apple Silicon 和 Intel 构建、检查签名并离线安装本架构 npm 平台包；通过后组装仅引用这两个精确版本的主包，生成 `shou-npm-release` 构建附件。npm 发布使用该附件的已验证 tarball，先发布两个平台包，再发布主包；GitHub 令牌不授予 npm 发布权限，npm 账号认证单独完成。

发布前对齐原生版本、源码状态、文档与更新元数据，完成原生签名后重新计算最终文件哈希。按 [npm 分发规范](npm-distribution.md#发布与验收)先发布经过验收的精确版本平台包，再发布主包，核验 registry 安装、`npx`、版本与能力。GitHub Release 使用同一版本的已验证原生产物。桌面更新与 npm 安装继续各自管理生命周期，发布后记录标签、registry integrity、产物哈希及实际验收结果。
