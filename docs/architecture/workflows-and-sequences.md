# Workflows and sequence diagrams

English | [简体中文](../zh-CN/architecture/workflows-and-sequences.md)

Current desktop navigation and automatic discovery follow [Unified daily cleanup](../product/unified-cleanup.md).

Status: current workflow contract. Diagrams describe the implemented desktop fast path, reviewed desktop path, CLI/Agent contract and their remaining acceptance limits.


The desktop defaults to permanent cleanup with one exact-scope confirmation. Trash remains optional; choosing it never silently falls back to permanent removal. The CLI explicitly supports `--mode permanent` while preserving its existing default. Both modes share root/target verification, exclusions, mutation leases and item journals.

## 1. Discovery and personal rules

The default desktop action scans known application/developer-cache locations and automatically discovered and remembered projects without a directory picker. CLI `system scan` defaults to fixed locations; `--include-projects true` adds discovered and remembered projects. Both default to cleanup scope; project discovery probes conventional collections without recursively searching the whole home directory. Explicit project scanning remains available; space exploration uses full scope.

```mermaid
flowchart TD
    Start[Scan common apps] --> Inventory[Inventory explicit known roots]
    Inventory --> Register[Register available roots before capturing evidence]
    Register --> Scan[Bounded scan per root]
    Scan --> State{Target subtree complete?}
    State -->|No| Issue[Keep affected targets blocked and retain complete siblings]
    Issue --> Results
    State -->|Yes| Activity[Check application activity and protection]
    Activity --> Results[Per-root reviewable and blocked results]
    Results --> Select[Select candidates in one root]
    Select --> Preview[Prepare concrete plan and confirm]
    Preview --> Recheck[Recheck files and application before each move]
    Recheck --> Receipt[Record moved, skipped, failed or unknown]
    Receipt --> Restore[Separately confirm verified restoration]
```

Moving to Trash is reported as a processed estimate, not freed disk space. Only independently complete targets may enter plans, even if the enclosing scan is partial. Missing legacy coverage does not authorize partial targets; cleanup-mode completion does not imply full-tree measurement.

## 2. Desktop fast path and detailed review

The initial view centers **Start Scan**, with scan modes in its adjacent menu and current disk capacity in the header. After the standard scan, eligible built-in and enabled personal-rule candidates are selected automatically. Category checkboxes and path details adjust the same selection; the fixed bottom bar shows its count, estimate and **Clean & Free Space** action. The immutable plan is created and revalidated behind that action; users do not navigate an internal plan screen. The scan-and-clean shortcut remains in the scan menu.

```mermaid
flowchart TD
    Open[Open Shou] --> Entry[Start Scan and scan-mode menu]
    Entry --> Scan[Scan fixed locations and discovered and remembered projects]
    Scan --> Matches[Group verified matches by app, browser, developer tool and project]
    Matches --> Auto[Auto-select eligible built-in candidates]
    Auto --> Recommended[Bottom bar: Clean and Free Space]
    Matches --> Details[Review Details]
    Details --> Adjust[Adjust categories and concrete paths]
    Adjust --> Selected[Clean Selected]
    Recommended --> Action{Trash or permanent?}
    Selected --> Action
    Action --> Trash[Create action=trash and confirm once]
    Action --> Permanent[Create action=permanent and show irreversible confirmation]
    Trash --> Verify[Revalidate exact files and policy]
    Permanent --> Verify
    Verify --> Execute[Run the selected executor]
    Execute --> Result[Show item outcomes, estimates and next actions]
```

This path handles built-in and enabled personal rules together while retaining exact-scope review. The action is visible at the point of execution: **Move to Trash** is recoverable through the recorded batch; **Permanently Remove** is irreversible and remains bound to the selected plan.

```mermaid
flowchart TD
    Root[Extra folder or Agent rule scope] --> Access{Actual access?}
    Access -->|No| Grant[Reauthorize or narrow scope]
    Grant --> Access
    Access -->|Yes| Scan[Full-scope read-only space scan]
    Scan --> Full{Complete?}
    Full -->|No| Partial[Show results and coverage gaps]
    Partial --> Grant
    Partial --> Inspect
    Full -->|Yes| Inspect[Inspect projects and directories]
    Inspect --> Known{Suitable rule?}
    Known -->|Yes| Evidence[Inspect evidence and risk]
    Known -->|No| Skill[Read shipped rule-authoring Skill]
    Skill --> Questions[Existing agent asks missing purpose and keep-path questions]
    Questions --> Draft[Agent writes rule from answers and evidence]
    Draft --> Valid{Validation passes?}
    Valid -->|No| Revise[Revise using explicit errors]
    Revise --> Draft
    Valid -->|Yes| Import[Import disabled draft and preview]
    Import --> Review{Purpose and scope established?}
    Review -->|No| Exclude[Keep disabled or exclude]
    Review -->|Yes| Enable[Review and enable]
    Enable --> Rescan[Fresh scan of enabled version]
    Rescan --> Evidence
    Evidence --> Target{Target subtree complete?}
    Target -->|No| Grant
    Target -->|Yes| Select[Explicit candidate selection]
    Select --> Plan[Concrete immutable plan]
```

Large unknown directories remain visible. Rule cleanup requires eligible rule matches; explicit space-analysis removal can handle user-selected files or directories without a rule. Cleanup snapshots contain only rule-directed evidence. Repair access or rescan affected targets rather than planning from incomplete target evidence; an unrelated gap does not invalidate a complete sibling.

## 3. Confirmation and execution

```mermaid
flowchart TD
    Plan[Concrete plan] --> Policy{Protection valid?}
    Policy -->|No| Block[Refuse with reason]
    Policy -->|Yes| Entry{Entry point}
    Entry -->|Desktop| Sheet[Native confirmation sheet]
    Entry -->|CLI| TTY{Interactive terminal?}
    TTY -->|No| Required[confirmation_required]
    TTY -->|Yes| Prompt[Display scope and request confirmation]
    Sheet --> Confirm{Current digest confirmed?}
    Prompt --> Confirm
    Confirm -->|No| Stop[Stop without target changes]
    Confirm -->|Yes| Verify{Access and object state valid?}
    Verify -->|No| Stale[Require new preview]
    Verify -->|Yes| Journal{Intent durably recorded?}
    Journal -->|No| Failure[Stop with journal error]
    Journal -->|Yes| Action{Plan action}
    Action -->|trash| Trash[TrashExecution: process and record each item]
    Action -->|permanent| Purge[PermanentExecution: purge bound manifest entries]
    Trash --> Result[Success, skip, failure, unknown]
    Purge --> Result
```

All entry points use the same policy. An unexpired plan still needs revalidation. Journal and filesystem operations are not a cross-system transaction.

## 4. Native desktop sequence

```mermaid
sequenceDiagram
    actor User
    participant UI as SwiftUI
    participant Core
    participant Store
    participant FS as Platform adapter
    User->>UI: Select candidates and preview
    UI->>Core: Create concrete plan
    Core->>Core: Deduplicate and bind evidence
    Core->>Store: Save immutable plan
    Core-->>UI: Scope, digest, risks
    User->>UI: Choose Trash or permanent removal
    UI-->>User: Show action-specific confirmation and exact paths
    UI->>Core: One-time current-digest confirmation
    Core->>Store: Acquire execution lock
    Core->>FS: Revalidate root and full manifests
    alt Changed or unverifiable
        FS-->>Core: Invalid state
        Core-->>UI: Refuse or skip changed targets
    else Valid
        Core->>Store: Persist execution intent and action
        loop Each still-valid item
            alt Trash action
                Core->>FS: Recheck and move to Trash
                FS-->>Core: Actual Trash location, identity, or error
            else Permanent action
                Core->>FS: Recheck and purge original path
                FS-->>Core: Purged, skipped, failed or unknown
            end
            Core->>Store: Persist item result
            Core-->>UI: Progress
        end
        Core-->>UI: Receipt and available next actions
    end
    Core->>Store: Release lock on all exits
```

Recheck near each operation rather than relying only on one batch-start check. Resource release must cover every exception path.

## 5. Independent CLI sequence

```mermaid
sequenceDiagram
    actor User as Terminal user
    participant CLI
    participant Core
    participant FS as Platform adapter
    User->>CLI: Scan, query, create plan
    CLI->>Core: Save fixed plan
    Core-->>CLI: ID and digest
    User->>CLI: Inspect plan
    CLI-->>User: Paths, evidence, estimates, risks
    User->>CLI: Execute plan with action=trash or permanent
    alt No TTY
        CLI-->>User: Exit 7, confirmation_required
    else TTY available
        CLI-->>User: Request TRASH or PURGE <plan-id> confirmation
        User->>CLI: Confirm exact phrase
        CLI->>Core: Execute bound plan
        Core->>FS: Revalidate and process
        FS-->>Core: Outcomes
        Core-->>CLI: Execution receipt
        CLI-->>User: Text or JSON result
    end
```

No desktop process starts. Existing-agent drafting/import is described in the [agent workflow](../ai/coding-agent-integration.md).

## 6. Recovery and permanent batch removal

```mermaid
flowchart TD
    Receipt[Execution receipt] --> Exists{Recorded Trash object verified?}
    Exists -->|No or unknown| Missing[Explain unavailable recovery]
    Exists -->|Yes| Action{User action}
    Action -->|Restore| Dest{Original destination free?}
    Dest -->|No| Choice{Choose another location?}
    Choice -->|No| Keep[Keep in Trash]
    Choice -->|Yes| Other[Verify new location and access]
    Dest -->|Yes| RestoreConfirm[Confirm restoration scope]
    Other --> RestoreConfirm
    RestoreConfirm --> Restore[Restore without overwriting]
    Action -->|Permanent removal of Trash item| Explain[Show exact items and irreversibility]
    Explain --> Confirm{Separate confirmation?}
    Confirm -->|No| Keep
    Confirm -->|Yes| Verify[Revalidate identity and manifests]
    Verify --> Purge[Remove verified items from this batch only]
    Restore --> FollowUp[Append follow-up receipt]
    Purge --> FollowUp
    FollowUp --> Capacity[Separate processed estimates and availability]
```

Cancellation never triggers restoration. Permanent removal is irreversible and never empties unrelated Trash contents.

## 7. Interruption reconciliation

```mermaid
sequenceDiagram
    participant Client as CLI or desktop
    participant Core
    participant Store
    participant FS as Filesystem
    Client->>Core: Query interrupted execution
    Core->>Store: Load durable intent and item results
    Core->>FS: Verify original and recorded destination identities
    FS-->>Core: Completed, unprocessed, or unknown
    Core->>Store: Append reconciliation evidence
    Core-->>Client: Actual state and next actions
    Note over Client,FS: Never replay unknown targets by old path
```

## 8. Invariants

Configuration/action/selection changes invalidate confirmation. Cancellation stops new items at safe boundaries while preserving completed facts; a single in-progress system Trash call may finish before stopping. Partial success is explicit. History records facts; current recovery availability requires inspection. Every exception has a CLI and GUI representation, not only a log entry.

For permanent execution, an item enters `purging` before the platform call and `purged` only after the result is durably recorded. A cancellation or unexpected failure leaves the batch `cancelled` or `partial`; Shou never reports an unverified item as permanently removed and never retries it by path alone.


## Explicit space-analysis removal

Space analysis now supports local volume/folder discovery and direct explicit file/directory removal, independently of cleanup-rule workspaces. Desktop list and treemap share navigation and normalized selection. Current manifests and exclusions are checked before confirmation and execution. It reuses existing mutation journals and history. See [space analysis architecture, flow and sequence](../product/space-analysis.md).

Default space measurement is separate from deletion manifests. A read-only worker streams all measured files into a private SQLite catalog with per-directory totals and completeness. Desktop and CLI query directories on demand; measurement no longer stops at the one-million-entry deletion-manifest cap. `StorageScan` references its catalog and records `measured_entry_count`; nodes expose `is_complete`, and partial sizes are lower bounds. Removal still requires fresh complete target manifests and independent verification. Legacy JSON and paged records remain readable.

Installation, access setup, limited-scope scanning and update identity follow the [installation flow and permission sequence](../product/installation-and-access.md).

## Application batches and privacy

Application uninstall follows incremental summaries → inline components → multi-application selection → one confirmation → batch preflight → per-component execution → shared history. Filtering preserves other selections. Permanent removal is the desktop default, with an explicit Trash alternative. See [application uninstall](../product/application-uninstall.md) for its flow, sequence and personal-data boundaries.

Privacy follows source/time-range scan → initially empty selection → separate Cookie consent → exact plan → irreversible confirmation → full preflight → per-source database transactions → aggregate receipt. Each source commits independently; later failures do not roll back already committed sources. There is no restore entry. See [privacy cleaning](../engineering/privacy-cleaning.md) for the architecture, flow and sequence diagrams.
