# Domain data model

English | [简体中文](../zh-CN/architecture/data-model.md)

Status: development contract. [Swift models](../../packages/shou-core/Sources/Models.swift) implement the current entities; complete state and interruption acceptance remain pending.

## 1. Relationships

```mermaid
erDiagram
    Workspace ||--o{ RuleBinding : binds
    RuleDefinition ||--o{ RuleBinding : referenced_by
    Workspace ||--o{ ScanSnapshot : scanned_as
    ScanSnapshot ||--o{ Candidate : contains
    CleanupPreset ||--o{ RuleBinding : selects
    ScanSnapshot ||--o{ CleanupPlan : produces
    CleanupPlan ||--|{ PlanItem : contains
    CleanupPlan ||--o{ ExecutionReceipt : records
    ExecutionReceipt ||--|{ ItemReceipt : contains
    ItemReceipt ||--o{ FollowUpReceipt : followed_by
```

Relationships are conceptual; bindings may be shared across presets. Plan items retain scan provenance and rule-version snapshots.

## 2. Entities

| Entity | Important data | Constraint |
| --- | --- | --- |
| Configuration | Storage version, revision, workspaces, bindings, optional `global_exclusions` | Any policy change invalidates earlier scan/plan evidence |
| Workspace | ID, logical root, local path, volume/root identity, access credential | Never share credentials; verify access per entry point |
| RuleDefinition | ID, version, schema version, provenance, content digest, body | No silent same-version changes; draft is not enabled |
| RuleBinding | Workspace, rule version, enablement, exclusion/override digest | Local explicit binding; changes invalidate plans |
| CleanupPreset | Name, binding references, selection preferences | Stores logic, not execution permission |
| ScanSnapshot | ID, `scope`, `treeComplete`, `completedPaths`, configuration digest, status, statistics | Only independently complete, policy-valid candidates produce executable plan items |
| Candidate | ID, relative path, project clues, identity, estimates, risk, evidence | Unclassified directories remain visible but not executable |
| CleanupPlan | ID, API version, digest, creation/expiry, configuration, `action` (`trash` or `permanent`), state | Concrete targets/action; no dynamic expansion; action is immutable after confirmation |
| PlanItem | Candidate, original path, identity, full manifest digest | No duplicate or unresolved parent/child targets; manifest is the permanent-removal boundary |
| Confirmation | Plan/digest, action, entry point, time | One-time in-process confirmation, not a stored boolean |
| ExecutionReceipt | Execution/plan IDs, entry point, stage, overall outcome | Durable intent first; item records; partial outcomes possible |
| ItemReceipt | Original/result path, before/after identity, state, Trash path, error | `purging` is durable intent; `purged` requires a successful platform result; reverify before restore or purge |
| FollowUpReceipt | Item reference, restore/purge action, time, outcome | Separate confirmation; never rewrite original facts |

## 3. Rule lifecycle

```mermaid
stateDiagram-v2
    [*] --> draft
    draft --> invalid: Validation fails
    invalid --> draft: Revise
    draft --> validated: Validation passes
    validated --> enabled: Review and enable binding
    enabled --> disabled: Disable
    disabled --> enabled: Recheck and enable
    enabled --> draft: Import a new version as draft
```

A new version does not overwrite historical definitions. Enabling its binding invalidates pending plans using old configuration. Validation establishes structure and semantics, not disposability.

## 4. Scan and plan states

Scan states are `running`, `complete`, `partial`, `cancelled`, and `failed`. Status describes completion of the requested scan mode; it does not alone authorize a candidate. Permission gaps, budget interruption and cancellation remain visible. A fully measured candidate may remain eligible when an unrelated subtree is incomplete; incomplete targets cannot enter a plan.

| Snapshot field | Meaning |
| --- | --- |
| `scope` | `full` inspects the workspace tree; `cleanup` discovers only paths that can match enabled rule prefixes and fully measures matched targets |
| `treeComplete` | Whether the entire workspace tree was inspected; `complete` status in cleanup mode does not imply this is true |
| `completedPaths` | Relative roots of independently complete subtrees; a candidate requires full-tree completeness or positive coverage of its own subtree |

These fields are additive and optional for existing records. For legacy records without `treeComplete`, use the previous whole-tree status interpretation. Missing `completedPaths` supplies no independent coverage: an old partial snapshot does not gain execution eligibility. Plans retain the scan scope and budget for fresh policy reproduction, and every selected target still requires an unchanged complete manifest.

The validated time budget also bounds candidate analysis during scanning, planning, and execution. Candidate analysis uses a monotonic deadline in each phase; persisted budgets outside the supported limits are rejected before policy reproduction.

Space analysis requires a `full` scan. A cleanup snapshot is sparse evidence: absent directories and unvisited bytes are unknown, not zero. UI and machine consumers must show this limitation rather than present its root aggregate or treemap as complete disk usage.

```mermaid
stateDiagram-v2
    [*] --> preview
    preview --> ready: Selected and policy-valid
    ready --> stale: Expiry or changed state
    ready --> executing: Current confirmation and revalidation
    executing --> completed: All items succeed
    executing --> partial: Failure or skip
    executing --> cancelled: Cancellation leaves pending items
    executing --> interrupted: Unexpected termination
    stale --> [*]
    completed --> [*]
    partial --> [*]
    cancelled --> [*]
    interrupted --> [*]
```

A provisional plan lifetime is 10 minutes, subject to prototype evidence. Unexpired plans still require object revalidation. Scope, action, rule, or exclusion changes produce a new digest. `trash` and `permanent` are separate first-class actions; an action cannot be changed after the plan is confirmed. Never automatically replay partial, cancelled, or interrupted plans.

## 5. Item states

`pending`: no item-start boundary recorded. `moving`: durable Trash intent saved before the filesystem call; an unfinished result needs verification. `trashed`: verified move with actual location. `purging`: durable permanent-removal intent saved before the platform call; outcome is not yet known. `purged`: the bound original target was permanently removed and the result was saved. `skipped`: intentionally unprocessed. `failed`: known operation error. `unknown`: interruption prevents determining outcome. `restored` and follow-up `purged`: current status derived from follow-up receipts. Legacy pending records cannot prove no filesystem operation happened.

```mermaid
stateDiagram-v2
    [*] --> pending
    pending --> moving: action=trash
    pending --> purging: action=permanent
    moving --> trashed: verified Trash result
    purging --> purged: verified permanent result
    moving --> failed: known Trash error
    purging --> failed: known purge error
    moving --> unknown: interrupted result
    purging --> unknown: interrupted result
    pending --> skipped: safe boundary or policy change
    trashed --> restored: verified follow-up
    trashed --> purged: verified Trash follow-up purge
```

Execution progress is transient: `stage`, `processedCount`, `itemCount` and `path` describe actual work, not a new authorization or durable outcome. A stop request prevents new item operations at a safe boundary; an in-progress system Trash operation may finish and must be reconciled before the final receipt.

Follow-up progress uses the same transient type without changing persisted receipts or CLI JSON. Its total counts only explicitly selected items. `preflight` reports read-only verification; `restoring` or `purging` starts after the pending follow-up intent is saved. `processedCount` increases only after the completed or failed outcome is saved, so it counts persisted outcomes rather than successful actions. Cancellation before intent leaves the item unstarted; after a restore intent, the current item finishes and records its result before the next-item cancellation boundary. Neither progress nor a batch checkbox authorizes retrying a pending follow-up.

Do not rewrite initial facts or retry unknown items by old path. Permanent removal and external Trash actions can eliminate recovery. A `permanent` plan records `operation=permanent_cleanup`; its byte estimate is reported separately from volume availability.

`HistoryInspection` is a transient read result, separate from execution and follow-up facts. It retains the original recorded state, check time, unfinished flag and per-item observations of the exact saved paths. The mutation lease prevents concurrent Shou mutations during inspection; a shared entry/time budget bounds the directory checks. Full manifests and identities are compared, with the same recorded-root ctime exception as follow-up verification. This does not hash contents or promote unknown items into executable follow-ups. Missing destination paths are reported without searching the user's Trash. A pending restore/purge remains pending and blocked; observations do not manufacture a completion receipt.

## 6. Risk and explanation

Effective risk is the highest level required by declarations, provenance review, protection, and runtime evidence: `review`, `high`, or `blocked`. No level promises absolute safety or automatic execution.

Store matching conditions, rule/version, missing evidence, rebuild notes, exclusions, and protection reasons. Translation affects presentation only.

## 7. Identity and paths

Rules contain relative patterns; local bindings/previews/receipts may contain absolute paths. Use platform volume/object identifiers and available type, size, modification, and metadata-change evidence.

Directory manifests cover descendants, including opaque symlink entries without target traversal. A manifest digest is not a content hash or proof of reproducibility. Never infer identity from a path prefix, Unicode normalization, or case-folded string.

## 8. Capacity fields

| Field | Meaning | Limitation |
| --- | --- | --- |
| `logical_bytes` | Logical file lengths | Not allocated storage for sparse files |
| `allocated_bytes_estimate` | Reported allocation estimate | Hard links, clones, compression complicate attribution |
| `trashed_bytes_estimate` | Original estimate for successfully trashed targets | Not freed space |
| `purged_bytes_estimate` | Original estimate for permanently removed targets | Not guaranteed newly available space |
| `volume_available_before/after` | System-reported volume availability | Concurrent activity and snapshots affect observation |

Use integer bytes and UTC timestamps in machine contracts; localized UI uses explicit decimal units, not interchangeable GB/GiB labels.

## 9. Persistence and retention

Version configuration/rule/receipt formats; failed migrations preserve previous data. Scan caches and stale plans may be budget-managed, but history does not control file deletion.

Determine history retention from measured storage costs. Deleting history must explain potential loss of application recovery/ownership verification; it never deletes unrelated Trash items. User-scoped storage is not isolation from equally privileged local processes.

## 10. Exclusion policy and configuration compatibility

`Configuration.global_exclusions` is an optional array of validated relative patterns. Persistent `Workspace.exclusions` contains only that workspace's patterns; project exclusions are exact project prefixes combined with relative patterns. `ExclusionSettings` reports the global and workspace arrays and a stable, deduplicated effective array. Rule-specific exclusions remain independent.

Scanning and draft preview merge workspace and global protection before matching. The snapshot and plan retain this effective policy in `workspace.exclusions`. Planning and execution recheck the current configuration digest, recompute effective protection and reproduce eligibility; a stored plan is not authority to bypass a later exclusion. A protected descendant blocks its containing cleanup target.

Configuration version `1` remains readable when global protection is absent or empty. The first saved nonempty global exclusion upgrades storage to version `2`; removing the last pattern preserves version `2`. Earlier builds reject version `2`, preventing silent omission of protection during a downgrade. Version `1` containing nonempty global exclusions is rejected. This storage version is independent of CLI API `1.0` and rule schema `1.0`.

## 11. Startup discovery

`StartupInventory` is a transient read result independent of cleanup storage. `StartupDefinition` retains source/path, label, an optional absolute executable, trigger clues and a definition-only Disabled hint. For current-user LaunchAgents, configured and runtime states are best-effort point-in-time observations from bounded `launchctl` queries; unsupported or expired reads remain `unknown`, and no execution authority is derived from these facts. `StartupSourceCoverage` distinguishes inspected, missing, partial, unavailable and uninspected sources. The `launchd_definitions` scope and explicit unavailable source families prevent a complete source read from implying complete macOS registration coverage. See [startup discovery](../product/startup-items.md).


## Application review, plan and receipt origins

`ApplicationCatalog` distinguishes physical installations even when bundle identifiers match, and retains source coverage and issues. `ApplicationUninstallReview` contains nine exact component families, complete manifests, eligibility, personal-data consent requirements, blocking reasons and non-authorizing coverage warnings. `ApplicationUninstallPlan` binds selected components, app metadata, configuration, consent, budget and a 15-minute expiry. Initial configuration has a stable `unconfigured` revision until a real configuration is saved.

`ExecutionReceipt.operation` is optional for compatibility; `application_uninstall` items each carry `UninstallReceiptOrigin` with component kind, application path, bundle identifier and exact parent identity. Ordinary receipts cannot opt into these origins. Restoration validates component-kind paths and parent identity independently of discovery or a later application installation. Uninstall receipts currently allow restore only.

`FileEntry.contentDigest` is optional and omitted when absent, preserving legacy directory-manifest encoding. A standalone file target carries one root entry and a bounded SHA-256 digest. Its Trash-root comparison allows only ctime normalization while preserving content and every other metadata field. Directory descendants retain exact metadata comparison. See [application uninstall](../product/application-uninstall.md).


## Explicit space-analysis removal

Space analysis now supports local volume/folder discovery and direct explicit file/directory removal, independently of cleanup-rule workspaces. Desktop list and treemap share navigation and normalized selection. Current manifests and exclusions are checked before confirmation and execution. It reuses existing mutation journals and history. See [space analysis architecture, flow and sequence](../product/space-analysis.md).
