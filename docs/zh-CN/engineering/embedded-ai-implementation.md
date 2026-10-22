# 内置 AI 调查：首版实现与验收

[English](../../engineering/embedded-ai-implementation.md) | 简体中文

日期：2026-10-22。这是当前工作区的实现记录，不代表已发布版本或生产验收完成。

产品合同见[20 个用户故事及 11 个用例](../product/embedded-ai.md)、[架构／状态／流程／时序](../architecture/embedded-ai.md)和[33 项验收矩阵](embedded-ai-acceptance.md)。本轮已实现默认关闭的桌面开关、结构化决策优先路由、独立 Jev 配置、按需主模型、分服务用量及跨页原生入口。实现、合成验证和真实服务证据分层记录，未通过项仍保留。

## 使用方式

在「设置 → AI 调查 → 添加连接」分别填写协议、API 基础地址和模型。支持 OpenAI Responses、OpenAI Chat Completions、Anthropic Messages，以及采用相应工具调用协议的兼容网关。地址包含网关前缀，末尾不填写 `/responses`、`/chat/completions` 或 `/messages`。远程服务使用 HTTPS；HTTP 仅允许本机回环地址。

macOS 默认采用 `local` 认证，将 API 密钥保存到当前用户的独立私有目录，连接记录只保存引用；Windows 默认仍使用 Credential Manager（协议值 `keychain`），也支持 `local`。两端支持明确指定环境变量及无需认证的本机服务。不会读取 SDK 默认的供应商环境变量。「测试连接」仅发送生成的令牌，验证模型调用工具后能接收结果并完成下一轮。

连接可启用「使用结构化决策」，选择当前唯一内置提供方 Jev，独立设置 TypeSafe API 根地址、模型和认证；主模型为必需项，Jev 可关闭，关闭后由主模型接管且保留决策配置和密钥。路由先处理本地占用目标，再按需分类／询问重建条件／复核，已知意图通过本地模板形成规则。只有开放式理解才记录原因并升级主模型；决策服务技术失败不触发昂贵兜底。Jev 使用 `POST /systemone` 的固定 Choice 问题，仅接收待提议目录的相对元数据、模型用途假设、重建条件与用户明确回答。`supported` 才进入禁用草稿；`needs_information` 要求补证据，`retain` 保留内容。响应异常会使调查失败并保留已有结果，不能被 SDK 工具错误处理掩盖为完成。复核结果在检查器独立展示，置信度不等于删除安全概率。

完成空间扫描后，点击「智能分析」。右侧原生检查器固定显示本次调查范围、所选服务及发送内容，用户可以补充保留条件后开始。调查期间可继续浏览空间图；切换目录不改变正在进行的调查范围。刷新扫描或执行过清理后，旧结果仍可查看，但必须重新调查才能预览建议。

追问使用独立问题和可选回答，回答后继续同一次调查。每条规则建议都有自己的用途说明、重建条件和「预览此规则」按钮。预览导入默认禁用的高风险草稿，复用现有规则预览、单条启用、重扫和清理确认。AI 不持有任何删除工具。

## 实现结构

| 层 | 实现 |
| --- | --- |
| ShouCore | `AIConnection`、调查状态、问题、建议和证据范围策略；复用闭合规则解析器和禁用导入 |
| ShouPlatform | 本地连接记录、私有凭据文件、旧 macOS 钥匙串兼容、Windows Credential Manager、显式环境凭据 |
| ShouAI | macOS 使用 Swift AI SDK `0.20.0`；Windows 使用有界非流式协议适配；共享路由、索引工具、预算和检查点 |
| macOS | 原生 Form 连接表单、SecureField、可调整右侧 inspector、可取消任务和逐条规则预览 |
| CLI／desktop bridge | 同一个调查服务；bridge 发送任务进展，取消传播至 SDK／URLSession |

SDK 固定提交为 `4e0230a06092583c4dd541071b1ce8e181821bf9`。SDK 类型与消息保留在 ShouAI 内，不进入规则、清理计划或执行层。macOS 工具循环由 SDK 执行；Windows 不引入 SDK 中不可移植的 Apple API，由受限运行适配调用相同证据工具。两端不复制规则引擎。App 包含其 Apache-2.0 许可证。

首版证据仅来自已有大小索引：相对路径、类型、占用、文件数、最新修改时间和覆盖状态。每页 30 条，最多 300 条／64 KiB 元数据；凭据目录、链接及特殊文件被过滤。不读取文件正文、运行 Shell 或自动访问网页。目录用途和重建方式需要模型说明不确定性，必要时询问用户。定向配置内容读取仍未开放。

每次调查最多 12 个模型步骤、32 次工具执行、8 条建议、3 个追问；每轮最多 180 秒、3072 个输出 token。已报告 token 达 32000 时停止后续步骤；这是已用量停止阈值，单次返回可超过阈值，不能作为精确费用上限。回答等待时间不计入单轮超时，调查超过 24 小时不能恢复。

结构化决策最多请求 8 次，输入／响应分别限制为 24 KiB／64 KiB，报告的用量计入同一调查 token 阈值。两类服务均不自动重试或跟随重定向。macOS 新配置不访问钥匙串，旧 `keychain` 的读取、更新和新增均禁止交互授权；不可用时显示应用内修复提示。编辑器提供「改用本地密钥存储」，重新填写一次密钥后保存，不自动读取或删除旧钥匙串。保存操作在后台执行，阻止重复保存和关闭表单；取消连接测试后不会继续启动 Jev 测试。凭据加载时间不计入 180 秒处理时限，返回后仍检查取消与开关。

模型响应正文另有 1 MiB 上限。检查器可展开查看已读取的索引证据，并显示建议目录的快照占用。

检查点保存所选连接、范围、问询、SDK 续接消息和已验证建议，不保存密钥。恢复使用原连接，不因设置变化而静默换服务商。结果状态区分等待、完成、达到调查上限、取消和失败。`limit_reason` 明确区分 `time`、`tokens`、`steps`、`decisions`、`tools`、`evidence`、`response` 和 `directories`；界面给出具体上限与后续操作，不将内部限制描述为账户余额不足。错误正文不落入结果；网络不跟随重定向，不自动重试。

## 凭据与范围交互修订

借鉴 [CC Switch 的供应商持久化](https://github.com/farion1231/cc-switch/blob/e4873bc8aa2555225d4867ec2f04b1290f1d21d9/src-tauri/src/database/dao/providers.rs)：其普通供应商 Key 随 `settings_config` 保存在本地数据库；特定账号服务仍可能使用钥匙串，不能概括为完全不使用钥匙串。Shou 复用现有原子存储，不为密钥新增 SQLite。

`ai-credentials` 与公开连接、检查点、导出及派生记录清理隔离。macOS 目录 0700、文件 0600，检查当前所有者、普通文件、单硬链接、8 KiB 上限，拒绝跟随符号链接；写入沿用原子替换和持久化刷新。Windows 本地模式复用原生私有目录 ACL、受限读取与原子写入。两端默认存储选择是平台差异，网络与业务合同一致。它是文件权限保护，并非钥匙串加密；表单明确说明。

方案选择显示实际协作服务，例如 `Jev + gpt-6.1-sol`，并标注优先与按需角色。单服务策略只展示实际参与的服务。启动范围可选全部已扫描范围或单个目录；空间页优先带入高亮目录，也可重新选择物理目录，显示绝对路径后再确认。全部范围指当前索引根及子目录，不等于自动扩大到其他卷；分析范围不改变清理勾选。

本轮发现的用户记录为 0 步、18 条证据、两项服务均 0 请求／0 token；停止发生在凭据读取后的 180 秒时限检查，不能解释成账户额度耗尽。新代码排除凭据读取耗时并返回具体 `limit_reason`，历史记录保留原始事实。

## CLI 合同

`shou capabilities --command ai --json` 提供所有命令、必填参数和副作用。`network` 表示会向用户选择的模型发送数据。CLI 最终仍返回现有 JSON envelope；预算结束、取消和失败返回 partial／退出码 6，并保留可审阅结果。

```json
{
  "id": "connection_example",
  "name": "My Gateway",
  "api_protocol": "chat_completions",
  "base_url": "https://example.com/gateway/v1",
  "model": "my-tool-capable-model",
  "authentication": "environment",
  "environment_variable": "SHOU_AI_API_KEY",
  "main_model_enabled": true,
  "routing_strategy": "decision_first",
  "decision": {
    "provider": "jev",
    "base_url": "https://api.typesafe.ai/v1",
    "model": "jev-1.13.0",
    "authentication": "environment",
    "environment_variable": "SHOU_JEV_API_KEY"
  }
}
```

```sh
shou ai connections save --file connection.json --json
shou ai connections test --connection-id connection_example --json
shou ai investigate --scan-id storage_example --path build --connection-id connection_example --locale zh-CN --json
shou ai show --investigation-id investigation_example --json
shou ai resume --investigation-id investigation_example --file answers.json --json
shou ai advice import --investigation-id investigation_example --advice-id personal.ai.example --json
```

`answers.json` 是当前问题 ID 到回答的对象。连接及回答文件最大 16 KiB；连接 JSON 拒绝原始密钥字段。导入会在需要时登记扫描根为工作区，规则仍保持禁用。

CLI 另提供 `ai connections credential save --connection-id <id> [--service model|decision|jev]`，只从标准输入将密钥保存到所选本地或系统凭据存储，不接受密钥参数或配置文件；以及 `ai connections decision test --connection-id <id>`，发送合成证据验证所选决策服务。可选 `decision` 配置包含 `provider`、`base_url`、`model`、`authentication` 和 `environment_variable`；缺少提供方的旧记录按 Jev 读取。`decision` 凭据入口按所选提供方隔离，`jev` 仅为 Jev 的兼容别名。bridge 提供 `ai.decision.test`。

bridge v1 增加 `ai.connections`、`ai.test`、`ai.investigate`、`ai.show`、`ai.resume`、`ai.advice.import`；`ai.resume` 的 `answers` 为问题 ID 到字符串的对象。进展沿用 `kind: progress`／`value`；停止沿用 `kind: cancel`，不增加新的确认绕过通道。SDK 依赖仅在 macOS 启用；Windows 的可移植运行适配支持同三种协议，并复用同一调查／决策／规则服务。bridge 通过真实运行时能力报告 `ai_investigation`。旧 SDK 检查点不伪装转换为可移植消息；不兼容时明确要求新建调查。

## 自动验证与剩余范围

Windows 扩展前版本通过 87 项 AI CLI 检查及 bridge 取消、159 项 CLI 合同、desktop bridge 回归和 274/274 Core／平台自测。历史合同验证：Jev 的支持／不确定／保留／畸形结果均为零主模型请求；占用目标零网络；只有必要升级发出一次主模型；相同证据不重复付费；`main_only` 不调用已配置决策服务。提供方替换、旧策略、未知提供方和开关撤销在 AI 安全子集 2/2 通过。

原生 `.build/ai-decision-ready/Shou.app` 使用生成夹具完成：默认关闭、仅 Jev 连接测试、智能清理目录选择、本地测量、索引复用、保留回答跨页保存、继续调查、精确 `build/cache` 禁用草稿和 14.7 MB 预览、单条启用及新扫描、明确废纸篓确认、真实回执及恢复。三个文件 SHA-256 一致，源码和配置完整。慢速调查关闭后正确 cancelled，两个决策请求后计数不再增加。

二次系统目录选择器曾无响应；恢复测试选择服务后原任务与回答仍在。实现已改用异步 `NSOpenPanel.begin`，同时修正开关辅助功能名称、测试提示和重复成功提示；最新包 `.build/ai-provider-ready/Shou.app` 的复测单独记录。结构化服务 UI 和 CLI 使用通用名称；当前仅注册 Jev，Clef 尚未实现。

完整 `scripts/test.sh` 已执行：除最后 `verify-native-cli.py` 的生成 Rust/node 夹具在执行前因 `plan_stale` 被拒绝，前面的 Core、AI、CLI、bridge、空间、大文件、卸载、隐私和安装缓存检查通过。该失败属于现有原生清理回归，未绕过预检；完整脚本不标为全绿。日志 `/tmp/shou-ai-provider-full-tests.log`。

`python3 scripts/verify-ai-investigation.py` 使用临时生成目录、本机 HTTP 服务和合成密钥，覆盖三个协议的完整工具往返、网关前缀、真实 SDK 多轮、跨 CLI 进程问询恢复、逐条禁用导入及原生规则预览；同时检查目录越界、私密名称与正文不发送、通配符拒绝、步骤／token 停止、错误脱敏、无认证头、重定向拒绝和 bridge 取消。原有文件与历史保持可核验。

前一版通过 78 项 AI CLI 检查及 bridge 取消验证，包含超大响应停止、规则用途／重建条件分别保留，以及 Jev 的支持、补证据、保留、畸形响应、重定向拒绝和错误正文脱敏。macOS 15.8.1（Apple Silicon）上的原生界面走查已完成：连接表单与合成工具调用测试、选择生成目录并扫描、打开检查器、填写保留要求、回答追问、继续调查、展开索引证据、查看单条建议和 14 MB 规则匹配预览。草稿保持禁用，未执行清理。

用户指定服务的真实验收使用生成目录，未发送个人目录或文件正文：`https://sub2api.bugu.run/v1`、Responses、`gpt-6.1-sol` 的工具调用往返通过；TypeSafe `jev-1.13.0` 的固定 Choice 判断通过。首轮完成索引查询、一次追问、Jev 支持判断、单条禁用建议导入和规则预览；累计 33,613 token，正确标为预算结束。第二轮用明确保留要求正常完成，使用 16,689 token／约 60.8 秒，但 Jev 返回需要补证据，因此没有生成建议。这些结果验证服务合同和流程，不代表 Jev 的实际准确率或已完成质量校准。密钥仅保存于系统钥匙串。

测试包已保存真实连接，包内 CLI 的两项真实测试通过。桌面先前停在系统钥匙串，用户随后自行完成授权；本轮在 `.build/ai-ready/Shou.app` 重新打开原生保存的连接，两个密钥字段均留空，观察到「已连接 · 工具调用验证通过」及「Jev 结构化判断验证通过」，确认该包能读取凭据并访问真实服务。调用栈曾确认同步保存阻塞主线程；后台保存和取消后阻止后续 Jev 的修复已另包构建校验。修复包 `.build/ai-keychain-responsive/Shou.app` 的系统等待、真实调查及完整 UI 仍待走查，不能套用旧包证据。未通过自动化操作 SecurityAgent，也未执行本轮清理。

目录选择使用物理路径，避免 Foundation 将 `/private/var` 折叠为 `/var` 别名后被 no-follow 扫描拒绝；生成目录和链接选择的回归覆盖此边界。

已完成开发机 Swift 6.2.3 构建、原生 App 打包与签名校验、CLI／desktop bridge／空间分析回归、本地化及文档检查。除上述指定网关和 TypeSafe 外的真实 OpenAI／Anthropic／其他兼容网关、macOS 14 真机、Windows、逐字流式输出、配置正文读取、真实调查质量与外部 Agent 流程成本对比仍待验收。当前 UI 保留本次窗口会话的调查，跨进程问询恢复通过 CLI 提供；macOS 与 Windows 已增加本地已完成／等待调查列表，等待任务可在 24 小时内按原连接续接；中断的 running 检查点不显示为可续接任务，进程崩溃恢复仍未交付。现有外部 Agent 路径继续可用；AI 没有改变离线扫描和清理合同。

## Windows 与 CLI 对齐

CLI 通过发现合同提供共 15 个 AI 命令，包括 `ai providers`、`ai list`、`ai cancel --investigation-id <id>` 及 `ai connections show|delete|restore --connection-id <id>`。配置列表支持 `--state active|deleted|all`，可恢复删除保留历史凭据引用，恢复后可继续使用。调查列表最多返回最近 100 条，累计正文不超过 2 MiB；取消标记由原调查进程监测，取消在途请求并阻止后续步骤。取消命令本身成功表示已受理，原任务状态应通过 `ai show` 确认。等待任务取消立即保存终态。显式 CLI 网络命令独立于桌面偏好。

bridge 另提供 `ai.providers`、`ai.list`、`ai.cancel`、`ai.connections.save`。保存输入为 `profile` 对象和可选 `model_key`／`decision_key`，密钥仅通过当前子进程标准输入写入系统凭据存储，不进入连接 JSON、参数、返回值或日志；配置字段与 CLI 共用严格校验。`authentication: keychain` 在 Windows 映射到当前用户的 Credential Manager，作为兼容枚举保留。

Windows WPF 使用系统 Fluent 主题，提供默认关闭开关、配置新增／编辑／可恢复删除／恢复／合成测试、独立主模型及决策配置、已安装提供方选择、目标和精确物理目录、发送内容披露、本地测量或索引复用、真实阶段、问题选项／自由回答、继续／停止、证据／服务用量／升级原因、本地调查列表，以及逐条导入并进入原规则预览。清理、空间分析、大文件父目录、规则页均有入口。等待中的原范围和未提交回答不因切页变化；退出明确说明停止及未提交回答丢失。

Windows 使用有界非流式 HTTP 传输，接收期间限制正文大小、拒绝重定向与重试，保留协议原生的工具调用和续接消息。Responses 请求使用 `store: false` 并保留后续工具调用需要的响应项目。macOS 可用进程级 `SHOU_AI_RUNTIME=portable` 验证同一运行适配；这不能代替 Windows 本机验证。

仓库现有 `.github/workflows/windows.yml` 的 Check 阶段已接入 `verify-ai-investigation.py <shou.exe>`，使用本机合成服务和仓库内生成目录，不使用真实密钥。它与原有 WPF 子进程检查、真实桌面协议、打包检查一同执行。最新 16 项 .NET 进程检查已在开发机通过；WPF 交叉构建零警告零错误，Windows 凭据 C++ 交叉语法检查通过。远程 CI 必须检出含本轮改动的提交；旧 HEAD 的成功不能作为本轮证据。Windows 原生 CI、WPF 按钮旅程和 Credential Manager 运行结果待单独记录。

本轮新增验证：默认 SDK 与 `SHOU_AI_RUNTIME=portable` 两种运行方式各通过 94 项 AI CLI 检查，包含三协议完整问答／预览、Jev 零主模型、跨进程在途取消与状态核验；159 项通用 CLI 回归通过。此为 macOS 开发机证据，Windows CI 还需验证原生网络与凭据 API。新增 `storage.show` bridge 与已有 `analysis show` 对齐，只读返回原索引根和状态，供 Windows 重启后恢复精确范围。

当前 desktop bridge 完整回归已通过，覆盖跨根确认、空间导航、大文件、规则预览、历史和 stale-target 拒绝。首次运行遇到空间夹具旧断言，断言随其他任务修正后重跑通过；失败记录保留。最新 .NET 检查含真实共享 CLI 共 16 项通过。本地化 1695 项、96 篇文档／823 个局部链接及中英架构共 26 个 Mermaid 解析通过。

## 最新 macOS 包的原生补验

`.build/ai-cross-platform-ready/Shou.app` 已完成异步目录选择取消／再次打开、选择精确生成目录及本地测量，结果为 14.7 MB；启动前显示真实默认连接、精确目录和发送说明。历史列表的原行内按钮未能激活，改为标准列表选择与「打开调查」按钮，支持 Return，并在面板中显示加载错误和加载状态。

修复包 `.build/ai-cross-platform-history-ready/Shou.app` 在无当前扫描时恢复原范围、原连接及等待问题，查看记录前后合成服务计数均为 9。填写保留条件并继续后，计数变为 10；任务为 `investigation_d3367f95-ca6f-4598-b725-6de50adfd7fa`，累计 Jev 3 次、报告 1230 token，主模型 0 次，产生一条 `build/cache` 的 14.7 MB 禁用草稿建议。此为合成协议和交互证据，不代表真实服务分类质量。

最终包 `.build/ai-cross-platform-final/Shou.app` 已完成构建、临时签名和桌面／CLI 产品验证；重启后能用 Return 打开完成记录，「新建调查」重新进入原精确目录的测量面板，取消仍保留历史结果。默认连接仍为真实桌面连接。本地化更新为 1696 项。原生记录、产品哈希和本地检查日志索引在 `.build/ai-cross-platform-review/`；Windows CI 尚无包含本轮改动的运行证据。

## 配置增删改查与决策开关

每个新保存和可运行方案都必须有有效主模型。Jev 通过 `routing_strategy` 开关：`decision_first` 开启协作，`main_only` 关闭并由主模型接管；保留 `decision` 对象及其独立密钥。关闭时，决策测试直接返回 `ai_decision_disabled`，不读取其凭据；普通连接测试只测试实际启用的服务。旧 Jev 单独方案可显示并修正或移除，但不能启动或续接。

macOS 设置提供完整列表、实际服务组合、每行决策开关、设为默认、新建／编辑／测试、具名删除确认和已删除配置恢复；Windows 工作区提供对应选择、编辑器、决策开关、删除和恢复。运行或等待时禁用配置修改；任务使用原连接快照。密钥留空保留原值，关闭 Jev 不要求重新输入密钥。

CLI 的十五个 AI 命令包含：

```sh
shou ai connections list --state active --json
shou ai connections show --connection-id connection_example --json
shou ai connections save --file connection.json --json
shou ai connections delete --connection-id connection_example --json
shou ai connections list --state deleted --json
shou ai connections restore --connection-id connection_example --json
```

同一 ID 的 `save` 用于更新。`show` 可读取已删除方案的非密钥正文；`list` 默认 active，支持 deleted／all。删除仅写 `ai-connection-states` 状态，保留历史快照及凭据；恢复前禁止编辑、测试和启动。bridge 对应 `ai.connections`、`ai.connections.deleted`、`ai.connections.show`、`ai.connections.save`、`ai.connections.delete`、`ai.connections.restore`。这些配置操作均不联网。

本轮验证结果与新包安装证据在下文记录；旧包和旧提交上的通过不能替代本轮。
