# 开发工具全量能力与领域边界

[English](../../engineering/developer-tool-capability-map.md) | 简体中文

2026-10-27 只读复核 FlyEnv 4.20.2 源码，提交 `71288acf873fbade9889b14c25c78561362d9aab`。当前目标覆盖整个工具模块，不能以 MySQL、Nginx、Redis、PostgreSQL、MongoDB 五种已存在适配的软件代表全部范围。本文拥有全量范围及能力归属；[逐软件适配](developer-tool-adapters.md)拥有实现约束，[工具管理](../product/developer-tools.md)拥有用户行为合同。

## 源码覆盖范围

实际注册入口 `src/render/core/AppModules.ts` 扫描 `components/*/Module.ts`，当前共 71 个根模块；`AppTool.ts` 另外注册 38 个内部工具。Composer、Maven 是嵌套管理能力，插件及用户自定义模块是开放扩展范围，均不能混入根模块计数。分类枚举声明 17 类，Cron 与 Tools 根没有显式 `moduleType`，在 Shou 归入其他。

逐根能力、声明与视图链接、38 项内部工具、文件摘要及与前次提交的差异见本次源码报告 (本地证据: `output/reviews/developer-tools-scope-2026-10-27/REPORT.md`)及其机器清单 (本地证据: `output/reviews/developer-tools-scope-2026-10-27/source-inventory.json`)。未变化文件的深入调用链沿用报告中链接的前次证据；新提交另行复核。静态入口不证明运行成功，本机旧安装包也不代表当前源码行为。

| 范围 | 参考根模块 | 必须保留的专属任务 |
| --- | --- | --- |
| 工作台编排，1 | StartupGroup | 命名组、成员、默认组、排序、逐成员启停结果；与工作台成员选择及系统自启分别建模 |
| 站点与证书，2 | Host、MkCert | PHP/Tomcat 站点、vhost 模板、hosts、导入导出、根 CA、证书与私钥 |
| AI 编程，6 | Antigravity、ClaudeCode、Codex、CopilotCli、Kimi、OpenCode | 逐工具安装、配置层级、会话、MCP、插件或 Skills；不是每种软件都有所有任务 |
| AI 服务，6 | CliProxyAPI、Hermes、MCP、N8N、Ollama、OpenClaw | 代理、网关、模型、用户、工具审批与审计；各自有不同状态与配置合同 |
| 容器，1 | Podman | 机器、镜像、容器、Compose、终端、日志、构建、导入导出 |
| 隧道，2 | Cloudflared、CloudflareTunnel | CLI 安装与隧道实例分别管理；域名、远端 DNS、ingress、凭据与日志 |
| Web，6 | Apache、Caddy、FrankenPHP、HttpServe、Nginx、Tomcat | 软件配置、实例目录、访问／错误日志、站点集成；HTTP 目录共享不套用安装服务表 |
| 语言与 SDK，18 | Bun、Deno、DotNet、Erlang、Flutter、GoLang、Gradle、Java、Nodejs、Perl、PHP、PHPFPM、Python、RoadRunner、Ruby、Rust、SwooleCli、Zig | 版本、PATH、管理器默认版本、项目；PHP 扩展／Composer、Node scripts／依赖、Java Maven、Flutter Android／ADB、Rust targets、FPM worker 独立适配 |
| 数据库，7 | ClickHouse、MariaDB、MongoDB、Mysql、Neo4j、PostgreSql、Qdrant | 数据实例、账号／授权／备份、扩展、Java、管理面板；不能按共同分类推导 SQL 兼容性 |
| 缓存与队列，3 | Memcached、RabbitMQ、Redis | 配置与运行；RabbitMQ 的 Erlang/EPMD/plugin、Redis Commander 独立；Memcached 没有参考专属配置／日志页 |
| 治理，5 | Consul、Etcd、Rnacos、Temporal、TemporalCli | 集群与数据、配置、UI；正式 Temporal Server 与 CLI start-dev 是不同实例合同 |
| 邮件，1 | MailPit | MP_*、SMTP/Web/POP3、邮件数据库、保留期、relay/webhook、日志与版本来源 |
| DNS，2 | DNS、Numa | 内置 TCP/UDP DNS 与独立 Numa 程序分别处理；监听、上游、解析、实时记录 |
| FTP，2 | FTP、FTPSRV | Pure-FTPd 与内置 ftp-srv 分开；账号、密码、共享目录、连接及服务 |
| 搜索，4 | Elasticsearch、MeiliSearch、Typesense、ZincSearch | 安装／公共配置、JVM、工作目录、索引数据、导入、首次管理员、Web 地址 |
| 存储，2 | Minio、Rustfs | 数据目录／卷、访问密钥、TLS/KMS、console；安装与对象数据的生命周期分开 |
| 其他，3 | Cron、Git、Tools | 持久任务与运行记录；Git/SSH/LFS 检测；38 个内部工具及自定义 URL |

Shou 目录中的 79 项与上述范围对应，并额外列出 Composer、Maven 及 Claude Desktop、Gemini、Grok、Pi、MiniMax Code、Oh My Pi。前两项是参考中的嵌套能力，其余六项是 Shou 的额外 AI 范围。目录已有名称、来源或路径，不表示这些专属管理任务已经完成。

## 能力按操作对象组合

一个软件可以同时参与多个领域。PHP 有安装、配置、扩展和项目，PHP-FPM 再拥有实例；Podman 同时有机器、镜像、容器和 Compose。不要用一个 `isService` 或全能基类推导所有操作，也不把 17 个导航分类直接变成 17 个领域聚合。

| 能力所有者 | 操作对象与边界 | 软件适配的责任 |
| --- | --- | --- |
| 安装与来源 | 产品、安装副本、来源、可用版本、安装／卸载计划 | Homebrew/WinGet/Static 与 fnm/nvm/GVM/rustup/SDKMAN 各自维护来源；不负责业务配置或数据库账号 |
| 实例生命周期 | 精确实例、主管、程序身份、配置、工作／数据目录、阶段及结果 | 启动配方、停止方式、退出等待及重新发现；不同软件的参数和时限不塞入 UI |
| 配置与日志 | 全局、安装、实例、项目或用户作用域中的确切文件 | 生效路径、include、格式、默认值、日志轮转及敏感字段；安全文件 I/O 共用 |
| 语言项目与环境 | 项目、所选 runtime、工作目录、命令、端口、环境、构建产物 | PHP/Node/Flutter 等项目任务；PATH 命中、管理器 default 与项目 runtime 分开 |
| 数据库管理 | 实例连接、数据库、User/Host、授权、导出、维护态 | 每种引擎的客户端、认证、SQL、备份参数与分步回执；MariaDB 不继承 MySQL 8 的默认语义 |
| 站点与证书 | 站点、vhost、hosts、CA、证书及私钥 | 按 Web 引擎生成／核实配置；系统 hosts 写入、根信任与证书签发分别授权 |
| 容器管理 | Podman 机器、镜像、容器、Compose 项目与卷 | 原生 CLI/API 适配及各对象状态、数据影响、终端／日志；不把删机器包装成普通停止 |
| 网络与共享 | 隧道、远端 DNS/ingress、本地监听、共享目录、FTP 用户 | 本地／远端后果、凭据、连接与端口；内置 socket 服务不等同外部进程实例 |
| AI 工作台 | 客户端作用域、供应商、会话、MCP、Skills/Plugins、模型、网关 | 逐客户端路径与格式、实际 CLI 能力、凭据引用和网关主管；声明与运行健康分开 |
| 任务与组编排 | 定时任务、运行记录、启动组成员与逐项结果 | Cron 的持久任务适配和组的成员调度分开；工作台选择不自动创建启动组 |
| 内部工具 | 转换、文件、进程、网络或系统环境操作 | 纯内存转换、文件写入、用户代码执行、信任／环境改动采用各自用例，不共享任意 Shell 入口 |
| 独立管理面板 | companion 安装、进程、地址、与目标实例的关联 | pgAdmin/DbGate/redis-commander/ch-ui/Temporal UI 分别管理；打开 URL 不代表数据库已认证 |

Core 为实际接入的用例声明小接口；Platform 的软件目录拥有本软件策略；UI 组合确已接通的任务。共用身份核验、文件访问和状态机，避免每个目录复制执行器。已有目录是当前实现清单，不限制最终软件范围；待实现的软件不得通过空目录、常量 capability 或可点击占位页获得“完成”状态。

## 对后续实现的直接约束

语言模块侧栏在参考中控制 `LanguageProjects` 的项目集合，不是启动“Python 服务”或“Rust 服务”；Gradle 又没有项目页。PHP-FPM 的 Windows worker 是实例配置，不能等同项目数量。来源筛选、当前运行版本、PATH 命中、管理器默认版本与项目运行时需要独立事实。

参考当前提交的停止差异也需纳入软件策略：公共 Unix 上限 10 秒，Consul 60 秒、Cloudflare Tunnel 40 秒、Neo4j 120 秒，均持续核对退出并可提前完成。Shou 当前共用等待并不因此自动拥有这些适配；新增时应分别使用生成夹具证明真实退出、超时保留、阶段日志和立即反馈，不能给全部服务加长 timeout 或先清 PID 记录。

AI 需要逐项核实可达功能：OpenCode Providers 当前只列 id/type；Hermes Providers 未接入根页；Antigravity 管理 agy CLI；Kimi MCP 当前只有 HTTP/SSE。不能把文件名、静态目录或提示成功当作已完成的配置流程。参考的失败转空列表、格式重写丢注释和未知状态显示关闭也不能沿用。

每项软件按“已有安装发现 → 选择确切副本／实例／项目 → 读取状态 → 实际任务 → 独立回读 → 失败定位”完成闭环。安装表、启停、配置、日志、专属管理与 companion 各自记录完成度；Mac 源码、生成夹具、Computer Use 与 Windows 原生验收分开。

## Shou 当前差距

当前共用层包含目录、已有安装发现、部分安装来源与服务主管。MySQL 已接入数据库／账号／导出、配置／日志及实例组的部分用例；Nginx、Redis、PostgreSQL 有本机配方及配置／日志子集；MongoDB 有配置／日志路径策略，尚无相应本机配方。Claude Code、Codex、OpenCode、Claude Desktop、Gemini 只有有限只读配置／扩展元数据。

后续配置增量新增 Apache、Caddy、Meilisearch、Consul、etcd、Numa、Mailpit 七种软件目录及配置／日志路径策略，与前四种共用确切文件读写；MySQL 仍保留专属任务。按真实文件与安装观察发现已有存储，Caddyfile、TOML、JSON 使用同一编辑安全边界，配置发现移至后台。它们不是新增的本机启停配方，也未实现各软件的全部业务任务。实现与实际验证见配置适配增量 (本地证据: `output/reviews/developer-configurations-2026-10-27/REPORT.md`)。

其余软件的专属管理，以及站点证书、语言项目／环境写入、容器、任务、完整网络和 AI 管理仍未接通。Homebrew 主管的共用能力可能覆盖更多软件，仍需精确登记与实例核验；不能因此宣称每个软件已验收。Windows SCM 与安装器的公共执行门禁继续关闭，新增配置任务尚未在 Windows 实现。
