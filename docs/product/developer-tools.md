# Developer tool management

English | [简体中文](../zh-CN/product/developer-tools.md)

Tools contains separate Developer Tools and [AI Workbench](ai-workbench.md) pages. Runtimes, servers and developer utilities belong to the former; AI software belongs to the latter. Project artifact cleanup remains under Apps & Projects. Discovery, package installation and cleanup authority are independent.

## Scope and implementation

The target includes all seventeen categories from the reference. The canonical [catalog](../../packages/shou-core/Sources/Resources/developer-tools.json) contains 79 entries, including eighteen AI tools. Fifty-four entries have observed Homebrew references and twenty-eight have WinGet references. Inclusion is not a claim that every installation, service or site adapter works. Current source, version, identity, platform and acceptance gates still apply; deprecated sources can identify existing installations without authorizing new installation.

The [full capability and domain map](../engineering/developer-tool-capability-map.md) covers 71 reference roots, 38 internal utilities and nested managers, separating installation, instances, projects, sites/certificates, containers, networking, tasks and AI. Existing software adapter directories describe an implementation subset, not the complete target.

| Capability | macOS working tree | Windows working tree |
| --- | --- | --- |
| Catalog, filters, search, favorites and separate AI page | Native source | Native source |
| Existing installations | Homebrew/mise registrations; common PATH, nvm/Python and known environment locations; matching npm metadata | WinGet registrations; process/user/system PATH and common tool/Node manager locations |
| Multiple installations, paths and versions | Separate observations | Separate observations; native evidence recorded independently |
| Review, expiring authorization and intent/result records | Swift Core and fixed Homebrew operations | C# Core and official WinGet COM source |
| Installation/uninstallation execution | Homebrew; generated manager fixtures, no personal software mutations | Native-installer acceptance gate remains closed; discovery and review available |
| npm, uv, Cargo and standalone installer mutations | Pending; discovery grants no uninstall permission | Pending |
| Immediate service switches | Current-user Homebrew services and four local-instance strategies; source/version/configuration binding | SCM/package/executable binding source; public mutation gate closed |
| MySQL schemas/accounts/configuration/logs/independent instances | [Dedicated implementation](mysql-administration.md); engine and UI evidence are separate | Dedicated adapter pending |
| Other database tasks, sites, certificates, containers and scheduled tasks | Separate work; not implied by MySQL support | Pending |

This implementation therefore does not support every reference feature. Unconnected entries accurately describe their state and link to official guides instead of exposing nonfunctional service switches.

## Existing environments

Read-only discovery precedes installation. Registration records, matching npm metadata and executable observations identify their source separately. Discovered programs are never executed to obtain versions. Metadata can supply a version; a file alone is labeled detected with unverified version and runtime health.

Different locations and versions remain separate. PATH aliases resolving inside the same manager-reported version directory do not create another installation. Budgets and unreadable sources produce partial coverage; absence means not found in scanned sources, not absent from the computer. Custom data roots, other managers, WSL, containers and whole-disk discovery are outside current coverage.

Discovery does not migrate, reinstall or modify PATH, shell profiles, databases, configurations or running services. Supported current-user instances are inventoried separately; only a complete verified recovery recipe and the current action request admit lifecycle control. An npm installation cannot be removed through Homebrew. Adding another source must identify the independent copy during review.

## Mutation contract

The installation page presents installed and available versions once per exact source and installation path, with one Uninstall entry. Installed packages are not duplicated in the available-package list. Service rows open uninstall for the installation they actually use. When multiple services share an installation, its review lists every affected instance and enables confirmation only after each has been stopped and verified. Multiple instances do not disable entry into review, and uninstalling a shared program is never described as removing just one service. The scope covers the verified version set owned by that source, without separately deleting data directories. Windows follows the layout and review source changes; installer and service mutation gates remain unchanged.

Core admits exact catalog identities and owns a two-minute, single-use plan binding action, source/manager identity, installed state, target version and native evidence. It rechecks before review and dispatch, obtains the private cross-process record lease, persists intent before mutation and records separately verified outcomes. Expiry, changed evidence, wrong confirmation or failed intent publication prevents dispatch.

macOS uses an existing Homebrew manager at a supported trusted location and fixed argument arrays. No shell, sudo, manager bootstrap, automatic license acceptance, zap, force, autoremove or dependency cleanup is requested. Homebrew may install/upgrade dependencies and run setup steps. Review describes declared direct dependencies and transitive effects; it does not claim every transitive version is frozen. Uninstallation permanently removes manager-owned software. Shou does not request removal of databases, models, projects, accounts or configuration, but package-owned uninstall hooks may affect their own files.

Windows validates the predefined official WinGet catalog, exact ID, version, installed identity and user/system scope. Installation pins the target version, rejects hash bypass, force, automatic agreements and unknown-version upgrades, skips dependency dispatch and never restarts Windows. Once dispatched, an installer is awaited; stop is not rollback. Existing cleanup/uninstall/startup gates remain unchanged, and this module requires its own native-installer acceptance.

Closing waits for the current manager. Missing verification, timeouts, failed processes and mismatched installation state remain uncertain without automatic retry or invented freed-space claims. Success requires reading back the target version or absence of that package registration. This does not establish full runtime health of the installed software.

## UI and ownership

Developer Tools and AI Workbench open on My Workspace, containing only explicitly selected tools. Add Tools combines the catalog with observed installation status and sources, with an Installed Only filter instead of another Installed tab. Its capsule switches add/remove workspace membership and persist immediately. Returning to My Workspace exposes management. Removing membership neither uninstalls software nor stops services; accessible names distinguish selection from runtime control.

The workspace retains a category rail and persistent details. One scoped query loads all selected tools, so each tool need not be opened first. Every rail row uses the same name, status and navigation arrow. Service switches live only beside exact instances in details; multiple instances remain separate. An empty workspace offers Add Tools without automatically selecting installed software. Mac Homebrew-backed tools share the available/installed version table previously limited to MySQL. Installation uses accent and uninstall uses red, with a single frozen review. Action buttons say “Uninstall” and open the existing exact-source and impact review in details.

Swift/C# Core owns validation and authorization; Platform owns discovery, fixed manager operations and native records; UI does not construct commands or infer uninstall authority from filenames. The catalog is generated into Windows resources with source digests. Update [SYNC.md](../../SYNC.md) for changes. See the [reference review](../engineering/tool-management-review.md). Domain, generated manager, real read-only inventory, WinUI and native-installer evidence must remain separate. Personal software is used only for read-only inspection and review cancellation.

The workspace uses a grouped tool rail and a persistent source/version/path table. Details retain resolved targets and launch aliases. macOS additionally recognizes fixed-identity Claude Desktop/Ollama application bundles; Windows npm wrappers use bounded, package-name-matched metadata. An absent optional manager alone is not a discovery failure.


First display does not wait for whole-machine discovery. Render the page/session results, progressively merge local metadata and manager sources in the background, and query services for the selected workspace set in one scoped batch. Read-only scans allow search, tool switches and navigation; mutations wait for verification. Each tool retains its observation time, re-entry avoids repeat discovery, and explicit refresh obtains new facts. Old display observations grant no mutation authority.

## Service capsule switches

The rail is navigation only, with a consistent name, status and arrow for every tool. Capsule switches live beside verified instances in the right-hand source table; multiple services remain separate. Unknown state is never shown as a fabricated OFF. AI uses this same interaction. An installed CLI, MCP declaration or skill does not establish a controllable background service. Favorites never substitute for service state.

Clicking requests one change to the displayed source/version without another dialog. Core consumes the exact observation, rechecks under the private mutation lease, persists intent before dispatch, awaits system state and separately records verification. Uncertain outcomes do not retry or restore authority to the old observation. Navigation and closing wait for in-flight work.

macOS supports catalog-owned, single-version, current-user Homebrew services. Manager, recipe, installation, definition and process identity are checked, and registered plists must match packaged definitions. KeepAlive uses verified-domain launchd bootout/bootstrap rather than Homebrew kill, which may return zero without stopping. Loaded idle jobs use kickstart. Persistent plists and disabled overrides remain unchanged. Unknown domains, multiple kegs and custom/foreign definitions remain unavailable. Simulated manager and real generated launchd tests are separate evidence.

Runtime instances are independent of installation origin. Four closed Swift strategies handle Nginx master/prefix/config, MySQL defaults-file/data/socket arguments, Redis configuration/pidfile/working-directory association, and explicit PostgreSQL DATA_DIR. Shared binaries retain separate instance PIDs/configurations. Persist a complete recovery recipe before stopping, wait for bound workers, then start and verify. Incomplete recipes/supervisors retain running facts and a specific reason without stopping first. Coverage is limited to supported current-user processes, not all users or all software. See [per-software adapter design](../engineering/developer-tool-adapters.md).

The Windows SCM adapter binds ordinary single-link binaries to explicit, freshly verified WinGet installation roots, versions, configuration and access. It does not alter startup type, elevate or force-kill processes. Its public control gate remains closed; known state is read-only until separate generated-service native acceptance.

### State, restart and source boundaries

Rows distinguish instance-scoped running/stopped, transitions and unknown observations. Last Checked and Refresh Status explain snapshot age. Full refresh invalidates old package review and refreshes AI inventory. Restart holds one mutation lease across stop, verified same-source/version stopped state, a durable stage result and subsequent start. A failed stop never dispatches start. Incomplete start preserves the stopped partial outcome without rollback or retry.

Other tools can run Homebrew binaries with their own configuration. Homebrew stopped does not imply no process exists. Supported direct instances remain separate, regardless of installer. Unverified supervisors retain their specific gap; there is no name-based termination fallback.

Details show configuration/definition, PID, login registration, actual transition stage and failure code. Logs are read locally, limited to the last 64 KiB/200 lines; startup output is separate from business logs. Log failures preserve service rows. One primary progress indicator belongs to the active instance; failures retain rows and refresh, and uncertain results require a fresh observation. Port health, PATH defaults, aliases, notes, groups, reload and continuous monitoring remain pending.

Node package metadata establishes package name and version, not the installing manager. Known Bun, nvm and npm storage roots receive separate storage-source labels; other locations show Node package. Source pills grant no installation or uninstallation authority.

MySQL now has a [dedicated administration contract](mysql-administration.md) for schema/account tasks, configuration, logs, exports and independent instance creation. This macOS implementation does not add those tasks to other tools or establish Windows parity. The contract records remaining gaps and evidence limits.

## Software configuration files and logs

Mac Nginx, Redis, PostgreSQL, MongoDB, Apache, Caddy, Meilisearch, Consul, etcd, Numa and Mailpit expose configuration/log tasks. Platform resolves existing files from exact instances, Homebrew service arguments and software-specific layouts. PostgreSQL DATA_DIR is distinct from installation. Observed installations can associate existing development-environment storage; a stored configuration is a file candidate, not proof that a running service uses it. Discovery and reads run in the background, discarding stale results after software changes.

Users can choose an exact file, including extensionless Caddyfile and cnf/conf/YAML/TOML/JSON. Unknown formats remain readable but cannot be saved. No include expansion, configuration execution, elevation or automatic restart occurs. The shared file adapter also backs MySQL: no symlinks, ordinary single-link files, 256 KiB limit, identity/text rechecks, locking, hash-only intent, same-handle writes and verified results. Only current-user-writable configurations without group/world write access can be changed. Running direct local instances must stop before saving. External-instance configuration changes still require a future restart-recipe registration flow; saving grants no restart authority.

Apache stored configuration uses the original executable-path digest; Caddy uses Caddyfile; Meilisearch/Numa use TOML; etcd uses YAML; Consul requires a verified major version for its JSON filename, without guessing when unknown. Mailpit uses MP_* environment configuration rather than an invented config argument; MP_LOG_FILE values retain embedded equals signs. Stored configurations/logs must already exist, without generating defaults.

Nginx resolves explicit absolute access/error paths, Redis resolves explicit logfile, and Apache resolves explicit access/error paths. Other new adapters use verified storage layouts or explicit configuration paths. Business logs and startup output remain distinct. PostgreSQL rotation, MongoDB YAML log paths and Nginx included-log directives are not fully parsed, so paths are not guessed. The viewer shows the last 64 KiB/200 lines. Missing path, unreadable file and empty log are separate states.

The log page additionally offers Clear Log, reviewing the exact path and allocation inline before one red permanent-clear confirmation. Core owns a two-minute single-use plan, live-file recheck, mutation lease, intent and outcome. Native truncates a safely writable current-user-owned ordinary single-link file in place, preserving its identity for service writers without Trash or recovery copies. Appends, replacements, links, unsafe permissions and missing intent prevent mutation. Continuing writes can leave verification uncertain; refresh is required without automatic retry. Journals exclude log contents, and allocation estimates do not promise an exact increase in system free space.

Recognized Homebrew installation rows directly expose uninstall review, verifying the complete set of versions the selected package will remove. Known active instances require stopping first, and dispatch rechecks current-user image paths beneath Cellar/Caskroom. Copied cask apps in Applications and other users are not fully covered, so this is not whole-machine activity verification. Static/custom installation-directory deletion and complete residual cleanup remain pending. Windows now implements the same permanent-log-clear domain contract and native log page. Nginx, MySQL and Redis discover existing local layout files; other tools allow an exact log selection through the native picker. Reads are limited to 64 KiB/200 lines. Truncation accepts only current-user-owned ordinary single-link .log/.err/.out files, pins ancestors and the file handle, and rejects reparse points, protected locations, replacements, appends and active write handles. Stop the writer and refresh when occupied. No elevation or recovery copy is used. Installation rows also expose exact WinGet-source uninstall review; its public installer execution gate remains closed. Dedicated configuration writes and other automatic log paths remain pending. Native results are recorded separately.
