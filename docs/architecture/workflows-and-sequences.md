# Workflows and sequence diagrams

English | [简体中文](../zh-CN/architecture/workflows-and-sequences.md)

Status: design draft. Diagrams specify intended behavior, not implemented capabilities.

## 1. Discovery and personal rules

```mermaid
flowchart TD
    Root[Choose workspace] --> Access{Actual access?}
    Access -->|No| Grant[Reauthorize or narrow scope]
    Grant --> Access
    Access -->|Yes| Scan[Read-only scan]
    Scan --> Full{Complete?}
    Full -->|No| Partial[Show results and coverage gaps]
    Partial --> Grant
    Full -->|Yes| Inspect[Inspect projects and directories]
    Inspect --> Known{Suitable rule?}
    Known -->|Yes| Evidence[Inspect evidence and risk]
    Known -->|No| Draft[User or existing agent drafts rule]
    Draft --> Valid{Validation passes?}
    Valid -->|No| Revise[Revise using explicit errors]
    Revise --> Draft
    Valid -->|Yes| Import[Import disabled draft and preview]
    Import --> Review{Purpose and scope established?}
    Review -->|No| Exclude[Keep disabled or exclude]
    Review -->|Yes| Enable[Review and enable]
    Enable --> Rescan[Fresh scan of enabled version]
    Rescan --> Evidence
    Evidence --> Select[Explicit candidate selection]
    Select --> Plan[Concrete immutable plan]
```

Large unknown directories stay visible but are not executable. Repair access or rescan narrower scope rather than planning from incomplete evidence.

## 2. Confirmation and execution

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
    Journal -->|Yes| Trash[Process and record each item]
    Trash --> Result[Success, skip, failure, unknown]
```

All entry points use the same policy. An unexpired plan still needs revalidation. Journal and filesystem operations are not a cross-system transaction.

## 3. Native desktop sequence

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
    User->>UI: Confirm moving to Trash
    UI->>Core: One-time current-digest confirmation
    Core->>Store: Acquire execution lock
    Core->>FS: Revalidate root and full manifests
    alt Changed or unverifiable
        FS-->>Core: Invalid state
        Core-->>UI: Refuse or skip changed targets
    else Valid
        Core->>Store: Persist execution intent
        loop Each still-valid item
            Core->>FS: Recheck and move to Trash
            FS-->>Core: Actual location, identity, or error
            Core->>Store: Persist item result
            Core-->>UI: Progress
        end
        Core-->>UI: Receipt and available next actions
    end
    Core->>Store: Release lock on all exits
```

Recheck near each operation rather than relying only on one batch-start check. Resource release must cover every exception path.

## 4. Independent CLI sequence

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
    User->>CLI: Execute plan
    alt No TTY
        CLI-->>User: Exit 7, confirmation_required
    else TTY available
        CLI-->>User: Request current-scope confirmation
        User->>CLI: Confirm
        CLI->>Core: Execute bound plan
        Core->>FS: Revalidate and process
        FS-->>Core: Outcomes
        Core-->>CLI: Execution receipt
        CLI-->>User: Text or JSON result
    end
```

No desktop process starts. Existing-agent drafting/import is described in the [agent workflow](../ai/coding-agent-integration.md).

## 5. Recovery and permanent batch removal

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
    Action -->|Permanent removal| Explain[Show exact items and irreversibility]
    Explain --> Confirm{Separate confirmation?}
    Confirm -->|No| Keep
    Confirm -->|Yes| Verify[Revalidate identity and manifests]
    Verify --> Purge[Remove verified items from this batch only]
    Restore --> FollowUp[Append follow-up receipt]
    Purge --> FollowUp
    FollowUp --> Capacity[Separate processed estimates and availability]
```

Cancellation never triggers restoration. Permanent removal is irreversible and never empties unrelated Trash contents.

## 6. Interruption reconciliation

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

## 7. Invariants

Configuration/action/selection changes invalidate confirmation. Cancellation stops new items while preserving completed facts. Partial success is explicit. History records facts; current recovery availability requires inspection. Every exception has a CLI and GUI representation, not only a log entry.
