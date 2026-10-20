# System architecture

Shared scan and execution feedback, batch counts, cancellation and progress diagrams: [operation progress](../product/operation-progress.md).

English | [简体中文](../zh-CN/architecture/system-design.md)

Current desktop navigation and automatic discovery follow [Unified daily cleanup](../product/unified-cleanup.md).

Status: current development architecture. Shared scanning, planning, receipts, Trash execution and bounded permanent execution have source implementations; Windows, distribution and filesystem race acceptance remain pending.

## 1. Constraints

Share one portable Swift core between the native macOS application and Swift CLI. Windows later consumes the same contracts/core. Rules are declarative whether handwritten or generated externally.

Shou integrates no models and develops or hosts no agents. Initial operation needs no cloud service, account, privileged helper, or persistent daemon. Keep real platform dependencies isolated without a speculative plugin runtime.

## 2. Context

```mermaid
flowchart TB
    User[User] --> GUI[Native desktop]
    User --> CLI[Swift CLI]
    Terminal[User bin shou launcher] -->|Execute packaged binary with original arguments| CLI
    GUI -->|Copy request and local paths| Skill[Bundled rule-authoring Skill]
    Skill -->|User hands off to existing client| Agents
    Agents[Existing coding agents] -->|Authorized calls| CLI
    Agents --> Draft[JSON rule draft]
    Draft --> GUI
    Draft --> CLI
    GUI --> Core[Shared core]
    CLI --> Core
    Windows[Future native Windows UI] -.Structured process bridge.-> CLI
    Core --> Policy[Access and safety policy]
    Core --> Store[Local versioned storage]
    Policy --> FS[Explicit workspace filesystem]
    FS --> Trash[System Trash or Recycle Bin]
    Core --> Results[Plans and receipts]
    Results --> GUI
    Results --> CLI
```

External agents, model-generated drafts, imported files, and project content remain outside the trust boundary.

## 3. Modules

```mermaid
flowchart LR
    App[macOS SwiftUI and AppKit] --> Core[Portable ShouCore]
    App --> Setup[First-use and scan access guidance]
    Setup --> Access[ShouPlatform / native access evidence]
    Access --> Privacy[macOS privacy settings, user controlled]
    App --> AgentSupport[ShouAgentSupport / Skill resources]
    CLI --> AgentSupport
    App --> SkillInstall[ShouPlatform / Skill installation and ZIP export]
    CLI --> SkillInstall
    SkillInstall --> AgentSupport
    CLI[Swift executable] --> Core
    App --> Quick[Desktop quick-clean routing]
    Quick --> Core
    App --> LargeFiles[Large-file browser and selection]
    LargeFiles --> Core
    Core --> CatalogQuery[Saved catalog directory and large-file queries]
    Core --> Uninstall[Application summaries and batch uninstall]
    Core --> PrivacyService[Source-specific privacy service]
    PrivacyService --> SQLite[Time-bounded schema-aware SQLite transactions]
    PrivacyService --> PrivacyReceipts[Irreversible aggregate privacy receipts]
    Core --> Rules[Rule validation and matching]
    Core --> Scanner[Scan orchestration]
    Core --> Planner[Evidence and planning]
    Core --> Safety[Access and protection]
    Core --> Router[Execution router]
    Router --> TrashExec[TrashExecution]
    Router --> PurgeExec[PermanentExecution]
    Core --> FollowUp[Restore and Trash follow-up]
    Core --> Store[Persistence orchestration]
    Scanner --> Interfaces[Platform capability interfaces]
    Safety --> Interfaces
    TrashExec --> Interfaces
    PurgeExec --> Interfaces
    FollowUp --> Interfaces
    Store --> Interfaces
    Mac[macOS adapter] --> Interfaces
    Win[Future Windows adapter] -.Implements.-> Interfaces
```

Core declares the minimal protocols it consumes. Platform packages implement them; the core never depends on concrete adapters. Rules, planning, and scanning initially remain responsibilities within one core package rather than independently published packages.

Skill resources are shared by both products. Installation and export stay outside cleanup storage and rule enablement; see [distribution architecture and sequence](../ai/skill-distribution.md).

### Isolated read operations

The desktop injects `NativeFileSystem(readWorkerExecutable:)` with the packaged `Contents/Helpers/shou` executable. Root-identity queries and full/cleanup traversal run in short-lived read workers so a stalled filesystem call does not keep the desktop waiting on that call. The CLI's hidden worker entry accepts only identity and inspection requests and runs before opening the record store. It is a platform implementation detail, not a public agent protocol, a second cleanup engine or a persistent service. The independent CLI keeps its normal direct adapter.

```mermaid
flowchart LR
    Core[Shared core] --> Adapter[Native filesystem adapter]
    Adapter -->|Identity and inspection| Worker[Temporary bundled CLI read worker]
    Worker -->|Read only| Files[Explicit filesystem scope]
    Worker -->|Validated evidence and progress| Adapter
    Adapter -->|Confirmed mutations and live verification| Parent[Parent native Trash and recovery operations]
    Parent --> Files
```

Each request uses a current-user temporary channel: a `0700` directory and `0600` files. Request/result versions, request identity, parent identity, output size, progress and snapshot structure are checked before evidence reaches Core. Malformed, missing, timed-out or cancelled work cannot become a complete snapshot. Scope, matching, candidate eligibility, plans and receipts remain owned by the shared core.

Cancellation or the wall-clock deadline requests termination of only the owned read child and returns without waiting for process exit. At most two live read children are retained, including a child still awaiting kernel exit; further work returns a resource limitation. A child watchdog also terminates it on parent exit or its deadline. This bounds desktop waiting and child accumulation; it does not promise immediate completion of a kernel request. Trash, restoration and permanent removal remain parent-process operations with native identity/manifests revalidation and existing confirmation/receipt gates. No model or agent is introduced. Automated checks cover evidence equivalence, cancellation, timeout, the two-child cap and capacity recovery. The packaged desktop has passed scan-stop and partial-result checks; exact runtime coverage is recorded in [acceptance](../engineering/acceptance-and-testing.md).

### Common application scanning

`KnownLocations` defines explicit roots and rule associations without accessing disk. `PlatformFileSystem.locationAvailability` supplies current availability; `ShouEngine` owns registration and bounded scanning. `BuiltinCatalog` binds fixed rules only to their exact known root. Project rules remain usable in selected project workspaces. A path with the same folder name elsewhere does not activate an application rule.

`scanKnownLocations` inventories roots, registers all available roots, then produces one `ScanSnapshot` per root. Registration happens first so it cannot invalidate earlier configuration digests. Missing roots are skipped; inaccessible or incomplete roots produce separate issues. The desktop standard scan probes conventional developer collections and includes remembered project folders; CLI `system scan` includes them only with `--include-projects true` (default `false`). Both use cleanup scope by default. Neither discovers projects through an implicit home-wide scan, changes operating-system permissions nor deletes targets. Plans remain bound to one root and explicit candidates.

`InstalledApplicationCaches` extends only the exact macOS current-user `Library/Caches` root. `ApplicationCatalogReading` supplies actual bundle identity/Info.plist evidence; `ApplicationUninstallChecking` supplies read-only owner activity facts without invoking the uninstall workflow. A valid installed owner with no observed duplicate identifier or overlapping discovery issue yields an exact directory rule. Static scopes, including disabled and narrower declarations, take priority. Optional snapshot/plan evidence binds selected owners and any partial-coverage flag. Plan creation, execute preflight and every item re-read inventory, the exact app and activity before shared permanent/Trash execution. Application ownership is distinct from cache ownership: administrator-owned third-party bundles can have eligible current-user caches. No bundle, support data or container is selected by this feature.

An unavailable inventory omits generic discovery; partial inventory remains partial and isolates failures to overlapping owner paths. An owner, descendant or ancestor issue, unavailable/uninspected owner source or observed duplicate blocks the affected cache. Other verified owners remain manually selectable with a digest-bound coverage warning and no automatic recommendation. Complete evidence becoming partial requires a new scan and explicit review. Fixed-rule scans remain available, and discovery issues surface in the system result. Snapshot filesystem status does not silently claim application inventory completeness. See the [daily cleanup architecture, flow and sequence](../product/unified-cleanup.md#installed-application-caches) and [optional evidence contract](data-model.md#4-scan-and-plan-states).

### Scan coverage and artifact evidence

`full` inspects the workspace tree for space analysis. `cleanup` uses enabled rule prefixes to decide which branches to discover, prunes `.git` during discovery, and fully measures a matched target before it can be eligible. Pruning discovery does not exempt protected content inside a matched target from inspection. Cleanup completion is not proof that the whole tree was measured: snapshots record `scope`, `treeComplete` and candidate coverage in `completedPaths`. A partial scan may authorize an independently complete target; missing legacy coverage never relaxes an incomplete target. UI must explain sparse cleanup results and request a full scan for directory-space exploration.

`ArtifactEvidenceChecking` is a read-only Core port implemented by `NativeArtifactEvidence`. Exact bundled definitions, not a rule ID prefix or user declaration, gate generated-source exceptions. Rust build-script `OUT_DIR`, Swift generated build products and Cargo extracted registry sources require their recognized layouts and native ownership/activity evidence. Cargo sources additionally require archive/checksum integrity and an available local restoration source. Tracked, modified, unknown or unverifiable data remains blocked. See [rule semantics](../rules/rule-specification.md).

`ApplicationActivityChecking` is a separate core port, implemented by `NativeApplicationActivity` using macOS running-application metadata. Known application rules are blocked while their application is running or activity cannot be checked. The engine checks during scanning and plan creation, then again immediately before each move. A late-running application produces a skipped item receipt; independent items continue. Shou never quits applications. This protects identified desktop applications; arbitrary compiler and package-manager tasks must still be stopped by the user. A process check cannot atomically prevent an application from launching after it.

| Layer | Concrete responsibility |
| --- | --- |
| `SmartScanView` / CLI | Start a scan, present progress and per-root evidence |
| `KnownLocations` / `BuiltinCatalog` | Explicit roots and declarative matching metadata |
| `ShouEngine` | Configuration, snapshots, policy, plans, revalidation and receipts |
| `PlatformFileSystem` | Availability, bounded inspection, identity and filesystem operations |
| `ApplicationActivityChecking` | Read application activity without controlling processes |
| `InstalledApplicationCaches` / application catalog and facts ports | Bind exact installed-ID cache rules and revalidate selected owners without uninstall authority |
| `ArtifactEvidenceChecking` | Read tracked-content, build-process and Cargo-integrity facts; never supplied by rule documents |
| `RecordStore` | Atomic records and cross-process mutation lease |

These are package-internal responsibilities and small ports, not a plugin system or a separate service for each rule. The CLI runs without the desktop process. A future Windows adapter must implement and validate its own roots, activity and Recycle Bin behavior before enabling them.

Repository organization; Windows and brand-source entries remain future deliverables:

```text
apps/macos/                 Native SwiftUI and AppKit application
apps/cli/                   Swift CLI: shou / shou.exe
apps/windows/               Future native Windows application
packages/shou-core/         Portable models, rules, orchestration, plans
packages/shou-platform/     Concrete platform implementations
packages/shou-contracts/    Language-independent schemas and contracts
skills/                     ShouAgentSupport and portable rule-authoring Skill
scripts/                    Build, check, package, benchmark
examples/rules/             Reviewable rules
assets/brand/               Brand source assets
tests/fixtures/             Fictional filesystem and contract fixtures
docs/                       English documentation and localized editions
```

See [monorepo and platforms](monorepo-and-platforms.md) for dependency rules.

## 4. Responsibilities

| Service | Owns | Excludes |
| --- | --- | --- |
| WorkspaceAccess | Root binding, actual access, expiration | Permission escalation through rules |
| RuleService | Parsing, versions, provenance, validation, enablement | Script execution or trusting model claims |
| Scanner | Bounded traversal, project clues, sizes, modification evidence | Declaring unknown directories disposable |
| Matcher | Deterministic predicates within bound scope | Searching unauthorized volumes |
| Planner | Deduplication, protection, selection, manifests, digests | Deletion or inherited authorization |
| Confirmation | Current plan/action confirmation in UI or TTY | Standing reusable permission |
| Executor | Revalidation, Trash operations, cancellation, outcomes | Blind path-based retries |
| ReceiptService | Verified restore and permanent batch removal | Emptying unrelated Trash contents |
| LocalStore | Atomic records, versions, locks, interruption data | Uploading file contents |

Presentation never owns a separate policy implementation. Localization changes display text, not business behavior.

## 5. Concurrency

Enable Swift 6 concurrency checks; provisional minimum macOS is 14. UI state is `@MainActor`; traversal and statistics run off the main thread. Use bounded structured concurrency, propagated cancellation, and coalesced progress updates. Unknown totals use counts/stages, not fabricated percentages.

Serialize destructive execution within a process and use platform-backed locks across processes. A Swift actor cannot protect independent GUI/CLI processes. Inject filesystem, clock, and persistence only at actual external boundaries.

The macOS application delegate and a forwarding window delegate guard termination and closing during mutations. They request cancellation through `AppModel` and await its execution task. Core checks cancellation before each item and before journaling; the native adapter finishes journaled Trash/restore verification in the parent rather than a cancellable read worker. Failure keeps the window available for review. Follow-up identity is the pair `(executionId, itemId)`, so matching item IDs in different batches do not share eligibility.

## 6. Local persistence

Begin with versioned JSON objects and streamable large manifests. Adopt SQLite only if measured query/volume needs justify it.

Platform adapters select user-scoped data roots. Use same-directory temporary writes, atomic replacement, and tested durability for intent journals. Lock configuration changes and destructive execution. Permit at most one destructive task per user; immutable snapshots can be read independently.

Caches are rebuildable; rules, exclusions, and receipts are not disposable scan caches. Persist intent before processing files. Disk-full or journal failure prevents starting; unexpected post-operation failures produce unknown states and stop further work. Revalidate local files rather than trusting their storage location.

## 7. Access and distribution

The GUI uses native directory panels; sandboxed designs require security-scoped bookmarks and lifetime management. Expired access requires reauthorization.

CLI path registration is configuration, not an OS permission grant. Actual terminal/process/TCC/filesystem access must be checked. GUI access does not imply CLI access or the reverse. No initial privilege-borrowing service is planned.

Prefer directly distributed signed/notarized macOS packages, subject to M0 validation of Sandbox, signing, CLI location, and permissions. Windows signing, runtime delivery, and native permissions are independent concerns.

## 8. Filesystem races

Record root and object identity, volume, type, size, modification/metadata information, and full directory manifests. Top-level `mtime` alone is insufficient.

Before execution, recheck access, configuration, rules, expiry, paths, identities, and manifests. Resolve paths within a verified root without following ancestor links; string-prefix checks are insufficient. Changed or unverifiable targets are refused/skipped without scope expansion or blind recursive fallback.

Known internal POSIX symlinks are opaque entries, never traversal roots. Platform Trash APIs and descriptor-based identity constraints need actual race prototypes. A check followed by an unrelated path operation is not an atomic safety guarantee; unmet constraints block release or narrow support.

Trash follow-up verification tolerates a change only to the saved top-level directory's `ctime`, which macOS may update after the move. Its identity and every other saved root field must still match, as must all descendant entries. This exception applies only to recorded Trash follow-ups; it does not relax ordinary scan or pre-move verification.

## 9. Existing-agent interface

Provide public rules, capability discovery, structured CLI results, and stable plan/history IDs. Existing Codex, Claude Code, and WorkBuddy tools may call these under their own authorization policies. No model SDK, agent runner, chat service, or global tool configuration is part of Shou.

`ShouAgentSupport` packages the rule-authoring Skill and its question matrix independently of `ShouCore`. Both frontends depend on this resource target. The Rules page copies a request containing local paths; `agent skill --json` exposes the same entrypoint and instructions without opening cleanup storage. The agent asks unresolved questions and writes a declarative draft; validation, disabled import, preview and later confirmed cleanup remain in the existing core. No agent process, provider SDK or inference service is added.

MCP is outside current scope; additional protocols require demonstrated integration needs. See [agent workflow](../ai/coding-agent-integration.md).

## Startup discovery boundary

`StartupInventoryService` owns read orchestration independently of cleanup storage. Core defines `StartupInventoryReading` and portable evidence/coverage models; `NativeStartupInventory` owns macOS directories, bounded physical reads, property-list interpretation and allow-listed read-only `launchctl` state queries for current-user agents. CLI and SwiftUI use the same service. The desktop opens Login Items through the public ServiceManagement API. State queries never change settings or require a privileged helper; mutation remains a separate, confirmed current-user control capability. See [startup discovery](../product/startup-items.md).

## 10. Engineering principles

KISS: one core with limited declarative semantics. DRY: reuse validation, protection, plans, and execution. YAGNI: no speculative cloud, scripting, privileged daemon, or model platform. SOLID: explicit responsibilities and minimal platform-facing interfaces.


## Application uninstall boundary

Application discovery and uninstall are a separate domain from rebuildable-cache rules. `ShouEngine` owns exact component associations, consent, current exclusions and digest-bound plans; `ApplicationCatalogReading` and `ApplicationUninstallChecking` supply platform evidence. The existing `TrashExecution` and `PermanentExecution` journals are shared with cleanup. Incremental `ApplicationSummary` results are separate from complete removal manifests; `ApplicationUninstallBatchPlan` binds explicit per-application selections and rejects overlapping paths before one confirmation. Each uninstall item records an exact original parent and component kind, allowing one receipt to cover several Library families and an installation directory. `ReceiptOrigins` validates those associations before history inspection or restoration. A separate restricted application-parent identity capability preserves ordinary workspace-root restrictions. See [application uninstall](../product/application-uninstall.md) for architecture, flow and sequence diagrams.

## 11. Current execution paths

The user experience intentionally has two levels. The desktop uses a fast path for verified built-in rules: one scan preselects eligible built-in and enabled personal-rule candidates and one native confirmation starts a concrete plan. Custom rules, blocked candidates and mixed selections enter the detail review. The CLI keeps explicit scan, plan and execute checkpoints because an existing coding agent needs stable JSON state and a resumable boundary.

```mermaid
flowchart TD
    Entry[Desktop or CLI entry] --> Fixed{Desktop fixed-rule path?}
    Fixed -->|Yes| Scan[Scan known locations and discovered and remembered projects]
    Scan --> Auto[Auto-select eligible built-in candidates]
    Auto --> Quick[Clean Recommended]
    Quick --> Mode{User chooses action}
    Fixed -->|No| Review[Review details and select explicit candidates]
    Review --> Mode
    Mode -->|Trash| TrashPlan[Create action=trash plan]
    Mode -->|Permanent| PurgePlan[Create action=permanent plan]
    TrashPlan --> Confirm[Native sheet or TTY confirmation]
    PurgePlan --> Confirm
    Confirm --> Revalidate[Recheck configuration, activity, identity and full manifest]
    Revalidate --> Route{Plan action}
    Route -->|trash| TrashExec[TrashExecution: move and verify returned location]
    Route -->|permanent| PurgeExec[PermanentExecution: purge bound manifest entries]
    TrashExec --> Receipt[Durable receipt and next actions]
    PurgeExec --> Receipt
```

`CleanupPlan.action` is the routing boundary. `TrashExecution` records the system-provided Trash location and supports later verified restoration. `PermanentExecution` uses the same plan binding, lease, revalidation and per-item journal, but calls the platform purge capability against the original path and never creates a recovery location. Neither executor accepts arbitrary shell text or expands a plan after confirmation.

```mermaid
flowchart LR
    Plan[Immutable plan + full manifests] --> Lease[Mutation lease]
    Lease --> Preflight[Fresh policy and identity checks]
    Preflight --> Journal[Persist execution intent]
    Journal --> TrashExecution[TrashExecution]
    Journal --> PermanentExecution[PermanentExecution]
    TrashExecution --> TrashReceipt[trash / trashed / trashPath]
    PermanentExecution --> PurgeReceipt[permanent / purging / purged]
    TrashReceipt --> FollowUp[Optional restore or purge of verified Trash items]
    PurgeReceipt --> Terminal[Completed, partial, cancelled or failed]
    FollowUp --> Terminal
```

The permanent path is deliberately a first-class action rather than a hidden fallback. Its safety boundary is the reviewed plan and its exact manifest: a missing, replaced, expanded or unverifiable item is skipped or fails, and unrelated Trash contents are never enumerated or emptied. `operation=permanent_cleanup`, `purging`, `purged` and `permanentlyRemovedBytesEstimate` make the irreversible outcome machine-readable.


## Explicit space-analysis removal

Space analysis now supports local volume/folder discovery and direct explicit file/directory removal, independently of cleanup-rule workspaces. Desktop list and treemap share navigation and normalized selection. Current manifests and exclusions are checked before confirmation and execution. It reuses existing mutation journals and history. See [space analysis architecture, flow and sequence](../product/space-analysis.md).

Default space measurement is separate from deletion manifests. A read-only worker streams all measured files into a private SQLite catalog with per-directory totals and completeness. Desktop and CLI query directories on demand; measurement no longer stops at the one-million-entry deletion-manifest cap. `StorageScan` references its catalog and records `measured_entry_count`; nodes expose `is_complete`, and partial sizes are lower bounds. Removal still requires fresh complete target manifests and independent verification. Legacy JSON and paged records remain readable.

On macOS, this worker uses a bounded FIFO of directories and up to eight concurrent readers. Bulk metadata reads overlap; SQLite appends and postorder totals remain serialized. Cancellation propagates from the parent task into the readers, and all tasks join before publication. See [scan architecture, flow and sequence](../engineering/storage-scan-performance.md).

### Privacy domain

Privacy records have a separate source model from cache files. GUI and CLI share `PrivacyService`; the platform discovers standard profiles and no-follow identities. Core checks time bounds, schema, activity, exclusions and fingerprints before per-source transactions. Receipts retain aggregates only; irreversible logical deletion has no restoration or disk-space promise. See [privacy architecture, flow, sequence and support matrix](../engineering/privacy-cleaning.md).
