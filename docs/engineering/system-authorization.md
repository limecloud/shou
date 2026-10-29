# System authorization and item execution

English | [简体中文](../zh-CN/engineering/system-authorization.md)

Status: both platforms have source and portable checks. Native Windows, UAC and actual UI evidence is recorded separately; compilation does not establish native acceptance.

Core declares a small authorization port; Platform owns a process session. macOS uses native authentication and a private Unix socket. Windows uses UAC and an ACL-protected local named pipe. Both validate peer PID, process birth identity, executable path, random handshake and protocol version. The OS owns password UI. Shou stores no passwords and installs no persistent service. Process exit or channel failure ends the session; dispatched requests never reconnect or replay automatically.

Features share the established administrator session during one Shou run, without authenticating for every item or operation. Protocol v2 uses strictly increasing request sequences to reject replay and reordering with constant storage; cancellation binds the same request ID and sequence. The worker no longer exits after 10,000 cumulative requests; per-message and operation budgets remain bounded. The first request may initiate native consent. After cancellation, failed authentication or session loss, background work and subsequent items cannot open another password/UAC dialog automatically; recovery requires an explicit authorization action. Restarting Shou requires a new session: this contract does not retain administrator access across processes or restarts.

System capability is separate from current business consent. The protocol accepts fixed typed operations, never arbitrary commands, SQL, scripts or business-store paths. Windows covers privileged file identity/directory reads, provisioned-root checks, exact-manifest cleanup, MSI uninstall and current-user scheduled-task control. MSIX stays in its original user context. Another account's user installation does not become the caller's installation after entering administrator credentials. Existing Windows acceptance gates still govern public cleanup, system uninstall, startup and privacy execution.

Cleanup validates plan structure, digest, current confirmation, expiry, source bindings, configuration and overlapping scope first. Each item then rechecks its identity, complete manifest, ownership, exclusions and activity, persists intent, executes and records its outcome. An independently stale item or known permission/I/O failure does not suppress independent items. Unknown outcomes, journal failures, invalid global scope and cancellation stop further work. Privacy retains one database transaction per source. History recovery checks each item and never overwrites destinations. Cancellation cannot undo completed work; successful authorization does not retry an old cleanup plan.

| Feature | Access and scope |
| --- | --- |
| Smart cleanup, project outputs, application leftovers | Shared file capability; domain ownership, rules, full manifests, activity and exclusions remain enforced |
| Space analysis and large files | Shared bounded reads and cleanup; unreadable items retain coverage gaps, requiring a fresh scan after authorization |
| Application discovery and uninstall | macOS supports app-only review of missing metadata and administrator-owned bundles; Windows retains exact MSI/MSIX identity and never converts an unknown installer into file deletion |
| History, restore and later permanent removal | Shared file capability; reading a receipt grants no recovery authority and unknown results cannot replay |
| Privacy | Independent sources, transaction rollback and count verification; macOS Full Disk Access is separate, while exclusions are not administrator failures |
| Startup | macOS system daemons and Windows current-user tasks share their platform session; protected system sources and other accounts stay protected |
| Developer configuration and service logs | macOS uses exact identity at fixed supported configuration/log locations; log truncation retains the file; unimplemented Windows software-specific features remain unavailable |
| Software updates, tool install/uninstall and owner cache commands | Keep the package manager's execution/authentication boundary; never elevate arbitrary Homebrew, mise or Docker commands; Windows WinGet retains system-installer behavior |
| MySQL and other database administration | Database users, passwords and grants belong to their database session, independently of OS administrator access |
| AI credentials/configuration, monitoring, rules and record maintenance | Existing credential stores and private user records; read-only observations grant no process-control or deletion authority |

Full Disk Access, administrator identity, folder selection, database credentials and tool login are distinct capabilities. UI offers recovery according to observed errors. Authorization cannot hide system protection, changed identities, cloud placeholders or missing implementations. Shared resources and simulated tests cannot establish native Windows UAC, ACL, WinUI, installation or ARM64 acceptance.

macOS authorized space scans write their SQLite index only inside a newly created private temporary directory, closing the index before transferring ownership to the caller. The client verifies directory/file ownership, permissions and identity, then imports through exclusive creation in its own record directory. The pointer returned by `mkdtemp` belongs to its input buffer: copy it into a Swift string within the buffer pointer's valid scope, never after an implicit pointer conversion has ended. Regress this boundary with optimization enabled; a Debug pass alone cannot rule out pointer-lifetime failures. Windows has independent C# traversal and authorized reads and does not use this SQLite temporary-directory path.

## Authorization handshake regression

The ordinary client reads the elevated worker's effective UID and microsecond birth time using `KERN_PROC_PID`, alongside the Unix socket peer PID, executable path and random handshake. `PROC_PIDTBSDINFO` cannot inspect the administrator process across users and must not be used here. Read-only regression checks cover root-owned `launchd` and the caller, alongside session reuse, non-replay, cancellation and scope refusal.

Connection failures report incomplete authorization. Only a dispatched request that loses its result channel asks the user to inspect operation records. macOS owns the password dialog; automated protocol checks do not replace authentication completed by the user in that system window.

Both platforms have long-session regressions completing 10,005 requests over one authenticated channel, alongside replay rejection, cancellation and refusal to authenticate automatically after channel loss. These are local protocol/generated-fixture checks, not acceptance of native password dialogs or Windows UAC.

Application activity fallback also reads ownership and microsecond birth identity through `KERN_PROC_PID`, avoiding cross-user restrictions on `PROC_PIDTBSDINFO` in an administrator worker. Identity must match before and after `KERN_PROCARGS2`; unverifiable live processes still block removal. Failure diagnostics retain stage, PID, native error and caller/target UID, never arguments or environment contents. A fixed read-only `applicationActivity` request lets authorized component review verify the same context without mutation or replay authority.

Application selection shares this session: automatic queues allow initial authentication only, while cancelled/lost sessions require explicit row recovery. Success refreshes read-only evidence without execution. macOS adds fixed `inspectApplicationShortcut`/`purgeApplicationShortcut` worker operations, rejecting extra fields and limiting scope to a single dangling terminal link below installation roots. Windows machine-MSI administrator requirements come from installation identity; UAC cancellation retains selection/acknowledgement. Unsupported installers and system protection never offer authorization as a false remedy. Windows shortcut scope stays with current-user files, without elevated shell resolution or target execution.
