# Reference capability map and implementation gates

English | [简体中文](../zh-CN/engineering/reference-capability-map.md)

Status: source-based comparison, 2026-10-21. This document compares [MangoDisk](https://github.com/harry0703/MangoDisk), the open-source [Mole CLI](https://github.com/tw93/mole), and the current Shou worktree. It defines priorities and acceptance gates; it does not declare feature parity or release readiness. Existing large-file and permanent-removal acceptance retains its recorded scope. The initial comparison was read-only; 0.9.0 implementation status is tracked separately below. See [acceptance and testing](acceptance-and-testing.md) for executed test records.

The matrices and phase gates below preserve the **pre-0.9.0 implementation baseline**. They are not the current feature checklist. For implemented N01–N09, exact checks and remaining release/environment gates, use the [0.9.0 tracking document](next-version-0.9.0.md).

Product direction revised 2026-10-22: built-in cleanup AI is the next-stage mainline under [AI01–AI06](implementation-plan.md); the earlier priorities no longer exclude model integration. Source comparisons and historical acceptance retain their original dates and scope.

## Evidence contract

| Evidence | Supported conclusion | Limit |
| --- | --- | --- |
| MangoDisk source | Owners, algorithms, declared operations, safeguards and UI wiring at the inspected checkout | A complete source entry does not prove that an installed build executed the operation successfully |
| Mole source and upstream comparison | CLI commands, Skill distribution and changed selectors at a fixed commit | The separately distributed native Mole applications and their tested-app catalog are not verified by the open-source CLI checkout |
| Local Shou record inventory | File counts and serialized lengths in six inspected record collections at review time | Development-instance data, not typical-user growth, physical allocation or a performance benchmark |
| REA package inventory and property lists | Installed bundle identity, resources and declared metadata | Package facts do not prove interaction, permissions, scanning, mutation or recovery |
| REA passive runtime observation | The exact installed reference process/window exposed the cleanup entry, storage/privacy/system sidebar, scan button and scan-mode control; 42 accessibility nodes, no truncation or reported gaps | No action steps were supplied. This does not establish menu interaction, scanning, results, cleanup or recovery |
| CUA interaction with the installed reference | Observed cleanup category → rule → path hierarchy, mixed selection and fixed bottom selection/action area | No reference cleanup action was triggered; observations do not establish deletion or restoration behavior |
| CUA interaction with Shou | Accessible-scope setup, large-file filtering and selection, exact permanent confirmation cancellation, generated-fixture Trash execution and history restoration; other journeys retain their separately recorded scope | No automatic Full Disk Access, complete filesystem coverage, GUI permanent execution or missing feature families are established |
| Shou source | Existing capability boundaries and implementation owners | New or existing code still requires the relevant Core, CLI and native GUI acceptance |

All source paths below are relative to the repository named in the column. Counts describe the inspected catalogs, not successful tasks or supported-machine coverage. References to current Shou implementation are source facts unless a separately linked acceptance record says otherwise.

Local runtime evidence: `.build/mangodisk-rea-cleanup-runtime.json`, evidence ID `ev_d10f9814fdd19dd882d7b38fdd2ac46d1cb05aadbf769f85b69eac0f75e5a8be`. The observer used an isolated precompiled helper after the original compiler timeout; helper sources and executable were SHA-256 checked while the original target identity checks remained in force. The local artifact is separate from source conclusions and CUA observations.

## Review baselines

| Target | Inspected baseline |
| --- | --- |
| MangoDisk | Local source version 1.2.0, commit `032e1e140dec2e28d0bef3232f3f2197cbd4a4d9` |
| Mole CLI | Upstream commit `84dc779dc651ff1f0509a2054b6e25b8fb5d2ac5`, dated 2026-10-21 |
| Shou | Current local worktree, including the separately recorded hard-link permanent-removal fix |
| Existing Mole rule map | Still pinned to `7b2a196061e1be7fae4ba422cd9102313fcb321d`; this review does not update or revalidate the map against the newer commit |

The upstream comparison reports 25 commits and 60 changed files since the rule-map baseline, including `lib/clean/app_caches.sh`, `caches.sh`, `user.sh`, uninstall handlers and the Mole Skill. Source and comparison metadata are retained under `.build/reference-review-20261021/`. No reference cleanup scripts were executed. This round contains no shared-dataset three-product benchmark or new reference GUI acceptance, so it establishes neither speed ratios nor runtime parity.

## Pre-implementation capability baseline

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
| AI assistance | Context-specific `MdAiWorkspace` integration is present in the reference UI | Shou integrates external coding-agent rule workflows through `apps/macos/Sources/AgentRuleSetupView.swift`; the current version has no built-in model session. A cleanup-specific Agent is now in next-stage scope; see [integration design](embedded-ai-investigation.md) |
| Settings, exclusions and updates | Dedicated settings, locale, theme and update flows | Implemented settings/exclusions and Sparkle through `apps/macos/Sources/AppUpdater.swift`; installation and access guidance is being refined. A visible guide does not grant access |

## Pre-implementation daily-cleanup gaps

The main gaps concern reclaimable sources, repeated work and resolving failures. More navigation destinations would not close them.

| Area | Reference evidence | Shou gap and next boundary |
| --- | --- | --- |
| Smart Cleanup scanning — P0 | MangoDisk's `cleanup/scan.rs` compiles a scan plan and uses a hardware/device-bounded worker pool, capped at four; conservative device classes reduce concurrency | `KnownLocations.scanKnownLocations` scans registered roots sequentially. `NativeFileSystem.inspectTree` uses a recursive name/stat reader. The bulk metadata reader and 1–8 workers in `NativeStorageMeasurement` serve space analysis, not this cleanup path. Compile shared root work and reduce redundant I/O before tuning bounded concurrency |
| Repeat-scan reuse — P1 | MangoDisk's `storage/index/cache.rs` validates configuration fingerprints, mutation revisions and filesystem change tokens; platform adapters use FSEvents on macOS and USN evidence on supported Windows volumes | Shou persists scans/catalogs but has no corresponding change-tracking reuse contract. Add verified reuse with fallback when history is unavailable; a saved result alone does not prove freshness |
| Shou's own retained data — P0 | Direct read-only inventory of this local instance | Six collections total 2,992,132,938 serialized bytes: 587 scans (2,458,527,693 bytes), 43 plans (121,738,909), 100 storage-entry pages (343,096,059), 23 histories (59,501,382), six storage plans (8,689,225) and 22 storage scans (579,670). `HistoryRetention` only clears history/follow-ups; `LocalStore.removeHistoryRecord` excludes other collections. Add expiry/quota-based collection of derived records with reference protection, plus paged history summaries. `AppModel.refresh` currently loads full receipts through `Engine.history()` |
| Large tool-managed consumers — P1 | MangoDisk's `cleanup/cleaners/` has Docker build cache, Conda cache, unused Rust toolchains, model storage, archived Codex sessions and Xcode-specific handlers. Mole's `lib/clean/brew.sh` previews and executes matching `brew cleanup --prune=30` operations | Shou's directory-only rule format cannot invoke owner tools or select individual disk-image files. A BuildX path declaration does not reclaim the Docker daemon's build cache. Keep declarative personal rules for paths; add narrowly typed, fixed-operation adapters for sources needing tool/version/reference knowledge |
| Failure-to-resolution interaction — P0 | MangoDisk's `src/pages/cleanup/cleanup-application-close.ts` groups rules by owning application and scopes retries to remaining failed targets | Shou already has uninstall's Request Quit and a completion-page Scan Again. Request Quit does not wait for verified closure and resume the affected selection; the result retry starts another section scan. Smart Cleanup needs grouped close → verify → refresh affected targets → reviewed retry, retaining unrelated selection and successful outcomes |
| Orphans and privacy depth — P1/P2 | MangoDisk has independent `applications/leftovers/` and source-specific `privacy/` domains; Mole's `clean` includes already-uninstalled application leftovers | Shou associates components during uninstall but has no independent orphan inventory. Privacy supports selected history/cookie schemas, not the reference's full activity/account-state set. Add exact owner-absence evidence and prioritize explicit privacy sources rather than broad parent-directory deletion |
| External-agent customization — P1 | Mole now ships `skills/mole/SKILL.md`, `llms.txt`, Codex/Claude plugin entry points and `npx skills add` distribution. MangoDisk exposes `clean` with human/JSON/JSONL, apply, dry-run and explicit noninteractive confirmation options | CLI or a Skill alone is no longer distinctive. Shou has richer discovery/schema contracts and versioned personal-rule import/preview/enable reused by desktop. Complete uncovered-consumer discovery → external-agent rule draft → benefit verification → future reuse, reducing repeated handoff. Next-stage built-in cleanup AI reuses the same rule/execution flow while external interfaces remain supported |
| Windows product coverage — P1 | MangoDisk has 93 Windows filesystem TOML definitions, separate from 128 macOS and 31 project-artifact definitions; counts are not equivalent rule models | `BuiltinTemplate.supportedPlatforms` resolves to 210 macOS templates but only six Windows project templates; no fixed Windows cache location is enabled by those templates. `DesktopBridge` advertises applications/startup/privacy as false. Cross-compilation and bridge checks do not establish real Windows filesystem/UI acceptance |
| UI languages — P2 | MangoDisk contains 11 UI locale catalogs | Shou's `Localization.swift` exposes Chinese and English. Eleven README languages do not establish eleven application languages. Complete shared Core/macOS/Windows messages and switching acceptance before expanding language claims |
| Release identity — P1 | Shou's own packaging and installation contract | Local packages use an ad-hoc signature unless an explicit Developer ID identity is supplied. Sparkle exists, but Developer ID signing, notarization and clean-machine update/access acceptance remain separate work; changing local signing identity can invalidate privacy approvals |

### Rule coverage is still partial

The existing [Mole coverage report](mole-rule-coverage.md) contains 844 tested-app inventory entries, of which 83 map to explicit Shou cache/log declarations and 761 are inventory-only gaps. The offline manifest self-test passed in this review. These are mappings, not 844 application compatibility tests. Runtime installed-bundle cache discovery can find additional exact caches, but it does not establish application-specific profiles, tool-managed storage or orphan cleanup. The upstream README identifies the open-source CLI and native Mole app as separate downloads; do not attribute the native app's tested-app claims to CLI source acceptance.

### Architecture direction

Retain shared deterministic Core and native desktop/CLI adapters. Add a fixed-capability cleanup strategy beside path rules where needed: discovery → typed selection → exact preview → existing review/authorization → domain execution → outcome verification. For example, MangoDisk's Docker handler pins the local default context, separates preview from builder pruning, and bounds time/output. This is a useful adapter boundary, not a reason to permit arbitrary commands in imported JSON rules.

Routine desktop actions should remain one task with an appropriate confirmation and visible result. Internal scan/plan/execution contracts do not require separate user-facing pages. External-agent confirmation transport is a separate UX decision: Shou currently requires controlling-terminal confirmation for destructive public CLI execution and a request-scoped challenge for the Windows bridge. Neither contract changes during this review.

Exact duplicates and orphan removal offer more direct storage value than system-preference toggles or a resource dashboard. Universal-binary thinning, broad system optimization and monitoring remain optional. Built-in cleanup AI follows the new implementation plan; a product-hosted inference backend and general agent platform remain outside the initial stage.

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
| P0: daily cleanup reliability and cost | Smart Cleanup scheduling, retained-record collection, lightweight history, application-close/failed-target recovery and existing deletion regressions | Identical fixture coverage and cold/warm timing before/after; bounded concurrency/cancellation; record-quota tests preserving active plans and recovery facts; close → verify → scoped retry; stable counts/selection/results through partial failure; retain native permanent deletion and supported restoration regressions |
| P1: useful reclaim and customization | Selected owner-tool adapters, persistent agent-authored rules, independent orphan discovery, verified scan reuse, Windows cache coverage and distribution identity | Per-adapter preview/execution agreement, local-owner scope, time/output budgets and verification; external agent → disabled draft → preview → authorized enablement → desktop reuse; exact orphan association and owner absence; change-history invalidation; real Windows fixture deletion/UI; signed/notarized clean install and update/access acceptance |
| P2: storage and privacy breadth | Exact duplicates, selected privacy sources and additional UI languages; retain existing large-file contracts | Full-content duplicate equality, replacement detection and retained-file choice; large-file identity/pagination/accounting regressions; per-source privacy schema/time-range and impact consent, native mutation verification; translated messages and switching on each desktop |
| P3: optional extensions | Resource monitoring/menu bar, universal-binary optimization, reversible system preferences and selected maintenance, only after product selection | Monitoring needs metric origin, sampling interval, unavailable states and resource cost. Binary changes need architecture/signature identity, interruption handling, write verification and recovery policy. Preferences require recovery baselines and restoration; privileged maintenance requires accurate non-cancellable states. Built-in cleanup AI follows AI01–AI06 separately, rather than this optional system-extension track |

Every selected capability needs both positive and negative cases. Cover permissions, running applications, stale identities, protected descendants, unsupported schemas, time/output budgets, cancellation before and after mutation, partial failure and unknown verification. Use disposable generated fixtures for destructive acceptance. Never use a successful source build, catalog count, package inventory or visible page as a substitute for native end-to-end evidence.

For implementation status, retain separate facts for source presence, successful build, Core tests, CLI contracts, native GUI interactions and operation/recovery verification. Refer to [cleanup interaction and architecture decisions](reference-design.md), [system architecture](../architecture/system-design.md) and the actual [acceptance records](acceptance-and-testing.md) when updating this map.

## Acknowledgment

MangoDisk's available source informed capability inventory, scan scheduling, domain boundaries and phased acceptance criteria. Mole's public source informed CLI/Skill comparison and owner-tool cleanup boundaries; the separate [Mole coverage report](mole-rule-coverage.md) retains pinned rule-source attribution and license information. These acknowledgments do not imply affiliation, runtime parity or reuse of either complete catalog. Shou keeps its own native implementation, rules, Core contracts and safety boundaries.

## 0.9.0 implementation delta

The current worktree implements retention/history summaries, bounded concurrent cleanup roots, graceful app close/scoped retry, typed tool cleaners, measured agent rule discovery, eight Windows cache locations and independent orphan reviews. See [delivery tracking](next-version-0.9.0.md) for checks and remaining native gates. This does not close duplicate detection, FSEvents/USN reuse, broader privacy, Developer ID distribution or the 844-app rule-map gap.

Windows alignment update, 2026-10-22: the newer worktree declares 19 fixed Windows cache locations and 16 shared project rules, with exact AppData scopes, native project evidence, shared cleanup review, directory continuation, large-file management and an embedded AI interface. Application management, startup, privacy, default recycling/restoration, full localization and Windows distribution acceptance remain incomplete. Use the [current Windows implementation matrix](windows.md) for source status; the comparison tables above retain their original baseline and do not establish native Windows acceptance.
