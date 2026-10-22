# Built-in AI: architecture, states, flows and sequences

English | [简体中文](../zh-CN/architecture/embedded-ai.md)

Date: 2026-10-23. The [product contract](../product/embedded-ai.md) owns user behavior; this document explains shared implementation. The gate, router, shared launch and desktop waiting-record continuation after restart are implemented. Interrupted-running recovery and additional adapters remain future work. Diagrams do not establish acceptance on every platform. See the [acceptance matrix](../engineering/embedded-ai-acceptance.md).

## 1. Context and trust boundaries

```mermaid
flowchart TB
    User[User] --> Desktop[Native macOS pages and inspector]
    User --> CLI[Independent CLI]
    Desktop --> Gate[Desktop AI switch and request gate]
    Gate --> Session[AIWorkspaceSession]
    Session --> Service[ShouAI investigation service]
    CLI --> Service
    Bridge[desktop bridge] --> Service
    Service --> Route[Task router]
    Route --> Local[Core and local rule or text templates]
    Route --> SDK[Swift AI SDK for open-ended understanding]
    SDK --> Provider[User-selected model gateway]
    Route --> Decision[StructuredDecisionService]
    Decision --> Jev[Jev native decisions]
    Service --> Evidence[Bounded index evidence tools]
    Evidence --> Core[ShouCore queries and rule validation]
    Core --> Index[Local space catalog]
    Service --> Checkpoint[Local investigation checkpoint]
    Desktop --> Profiles[ShouPlatform profiles and private credentials]
    CLI --> Profiles
    Profiles --> Service
    Service --> Advice[Validated advice]
    Advice --> Preview[User selects one disabled import and preview]
    Preview --> Review[User enables and freshly scans]
    Review --> Confirm[Existing concrete plan and confirmation]
    Confirm --> Execute[Deterministic execution and receipts]
    Execute --> Files[Local filesystem]
```

External services receive bounded evidence and user answers. Model output, names and answers remain untrusted. Neither model has deletion tools. The route to execution crosses user review, enablement, a fresh scan and current confirmation; it is not one model-callable action.

## 2. Structured-decisions-first routing and escalation

`InvestigationRouter` implements a bounded cleanup workflow reusing evidence, rules and questions. Route by required output, available evidence, explicit policy and configured connections. Swift owns rules/budgets; Jev chooses only from allowed actions.

```mermaid
flowchart TB
    Task[Cleanup subtask] --> Deterministic{Code or local template sufficient?}
    Deterministic -->|Yes| Core[Local calculation, explanation or rule compilation]
    Deterministic -->|No| Type{Fixed-choice decision?}
    Type -->|Yes and configured| Jev[Jev Choice]
    Type -->|Fixed decision without Jev setup| Gap[Retain gap and offer setup]
    Jev --> Outcome{Actual answer}
    Outcome -->|Supported bounded intent| Validate[Local scope, condition and rule validation]
    Outcome -->|Retain| Retain[Preserve with explanation]
    Outcome -->|Missing evidence| Evidence{Query or ask?}
    Evidence -->|Yes| Gather[Bounded index or user question]
    Gather --> Task
    Evidence -->|Needs open-ended understanding| Escalate{Main model configured and disclosed?}
    Type -->|Open-ended semantics| Escalate
    Escalate -->|Yes| Main[Main model with necessary context only]
    Escalate -->|No| Gap
    Main --> Validate
    Validate --> Review{New hypothesis needs review?}
    Review -->|Yes| Jev
    Review -->|No| Result[Local explanation or disabled draft]
    Core --> Result
    Jev -->|Network, auth or format failure| Failed[Explicit failure without provider fallback]
```

All loops respect step/evidence/question/time/token budgets. Deduplicate identical evidence/question/intent fingerprints within the same investigation/connection while evidence is unchanged. New evidence can justify a new decision; exhausted budgets preserve incomplete findings. Repeated uncertainty must not cause unbounded calls.

| Fixed decision contract | Bounded outputs | Local next step |
| --- | --- | --- |
| Purpose classification | Generated/dependency/user data/mixed/unknown | Select known template or gather evidence, never deletion permission |
| Local next action | Bounded descent/ask/retain/escalate/finish from classification and existing answers | Current code selects the action without an extra paid decision |
| Local template compilation | Controlled draft for an exact generated folder | Swift compiles and Core validates; disabled by default |
| Rebuild review: existing | supported/needs_information/retain | Disabled draft, evidence or retention |

Jev generates no tool code, arbitrary paths, arbitrary rule JSON or free-form explanations. Explicit user retention takes precedence. Localized templates handle known questions/explanations; do not call GPT merely to rephrase a sufficient result.

```mermaid
sequenceDiagram
    participant UI as Native task view
    participant R as InvestigationRouter
    participant C as Core and templates
    participant J as Jev
    participant M as On-demand main model
    UI->>R: Disclosed scope, policy and target
    R->>C: Read facts and try deterministic handling
    alt Local handling sufficient
        C-->>R: Facts, explanation or validated intent
    else Fixed decision
        R->>J: Minimal evidence and bounded question
        J-->>R: Choice and reported usage
        R->>C: Validate and compile known intent
    else Open-ended understanding needed
        R-->>UI: Escalation reason and actual destination
        R->>M: Necessary context, not full index
        M-->>R: Explanation or intent and usage
        R->>C: Deterministic validation first
        opt New hypothesis requires Jev
            R->>J: New evidence and review intent only
            J-->>R: Support, retention or missing evidence
        end
    end
    R-->>UI: Outcome, per-service usage and escalation reason
```

`AIConnection` supports an independent `DecisionConnection`, required main model and decision switch, `decision_first / main_only` policy and task goals. Checkpoints retain routing queues, answers, fingerprints, service usage and escalation reasons, shared by CLI/bridge. Old records stay readable with missing historical metrics shown as unrecorded, never invented. Routing/templates belong to ShouAI; Core stays model-independent.

## 3. Modules and interface reuse

| Module | Base responsibilities | Implemented changes |
| --- | --- | --- |
| `ShouCore` | DTOs, evidence policy, rules, scans, plans, execution | Keep UI switches out of matching/deletion eligibility |
| `ShouPlatform` | Profiles, private local/system/explicit environment credentials, native selection | No interactive Keychain access; private local files by default on macOS |
| `ShouAI` | SDK adapter, investigation actor, evidence, Jev, budgets/checkpoints | Retain shared semantics; new tools require separate contracts |
| `InvestigationRouter` | Bounded workflow | Local first, Jev fixed decisions, main-model escalation, deduplication and service usage |
| `AIWorkspaceSession` | Window connection/task/answers/preview coordination | Desktop gate, cross-page targets and stopping state |
| Connection editor | Form, SecureField, test/save | Gated tests and separate model/Jev outcomes |
| Investigation inspector | Scope/disclosure/questions/evidence/advice | Complete empty, no-advice, stale, failure, usage and next-action states |
| `AILaunchView` | Native target review | Shared folder selection, index reuse, task conflicts and explicit start |
| CLI/bridge | Shared service, discovery, results, continuation/cancellation | Do not claim desktop preference enforces OS-wide network denial; report unavailable platforms |

```mermaid
flowchart LR
    Smart[Smart Cleanup entry] --> Launch[Shared launch panel]
    Large[Large-file parent] --> Launch
    Rules[Personal Rules entry] --> Launch
    Space[Space Analysis current or child folder] --> Resolve[Target and index coordination]
    Launch --> Resolve
    Resolve --> Conflict{Existing task needs a choice?}
    Conflict -->|Return to current| Existing[Original task and scope]
    Conflict -->|Explicit new task| Coverage{Valid index covers target?}
    Coverage -->|No| Scan[Existing read-only space scan]
    Coverage -->|Yes| Inspector[Shared native inspector]
    Scan --> Inspector
    Inspector --> Start[User explicitly starts network investigation]
```

Pages provide intent and exact targets without independent model loops. Multiple files must not silently expand scope to an ancestor. Reuse a valid `StorageScan`/catalog and relative folder, not a sparse cleanup `ScanSnapshot`. Otherwise scan locally. Navigation, inspector visibility and task lifetime are separate.

## 4. Data and persistence

| Object | Contents | Semantics |
| --- | --- | --- |
| `AIConnection` | ID/name/required main-model setup/decision/routing policy | No key; protocol and gateway prefix remain independent |
| `DecisionConnection` | Provider/root/model/credential reference | Jev uses `/systemone`; future adapters own their native protocol; `JevConnection` alias retained |
| `AIInvestigation` | IDs/scope/connection snapshot/status/time/questions/evidence/advice/usage | Resume uses original connection |
| `InvestigationCheckpoint` | State/SDK continuation/pending calls/observed folders/retention answers/routing queue/decision fingerprints | Private local record without credentials, not generic chat export |
| `AIAdvice` | Exact observed folder/explanation/validated rule | No execution authorization |
| `AIDecisionReview` | Path/actual model/verdict/probabilities/usage | Decision probability is not cleanup safety probability |
| Desktop preference | Enabled boolean | Local default false; independent of profiles, credentials, rules and task states |

Existing domain states are only `running / waiting / complete / limited / cancelled / failed`. Ready, off, unconfigured, stopping and stale are UI states, not fabricated domain completion states. No separate persistent retained/unknown-item entity currently exists; summaries/reviews hold that information. Structured lists would require DTO, CLI/bridge and compatibility changes.

## 5. Switch and task state machine

```mermaid
stateDiagram-v2
    [*] --> Off
    Off --> Setup: User enables
    Setup --> Ready: Valid connection and scan
    Ready --> Running: Explicit start
    Running --> Waiting: Question and checkpoint
    Waiting --> Running: Answer with original scope and connection
    Running --> Complete: Normal model completion
    Running --> Limited: Step, usage, evidence or time budget
    Running --> Failed: Protocol, credentials, Jev or storage error
    Running --> Stopping: Stop or disable
    Waiting --> Stopping: Stop or disable
    Stopping --> Cancelled: Cancellation with findings retained
    Stopping --> Off: Cancelled and switch off
    Cancelled --> Ready: New investigation
    Failed --> Setup: Repair then new investigation
    Limited --> Ready: Narrow scope and start new
    Complete --> Stale: Scan or files changed
    Waiting --> Stale: Scan or files changed
    Stale --> Ready: Remeasure or new investigation
    Ready --> Off: Disable
    Setup --> Off: Disable
    Complete --> Off: Disable and retain findings
```

This is the current UI state contract; complete interaction evidence is tracked per scenario. Off can display previous findings and does not clear them. Stopping is feedback; actual service outcomes determine final domain state. Completion racing with a switch event must not turn completed facts into false cancellation. No new request may start while off regardless of final state.

## 6. Connection and credential test sequence

```mermaid
sequenceDiagram
    actor U as User
    participant UI as Connection editor
    participant Gate as Desktop gate
    participant K as Private credential storage
    participant Test as Shared connection test
    participant M as Selected model
    participant J as Optional Jev
    U->>UI: Enter protocol, root, model and key
    U->>UI: Test Connection
    UI->>Gate: Check enabled and cancellation
    alt Disabled
        Gate-->>UI: Enable guidance, no request
    else Enabled
        UI->>Test: Use entered key or saved reference
        Test->>K: Read selected saved credential only if needed
        Note over UI,K: Local reads need no system approval, legacy Keychain access is noninteractive
        Note over Test,M: Main model is required
        Test->>M: Synthetic token and tool definition
        M-->>Test: verify_connection call
        Test->>M: Locally verified tool result
        M-->>Test: Final response
        opt Jev configured and still enabled, not cancelled
            Test->>J: Synthetic Choice question
            J-->>Test: Validated structured answer
        end
        Test-->>UI: Separate model and Jev results
    end
    U->>UI: Save
    UI->>K: Save credentials in background
    UI->>UI: Persist secret-free profile
```

A synthetic test verifies that configuration's round trip. HTTP 200, main-model success or high Jev probability alone cannot mean overall success. Saving is local while disabled; testing is gated. The gate is implemented and rechecked after credential access. Save progress prevents duplicates/dismissal; no default path requests system approval. Local files use per-user permissions, not Keychain encryption.

## 7. On-demand main-model loop, questions and decision review

This describes only the escalated or explicitly main-only SDK branch; section 2 describes default decision-first routing.

```mermaid
sequenceDiagram
    actor U as User
    participant UI as Native inspector
    participant S as AIInvestigationService
    participant E as Bounded evidence tools
    participant C as Core catalog
    participant M as SDK and model
    participant J as Optional Jev
    participant P as Local checkpoint
    U->>UI: Review scope and services, enter retention, Start
    UI->>S: scanId, scope, connection snapshot and request
    S->>P: Save initial task
    loop Within budgets and not cancelled
        S->>M: Domain instructions, bounded context and tools
        M-->>E: Directory query or inspection
        E->>E: Validate exact relative scope and budget
        E->>C: Query saved catalog
        C-->>E: Measured metadata and completeness
        E-->>M: Minimized evidence
        opt User answer required
            M-->>S: ask_user
            S->>P: Save waiting state and continuation
            S-->>UI: Question, options and existing findings
            U->>UI: Answer and Continue
            UI->>S: Same task ID and answers
            S->>S: Check expiration, original scope and connection
        end
        opt Exact folder proposal
            M-->>E: propose_rule
            E->>E: Validate observed directory and conditions
            opt Original policy is decision-first with a decision provider
                E->>J: Candidate evidence, hypotheses and retention
                J-->>E: supported, needs_information or retain
            end
            E-->>S: Validated advice or evidence/retention outcome
        end
        S->>P: Save state, continuation and actual usage
        S-->>UI: Publish real stages and partial findings
    end
    S-->>UI: complete, limited, cancelled or failed
```

Main-only policy never calls the decision provider. When decision-first review is required, only `supported` can yield a disabled draft. Uncertainty never invents answers; retention produces no cleanup advice. Failed/malformed review must not be hidden by tool-error handling and reported complete. Completion without advice is valid. Decision accuracy still requires calibration.

## 8. Individual rule through cleanup flow

```mermaid
flowchart TB
    Result[Investigation findings] --> Choice{User chooses a proposal?}
    Choice -->|No| Keep[Retain content or read findings]
    Choice -->|Individual preview| Fresh{Snapshot still valid?}
    Fresh -->|No| New[Rescan and investigate]
    Fresh -->|Yes| Draft[Import disabled exact rule]
    Draft --> Preview[Existing Core actual matching]
    Preview --> Explain[Matches, protections, conditions and benefit]
    Explain --> Decision{User decides}
    Decision -->|Keep disabled| Saved[Save draft without cleanup]
    Decision -->|Enable and scan| Scan[Fresh current-file scan]
    Scan --> Select[User selects exact items and action]
    Select --> Plan[Existing immutable plan and confirmation]
    Plan --> Verify[Identity, manifest, rules and protection checks]
    Verify --> Receipt[Per-item execution and durable receipts]
    Receipt --> Measure[Remeasure and permitted restore]
```

Reuse existing rule/plan/execution services, with no second engine or AI confirmation bypass. Generated fixtures passed native investigation through Trash receipt and restoration with matching file hashes; live-service evidence remains package-specific.

## 9. Disable and cancellation sequence

```mermaid
sequenceDiagram
    actor U as User
    participant Settings as AI Settings
    participant Session as Window coordinator
    participant Network as Model or Jev requests
    participant Store as Local records
    U->>Settings: Disable AI Investigation
    Settings->>Session: Close desktop request gate first
    Session->>Session: Cancel tasks and show Stopping
    Session->>Network: Request cancellation of in-flight work
    Note over Session,Network: Delivered content cannot be recalled, credentials are read without interactive prompts
    Network-->>Session: Actual completion or cancellation
    Session->>Session: Recheck switch and prevent subsequent requests or Jev
    Session->>Store: Retain findings and actual final state
    Session-->>Settings: AI off, existing findings readable offline
```

The behavior is implemented. Automation covers default-off, revoked permits and post-credential checks; native slow-request cancellation showed stable counts after disable. Hiding a button is insufficient: tests, answer continuation, automatic steps and Jev all need coordination/cancellation checks. Disabling does not delete credentials/rules/history or rewrite independent CLI authorization.

## 10. Protocol, evidence and resource contracts

Swift AI SDK `0.20.0` supplies loops for `responses`, `chat_completions` and `anthropic`, appending `/responses`, `/chat/completions` and `/messages` while preserving the API-root prefix. Jev independently uses `POST /systemone`. Require remote HTTPS, allowing HTTP only on loopback; no retries or redirects. Apple SDK dependencies remain macOS-only; Windows uses a bounded non-streaming three-protocol adapter for the same evidence tools/service. Runtime checkpoint formats are explicit and incompatible messages are not silently migrated.

| Limit | Current value/meaning |
| --- | --- |
| Evidence | 30 rows/page, 300 rows/64 KiB total; relative path/kind/allocation/count/time/completeness |
| Main loop | 12 steps, 32 tools, 8 suggestions, 3 questions; 180 seconds/turn, 3072 output tokens |
| Tokens | Stop subsequent steps at 32000 reported tokens; one response can cross the threshold, so no exact spending cap |
| Jev | 8 reviews, 24 KiB inputs/64 KiB responses; usage joins the shared threshold |
| Model response/checkpoint | Each at most 1 MiB; provider error bodies excluded from user results |
| Continuation | Waiting questions resume across CLI processes within 24 hours; both desktops list local waiting/finished records; interrupted-running recovery remains open |

No file/configuration contents, Shell, web fetches, arbitrary plugins or project Agent instructions are exposed. Filter private names, links and special files. Relative names and user answers can still contain private information; disclosure must not claim anonymization. New configuration/activity/uninstall/startup/privacy tools need their own evidence, destination, UI, budgets and acceptance before extending this design.

## 11. Implementation status and verification order

1. Implemented default-off desktop gate covering tests, start/resume, Jev and disable races.
2. Implemented structured-decisions-first routing, bounded questions/templates, independent configuration and service usage; prove zero main-model calls for sufficient cases.
3. Implemented shared launch panel and four P0 page entries reusing scans/inspector.
4. Empty, stopping, stale/error/no-advice states and post-preview next actions are implemented; full interaction combinations remain under acceptance.
5. Generated fixtures for scope/disclosure, languages, keyboard/appearance, then the selected providers' live desktop flow.
6. Keep interrupted-running recovery, domain adapters, content tools, quality, native Windows CI for this revision and UI acceptance as explicit open gates.

Acceptance conditions/evidence belong to the [matrix](../engineering/embedded-ai-acceptance.md); runtime observations belong to the [implementation record](../engineering/embedded-ai-implementation.md).

## 12. Replaceable structured decision adapters

Routing depends on `StructuredDecisionProvider`; `StructuredDecisionService` selects an adapter using `decision.provider` in the connection. Jev is the only bundled adapter today. Future services such as Clef implement the same interface using their own endpoint, authentication and native protocol. A non-Jev service must never be forwarded to `/systemone` or presented as integrated by merely changing a model name.

`StructuredDecisionRequest` carries a controlled relative path, minimal evidence and fixed choices/criteria. The common result contains a validated choice, model, probabilities and reported usage. Routing, local templates, retention conditions, budgets and cleanup permissions remain independent of the provider. Failures never silently switch services; an active task retains its original connection snapshot, and connection changes affect new tasks.

`DecisionConnection` stores the provider identifier and non-secret settings; `JevConnection` remains a source-compatible alias. Old profiles without `provider` mean Jev; legacy `jev_first` is accepted while new policy uses `decision_first`. Existing Jev Keychain accounts remain valid; other providers use separate credential references. An unknown provider is explicitly unavailable, with no silent fallback. Every new adapter must pass the same contract, scope, cancellation, budget and redaction gates.

```mermaid
flowchart TB
    Router[InvestigationRouter] --> Common[StructuredDecisionService validation and gate]
    Common --> Registry[Select registered adapter by decision.provider]
    Registry --> Jev[JevDecisionProvider implemented]
    Jev --> Native[POST /systemone]
    Registry -. Future adapter .-> Alternative[Clef and others: not implemented]
    Alternative -. Own protocol .-> API[Provider API]
    Settings[Editor lists installed providers only] --> Profile[DecisionConnection and separate credentials]
    Profile --> Snapshot[Connection snapshot fixed at start]
    Snapshot --> Router
    Registry --> Unknown[Unknown provider explicitly unavailable]
```

To switch, select an installed provider, enter its settings, explicitly test, save and start a new investigation. Existing Jev credentials remain stored. CLI `--service decision` writes the selected provider's separate local or system credential account; `--service jev` remains a Jev-only compatibility alias. Protocol-specific suffix checks belong to that provider's configuration; the main model is required; disabling decisions changes routing while retaining provider settings and credentials. New adapters require code registration and contract acceptance; Clef is not selectable today.

## Cross-platform runtime and cancellation

```mermaid
flowchart TB
    Mac[macOS SwiftUI] --> Service[Shared investigation service]
    Win[Windows Fluent WPF] --> Bridge[Versioned stdin bridge]
    CLI[Independent CLI] --> Service
    Bridge --> Service
    Service --> Router[Local / structured decisions / escalation]
    Router --> Provider[StructuredDecisionProvider]
    Provider --> Jev[Jev adapter]
    Provider -. future adapter .-> Future[Other provider]
    Service --> MacRuntime[macOS SDK runtime]
    Service --> Portable[Windows bounded runtime]
    MacRuntime --> Tools[Shared bounded evidence tools]
    Portable --> Tools
    Tools --> Core[Core rule import and preview]
    Win --> Credentials[Windows Credential Manager]
    Mac --> LocalKeys[Private local credentials / legacy Keychain]
```

```mermaid
sequenceDiagram
    actor User
    participant UI as Native desktop
    participant Worker as Shared worker
    participant Store as Local checkpoints
    participant HTTP as Selected provider
    User->>UI: Disable AI or stop
    UI->>Worker: Cooperative cancellation
    Worker->>HTTP: Cancel in-flight request
    Worker->>Store: Save cancelled state and evidence
    Worker-->>UI: Partial checkpoint
    Note over UI,Worker: No subsequent provider step
    User->>UI: Open saved waiting record after restart
    UI->>Store: Read original connection and questions
    Store-->>UI: No network request
    User->>UI: Enable and submit answers
    UI->>Worker: Resume original record within 24 hours
```

```mermaid
flowchart LR
    Cancel[CLI ai cancel] --> Marker[Persist cancellation marker]
    Marker --> Monitor[Original worker observes marker]
    Monitor --> Transport[Cancel request]
    Monitor --> Budget[Refuse next tools and requests]
    Transport --> Result[Save cancelled checkpoint]
    Budget --> Result
    Result --> Show[CLI ai show / desktop result]
```

## 14. Configuration lifecycle and Jev switch

`main_model_enabled: false` identifies legacy records only; new saves, starts and continuations require a valid main model. `routing_strategy: main_only` disables decisions even when the retained `decision` object exists: no decision credential read or request. `decision_first` enables them. A single routing field represents the switch without a conflicting duplicate Boolean.

```mermaid
flowchart TD
    C[Configure main model] --> V{Valid main model?}
    V -->|No| E[Repair in editor]
    V -->|Yes| S{Decision service enabled?}
    S -->|Yes| D[Local analysis and fixed Jev choices]
    D -->|Sufficient| F[Local summary or disabled draft]
    D -->|Open-ended understanding| M[Configured main model]
    S -->|No| M
    M --> F
    S -.Retain while disabled.-> K[Decision settings and separate key]
```

Profiles live in `ai-connections`; recoverable removal state lives in `ai-connection-states`. Removal writes state only, retaining investigation snapshots and credentials. Default lists exclude deleted profiles; explicit reads return key-free profiles. Editing checks deletion before profile and credential writes; restore is required first.

```mermaid
sequenceDiagram
    actor U as User
    participant UI as macOS or Windows
    participant S as AIConnectionStore
    participant H as History and credentials
    U->>UI: Create or edit configuration
    UI->>S: Validate required main model and save
    U->>UI: Disable Jev
    UI->>S: Save main_only and retain decision
    S-->>UI: Refresh active choices and service disclosure
    U->>UI: Confirm removal of named configuration
    UI->>S: setDeleted true
    S-->>UI: Exclude from active choices
    Note over S,H: Preserve profile, historical snapshots and keys, no network
    U->>UI: Restore deleted configuration
    UI->>S: setDeleted false
    S-->>UI: Original configuration available again
```
