# 发布与在线升级

[English](../../engineering/releasing.md) | 简体中文

## 版本与产物

将 `apps/macos/Info.plist` 中的 `CFBundleShortVersionString`、`CFBundleVersion` 及 `ShouCLI.version` 设置为发布版本。Git 标签为 `v` 加该版本号。每次发布递增构建版本，供 Sparkle 比较更新。

发布产物包括通用 DMG、应用 ZIP、独立 CLI 归档、经过签名的 `appcast.xml` 和 `SHA256SUMS`。最低系统为 macOS 14。ZIP 与 DMG 包含同一应用；CLI 归档包含运行所需的规则、Schema 和本地化资源。v0.11.0 仅发布 macOS，Windows 发布待实现。

## 签名

应用通过 `SUPublicEDKey` 内嵌 Sparkle Ed25519 公钥。将匹配的 base64 私钥种子保存到仓库 Secret `SPARKLE_PRIVATE_KEY`，禁止提交私钥。请保留受保护备份，已安装版本会用该公钥验证后续更新。本次初始密钥的本地备份位于已忽略的 `.shou-local/sparkle-private-key`。

流水线将 Secret 写入权限为 `0600` 的临时文件，签名后移除临时副本。Sparkle 要求签名订阅，并在解压前验证下载包。应用从 GitHub 最新 Release 的 `appcast.xml` 获取更新；包地址与校验信息均指向明确版本的 Release。

Sparkle 更新签名与 Apple Developer ID 签名、公证分别管理。初始打包脚本使用 ad-hoc 应用签名；下载说明和 Release Notes 会说明安装限制。

## 验证与发布

1. 执行 `sh scripts/test.sh --native-trash-purge` 并检查实际日志。该参数显式启用原生规则目录夹具的清理、恢复与永久移除。默认规则目录检查仅恢复、不永久移除；部分 CLI 检查会独立永久移除其自行生成的夹具。任何检查均不得指向个人数据。
2. 执行 `sh scripts/release-macos.sh v0.11.0 /absolute/path/to/private-key-file`。构建两种 CPU 架构，测试 Release 核心和包内 CLI，检查 DMG、ZIP、独立 CLI、更新签名，并验证篡改包与订阅被拒绝。
3. 审阅源码、文档、运行资源与 Release Notes。提交、推送或发布前，取得用户要求的递交确认。
4. 推送版本标签。`.github/workflows/release.yml` 在 Apple Silicon 与 Intel 上运行全量测试（含超过 10 万个文件的原生清理及恢复）和发布构建，再生成并验证通用发布包。只有成功的任务才能进入发布阶段。手动重跑要求标签已存在。
5. 发布任务核对上传后的 SHA-256，在草稿中完成附件上传后公开发布，拒绝覆盖已经发布的版本。发布后确认下载链接，并从已安装应用检查更新。

Windows 暂无发行包或发布流水线。按[Windows 原生方案](windows-native-plan.md)分别验证 x64、ARM64，自包含交付 .NET 与 Windows App SDK，完成 Authenticode 签名、Velopack 安装更新与干净系统验收后再发布。

## npm 渠道

公开 CLI 包保持 `@limecloud/shou`，已发布的 `0.11.0` 产物仅支持 macOS。后续平台包、精确版本协调、原生 tarball 检查与发布顺序遵循 [npm 分发方案](npm-distribution.md)。npm 独立管理 CLI 渠道，与桌面更新分开。

## 桌面更新行为

Shou 有操作执行时会延后安装更新。默认不自动下载安装；用户可在设置中控制定期检查更新。本地安装演练可使用 `scripts/prepare-update-acceptance.py`，创建隔离的旧版本与候选版本应用副本，并通过 localhost 提供签名更新。传入 `--installed-app /path/to/previous/Shou.app` 可验证真实旧版本升级；候选版本从 Info.plist 读取。发布后还需验证正式订阅可用及“已是最新版本”行为。
