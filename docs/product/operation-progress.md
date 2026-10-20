# Operation progress and feedback

English | [简体中文](../zh-CN/product/operation-progress.md)

Scanning, rule cleanup, application uninstall, storage analysis, large-file removal, history restore and privacy cleaning share progress components. Users can see the current action, measured counts and stopping state.

## Display contract

| Workflow | Count source | Presentation |
| --- | --- | --- |
| Smart scan | Sum of the highest observed entry count per location | Cumulative count, phase, current path, indeterminate progress |
| Storage and large-file scan | Entries measured by the read-only scanner | Count, path, elapsed time, indeterminate progress |
| Application scan and component review | Known application set and checked applications | Percentage, processed/total, current application; results stream into the list |
| Rule cleanup, uninstall, direct removal and restore | Reviewed independent targets and durable outcomes | Central progress screen, percentage, processed/total, path and Stop |
| Privacy scan and deletion | Discovered or reviewed database sources and transaction outcomes | Source counts and percentage; browser and profile names only |
| Startup discovery and plan preparation | Total not yet established | Current action, indeterminate progress and Stop |

Percentages describe processed targets in a known set, rather than elapsed time, successful cleanup or reclaimed disk space. A selected directory is one reviewed target. No file-level count is invented when its descendants have no individual progress events. Unknown scan totals remain indeterminate.

Preflight never advances deletion counts. Executors advance counts after persisting individual outcomes; failures and skipped targets are processed outcomes, while completion separately reports success, failure and remaining work. Final receipt handling displays “Finishing cleanup”. Partial results and cancellation never receive a fabricated 100%.

Multi-location cleanup keeps one denominator throughout the operation. Each subsequent plan starts from durable outcomes in the preceding plans, excluding unprocessed tails. Operation identifiers reject stale callbacks, and older counts cannot overwrite newer progress.

## Component architecture

```mermaid
flowchart LR
  Scan[Scanning and source discovery] --> Events[ScanProgress / ExecutionProgress]
  Execute[Shared executors and privacy transactions] --> Events
  Events --> Sessions[AppModel and page sessions]
  Sessions --> Aggregate[Batch counts and operation identity checks]
  Aggregate --> Full[OperationProgressView central screen]
  Aggregate --> Inline[OperationProgressMeter inline presentation]
  Full --> Artwork[Independent decorative motion]
  Preferences[System and application Reduce Motion] --> Artwork
  User[Stop request] --> Cancel[Cooperative cancellation]
  Cancel --> Execute
```

Decorative motion does not drive measured progress. It pauses when stopping, when the window is inactive, or when either Reduce Motion preference is enabled. Native typography, controls, accent color and accessibility identifiers accompany monospaced, transitioning numeric values.

## State flow

```mermaid
flowchart TD
  Start[Start operation] --> Known{Known total?}
  Known -->|No| Discover[Indeterminate activity and measured counts]
  Discover --> Ready[Results ready for review]
  Known -->|Yes| Check[Preflight and current target]
  Check --> Work[Process one target]
  Work --> Save[Persist actual outcome]
  Save --> Count[Advance count and percentage]
  Count --> More{More targets?}
  More -->|Yes| Work
  More -->|No| Finish[Save final receipt and show results]
  Stop[Stop requested] --> Boundary[Stop at a safe boundary]
  Boundary --> Partial[Show completed and remaining work]
  Check -->|Verification failure| Error[Preserve diagnostic and selection]
```

## Execution sequence

```mermaid
sequenceDiagram
  actor User
  participant UI as Progress screen
  participant Session as Operation session
  participant Core as Shared core
  participant Store as Local journal
  User->>Session: Confirm reviewed operation
  Session->>UI: Operation ID, total and preflight state
  Session->>Core: Execute with progress callback
  Core-->>Session: Preflight and current target
  loop Independent targets
    Core->>Store: Persist intent
    Core->>Core: Revalidate and execute
    Core->>Store: Persist individual outcome
    Core-->>Session: Actual processed count
    Session-->>UI: Verify operation ID and aggregate counts
  end
  opt Stop requested
    User->>Session: Stop
    Session-->>UI: Stopping at a safe boundary
    Session->>Core: Request cooperative cancellation
  end
  Core->>Store: Persist final receipt
  Core-->>Session: Complete or partial outcomes
  Session-->>UI: Actual results and follow-up actions
```

Privacy counts advance after each independent database transaction, without displaying browsing content, Cookie values or sites. Committed sources retain their outcomes after cancellation; remaining sources are not cleaned. Animation does not change Core or CLI consent, authorization or execution semantics.

## Verification scope

`shou-tests --operation-progress-only` covers batch totals, partial-plan boundaries, integer limits, privacy source progress, committed transactions, cancellation and durable restore boundaries. The installed desktop also requires checks of scanning, execution, stopping, Reduce Motion and runtime language switching. Automated mutation tests use generated data only.

Related: [system architecture](../architecture/system-design.md), [unified cleanup](unified-cleanup.md), [acceptance and testing](../engineering/acceptance-and-testing.md). Third-party references belong in [acknowledgments](../../README.md#acknowledgements).
