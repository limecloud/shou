# Built-in AI: traceability and acceptance matrix

English | [简体中文](../zh-CN/engineering/embedded-ai-acceptance.md)

Date: 2026-10-22. Related: [stories/use cases](../product/embedded-ai.md), [architecture/sequences](../architecture/embedded-ai.md), [implementation evidence](embedded-ai-implementation.md). Pending implementation/acceptance never means passed. Existing service checks do not verify proposed routing or UI.

## 1. Evidence levels

| Status | Meaning |
| --- | --- |
| Existing automation | Executed generated-fixture, contract or regression checks at the stated layer |
| Existing UI observation | Observed on the specified development machine/package, not all packages/OS/accessibility combinations |
| Existing live service | Generated fixtures/synthetic questions sent to explicitly selected providers |
| Implementation pending | No implementation meeting this contract |
| Acceptance pending | Related implementation exists without complete scenario evidence |

Evidence uses macOS 15.8.1, Apple Silicon and Swift 6.2.3; it cannot establish macOS 14, Windows, distribution signing/notarization or clean-install acceptance. Live calls incur provider charges. Use authorized connections and minimal generated fixtures without repeating until a preferred verdict appears.

## 2. Traceability

| Check | Story/use case | Required observation | Status |
| --- | --- | --- | --- |
| AI-AC01 | US-AI01/UC-AI01 | New install off; enable/save never automatically call models | Implemented; default-off gate tests and ai-decision-ready initial off/no automatic requests observed |
| AI-AC02 | US-AI02/UC-AI01 | Independent protocol/root/model; no keys in profiles/output/logs | Existing automation/editor; re-audit changed paths |
| AI-AC03 | US-AI02/UC-AI01 | Three SDK protocols execute a tool then another model turn | Synthetic all three; selected live Responses passed; other live protocols pending |
| AI-AC04 | US-AI02/UC-AI01 | Reopen editor, leave keys blank, read Keychain and pass both tests | Both live tests passed in ai-ready; new package credential access requires separate evidence |
| AI-AC05 | US-AI03/UC-AI06 | Disable during run/wait/test blocks start/resume/subsequent Jev | Revocation/post-credential/bridge tests pass; native slow investigation cancelled with count stable at 2; wait/test combinations pending |
| AI-AC06 | US-AI03/UC-AI08 | Disable preserves credentials/enabled rules and offline scan/preview/cleanup | Switch independent of profiles/rules; offline findings observed; disabled-cleanup combinations pending |
| AI-AC07 | US-AI04/UC-AI02 | Smart Cleanup empty/results actions select exact folders and obtain space indexes | Shared folder selection/local measurement implemented and Smart Cleanup fixture flow observed; result menus pending |
| AI-AC08 | US-AI05/UC-AI03 | Space toolbar/list/map use the same exact target | Toolbar/list/map implemented; current-folder reuse/fixed scope observed; each context menu pending |
| AI-AC09 | US-AI06/UC-AI04 | Large-file action discloses parent; cancellation preserves scope | Parent scope and launch panel implemented; complete native result action pending |
| AI-AC10 | US-AI14/UC-AI05 | Rules distinguish built-in/external paths and reuse draft/preview | Separate built-in/external actions observed; second system picker timed out, recovered; async picker fix needs retest |
| AI-AC11 | US-AI07/UC-AI03 | Choice/free text, incomplete-answer guard and no silent provider forwarding | Synthetic continuation and native choice/free text pass; unsent answers survive page changes and completed after submission |
| AI-AC12 | US-AI08/UC-AI03 | Explain large branches, facts/hypotheses/gaps and retention | Basic tools/UI exist; quality calibration pending |
| AI-AC13 | US-AI09/UC-AI05 | One exact disabled import/actual preview without changing other rules | Synthetic/previous live CLI pass; current native fixture exact disabled import and 14.7 MB preview pass |
| AI-AC14 | US-AI10/UC-AI05 | Enable one, fresh scan, current selection, native confirmation and receipt | Native fixture passed enable/fresh scan/confirmation/Trash receipt/restore; SHA-256 of all 3 files unchanged; new live package separate |
| AI-AC15 | US-AI11/UC-AI06 | Cancellation/limits/errors preserve actual states/results, no false success | SDK/bridge cancellation, budgets and redaction pass; native cancelled/no-advice observed; other UI combinations pending |
| AI-AC16 | US-AI12/UC-AI07 | Annotated local/Jev-sufficient cases have exactly zero main-model requests | 87 AI checks include local goal and Jev-only support/uncertainty/retention/malformed routes with exactly zero main-model calls |
| AI-AC17 | US-AI12/UC-AI07 | Explicit escalation reason and no silent fallback if missing setup | Bounded evidence/user clarification produced exactly one main request with reason; missing connection/technical failures never silently escalate |
| AI-AC18 | US-AI12/UC-AI07 | No repeated unchanged-evidence review; new evidence permits bounded review | Evidence/question/intent fingerprints, bounded questions and shared routing budgets implemented; synthetic cache reuse passes |
| AI-AC19 | US-AI12/UC-AI07 | Per-service request/token/reason metrics without invented prices | Actual requests, reported tokens and reasons implemented with contract assertions and UI; no prices invented |
| AI-AC20 | US-AI12/UC-AI07 | Distinct Jev support/uncertainty/retention/malformed/error outcomes | 87 checks cover independent routing outcomes; previous selected-service review retained; real classification quality pending |
| AI-AC21 | US-AI13/all cases | Languages, appearance, narrow windows, long paths, keyboard/VoiceOver | Localization/partial UI evidence; full combinations pending |
| AI-AC22 | US-AI15 | Restart restores original question/scope/provider; expiration rejects | CLI and both desktops implement local records/waiting continuation; original connection/expiry retained; interrupted-running recovery remains open |
| AI-AC23 | US-AI16 | Domain-specific uninstall/startup/privacy evidence without private records | Adapters pending; do not ship as working entries |
| AI-AC24 | US-AI05/UC-AI06 | Return/new choice for conflicts; navigation/hiding preserves task | Return/stop-new conflict actions implemented; navigation/unsent answers retained; complete conflict-button path pending |
| AI-AC25 | US-AI08/UC-AI05 | Useful no-advice reasons/next steps; stale findings cannot preview | No-advice/new/24-hour stale UI and guards implemented; native no-advice observed; full stale actions pending |
| AI-AC26 | US-AI02/UC-AI01 | Keychain waits off main thread; cancellation prevents later Jev | Background save, noninteractive Keychain reads and post-read cancellation checks implemented; user owns system permissions |
| AI-AC27 | US-AI17 | Alternative adapters, legacy configuration, unknown providers, isolated credentials and fixed active-task provider | Alternative injection, unknown-provider rejection, legacy policy/profile and independent configuration tests pass; credentials separated by provider; Clef unimplemented |
| AI-AC28 | US-AI18 / UC-AI09 | Twelve operations, installed providers, isolated credentials and cross-process cancellation | Added to synthetic contracts; current results belong in the implementation record |
| AI-AC29 | US-AI19 / UC-AI10 | Windows four contextual entries, complete gating/configuration/questions/previews/system credentials | WPF cross-build and 15 subprocess checks pass; native CI and button journeys pending |
| AI-AC30 | US-AI18 / US-AI19 | Existing Windows CI verifies this revision’s Swift/WPF/AI contracts and packages | Check stage wired; requires a run link for a commit containing these edits, never old HEAD |


## 3. Jev routing comparison cases

Annotate paths, retention, facts, allowed actions and expected provider calls. Preserve actual uncertainty; assert routing/authority rather than forcing real models to produce a desired proposal.

| Case | Expected handler | Assertion |
| --- | --- | --- |
| Largest-folder query | Local sort/accounting | Zero calls to both models |
| Explicit generated cache, known template, preserved source/config | Local compilation or Jev plus template | Zero main-model calls; disabled exact draft |
| Explicit offline-dependency/release retention | Deterministic fields or Jev retention | Size/confidence never overrides retention |
| Mixed folder with missing rebuild evidence | Jev selects bounded query/question | No expanded disposal scope or repeated identical question |
| Unfamiliar semantics requiring prose | Disclosed main model with recorded reason | Minimal context, local validation, review when needed |
| Jev authentication/malformed/oversized response | Explicit failure with findings | No automatic main-model fallback/error-body disclosure |
| Jev support but Core protection/matching failure | Core rejection with reason | No bypass of rules, identity or confirmation |
| Disable after main response before Jev | Local finalization/cancellation | Zero new requests after disable; no invented rollback |

Compare the current main-model-plus-review path with Jev First on identical cases for quality, calls, tokens, time and actual-price costs. Without verified rates, compare usage only. One successful cheap decision does not prove overall savings.

## 4. UI acceptance journeys

1. New user: off → on → no connection → add/cancel → failed test/repair → save.
2. Each context: Smart Cleanup empty/results, Space toolbar/list/map, large-file parent and Rules; verify identical exact scope.
3. Measurement/conflicts: missing/current/partial scan, scan cancellation, running/waiting task and cancelled launch panel.
4. Investigation: ready, Jev, local completion, escalation, questions/resume, stopping, errors, limits and no advice.
5. Findings: evidence/Jev disclosure, service usage, individual previews, zero/protected matches, keep disabled, enable/fresh scan.
6. Cleanup: existing exact confirmation, cancel, explicitly authorized fixture execution, actual receipts/remeasurement.
7. Disable: running/waiting/testing, offline reading, blocked continuation and enabled-rule local operation.
8. Accessibility: both languages, long paths, minimum window, appearance, keyboard focus, actual VoiceOver and Reduce Motion.

Record package/version/signature, OS, fixture manifest, actions, observations and limits. Keychain approval for one signed package is not evidence for another. Failed actions, intermediate views or builds alone never count as UI passes.

## 5. Existing evidence and limits

- Current automation: 87 AI CLI checks and bridge cancellation cover three protocols, zero-main decision-first routes, local goals, necessary escalation, deduplication, continuation, independent import and scope/budget/redaction. AI safety subset 2/2 covers provider replacement and revocation; 159 CLI and desktop bridge regressions pass.
- Native fixture package `.build/ai-decision-ready/Shou.app`: initial off, Jev-only test, Smart Cleanup folder selection/local measurement, exact index reuse, fixed scope and answers across pages. The exact 14.7 MB `build/cache` proposal passed disabled import, preview, individual enablement, fresh scan, current confirmation, Trash receipt and restoration. All three file hashes match; no permanent removal.
- Same-package slow decisions: disabling produced cancelled with retained findings. Two `/systemone` requests remained stable afterward; zero main-model calls. This does not cover every waiting/testing/accessibility combination.
- A second native directory picker timed out. Recovering the test picker service retained the original task and unsent answer. Code now uses asynchronous selection; latest-package retest is recorded separately. Failed UI actions do not count as passes.
- Previous live evidence: selected compatible Responses `gpt-6.1-sol` and TypeSafe `jev-1.13.0`. A 33,613-token run ended limited with a disabled preview; a 16,689-token run completed without advice for missing evidence. Both live connection tests passed in `.build/ai-ready/Shou.app`, not every new signature or decision-first quality case.

Fixtures: `.build/ai-native-acceptance/Fixture`; current receipt `execution_44382605-ba47-4e82-aec5-1336f6586440`; logs `/tmp/shou-ai-provider-*`. Archive sanitized version/signature/actions/results before release without keys. Full test and latest-package outcomes belong to the implementation record.

## 6. Documentation and implementation completion

Validate bilingual navigation/IDs, local links, fences and Mermaid parsing; align diagrams with existing versus target behavior and remove conflicting integration claims. Documentation checks do not replace feature tests.

Desktop gate, decision-first routing, independent setup/usage, shared launch and state UI are implemented. Continue latest-package native live, accessibility and quality/cost acceptance per row. Desktop recovery, domain explanations, content reads, Windows and macOS 14 remain independent gates.
