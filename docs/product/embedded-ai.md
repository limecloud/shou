# Built-in AI: stories, use cases and interaction contract

English | [简体中文](../zh-CN/product/embedded-ai.md)

Date: 2026-10-22. This defines the built-in AI product and macOS interaction contract. Implemented behavior, proposed behavior and verification evidence are recorded separately; a design is not a delivery claim.

Related: [PRD F21](prd.md), [general stories](user-stories-and-use-cases.md), [architecture and diagrams](../architecture/embedded-ai.md), [acceptance matrix](../engineering/embedded-ai-acceptance.md), [implementation record](../engineering/embedded-ai-implementation.md).

## 1. User outcome and current gaps

Users should understand where major storage is used, what is worth handling under their retention requirements, and how to reuse that decision as a rule. An investigation can produce a draft, a retention recommendation or an evidence gap. Finishing an investigation does not mean cleanup occurred.

| Area | Current working-tree evidence | Required next behavior |
| --- | --- | --- |
| Connections | Default-off switch, native editor, switchable decision provider, required main model and configuration CRUD implemented | Live credential access and complete states tracked per package |
| Investigation | Shared launch, fixed scope, questions, evidence, suggestions and service usage implemented | Quality and full accessibility combinations pending |
| Page entry points | Smart Cleanup, Space, large-file parent and Rules share one coordinator; external tools are labeled separately | Bind each context and conflict to UI evidence |
| Rules | Generated fixture passed native investigation, preview, fresh scan, Trash receipt and restoration | Keep live-service evidence separate from fixture behavior |
| Recovery | CLI and both desktops open local records and resume waiting questions | Keep the original connection and 24-hour expiry; interrupted running tasks are not offered as resumable |

The desktop master switch is implemented, persisted locally and defaults off. Explicit setup for one user's Mac does not change defaults for other installations.

## 2. User stories

| ID | Story | Observable acceptance | Priority |
| --- | --- | --- | --- |
| US-AI01 | As a new user, I choose whether to enable AI and understand disclosure | Default off; destinations, metadata and a separate Start action are visible | P0 |
| US-AI02 | As a gateway user, I configure protocol, address, model and key independently | Manual model entry, secret-free profiles and tool-round-trip tests | P0 |
| US-AI03 | As a privacy-conscious user, I can turn AI off | Stop current work and block new desktop AI requests while local cleanup remains usable | P0 |
| US-AI04 | As a user running out of space, I investigate areas missed by Smart Cleanup | Choose an exact folder; obtain space measurements rather than reuse a sparse cleanup scan as a full index | P0 |
| US-AI05 | As a space-map user, I investigate the current folder or a child | List/map scopes agree; fixed scope and coverage remain visible | P0 |
| US-AI06 | As a large-file user, I understand the containing folder | Action explicitly investigates the parent; no file-content claim | P0 |
| US-AI07 | As a developer with offline/release needs, I state what must stay | Initial instructions plus focused choice/free-text questions apply to this investigation | P0 |
| US-AI08 | As a cautious user, I distinguish facts, hypotheses and unknowns | Measured sizes, evidence, rebuild requirements and unresolved next steps | P0 |
| US-AI09 | As a personal-rule user, I obtain independent folder rules | Exact scope, purpose, rebuild conditions, separate preview and disabled defaults | P0 |
| US-AI10 | As a repeat user, I reuse reviewed rules | Explicit enablement and fresh scans feed existing cleanup, including offline use | P0 |
| US-AI11 | As an investigating user, I stop or recover from errors without losing findings | No new steps after cancellation; repair/new-investigation actions preserve partial results | P0 |
| US-AI12 | As a cost-conscious user, I use Jev first for suitable decisions | Zero main-model calls when local code/Jev suffice; visible escalation reasons, destinations and separate usage | P0 |
| US-AI13 | As a keyboard, VoiceOver or other-language user, I complete the same tasks | Meaningful labels/focus/status in English and Chinese without color-only meaning | P0 |
| US-AI14 | As a Rules user, I begin investigation inside Shou | Explicit built-in action, with clearly labeled external tools as another route | P0 |
| US-AI15 | As an interrupted user, I recover a waiting investigation | Original time/scope/connection and expiration; both desktops implement local records/waiting continuation; interrupted-running recovery is tracked separately | P1 |
| US-AI16 | As an Uninstall/Startup/Privacy user, I understand source and impact | Domain facts and review flows are required; folder investigation cannot impersonate them | P1 |
| US-AI17 | As a cost-conscious user, I can replace the decision provider | Common contract, separate credentials and legacy compatibility; active tasks keep their provider; only Jev ships today | P0 |

## 3. Structured-decisions-first routing and cost

With a decision provider configured, the default is **Structured Decisions First**, currently using Jev: local code handles deterministic facts; Jev handles sufficiently evidenced decisions with fixed choices; the main model is used only for open-ended semantics, unfamiliar generation logic or explanations beyond templates. Routing, bounded questions and local draft templates are implemented; sufficient synthetic cases prove zero main-model calls.

| Task | Preferred handler | Escalation/stop condition |
| --- | --- | --- |
| Sizes, sorting, age, coverage, exact paths and matching | Local Core | Gather missing facts or report unknown; no model arithmetic |
| Evidenced classification, known-template selection, next bounded evidence action | Fixed Jev Choice | Query/ask first; escalate only when open-ended understanding is still needed |
| Whether explicit retention supports known rebuild conditions | Jev or deterministic explicit-field rules | Uncertainty gathers evidence; retain preserves content; probability cannot override users |
| Exact path and known intent to rule draft | Local templates and Core validation, optionally Jev-selected bounded intent | Observed paths only; no arbitrary Jev-generated rule JSON |
| Known-result explanation, questions and summary | Localized local templates | Main model only for unfamiliar semantics/conditions beyond templates |
| Unfamiliar meaning, complex retention, free-text explanation | Main model | Same scope/evidence; returned intent still validated locally |
| New model hypothesis or higher-risk draft | Jev review when needed | Avoid reviewing unchanged, already-checked evidence repeatedly; never grants deletion permission |

Every usable configuration requires a main model. **Enable Decision Service** selects `decision_first` when on and `main_only` when off. Jev assists the main model, while sufficient fixed-choice tasks can finish without a main-model request. Disabling Jev retains its settings and key and lets the main model take over. Jev-only profiles cannot start; legacy profiles remain readable for repair or recoverable removal.

Disclose all possible destinations before Start. Show actual **Structured decision** or **Main-model understanding needed: reason** stages. Semantic escalation within the already disclosed scope does not require repeated confirmation. New destinations, expanded scope or content reads require a new explicit choice. Jev network/authentication/format failures remain failures; do not silently route them to a more expensive provider. Distinguish uncertain evidence from unavailable services.

Show actual requests, reported tokens and escalation reasons per service. Without price configuration, show usage and unavailable cost, not fabricated amounts. Gateway billing uses its actual rates, not assumed OpenAI list prices. Compare calls/input/time/cost/quality on identical cases without unmeasured savings claims.

## 4. Switches, connections and network behavior

Use **Enable AI Investigation** in Settings → AI Investigation. New installations default off and persist explicit local choices. Saving a connection, scanning or opening a page never enables it automatically. Enabling without a connection is allowed and offers Add Connection.

| Action | Required behavior |
| --- | --- |
| Enable AI | Explain purpose, transmitted fields, provider and optional Jev destination; send nothing automatically |
| Disable AI | Block new desktop model/Jev requests immediately; cancel investigation and connection tests; retain findings, profiles and credentials |
| Read results while disabled | Existing findings and imported rules remain readable; continuation/testing requires re-enabling |
| Use rules while disabled | Enabled rules scan/clean locally; the switch does not disable or delete rules in bulk |
| Manage profiles while disabled | Local add/edit/save remains possible; tests explain the enable requirement |
| Enable Jev | New investigations default to Structured Decisions First; disclose possible Jev/main-model destinations and relative evidence |
| Disable Jev | Explain Main Model Only for subsequent tasks; preserve Jev credentials and active task configuration |
| Change the default connection | Affect new investigations only; never silently transfer an existing conversation |

Disabling cannot retract requests already received by a provider or erase provider records. Stopping is not rollback. Local credential reads need no system authorization. Legacy Keychain access is noninteractive, with in-app guidance to local storage on failure; cancellation and enablement are rechecked before subsequent network work.

The switch is a desktop network preference, not API-key revocation or an OS network permission. Explicit CLI `ai` network commands use their own invocation authorization and currently do not read desktop preferences. UI/help must explain this. Offline commands, scanning, previews and existing cleanup remain independent.

## 5. Page entry points and scope

Use **AI Investigation** for the built-in feature, with concrete **Investigate This Folder**, **Investigate Containing Folder** and **Create Rules with AI** actions. Label the separate handoff **External AI Tools** rather than using the same action name for different workflows.

| Page/location | Entry | Scope and contextual interaction | Status |
| --- | --- | --- | --- |
| Settings | Enable AI; configurations; add/edit/delete/restore/test | Switch, destination, protocol, model, credentials, optional Jev and test results | Implemented; default-off observed; current configuration acceptance is tracked separately |
| Smart Cleanup empty state | Investigate a Folder with AI… | Native folder picker; local measurement followed by explicit network start | Implemented; contextual UI acceptance tracked separately |
| Smart Cleanup results | Investigate Other Usage…; folder context action | Exact folder, no automatic home expansion; sparse cleanup scans are not full indexes | Implemented; contextual UI acceptance tracked separately |
| Space Analysis empty state | Scan before AI investigation | Folder/measurement flow without an unusable Start Investigation action | Local scan guidance implemented |
| Space Analysis results | Toolbar and folder/list/map actions | Current folder or exact child; browsing cannot change the running scope | Toolbar, directory and map menus implemented |
| Large Files | Investigate Containing Folder | Parent of one file, explicitly reviewed in the launch panel | Implemented; contextual UI acceptance tracked separately |
| Rules | Create Rules with AI… | Exact folder and retention requirements; new disabled drafts | Built-in and external actions implemented |
| Personal-rule details | Review, preview, enable and scan | Show original investigation basis; changes create disabled versions without overwriting enabled versions | Individual preview and existing rule chain connected |
| Application Uninstall | Help Understand This Component | Exact app identity, component category, shared/personal data and activity evidence | Later domain adapter; unavailable now |
| Startup Items | Help Understand This Item | Source, signature, registration and status evidence; existing control confirmation remains separate | Later domain adapter; unavailable now |
| Privacy Cleanup | Explain This Cleanup Item | Source/category/time range/aggregate counts only, no history records or cookie values | Later domain adapter; unavailable now |

Share one investigation workspace instead of independent page chat windows. Reuse a valid index covering the target; otherwise measure locally first. Disabled, unconfigured, missing-scan and active-task states need specific native guidance rather than a generic error.

Cross-page launch panels disclose the target, connection, measurement reuse and next action. An existing running/waiting task offers **Return to Current Investigation** or **Stop and Start New**. Dismissing the panel preserves the existing task. Never replace scope silently. Picker cancellation, missing paths or scan failures preserve the source page/state.

## 6. End-to-end use cases

### UC-AI01: First enablement and setup

Preconditions: new installation, AI off, no profile.

1. Open enablement guidance from Settings or a contextual entry.
2. Enable AI and read disclosure; no inference starts.
3. Enter protocol, API root, model and secure key in the native form; Jev is optional.
4. Test with synthetic data and see separate main-model tool-round-trip/Jev outcomes.
5. Save and choose the connection for later investigations.

Cancellation does not save form changes. Failed saves preserve input and show a cause. Saving, testing, investigating and continuing do not request the login Keychain password. Legacy configurations can switch to local storage with one-time key re-entry. Test success belongs to the tested configuration and resets after edits. No real folder is uploaded or cleaned.

### UC-AI02: Investigate usage from Smart Cleanup

1. Choose Investigate Other Usage or Investigate a Folder with AI.
2. Select an exact folder and obtain a local space scan if needed.
3. Enter the shared workspace with scope, coverage and model/Jev destinations.
4. Provide retention requirements and explicitly Start Investigation.
5. Investigate the largest relevant branches and retain unresolved areas, including those without templates.

Unreadable folders offer coverage details and another-folder selection. Disabled/unconfigured AI offers setup. Never treat sparse cleanup discovery as full measurement. No cleanup targets are selected automatically.

### UC-AI03: Investigate an unfamiliar folder from the space map

1. Choose Investigate This Folder on a directory or map tile in a valid scan.
2. Review fixed scope, evidence fields and services while continuing to browse.
3. Show real stages, evidence counts and steps, without fabricated percentages.
4. Ask a focused question when purpose cannot be established; allow options/free text.
5. Resume the original connection/task and explain completion, retention, evidence gaps or incomplete states.

Refreshing or changing files marks old results stale and requires a new investigation. Navigation never silently changes the task.

### UC-AI04: Investigate a large file's folder

1. Select Investigate Containing Folder for one measured file.
2. Show its parent and clarify that file contents are not read.
3. Confirm scope, reuse a valid index or scan locally, then follow UC-AI03.

For multiple parent folders, ask the user to choose one; never expand automatically to a shared ancestor. Size alone cannot establish that a video, archive or model weight is disposable or a rebuildable directory.

### UC-AI05: Independent rule through cleanup receipt

1. Read each exact directory, measured allocation, purpose hypothesis, rebuild requirements and limitations.
2. Preview one rule, importing it as a disabled draft and matching actual files.
3. Inspect matched/protected/outside-condition items and additional benefit beyond enabled rules.
4. Keep it disabled, or enable and freshly scan this rule.
5. Select actual items/action and use existing exact-scope cleanup confirmation.
6. Read per-item processed/skipped/failed/unknown outcomes; separate estimates from observed available-space changes.

Zero matches offer condition inspection/rescanning. Stale evidence blocks preview. AI enablement, preview and Jev support never grant deletion permission. Other rules retain their choices.

### UC-AI06: Disable, cancel or handle failure

1. Stop Investigation or turn off the master switch.
2. Immediately show a stop request, prevent duplicate continuation and cancel network/further steps.
3. Preserve confirmed evidence/advice and show the actual final status.
4. Read retained findings while disabled; re-enable before explicit new investigation.

Authentication failures lead to connection editing. Network/timeout failures offer a new investigation. Budgets explain incomplete scope and retained results. No automatic retries or provider switching. Only waiting questions currently support service continuation; restarting failed/cancelled work must not be labeled resuming the original step.

### UC-AI07: Jev-first handling and escalation

1. Configure the required main model, then configure and enable Jev to select Structured Decisions First.
2. Disclose possible destinations; compute measurements/scope locally.
3. Let Jev classify/review rebuildability while local code selects bounded evidence actions; local templates complete sufficient cases without main-model calls.
4. Show the reason before invoking an already disclosed main model for open-ended understanding; review new hypotheses as needed without repeated checks of unchanged evidence.
5. `supported` only supports draft review; uncertainty gathers evidence and retention keeps content. Show separate actual usage.

Jev failures preserve findings without automatic main-model forwarding. Repair or explicitly change strategy for a new task. Legacy profiles missing a main model must be repaired before starting or continuing. Routing and per-service usage are implemented; synthetic cases pass while live quality/cost comparisons remain pending.

### UC-AI08: Reuse offline next time

With reviewed rules enabled, disable AI or disconnect, then run Smart Cleanup. Enabled rules join a fresh local scan; disabled drafts do not. Confirm current items and read receipts. Reuse rule conditions and explicit choices, never old requests, target lists or deletion authorization.

## 7. Complete native states

Use native grouped Settings: feature/switch first, then default connection and management. Disabled settings remain inspectable with network actions clearly unavailable. Use Form/SecureField for connections and keep protocol/debug fields out of investigation results.

Use a resizable inspector with a stable title/close action, scope/connection/disclosure before questions/results, and a visible primary action footer. Closing it does not stop the task; reopening reveals current state. Scope changes require explicit choice. Window exit and unsent-answer loss need appropriate departure handling.

| State | Visible information | Action/recovery |
| --- | --- | --- |
| Disabled | Feature explanation, local cleanup and retained results | Enable AI; Settings |
| Unconfigured | Tool-capable connection needed | Add Connection; Cancel |
| No scan | Target and local-measurement explanation | Choose Folder; Scan |
| Scanning | Actual paths/counts/coverage/cancellable progress | Stop Scan |
| Ready | Fixed scope, time/completeness, services and retention input | Start; Edit Connection |
| Running | Stage, steps, evidence count and original connection | Stop; hide inspector without losing work |
| Waiting | Focused question, options, free text and limits | Continue; Stop; explain missing answers |
| Stopping | Requested stop and any system wait | Prevent duplicate continuation; preserve results |
| Complete with suggestions | Summary/evidence/individual rules/Jev | Individual preview; new investigation |
| Complete without suggestions | Retention reason, evidence gap and next diagnostic | Evidence; new investigation; return to browsing |
| Failed/limited/cancelled | Actual cause, partial findings, unresolved scope | Repair connection or new investigation; no success badge |
| Stale | Scan/files changed | Rescan/investigate; block old previews |
| Previewing | Actual local matching | Stop; retain disabled draft |
| Preview complete | Matched/protected/zero matches, benefit and conditions | Keep disabled; enable/scan; inspect conditions |
| Cleanup complete | Current receipt and per-item results | History; restore if available; remeasure |

Errors provide causes and next actions without provider bodies or secrets. Explain input limits nearby and retain typed input. Long content scrolls without pushing actions out of the window. Verify narrow windows, long paths, both languages and appearances.

Keyboard users can reach switches, connections, questions and suggestions. SecureFields have labels. Esc dismisses non-running forms or follows appropriate stop/departure handling. VoiceOver distinguishes running/waiting/stopped/failed. Events drive feedback; respect Reduce Motion and never derive progress from generated word counts.

Design references: [Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles), [Inspectors](https://developer.apple.com/design/human-interface-guidelines/inspectors), [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility). References do not establish accessibility acceptance.

## 8. Measures and delivery gates

Compare built-in/external workflows on identical generated or consented sanitized scenarios: first-task completion, manual handoffs, explained major usage, erroneous advice, unsupported assertions, question burden, elapsed time and reported usage. Tokens are observed usage; a stopping threshold is not an exact spending cap.

P0 delivery covers US-AI01–US-AI14 and US-AI17 with positive/exception paths, especially zero new requests while off, consistent cross-page scope, useful no-suggestion outcomes and individual rules through existing receipts. Implemented features and remaining interaction evidence are tracked separately. See the [acceptance matrix](../engineering/embedded-ai-acceptance.md).

## 9. Decision providers and switching

Structured decision-making is a capability; Jev is its first implementation. Settings show the actual provider, endpoint, model and routing policy without permanently naming the capability after Jev. When adapters such as Clef are implemented, the same connection editor can select them. Today only the implemented Jev adapter appears; unavailable services are never advertised as usable. A new provider requires its own configured and tested credentials. Existing credentials are not reused across providers, and active tasks are neither migrated nor resent.

Story **US-AI17**: As a user controlling cost and service choice, I want to replace the structured decision provider while keeping the same investigation, evidence and rule-review workflow. Acceptance requires a common routing contract, an injectable alternative adapter completing the same fixed decision, Jev as today's default, readable legacy profiles, explicit unavailable-adapter errors, and no changes to active tasks or cleanup permissions.

## CLI and Windows stories

| ID | Story | Acceptance |
| --- | --- | --- |
| US-AI18 | As a terminal/external-agent user, discover providers, configure/test, investigate/answer, list/cancel and import one draft | Fifteen discoverable operations; stdin-only credentials; cancellation reaches the running worker; cleanup retains terminal confirmation |
| US-AI19 | As a Windows user, complete a native AI journey with the same investigation/rule semantics as macOS/CLI | Fluent UI, default-off switch, PasswordBox/Credential Manager, four contextual entries, complete states and existing rule previews; native runtime claims require this revision’s CI |

### UC-AI09: Independent CLI investigation and cancellation

1. Discover actual operations/providers with `capabilities --command ai` and `ai providers`, then save a secret-free profile.
2. Supply credentials through stdin or an explicit environment variable and test the destination with synthetic data.
3. Scan locally, invoke `ai investigate`, and inspect scope/questions/usage/advice with `ai list`/`ai show`.
4. Answer current question IDs through `ai resume`, or invoke `ai cancel` from another process to stop in-flight requests and subsequent steps.
5. Import one disabled draft with `ai advice import`; preview, enablement, fresh scan and current-scope terminal confirmation use existing contracts.

### UC-AI10: Native Windows investigation and restart continuation

1. Enable the default-off switch and configure independent main/Jev services in the native form; tests send synthetic data only.
2. Enter from cleanup, a storage folder, a large-file parent or rules; inspect the exact scope/goal/connection/disclosure before starting.
3. Measure locally when no valid index can be reused. Waiting answers and scope survive page changes; disabling cancels requests.
4. Inspect evidence, structured reviews, usage and escalation, then preview a single disabled draft through the existing rule/cleanup journey.
5. Closing explains loss of unsent text. After restart, local records open saved questions and continue within 24 hours on the original connection. Expired/missing-index/incompatible-runtime records require a new investigation.

Cross-builds, native CI and WPF interaction are distinct evidence. CLI and desktops share business services; desktop preferences do not silently override explicit terminal network authorization.

## Credential, configuration and scope interaction additions

As a daily user, I save each key once and reuse it across desktop tests, investigations, continuation and CLI without login Keychain password prompts after app upgrades. macOS defaults to private local storage; legacy connections migrate through one-time in-app key re-entry. Keys are excluded from profiles, history, exports and logs. The editor distinguishes file permission protection from system credential encryption.

As a cost-conscious user, I see Jev and the main model together, with decision-first and on-demand roles, models and destinations. Choices show actual active services. New desktop configurations enable both services; the main model is required and Jev can be switched on or off.

As a disk browser user, I explicitly select all scanned folders or one folder. The macOS toolbar prefers one checked directory, then the highlighted directory, then the browsed directory. The launch sheet can change the scope and choose another physical folder. All means the current scan root and descendants, not other volumes. Cancel preserves the current task, and scope never changes cleanup selection. Local measurement or index reuse precedes explicit investigation start.

Limits show their exact reason, retained evidence and next action. Processing time excludes credential loading and user-answer waits. Tokens, steps, decision requests, tools, evidence, response size and overview directories have separate reasons. Internal limits do not imply exhausted provider balances; historical records without a reason are not rewritten.

## 12. Required main model, Jev switch and configuration management

| ID | Story | Observable acceptance | Priority |
| --- | --- | --- | --- |
| US-AI20 | As a multi-service user, I switch Jev on/off and manage complete configurations | Main model required; disabled Jev reads no decision key and sends no request; create/read/update/default/delete/restore available | P0 |

### UC-AI11: Manage configurations and switch Jev

1. Create a named configuration with a required main model and optional Jev assistance. Each service has its own URL, model and credential. Saving is local only.
2. Inspect names, active services and default selection; edit or select a default. Main-model fields stay visible and cannot be disabled.
3. Disable **Enable Decision Service**: new investigations use the main model directly, retaining decision settings/keys without reading or sending them. Re-enable later; missing Jev setup opens the editor first.
4. Blank key input preserves the saved key. Edits clear test success; connection tests verify enabled services only.
5. Deletion names the configuration and explains recovery. Confirmation removes it from choices; choose another complete default or show setup when none remains. Cancellation changes nothing.
6. Restore from **Deleted Configurations** to reuse the original credentials. Deleted profiles cannot be edited, tested or started until restored.

Running tasks retain their connection snapshot. Desktop configuration mutations are disabled during running/waiting work. CLI changes affect new investigations; continuation keeps its original snapshot. Legacy profiles missing a main model remain readable for repair or removal but cannot run Jev alone.
