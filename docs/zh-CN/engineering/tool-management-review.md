# 工具管理参考与实施差异

[English](../../engineering/tool-management-review.md) | 简体中文

分析日期：2026-10-26。输入包括用户提供的模块／版本／AI 应用截图、只读 FlyEnv 源码和公开 CC Switch `main` 源码。参考代码未在 Shou 内执行，没有复制 Electron、Vue、Rust、代理、安装脚本或界面资源。Shou 保留 SwiftUI/AppKit 与 WinUI 3／.NET 的平台边界。

## 已核实的事实

FlyEnv 声明 17 个模块分类，版本管理分别接入 Homebrew、MacPorts、SDKMAN、本地目录和独立下载包。`src/fork/module/Base/index.ts` 的在线目录与解包路径，以及 Nginx 模块的服务、配置与日志实现，证明这些不是单一包管理命令能替代的能力。`src/render/core/ASide.ts` 的 `switchChange` 调用模块 start／stop；截图中的胶囊是实际服务启停，不能用收藏开关替代。版本绑定及等待实际状态也须保留。

CC Switch 参考 `package.json` 标记版本 4.0.21；本次读取的是执行时公开 `main`，不将该版本号当作已发布包行为。README 的支持矩阵区分供应商切换／共存、MCP、Skills、提示词、会话与用量。`commands/misc.rs` 的 `enumerate_tool_installations`、npm 来源映射，及 `tool_uninstall.rs` 的逐安装候选计划，体现多个副本、管理器锚定和无跨来源回退；`tool_node_requirement.rs` 独立检查 Node 引擎要求。运行 `--version` 与 Shell 安装命令只能作为参考，不能直接移入 Shou 的固定命令边界。

Homebrew 与 WinGet 的声明引用通过公开目录观察建立。无法核实的引用不生成安装动作。原始观察与参考摘要保存在本次 `output/reviews/developer-tools-2026-10-26/`；静态观察不替代执行前检查。

## 采用与差异

| 参考思路 | Shou 选择 |
| --- | --- |
| 按工具归组，渐进展示版本和来源 | 分类工具列表＋常驻右侧来源版本表；开发者工具和 AI 共用交互 |
| 服务胶囊开关 | 精确来源／版本的即时启停，等待真实状态；收藏独立，登录登记保留 |
| 多个安装副本 | 独立来源、位置和版本，管理器目录内的别名去重 |
| 查询 CLI 版本 | 首轮不执行发现的程序；读取登记／npm 元数据，运行状态未验证 |
| 按安装器卸载 | 仅处理接通来源；拒绝找不到管理器就删除目录 |
| AI 工具集中管理 | 独立 AI 工作台；配置和凭据另立权限与逐工具适配 |
| 完整本地环境服务 | 首批 Homebrew 启停与 Windows SCM 门禁源码；完整站点、数据库、容器、证书和任务仍需独立工作包 |

Swift／C# 的领域接口与原生适配分别实现，不创建跨平台 Shell 引擎。共享目录、文案和设计资源保持唯一来源。生成管理器夹具仅证明固定参数、确认、日志、结果与数据保留，不证明所有软件包、WinGet 安装器、运行健康、服务或 AI 功能已可用。Windows 安装器公共门禁在独立验收前关闭。最终平台、源码、截图与结果以本次验收记录及 [SYNC.md](../../../SYNC.md)为准。

## 2026-10-26 REA 与完整源码盘点

本机安装包 4.18.2（ASAR SHA-256 `85120a41680fb11c137ef1549b99b40fb3b9d3e4b84e3247735c06d3cbc582d6`），源码为 4.20.2、HEAD `1d63e3300628eb1a4aa14050d3a3319fce527119`，不能混作同版行为。源码已逐项盘点 17 分类、71 个根模块路由、38 个内部工具，追踪版本来源、状态、重启、配置、日志、项目、AI 与系统变更调用链；完整行号报告见[参考证据](../../../output/reviews/developer-tools-2026-10-26/flyenv-source-ui.md)、[服务合同](../../../output/reviews/developer-tools-2026-10-26/flyenv-source-services.md)和 [AI 盘点](../../../output/reviews/developer-tools-2026-10-26/flyenv-source-ai.md)。

REA CLI 6.7.0 分析安装包主进程／fork／manifest，以及 82 个服务相关 renderer 文件；证据 ID 为 `ev_5151fcbd2d9af721209c3063c8721547f4a08c416af376ba5a5ab2c4ce6786dd`、`ev_7f186816388e3a6eac04c7aaa03bf481e04d825b169abbf75e8edf54451f4a07`。索引覆盖完整安装包，选择外源码未作语义分析；renderer 因累积结果预算保留静态事实，部分语义分析未开始，不能声称完成安装包每个模块的反编译。十个 unpacked 原生文件与 ASAR 声明摘要矛盾，按 record-and-continue 保存为不受信观察，不执行它们。首次拒绝与完整证据位于 `.build/references/flyenv/`，[精简证据和限制](../../../output/reviews/developer-tools-2026-10-26/flyenv-reference-evidence.json)供复核。当前 REA MCP 未连接，使用现有 CLI，未修改全局注册或安装分析引擎。

实际 Computer Use 只读查看已运行的 4.18.2 Nginx 服务页，确认行内停止／重启、配置与日志页签及同一 Cellar 版本；未点击其启停、安装、保存或删除。FlyEnv 自管理 Nginx 正在运行而 Homebrew 服务状态为 stopped，实证了来源与生命周期必须分开。

普通 AI CLI 的安装、版本或复制命令不等于后台服务；OpenClaw／Hermes 网关另有真实生命周期。MCP 配置写入、供应商切换、技能编辑、数据清理分别需要独立权限。参考中的强制进程终止、整数据库重置、默认版本回退和内存运行状态不能直接移入 Shou。

## 逐软件复核与适配结构，2026-10-27

新增[逐模块能力报告](../../../output/reviews/developer-tools-2026-10-26/flyenv-module-capabilities-detail.md)，覆盖 71 根索引及 59 非 AI 模块的差异，385 条源码引用绑定精确提交；另有[安装／AI](../../../output/reviews/developer-tools-2026-10-26/flyenv-install-ai-detail.md)和[服务交互](../../../output/reviews/developer-tools-2026-10-26/flyenv-service-ux-detail.md)细查。MySQL 的库／授权、口令记录／维护重置、备份、群组各有独立链；Mailpit Static 调用中间历史 API，服务端资产筛选仍未知；ENV、各管理器 default、Alias 和备注也不是同一能力。

REA 另外选择已安装包的 Mailpit 配置、MySQL 管理／群组和 phpMyAdmin 四份源文件分析，解析 21,314 字节、5,763 AST 节点，无语法失败；证据 `ev_bdde0d876ad63f42a0d92e6649573f057919e3fa938e058dad7d88b8b798c2eb`。语义覆盖仍为 partial；对 fork 停止函数的两次语义追踪仅保留种子节点，没有证明完整调用边，因此行为结论以明确源码链为依据，不声称已完整反编译所有模块。全部仍为静态分析，未执行参考服务或其下载程序。

[逐软件适配设计](developer-tool-adapters.md)规定安装来源、实例生命周期、专属业务能力与原生视图分别承担职责。当前四种实例配方采用小型策略，共享授权／记录与生命周期；界面共用视觉外壳，专属任务按实际接通能力组合，不能再以统一安装列表代替全部管理功能。

## 当前源码范围复核，2026-10-27

参考工作树当前为 `71288acf873fbade9889b14c25c78561362d9aab`，仍标记 4.20.2；不能继续用前次提交描述最新源码。两次新增提交修改 20 个文件，根注册和视图没有变化；本次重新核对 71 个根、38 个内部工具，以及 Composer/Maven、工具链管理器、插件和自定义模块的计数边界。新增源代码差异包括公共停止时限扩展、Consul/Neo4j/Cloudflare Tunnel 的专属等待，以及 ClickHouse companion 失败处理。

[本次报告](../../../output/reviews/developer-tools-scope-2026-10-27/REPORT.md)逐根列出专属能力及 Shou 当前差距；[全量领域图](developer-tool-capability-map.md)是后续范围入口。完整源码按 REA 技能要求使用普通源码工具分析，复用未变化文件的前次调用链；本次未运行参考软件，未新增二进制分析或原生验收。源码指纹覆盖不等于逐函数语义覆盖。
