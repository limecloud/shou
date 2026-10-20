# Reference capability map and implementation gates

English | [简体中文](../zh-CN/engineering/reference-capability-map.md)

Status: source-based comparison, 2026-10-20. This document compares [MangoDisk](https://github.com/harry0703/MangoDisk) with Shou and defines acceptance gates for possible implementation phases. It does not declare feature parity, runtime acceptance or release readiness. The current round implements large-file Core, CLI and native GUI queries, selection and reviewed removal. Scoped local acceptance passed; this does not establish the remaining feature families. See [acceptance and testing](acceptance-and-testing.md) for actual test records.

## Evidence contract

| Evidence | Supported conclusion | Limit |
| --- | --- | --- |
| MangoDisk source | Owners, algorithms, declared operations, safeguards and UI wiring at the inspected checkout | A complete source entry does not prove that an installed build executed the operation successfully |
| REA package inventory and property lists | Installed bundle identity, resources and declared metadata | Package facts do not prove interaction, permissions, scanning, mutation or recovery |
| REA passive runtime observation | The exact installed reference process/window exposed the cleanup entry, storage/privacy/system sidebar, scan button and scan-mode control; 42 accessibility nodes, no truncation or reported gaps | No action steps were supplied. This does not establish menu interaction, scanning, results, cleanup or recovery |
| CUA interaction with the installed reference | Observed cleanup category → rule → path hierarchy, mixed selection and fixed bottom selection/action area | No reference cleanup action was triggered; observations do not establish deletion or restoration behavior |
| CUA interaction with Shou | Accessible-scope setup, large-file filtering and selection, exact permanent confirmation cancellation, generated-fixture Trash execution and history restoration; other journeys retain their separately recorded scope | No automatic Full Disk Access, complete filesystem coverage, GUI permanent execution or missing feature families are established |
| Shou source | Existing capability boundaries and implementation owners | New or existing code still requires the relevant Core, CLI and native GUI acceptance |

All source paths below are relative to the repository named in the column. Counts describe the inspected catalogs, not successful tasks or supported-machine coverage. References to current Shou implementation are source facts unless a separately linked acceptance record says otherwise.

Local runtime evidence: `.build/mangodisk-rea-cleanup-runtime.json`, evidence ID `ev_d10f9814fdd19dd882d7b38fdd2ac46d1cb05aadbf769f85b69eac0f75e5a8be`. The observer used an isolated precompiled helper after the original compiler timeout; helper sources and executable were SHA-256 checked while the original target identity checks remained in force. The local artifact is separate from source conclusions and CUA observations.

## Capability matrix

MangoDisk's navigation groups storage, privacy and system tasks. Its source entry is `src/lib/models/shell/application-shell.ts`. Shou's native navigation is owned by `apps/macos/Sources/ShouApp.swift`. A navigation destination is only one part of a capability.

| Capability | MangoDisk source and boundary | Shou status and implementation boundary |
| --- | --- | --- |
| Deep cleanup | `src-tauri/crates/mangodisk-core/src/cleanup/models.rs` defines ten categories; `src-tauri/crates/mangodisk-core/rules/filesystem/macos/` contains 128 TOML definitions and `src-tauri/crates/mangodisk-core/rules/project-artifacts/` contains 31 | Implemented with narrower coverage: `packages/shou-core/Sources/Resources/builtin-rules.json` contains 210 rules and 660 path patterns, bound to 65 explicit macOS roots. See the [Mole source and coverage map](mole-rule-coverage.md). `packages/shou-core/Sources/BuiltinCatalog.swift` owns the catalog. These counts are not equivalent to the reference's category or rule model |
| Space analysis | `src-tauri/crates/mangodisk-core/src/storage/analysis/service.rs` and its UI provide directory analysis, tree/treemap/sunburst views, cached results and mutation entry points | Implemented tree/treemap analysis with a SQLite directory catalog, progress and reviewed removal. Owners: `packages/shou-core/Sources/StorageOperations.swift`, `packages/shou-core/Sources/StorageCatalog.swift`, `apps/macos/Sources/StorageSession.swift`, `apps/macos/Sources/StorageViews.swift`. No sunburst view |
| Large files | `src-tauri/crates/mangodisk-core/src/storage/large_files/service.rs` provides a separate threshold-based inventory, cache and removal flow | Implemented with saved-catalog filtering, stable pagination, separate native entry, explicit cross-page selection, Quick Look and shared reviewed removal. Core 6/6 and installed CLI 34/34 passed; generated GUI fixtures completed Trash and restoration. See the scoped acceptance record |
| Exact duplicates | `src-tauri/crates/mangodisk-core/src/storage/duplicates/service.rs` uses file size, sample rejection, full BLAKE3 and a hash cache | Not implemented. Equal size or equal samples must not be presented as exact duplicates |
| Privacy cleanup | `src-tauri/crates/mangodisk-core/src/privacy/` separates browser activity/account state, application activity and system activity, with source-specific plans and policies | Source implemented in `PrivacyService`, `PrivacyDatabase`, `NativePrivacySources` and shared CLI/GUI entry points: standard Chromium history/cookies, supported Firefox schemas and Safari history schemas; explicit unsupported states for other kinds and browser-specific aggregates. Cookie sign-out consent and irreversible deletion are separate. See [privacy contracts](privacy-cleaning.md); executed acceptance is tracked separately |
| Startup items | `src-tauri/crates/mangodisk-core/src/startup/` separates inventory, policy, aggregation and control evidence | Implemented inventory and restricted current-user LaunchAgent control in `packages/shou-platform/Sources/NativeStartupControl.swift`. Login items and embedded helpers use native settings navigation where direct control is unsupported. `apps/macos/Sources/StartupInventoryView.swift` keeps definition, configured state and runtime state distinct |
| Application uninstall | `src-tauri/crates/mangodisk-core/src/applications/uninstall/` owns application identity, associations, plans, preflight, execution and history | Implemented incremental summary, inline component review, multi-application selection, batch preflight and one shared receipt in `ApplicationsSession`, `ApplicationUninstallBatch` and `packages/shou-core/Sources/ApplicationUninstall.swift`: application, caches, logs, preferences, application support, saved state, container, group container, WebKit and HTTP storage. Everything except the application/cache/log components requires additional personal-data consent. Desktop/batch defaults to permanent removal with a Trash alternative; the legacy single CLI plan defaults to Trash |
| Orphan leftovers | `src-tauri/crates/mangodisk-core/src/applications/leftovers/service.rs` provides a separate orphan inventory | Not implemented. Associated components of an installed application are not an orphan-only scan |
| Universal-binary thinning | `src-tauri/crates/mangodisk-core/src/applications/binary_optimization/macos_universal_binaries.rs` handles a distinct binary optimization operation | Not implemented. Ordinary cache cleanup must not modify executable architectures |
| System optimization | `src-tauri/crates/mangodisk-core/src/system_settings/catalog.rs` and `src-tauri/crates/mangodisk-platform/src/macos/system_settings.rs` provide 71 macOS preference definitions and corresponding platform handlers | Not implemented. Preference changes are not evidence of improved performance |
| System maintenance | `src-tauri/crates/mangodisk-core/src/system_maintenance/catalog.rs` and `src-tauri/crates/mangodisk-platform/src/macos/system_maintenance.rs` define ten macOS tasks | Not implemented. Tool availability is not a diagnosis that maintenance is required |
| Resource monitor / menu bar | `src/pages/tray-panel/index.vue` and platform system-resource providers expose CPU, GPU, memory, disk, network and process information | Not implemented. A disk-capacity summary is not continuous resource monitoring |
| History and recovery | `src-tauri/crates/mangodisk-core/src/history/` supports several operation domains | Implemented cleanup and uninstall receipts, inspection and separate restoration through `apps/macos/Sources/HistoryView.swift`, `apps/macos/Sources/HistoryInspectionView.swift` and Core records. Every new mutation domain needs explicit history and recovery semantics |
| AI assistance | Context-specific `MdAiWorkspace` integration is present in the reference UI | Shou intentionally integrates external coding-agent rule workflows through `apps/macos/Sources/AgentRuleSetupView.swift`; it hosts no model session or agent. Built-in AI is a product decision, not a presumed missing implementation |
| Settings, exclusions and updates | Dedicated settings, locale, theme and update flows | Implemented settings/exclusions and Sparkle through `apps/macos/Sources/AppUpdater.swift`; installation and access guidance is being refined. A visible guide does not grant access |

## Privacy: required granularity

The reference privacy model is a useful domain boundary, not a promise of uniform browser support. `src-tauri/crates/mangodisk-core/src/privacy/models.rs` distinguishes browser activity, browser account state, application activity and system activity. It also distinguishes ready, empty, running-owner, permission-required, unsupported-schema, unsupported and unavailable results. Unsupported and inaccessible sources must not become empty or successful results in Shou.

| Area | Observed source behavior | Implementation requirement |
| --- | --- | --- |
| Sessions and plans | `src-tauri/crates/mangodisk-core/src/privacy/service.rs` uses scan sessions, opaque selection tokens, expiring plans and confirmation requirements. It checks the entire plan's fingerprints before the first mutation and then rechecks individual entries | Keep scan → detail → selection → plan → preflight → execution → verification → history as one domain contract. Visible counts or a deletion button are insufficient |
| Running owners | Plans identify the owning browser/application and restrict close requests to the plan's own source IDs | Explicitly close or skip affected sources; never terminate unrelated processes or silently treat busy stores as clean |
| High-impact data | `src-tauri/crates/mangodisk-core/src/privacy/service/policy.rs` makes cookies/site storage manual with sign-out impact; passwords/autofill and editor local history are manual with data-loss impact | Separate impact classes and require explicit high-impact confirmation. Do not include these in ordinary cache convenience selection |
| Browser databases | `src-tauri/crates/mangodisk-core/src/privacy/browser_database/schema.rs` and `src-tauri/crates/mangodisk-core/src/privacy/browser_database.rs` contain schema-aware mutation, including implemented Chromium password removal | Define support per browser, data kind and schema. An older aggregate-only contract comment cannot override executable implementation; equal browser labels do not imply equal support |
| Safari | `src-tauri/crates/mangodisk-platform/src/macos/privacy.rs` exposes history, last-session data and cache, while cookie, password, autofill, site-permission and site-storage providers are absent in the inspected adapter | Do not claim comprehensive Safari privacy support from the shared data-kind model |
| Time ranges | Site permissions, saved passwords, autofill, frequently visited sites and website icons accept all-time operations only in the inspected service | Reject unsupported time filters; do not display a range that execution ignores |
| Native activity | The macOS adapter handles current clipboard state, recent documents/apps/networks and shell history. It does not provide clipboard history. Several document/application recent-item sources use native interfaces | Model each source independently. Do not substitute deletion of whole application-support directories for native recent-item or privacy operations |
| Sensitive details | Activity details are scoped to the active session and are prohibited from durable storage and logs by the reference model | Keep record contents out of logs, progress and persisted receipts; retain only the minimum operation facts needed for outcomes |

Protected group-container queries can block in the kernel; the reference macOS adapter documents this limitation and uses SharedFileList observation before some Office probes. A Shou implementation needs bounded, isolated read operations and honest cancellation/timeout states, rather than assuming every filesystem call is promptly cancellable.

## System optimization: reversible preferences

The inspected catalog and macOS adapter both contain 71 setting IDs. Their coverage includes Finder, Dock, panels, desktop metadata, Mission Control, windows, keyboard, documents/printing, Safari, TextEdit, Photos, personalized advertising, AirDrop, Activity Monitor, App Store, text substitutions, sound, Time Machine, sleep and security preferences. This is a preference-management catalog; no performance benchmark establishes acceleration.

`src-tauri/crates/mangodisk-core/src/system_settings/service.rs` expires plans, saves a merged per-setting recovery baseline before mutation, compares expected values and preserves recovery information when an error may have changed state. The platform adapter reads values back after writing. Only the inspected show-hidden-files operation immediately restarts Finder; other changes requiring an application restart remain separately gated.

`src/pages/system-optimization/index.vue` provides presets, categories, pending changes, risk confirmation and restoration. Equivalent Shou functionality must preserve exact before/after values, disclose restart effects, detect external changes and verify restoration. A list of toggles without those contracts does not satisfy this domain.

## System maintenance: task-specific outcomes

The reference macOS catalog has the following ten tasks. The availability scan mostly checks whether necessary tools exist; it does not diagnose ten faults or recommend running all tasks.

| Task | Actual operation boundary |
| --- | --- |
| Spotlight rebuild | `mdutil -E /` starts a rebuild; successful initiation is not completed indexing |
| LaunchServices refresh | Fixed `lsregister` garbage-collection and local/user registration commands |
| Quick Look cache | Fixed `qlmanage` cache reset and reset commands |
| Icon cache | Quick Look reset and, when necessary, icon-services process restart |
| Finder restart | Restart followed by a process-availability check |
| Core Audio restart | Restart followed by a process-availability check |
| User permissions | `diskutil resetUserPermissions` for the current user; command success does not independently validate every ACL |
| Legacy overrides | Remove specified legacy preference keys and read them back |
| Startup disk check | `diskutil verifyVolume /` verifies; no repair operation is present |
| DNS cache | Fixed cache-flush command and mDNSResponder signal |

Owners: `src-tauri/crates/mangodisk-core/src/system_maintenance/catalog.rs`, `src-tauri/crates/mangodisk-core/src/system_maintenance/service.rs`, `src-tauri/crates/mangodisk-platform/src/macos/system_maintenance.rs`. The service limits concurrency to two and serializes conflicting resources. Queued work may be cancelled; privileged work cannot be forcibly stopped after it starts. A future Shou implementation must report started, verified, failed, cancelled and possibly changed states according to each task's actual verification signal.

## Phased implementation and acceptance gates

These phases are sequencing proposals, not completion claims or authorization to modify system settings. Add only selected product capabilities; keep unimplemented destinations out of navigation. Use shared Core use cases for CLI and GUI instead of independent engines.

| Phase | Scope | Required exit evidence |
| --- | --- | --- |
| P0: existing journey baseline | Installation guidance, precise access status, standard scans, space analysis and existing cleanup/uninstall/startup boundaries | Clean install/update and language behavior; unknown access distinct from denied access; bounded scan/cancellation and partial results; generated-fixture review → confirmation → mutation → receipt → restore for supported recoverable operations. Read-only startup evidence and restricted control require distinct acceptance |
| P1: storage completion | Accept this round's large-file implementation; decide exact-duplicate and orphan-leftover scope; expand cleanup coverage only with explicit rules | Large-file threshold boundaries, stable file identities, complete measurement, hard-link accounting, cancellation, stale-plan rejection and GUI/CLI parity. Exact duplicates require full-content equality, replacement detection and explicit retained-file choices. Orphan detection requires evidence that an installed owner is absent and associations are exact |
| P2: independent high-impact domains | Privacy, reversible system preferences and selected maintenance tasks | Per-source capability matrix, unavailable/unsupported states, explicit impact consent, scoped owner-close policy, expiring plans, preflight, native execution, task-specific verification and durable outcomes. Preferences require recovery baselines and restoration; privileged maintenance requires accurate non-cancellable states |
| P3: optional extensions | Resource monitoring/menu bar and universal-binary optimization, only after product selection | Monitoring needs metric origin, sampling interval, unavailable states and resource cost. Binary changes need architecture/signature identity, interruption handling, write verification and a defined recovery policy. Built-in AI remains a separate product decision |

Every selected capability needs both positive and negative cases. Cover permissions, running applications, stale identities, protected descendants, unsupported schemas, time/output budgets, cancellation before and after mutation, partial failure and unknown verification. Use disposable generated fixtures for destructive acceptance. Never use a successful source build, catalog count, package inventory or visible page as a substitute for native end-to-end evidence.

For implementation status, retain separate facts for source presence, successful build, Core tests, CLI contracts, native GUI interactions and operation/recovery verification. Refer to [cleanup interaction and architecture decisions](reference-design.md), [system architecture](../architecture/system-design.md) and the actual [acceptance records](acceptance-and-testing.md) when updating this map.

## Acknowledgment

MangoDisk's available source informed the capability inventory, domain boundaries and phased acceptance criteria. The comparison credits that work without implying affiliation, runtime parity or reuse of its complete catalog. Shou keeps its own native implementation, rules, Core contracts and safety boundaries.
