# 本地开发

[English](../../engineering/development.md) | 简体中文

本文适用于当前 macOS 源码工程。Windows 按[原生方案](windows-native-plan.md)实施。源码构建、原生交互与发布验收分别处理。

## 环境要求

使用 macOS、Swift 6.2.3 与 macOS SDK。部署基线为 macOS 14，CI 选择 Xcode 26.2 并检查 Swift 版本。SwiftPM 在 `Package.resolved` 固定 Swift AI SDK `0.20.0` 与 Sparkle `2.10.0`；SQLite 由 macOS SDK 提供。

编辑前阅读[系统架构](../architecture/system-design.md)、[模块归属](../architecture/monorepo-and-platforms.md)与对应产品、安全合同。普通扫描和清理不需要模型凭据、网络或已运行桌面程序。

## 构建与运行

在仓库根目录执行：

```sh
swift --version
swift build --jobs 4
".build/debug/shou" capabilities --json
sh "scripts/build-macos.sh" debug
open "dist/Shou.app"
```

`swift build` 构建桌面、独立 CLI 与夹具测试程序。打包将 CLI 和资源 bundle 放在应用 Helpers 中，须保留完整应用结构。桌面二进制为 `ShouDesktop`，CLI 为 `shou`，避免大小写不敏感文件系统上的名称冲突。

## 标准验证

```sh
sh "scripts/test.sh"
```

该入口执行文案、目录和文档检查、Swift 构建、领域与原生生成夹具测试、公开 CLI 合同、模拟 AI 协议、终端确认及相关清理领域检查。原生废纸篓夹具验证移动与恢复；部分默认 CLI 检查会永久删除其自行生成的临时文件。测试不枚举或清空用户废纸篓。

构建成功后可运行专项：

```sh
".build/debug/shou-tests" --rule-catalog-only
".build/debug/shou-tests" --storage-catalog-only
".build/debug/shou-tests" --ai-safety-only
python3 "scripts/verify-cli.py"
python3 "scripts/verify-ai-investigation.py"
```

获得明确授权后，`sh "scripts/test.sh" --native-trash-purge` 额外验证生成夹具清单的不可逆删除。测试程序的独立选项 `--native-large-trash-only` 创建超过 100,000 个生成文件验证废纸篓和恢复，不纳入默认套件。

记录精确版本、系统、架构、实际检查、结果与限制。夹具通过不能代表可访问性、真实个人项目安全、其他平台或发布签名通过。见[验收规范](acceptance-and-testing.md)。

## 源文件与生成资源

| 来源 | 维护规则 |
| --- | --- |
| `packages/shou-contracts/rule.schema.json` | 唯一机器 Schema |
| `packages/shou-core/Sources/Resources/builtin-rules.json` | 版本化声明式规则目录 |
| `packages/shou-core/Sources/Resources/known-locations.json` | 精确的平台发现根 |
| `packages/shou-core/Localizable.xcstrings` | 中英文文案唯一来源 |
| `assets/design/tokens.json` | 八项设计值生成 WinUI XAML 与 SwiftUI 常量，由资源生成器同时检查 |
| `assets/brand` | 原生品牌源文件 |

生成与检查资源：

```sh
python3 "scripts/update-localizations.py"
python3 "scripts/update-localizations.py" --check
python3 "scripts/generate-windows-resources.py" --check
python3 "scripts/verify-rule-catalog.py" --self-test
python3 "scripts/verify-docs.py"
```

不手工修改生成的 `.strings`、`apps/windows/Generated` 或 `apps/macos/Sources/ShouDesign.generated.swift`。语言变化不能改变 ID、匹配、摘要或执行决策。共享来源变化后，运行 `python3 scripts/generate-windows-resources.py` 重新生成原生资源并校验摘要。macOS 常规测试入口也检查这些生成资源。

## 本地数据与隔离

macOS 日常数据根为 `~/Library/Application Support/Shou`。生成 CLI 夹具使用 `SHOU_DATA_DIR` 指向专用绝对目录。记录存储要求当前用户所有权、目录 `0700`、文件 `0600`、原子持久化写入和跨进程变更锁。

原生变更测试使用临时生成文件，不通过扫描或修改个人项目证明删除行为。模型测试使用本地模拟服务和合成密钥；真实服务调用须已有明确授权。

## 打包与发布

`sh "scripts/build-macos.sh" release universal` 将两种 macOS 架构构建为应用包。`python3 "scripts/install-macos.py" --check` 只验证已准备的本地包，不执行安装。本地安装、签名分发和公开更新分别处理；签名、归档、更新源验证与发布按[发布文档](releasing.md)执行。

## Windows 开发边界

Mac 运行 `sh scripts/test-windows-core.sh`，覆盖 C# Core/Presentation 测试、Platform 引用编译、嵌入资源和依赖本机 .NET 的 CLI 合同；Windows 原生用例明确跳过。WinUI 编译和系统行为需要 Windows，x64 与 ARM64 分别验收。Windows 本地构建和测试命令见 [Windows 指南](windows.md)，当前没有 Windows 发行包。源码、产物、缓存与工具链归属遵循[原生方案](windows-native-plan.md)。
