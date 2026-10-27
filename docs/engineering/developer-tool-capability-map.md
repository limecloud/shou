# Developer tool coverage and domain boundaries

English | [简体中文](../zh-CN/engineering/developer-tool-capability-map.md)

Read-only review on 2026-10-27: FlyEnv 4.20.2 source at `71288acf873fbade9889b14c25c78561362d9aab`. The requested scope covers the entire tool module. MySQL, Nginx, Redis, PostgreSQL and MongoDB describe existing adapters, not the complete target. This document owns scope and capability ownership; [per-software adapters](developer-tool-adapters.md) owns implementation constraints and [developer tools](../product/developer-tools.md) owns user behavior.

## Source coverage

`src/render/core/AppModules.ts` registers 71 roots through `components/*/Module.ts`; `AppTool.ts` separately registers 38 internal tools. Composer and Maven are nested managers. Dynamic plugins and custom modules are open extension scopes and do not belong in the root count. The category enum declares 17 categories; Cron and Tools omit an explicit root `moduleType` and map to Other in Shou.

The [current source report](../../output/reviews/developer-tools-scope-2026-10-27/REPORT.md) and [machine inventory](../../output/reviews/developer-tools-scope-2026-10-27/source-inventory.json) retain all roots, tool declarations, entry links, fingerprints and changes from the previous review. Detailed call-chain evidence is reused for unchanged files and changed source is reviewed separately. Static entries establish neither runtime success nor behavior of the older installed artifact.

| Scope | Reference roots | Dedicated tasks to preserve |
| --- | --- | --- |
| Workspace orchestration, 1 | StartupGroup | Named groups, members, defaults, sorting and individual outcomes; separate from workspace selection and OS startup |
| Sites and certificates, 2 | Host, MkCert | PHP/Tomcat sites, vhost templates, hosts, import/export, root CA, certificates and keys |
| AI coding, 6 | Antigravity, ClaudeCode, Codex, CopilotCli, Kimi, OpenCode | Per-tool installation, configuration precedence, sessions, MCP, plugins or Skills; capabilities vary |
| AI services, 6 | CliProxyAPI, Hermes, MCP, N8N, Ollama, OpenClaw | Proxies, gateways, models, users, tool approval and audit, each with distinct state/configuration |
| Containers, 1 | Podman | Machines, images, containers, Compose, terminals, logs, builds and import/export |
| Tunnels, 2 | Cloudflared, CloudflareTunnel | CLI installation versus tunnel instances, domains, remote DNS/ingress, credentials and logs |
| Web, 6 | Apache, Caddy, FrankenPHP, HttpServe, Nginx, Tomcat | Configuration, instance directories, access/error logs and sites; directory sharing differs from installed services |
| Languages and SDKs, 18 | Bun, Deno, DotNet, Erlang, Flutter, GoLang, Gradle, Java, Nodejs, Perl, PHP, PHPFPM, Python, RoadRunner, Ruby, Rust, SwooleCli, Zig | Versions, PATH, manager defaults and projects; PHP extensions/Composer, Node scripts/dependencies, Maven, Android/ADB, Rust targets and FPM workers need separate adapters |
| Databases, 7 | ClickHouse, MariaDB, MongoDB, Mysql, Neo4j, PostgreSql, Qdrant | Data instances, users/grants/backups, extensions, Java and companions; category does not establish SQL compatibility |
| Cache and queues, 3 | Memcached, RabbitMQ, Redis | Runtime/configuration, Erlang/EPMD/plugins and Redis Commander; reference Memcached has no dedicated config/log page |
| Governance, 5 | Consul, Etcd, Rnacos, Temporal, TemporalCli | Cluster/data identity, configuration and UIs; production Temporal Server differs from CLI start-dev |
| Mail, 1 | MailPit | MP_*, SMTP/Web/POP3, mail database, retention, relay/webhook, logs and sources |
| DNS, 2 | DNS, Numa | Built-in TCP/UDP DNS versus standalone Numa, listeners, upstreams, records and runtime output |
| FTP, 2 | FTP, FTPSRV | Pure-FTPd versus built-in ftp-srv, accounts, passwords, directories and connections |
| Search, 4 | Elasticsearch, MeiliSearch, Typesense, ZincSearch | Installed/shared configuration, JVM, working directory, indexes, imports, initial administrator and Web addresses |
| Storage, 2 | Minio, Rustfs | Data directories/volumes, keys, TLS/KMS and consoles; installation and object data lifecycles differ |
| Other, 3 | Cron, Git, Tools | Scheduled tasks/history; Git/SSH/LFS checks; 38 tools and custom URLs |

Shou's 79 catalog entries map to these roots plus Composer, Maven, Claude Desktop, Gemini, Grok, Pi, MiniMax Code and Oh My Pi. The first two are nested reference capabilities and the other six extend Shou's AI scope. A name, source or detected path does not establish completed dedicated management.

## Compose capabilities around their objects

Software may participate in several domains. PHP has installations, configuration, extensions and projects; PHP-FPM adds instances. Podman owns machines, images, containers and Compose. Do not infer all actions from `isService`, build a universal superclass, or turn the 17 navigation categories into 17 domain aggregates.

| Capability owner | Objects and boundary | Adapter responsibility |
| --- | --- | --- |
| Installations and sources | Products, copies, sources, versions and install/remove plans | Separate Homebrew/WinGet/Static/fnm/nvm/GVM/rustup/SDKMAN source facts; no business configuration or database accounts |
| Instance lifecycle | Exact instance, supervisor, executable identity, configuration, working/data directories, stages and outcomes | Recipes, stop strategy, exit deadlines and rediscovery belong to software, not UI |
| Configuration and logs | Exact global, installed, instance, project or user files | Effective paths, includes, syntax, defaults, rotation and secrets, sharing safe file I/O |
| Projects and environment | Project, runtime, working directory, command, port, environment and outputs | Language-specific tasks; PATH, manager default and project runtime remain distinct |
| Database administration | Instance connection, databases, User/Host, grants, exports and maintenance | Engine-specific clients, authentication, SQL and dump arguments; MariaDB does not inherit MySQL 8 defaults |
| Sites and certificates | Sites, vhosts, hosts, CA, certificates and private keys | Engine-specific configuration; separate hosts writes, trust installation and certificate issuance |
| Containers | Machines, images, containers, Compose projects and volumes | Native CLI/API adapters, object-specific state, data effects, terminals and logs |
| Networking and sharing | Tunnels, remote DNS/ingress, listeners, shared directories and FTP users | Local/remote effects, credentials and connections; sockets differ from external processes |
| AI workbench | Client scopes, providers, sessions, MCP, Skills/Plugins, models and gateways | Per-client paths/formats, actual CLI features, credential references and supervisors; declarations differ from health |
| Tasks and group orchestration | Schedules, run records and group members/outcomes | Persistent scheduler adapters differ from member dispatch; workspace selection creates neither |
| Internal utilities | Conversions, file/process/network/system-environment actions | Separate in-memory, file, code-execution, trust and environment use cases without arbitrary Shell dispatch |
| Management companions | Companion installation, process, address and target association | Separate pgAdmin/DbGate/redis-commander/ch-ui/Temporal UI lifecycles; opening a URL proves no database authentication |

Core declares small interfaces for connected use cases, Platform software directories own their strategies, and native views compose connected tasks. Share identity checks, file access and state machines. Existing directories describe implementation, not final scope. Empty directories, capability constants and clickable placeholders cannot mark pending software complete.

## Consequences for implementation

Reference language switches operate on `LanguageProjects`, rather than starting a Python or Rust daemon; Gradle has no project page. Windows PHP-FPM workers are instance configuration. Source selection, current runtime, PATH hits, manager defaults and project runtimes need independent facts.

The current source also varies Unix exit deadlines: Base 10 seconds, Consul 60, Cloudflare Tunnel 40 and Neo4j 120, continuously observing exits and finishing early. Shou does not acquire those adapters merely by having a shared waiter. Generated fixtures must prove exit, retained state after timeout, stage logs and immediate feedback. Do not increase every global timeout or remove PID records before observing exit.

Verify reachable AI behavior: OpenCode Providers currently lists id/type, Hermes Providers is not mounted, Antigravity manages agy CLI, and Kimi MCP currently supports HTTP/SSE. Filenames, static catalogs or success notifications do not establish complete configuration. Failure-to-empty fallbacks, comment loss and unknown-as-OFF behavior should not be carried over.

Complete each use case through existing-installation discovery, exact copy/instance/project selection, current state, actual operation, independent read-back and failure diagnosis. Track installation, control, configuration, logs, business management and companions separately. Source, generated fixtures, Mac Computer Use and Windows native acceptance remain separate evidence.

## Current Shou gaps

Shared layers provide the catalog, existing-installation discovery, selected sources and supervisors. MySQL has subsets of database/account/export, configuration/log and instance-group tasks. Nginx, Redis and PostgreSQL have local recipes and configuration/log subsets; MongoDB has configuration/log path policies but no local recipe. Claude Code, Codex, OpenCode, Claude Desktop and Gemini have limited read-only configuration/extension metadata.

The subsequent configuration increment adds Apache, Caddy, Meilisearch, Consul, etcd, Numa and Mailpit directories and configuration/log path policies. These share exact-file I/O with the previous four; MySQL retains dedicated tasks. Existing storage discovery requires observed installations and files. Caddyfile, TOML and JSON follow the shared editing boundary, with discovery moved off the main thread. These are not new direct-instance control recipes or complete business-management implementations. See the [configuration increment](../../output/reviews/developer-configurations-2026-10-27/REPORT.md) for actual verification.

Other dedicated management, sites/certificates, language projects/environment writes, containers, tasks and complete networking/AI management remain pending. Shared Homebrew supervisor handling can cover other software only with exact verified registration/instances; it does not establish acceptance for every package. Windows SCM/installer public execution gates remain closed; the new dedicated configuration tasks are not implemented on Windows.
