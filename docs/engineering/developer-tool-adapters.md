# Per-software developer tool adapters

English | [简体中文](../zh-CN/engineering/developer-tool-adapters.md)

Status: working-tree implementation and requirements, 2026-10-27. The installed reference and its source checkout have different versions. Facts and unknowns are retained in the [module capability review](../../output/reviews/developer-tools-2026-10-26/flyenv-module-capabilities-detail.md), [installation and AI review](../../output/reviews/developer-tools-2026-10-26/flyenv-install-ai-detail.md), and [service interaction review](../../output/reviews/developer-tools-2026-10-26/flyenv-service-ux-detail.md). Inventorying 71 roots and analyzing 59 non-AI modules does not mean Shou implements them all.

The [full capability and domain map](developer-tool-capability-map.md) owns the complete target, refreshed against `71288acf873fbade9889b14c25c78561362d9aab`. Existing software directories and four local-instance strategies describe implemented subsets. Projects, sites/certificates, containers, networking, tasks and dedicated AI management remain in scope; five existing adapters cannot define the entire architecture.

## Objects and responsibilities

A software product, an installed copy, and a running instance are distinct objects. An installation source owns version discovery and installation/removal. An instance binds executable, PID and birth time, configuration, working directory and data arguments. One installation can serve several instances. Processes launched from a terminal or another development tool remain part of local discovery; sharing an installer does not justify merging their switches.

Core owns authorization, lifecycle stages, mutation leases and intent/result journals. Platform resolves a software-specific recipe and delegates execution to the shared lifecycle implementation. Source adapters verify source identity, available versions, downloads, installation and resulting installation identity; they do not own database or service configuration behavior. Native views compose implemented capabilities and submit exact object/actions without building commands.

The Swift instance implementation uses a closed `DeveloperInstanceRecipeAdapting` registry with four small strategies. Process discovery, filesystem identity, recovery records, startup output and transition verification are shared. Add a concrete strategy and generated fixtures for another supported program. Do not grow a product-name conditional tree, executable plugin mechanism, declarative shell runner or base class with unrelated optional methods.

## Capabilities differ

| Software | Dedicated behavior | Current boundary |
| --- | --- | --- |
| Nginx | Master/workers, prefix, configuration, PID, access/error logs and site reload | Instance recipe strategy; site editing and reload pending |
| MySQL | Separate installation and data instance; defaults-file, data, port, socket; databases, users/grants, maintenance password and backups | Instance recipe strategy and [dedicated administration](../product/mysql-administration.md): schemas/accounts/export, configuration editing, two log types and independent groups; maintenance recovery and complete sources remain pending |
| MariaDB | Separate client, authentication and dump arguments | Discovery/source review; database actions pending |
| Redis | Rewritten argv requires exact config, pidfile and working-directory association; Commander is a separate companion | Instance recipe strategy; incomplete recipes prevent stopping; Commander pending |
| PostgreSQL | Actual DATA_DIR, postmaster identity, logs and pg_ctl/direct-start differences | Direct postgres recipe strategy; custom startup and pgAdmin pending |
| Apache, Caddy | Executable-specific Apache configuration/access/error logs; extensionless Caddyfile | Configuration/log path strategies; sites, reload and local recipes pending |
| Meilisearch, Consul, etcd, Numa | Distinct TOML/JSON/YAML, version-specific configuration and startup output | Configuration/log path strategies; indexes, clusters, DNS and local recipes pending |
| Mailpit | Static version history, MP_* configuration, mail database, SMTP/Web addresses, relay/webhook | Catalog/Homebrew source and configuration/log path strategies; Static installation and mail management pending; reference backend filtering unknown |
| Runtimes | PATH, application current version, manager default, aliases and notes are separate facts | Installation discovery; environment/default writes pending |
| AI software | Providers, configuration precedence, MCP, Skills and gateway lifecycle | Limited read-only inventory; writes/gateways pending |

Database listing, creation/grants, maintenance password changes, companion deployment and backup are separate use cases. Opening a panel, saving a local password or observing exit zero does not verify a database action. Do not copy initialization/destructive data cleanup, unresolved backup promises or optimistic version switching from the reference.

## First display and background reads

Render the workspace and in-memory installation results before awaiting Homebrew/mise/WinGet or every service. Coalesce installation discovery into one in-flight request, publish executable paths and local metadata first, and progressively merge manager registrations. Keep search and tool navigation usable; an unfinished query must not be described as uninstalled.

Verify services in one scoped batch for tools selected into the current workspace, retaining session results and a separate observation time for each tool. Re-entry uses those results; explicit refresh observes again. Failed background reads retain rows and errors while disabling stale observations. A scoped Core query invalidates only the requested tools and rejects unrelated adapter results. Mutations wait for source discovery/service verification and always recheck live identity/state; display caches grant no authority.

FlyEnv provides per-module `installedFetched`, coalesced requests and a shared reactive list, while startup also scans visible services concurrently. This does not prove zero first-load scanning or a universal instant-load time. See the [loading trace](../../output/reviews/developer-tools-2026-10-26/flyenv-loading-detail.md). Record UI/performance evidence separately and keep read-only discovery out of global application busy state.

## Lifecycle and failures

Freeze and revalidate a recoverable recipe before stopping. Recheck the original instance, stop it and wait for its bound workers, persist the stopped stage, recheck program/configuration, start the same recipe, then independently observe the new instance. Preserve running facts and explain missing evidence when recovery is incomplete. Supervised instances require their verified supervisor; no name-based kills or SIGKILL fallback.

Homebrew KeepAlive jobs cannot use `services kill`, which may return zero while refusing to stop. The implementation uses bootout/bootstrap for the exact launchd job, or kickstart for an already loaded idle job. It verifies the domain, definition path and actually loaded program/arguments, preserving the persistent plist and disabled override. An unreadable old PID is not proof that the process exited. Real generated launchd fixtures and simulated manager tests are separate evidence.

Direct-instance recipes retain closed arguments, paths and identities rather than credentials or full process environments. Startup uses a fixed restricted environment and does not promise arbitrary manual environment reproduction. Unsupported arguments/supervisors preserve running facts with a reason. Business logs and private startup output are separate. The viewer reads only the last 64 KiB/200 lines locally and does not export their contents automatically. Startup output currently has no rotation policy.

Working-directory identity and writability checks traverse the path and read metadata without requesting a directory listing. Generated fixtures cover an execute-only working directory, avoiding an unnecessary request to read protected directories during service discovery.

## UI and verification

Each MySQL group row supplies its own action context and reuses the service controller; a collapsed creation form separately selects the installation version. Core `MySQLInstanceRegistry` owns reviews and journaling for registration changes. The native adapter checks the exact stopped group and configuration without initializing or deleting a database. Scanning evicts invalid recipes from in-memory observations; explicit re-registration restores a start recipe. Disabled recipe records remain for audit but are not published as stopped instances. Real processes started externally remain independently discoverable.

Share the compact toolbar, category list, source filter, installation table and feedback. Show each runtime instance with configuration, PID, state and direct switch/restart controls. Installation filtering must not hide instances launched through another source. Keep one primary progress indicator, retain rows/stages/logs/refresh after failure, and never present unknown as OFF.

Compose dedicated tasks progressively: databases/users/backups within a selected MySQL instance, source/configuration/Web tasks for Mailpit, version/default actions for runtimes, and configuration precedence/extensions for AI software. These are target layouts; unimplemented tasks must not become clickable shells. Background operations remain visible from configuration tabs. Share visual and state semantics without forcing identical menus and fields.

Verification separates shared contracts, per-software generated recipes/multiple instances/failures, native supervisor fixtures and real UI. Cover changed configuration, shared binaries, PID reuse, delayed worker exit, startup/log failures and normal application closing. Personal services remain read-only evidence. Windows SCM and direct-instance strategies need independent implementation and native acceptance; Mac builds, resource generation and portable .NET tests do not open Windows execution gates.

MySQL's current native composition and implementation limits are owned by [MySQL administration](../product/mysql-administration.md). It has a typed database adapter distinct from process/source adapters; do not infer MariaDB or PostgreSQL compatibility from a similar screen.

`NativeDeveloperConfigurationFiles` shares secure read/edit I/O. MySQL retains its dedicated path policy; eleven other connected tools compose small `DeveloperConfigurationAdapting` strategies. Configuration and installation discovery share existing development-environment storage roots; file existence provides a candidate only. Background discovery keeps tool switching responsive. Editing never broadens restart recipes; external-instance re-registration remains pending. MySQL stop verification can exclude another instance only with leading `--no-defaults`, closed exact arguments and a distinct resolved DATA_DIR. Same data, unknown/abbreviated options and missing paths remain ambiguous; original-PID exit alone is insufficient.

## Developer-tool domain organization

Tools remain in existing Swift/C# projects, grouped by use case and software adapter boundary without a new plugin or messaging framework.

| Directory | Ownership |
| --- | --- |
| Core DeveloperTools/Catalog | Tool identity, installation sources, current reviews and outcomes |
| Core DeveloperTools/Lifecycle | Instance state, single-use actions, stop/start stages and receipts |
| Core DeveloperTools/MySQL | Schemas, User/Host, exports and independent-instance registration |
| Core/Platform DeveloperTools/AI | AI software configuration/extensions, separate from Shou rule investigation |
| Platform DeveloperTools/Inventory | Sources and existing environment discovery |
| Platform DeveloperTools/Lifecycle | Shared process identity, supervisors, recipe registration and execution |
| Platform DeveloperTools/Configuration | Exact-file I/O and the small software-configuration adapter interface |
| Platform DeveloperTools/Nginx, Redis, PostgreSQL, MongoDB, MySQL | Per-software paths, configuration clues and recovery strategies; MySQL also owns native database operations |
| Platform DeveloperTools/Apache, Caddy, Meilisearch, Consul, Etcd, Numa, Mailpit | Concrete new configuration/log path strategies; no local lifecycle authority |
| macOS UI DeveloperTools/Workspace, Configuration, MySQL | Workspace composition, shared file tasks and dedicated MySQL views |
| Windows DeveloperTools directories | Implemented Catalog/Lifecycle/Inventory/AI/Workspace responsibilities; no empty adapters for pending software |

Implemented software adapters have their own directories. Shared lifecycle execution does not depend on a particular database administrator. Software strategies answer small, specific questions and never construct arbitrary shell commands. Configuration-path discovery and restart recipes are separate interfaces: readable configuration grants no start authority. Version sources belong to installation; accounts, sites and cache business operations belong to the appropriate software domain.

These are logical modules in the same compilation target, not separately compiled packages. Domain services depend on small interfaces assembled at application entry points. The 79 catalog names do not justify empty modules, per-model repositories, an event bus or generic base classes. Add only concrete strategies, use cases, views and fixtures, sharing identity and safety operations.
