# Acceptance and testing

English | [简体中文](../zh-CN/engineering/acceptance-and-testing.md)

This document combines acceptance requirements with scoped runtime records. Each record states its tested boundaries; untested combinations remain pending.

## 1. Evidence layers

| Layer | Verifies | Does not establish |
| --- | --- | --- |
| Documentation/schema | Links, JSON, structural examples, translation consistency | Runtime matching or application builds |
| Core tests | Patterns, conditions, states, risks, deduplication | Native filesystem/permission behavior |
| Filesystem integration | Temporary roots, links, identities, Trash, journals | UI or agent compatibility |
| CLI contracts | JSON, exits, pages, cancellation, confirmation | GUI accessibility |
| GUI flows | Access, rules, previews, execution, recovery | Independent CLI behavior |
| Existing-agent tests | Actual client rule-addition workflows | Every client/version compatibility |
| Native distribution | Signing, runtimes, clean install/update/uninstall | Another OS/platform |

Use fictional fixtures and temporary roots rather than real development workspaces in automated deletion tests.

## 2. Product matrix

| Acceptance | Requirement | Pass condition |
| --- | --- | --- |
| AC01 | F01 | GUI selection/CLI registration and honest access failure |
| AC02 | F02 | Nested projects and unclassified large directories found |
| AC03 | F03 | Both entries add rules without code changes/releases |
| AC04 | F04 | Conditions, paths, markers, exclusions agree |
| AC05 | F05 | Each candidate exposes evidence, versions, risks, size basis |
| AC06 | F06 | Repeated/parent-child targets resolved without double counting |
| AC07 | F07 | Independent confirmation and revalidated item outcomes |
| AC08 | F08 | Trash distinct from freed space; only verified batch purged |
| AC09 | F09 | Exclusions/protection cannot be overridden |
| AC10 | F10 | Fresh presets, no restore overwrite, interruption query |
| AC11 | F11 | Discovery, JSON, exits, pages, independent terminal loop |
| AC12 | F12 | Positive/negative developer artifact/cache/dependency cases |
| AC13 | F17 | No platform-specific imports in core |
| AC14 | F18 | Actual Windows filesystem/UI/distribution evidence |
| AC15 | F19 | Documentation language switching and runtime text coverage; invariant machine decisions |

F13–F16 gain acceptance criteria when implemented, not advance completion credit.

## 3. Rule cases

Validate required fields, unknown/script rejection, versions, identical reimport, and changed-content conflicts. Reject unsafe paths and invalid patterns. Verify `**` zero/multiple levels, non-crossing `*`, exact ordinary marker files, complete descendant ages, and unknown-value rejection.

Draft preview never executes; enablement still requires fresh scans. Resource/permission/cancellation gaps never become complete evidence.

## 4. Developer fixture

Include an excluded active project, inactive Rust project with source/lockfile/`target` variants, Node.js/Electron project with manifests/dependencies/caches/outputs, version metadata, unique deliverables, and unclassified personal-tool data. Add sparse files, hard links, supported clones, and known/unknown link variations.

Use controlled sizes rather than filling tens of gigabytes solely for examples. Distinguish logical from allocated measurements.

## 5. Blocking safety cases

| ID | Case | Required outcome |
| --- | --- | --- |
| S01 | Target/ancestor link escapes workspace | No traversal or outside changes |
| S02 | Target replaced after scan | Refuse/skip replacement |
| S03 | Descendants change while top-level time stays fixed | Manifest detects invalidation |
| S04 | Protected/excluded descendant | Block entire parent operation |
| S05 | Rules, selection, exclusions, action change | Invalidate previous confirmation |
| S06 | Noninteractive destructive call | Confirmation error, no target changes |
| S07 | Concurrent destructive processes | One lock owner, explicit conflict |
| S08 | Repeated plan execution | Existing receipt, no second operation |
| S09 | Full disk/unavailable intent journal | Do not start destruction |
| S10 | Crash after operation before result | Reconcile, never replay unknowns |
| S11 | Trash object replaced or expanded | Refuse changed scope |
| S12 | Restore path occupied | No overwrite |
| S13 | Control sequences/instruction-like filenames | Correct JSON and safe terminal rendering |
| S14 | Trash capability unavailable | No permanent-delete fallback |
| S15 | Partial or cancelled coverage | Incomplete targets blocked; independent complete siblings require positive coverage and full manifests |
| S16 | Known dependency symlinks point outside | Process links only; preserve outside content and identity |
| S17 | Legacy partial record without coverage | Missing `completedPaths` never grants eligibility |
| S18 | Cleanup discovery complete with a sparse tree | `scope=cleanup`, `treeComplete=false`; space analysis requires `full` and UI explains missing coverage |
| S19 | Generated Rust/Swift sources or Cargo extracted sources | Exact trusted rule plus native layout/activity/ownership/integrity evidence; tracked/modified/unknown content blocked |
| S20 | Execution stopped during a system Trash call | No new item starts after the safe boundary; reconcile the active call and preserve actual outcomes |
| S21 | CLI and desktop standard scans | CLI `scan` defaults full, `system scan` cleanup with projects default false; desktop includes only registered projects, never implicit home discovery |

Any unconfirmed destruction, outside-scope processing, overwrite, or blind retry blocks release. Passing fixtures is not a universal no-risk guarantee.

## 6. CLI and actual agents

Verify one stdout JSON envelope, stderr separation, exit/status/error agreement, real capability discovery, disabled noninteractive import/preview, terminal-only execution/recovery, and state queries after interruptions.

Separately test actual Codex and Claude Code; record WorkBuddy/version permissions when available. No internal model requests, agent startup, global configuration changes, or simulated-click dependency.

## 7. Native UI and localization

Test appearance, resizing, navigation, sorting, multi-selection, context menus, Finder reveal, path copying, focus, keyboard, VoiceOver, and non-blocking main-thread behavior. Closing/quitting must not conceal continuing destructive work.

Cover permission expiration, partial results, empty matches, stale plans, and restoration conflicts. Treemap/list accounting and selection must agree. Validate terminology, long strings, plurals, non-Latin paths, time zones, and locale aliases. Every advertised runtime language needs full risk/confirmation/error/accessibility coverage. Compare IDs, digests, candidates, states, and decisions across locales.

## 8. Initial performance budgets

Unmeasured targets, adjustable only with recorded evidence:

| Measure | Initial target | Conditions |
| --- | --- | --- |
| 100,000-node scan | Within 60 seconds | Apple Silicon, 16 GB, local APFS SSD; no content hashing |
| Peak RSS | At most 300 MiB | Record manifest/storage strategy and cache state |
| UI feedback | Target at most 100 ms | Main-thread profiling and interaction measurements |
| Cancellation | Stop dispatching within 1 second | In-flight system call may take longer |
| 1,000,000 nodes | Bounded completion or explicit limit | No unbounded memory or silent truncation |

Record hardware, OS, build, storage, entries, cache state, time, memory, and errors. These budgets are not all-device promises.

## 9. Windows gates

Test actual core/CLI/UI, ACLs, occupied files, long paths, junctions/reparse points, Recycle Bin, restore conflicts, durability, cancellation, runtimes, signing, and clean upgrade/uninstall. Without native evidence, support remains unverified.

## 10. Reporting

Reports include build/contract versions, platform/client/locale, executed/pass/fail/skip cases, logs, limits, and reproductions without private data. Documentation checks establish only static document/schema validity, never MVP completion or runtime safety.

## 11. Local verification record — 2026-10-19

This scoped record supplements the acceptance plan. It does not establish full product or release acceptance. Environment: macOS 15.7.3 (24G419), Apple Silicon MacBookPro17,1, 16 GiB RAM; local debug application installed at `/Applications/Shou.app`, ad-hoc signed and not notarized.

| Scope | Observed result | Evidence under local `.build/` |
| --- | --- | --- |
| Core and isolated read worker | 94/94 checks passed, including protocol rejection, evidence equivalence, cancellation and timeout | `read-worker-core-final.log` |
| Independent CLI contract | 58 checks passed without modifying cleanup targets | `read-worker-cli-contract.log` |
| Built-in native cleanup | 74 rules and 460 patterns exercised within an 80/80 suite; real Trash → restore, retained files and hashes preserved, purge disabled | `complete-cleanup-native-final.log` |
| Large native target | 100,103 files and 100,204 manifest entries; Trash → restore with descendant metadata and sentinel hashes verified | `large-target-trash-restore.log` |
| Installed desktop cleanup | Project scan → preview/cancel → confirmed Trash → history → confirmed restore; all 1,035 fixture file SHA-256 hashes matched | `ui-cleanup-acceptance/gui-restore-verification.json` |
| Personal rule | Disabled draft, read-only preview, export, enable and fresh scan → confirmed cleanup → GUI restore; same 1,035 hashes matched; duplicate import remained idempotent and invalid JSON was rejected | `ui-cleanup-acceptance/gui-personal-rule-verification.json` and Computer Use observations |
| Personal-rule revision editing | An isolated application and data store exercised full JSON editing: malformed JSON, ID changes, existing versions and negative size were rejected; text changes invalidated validation. Version 0.1.1 saved disabled while the 0.1.0 binding remained; both patterns, exclusions and other fields matched. Previous results/selections cleared, draft execution stayed disabled, and explicit enable → fresh scan → GUI Trash → GUI restore preserved all five file SHA-256 hashes. Chinese/English switching and cancelling an edit passed | `ui-rule-revision-acceptance/gui-save-verification.json`, `gui-trash-verification.json`, `gui-restore-verification.json` and Computer Use observations |
| Revision regression | Core 96/96 and CLI contract 58 checks passed. Revisions cannot overwrite existing definitions, start disabled and preserve prior bindings. Old scans/plans and executable draft previews are rejected; explicit enable permits a fresh plan. Both languages passed checks for 560 resource keys | `rule-revision-core.log`, `rule-revision-cli.log` |
| Revision installation | Updated `/Applications/Shou.app` after confirming it had exited; signature and distinct-product checks passed. Hashes of 36 configuration/history records were preserved during installation. Computer Use verified the installed personal-rule filter, opening the editor, successful validation and cancelling back, without saving changes to existing rules | `desktop-rule-revision-install.json` and Computer Use observations |
| Exclusion policy regression | Core 99/99 and CLI contract 73 checks passed. Global protection covers existing and future roots, full/cleanup scans and draft previews; project prefixes preserve sibling eligibility. Policy changes invalidate evidence and modified stored plans cannot bypass current protection. Configuration upgrades to version 2 and remains there after the last global removal. An actual older helper accepted version 1 and rejected version 2 before and after the last removal | `exclusions-core.log`, `exclusions-cli.log`, `ui-exclusions-acceptance/old-build-compatibility.json` |
| Desktop exclusion management | Isolated GUI added global protection and a later workspace, verified disabled protected descendants, invalid `../demo`, whole-project `demo/**`, workspace protection and independent removal. Another workspace remained eligible. Changes cleared old results/selections. Rules and Settings entries, restart persistence and Chinese/English layouts passed. With a nonmatching global pattern retained, two generated targets completed GUI preview → Trash → restore; all 12 file SHA-256 hashes matched and the exact old Trash paths were absent | `ui-exclusions-acceptance/gui-policy-scans.json`, `gui-trash-verification.json`, `gui-restore-verification.json` and Computer Use observations |
| Exclusion installation | Updated `/Applications/Shou.app`; signature/product checks passed and 36 configuration/history record hashes were preserved. Installed GUI verified scope selection, compatibility explanation, invalid project rejection and closing without saving. Existing user configuration was not upgraded by these UI checks. Both runtime languages passed checks for 582 resource keys | `desktop-exclusions-install.json`, `ui-exclusions-acceptance/gui-final-verification.json` and Computer Use observations |
| Interrupted history and location inspection | Core 105/105 and CLI contract 80 checks passed. Coverage includes failures before/after the per-item journal boundary, failure after restoration but before its follow-up result is saved, and an independent child exiting with code 86 immediately after moving an isolated fixture. Stored intents remain unfinished and old plans cannot replay. The native catalog test covers 74 rules and 460 patterns, including exact original/Trash manifest observations before and after restoration. A separate native CLI TTY Trash → restore run passed | `history-inspection-native-location-final.log`, `history-inspection-cli-location-final.log`, `history-inspection-native-cli.log` |
| Desktop history inspection and restore conflict | A generated 98,304-byte target completed reviewed GUI Trash → inspection → occupied-destination restore rejection → separately reviewed restore after moving the conflict aside. All eight source/cache file hashes and the conflict sentinel matched; the exact old Trash path was absent and the original receipt remained byte-identical. Synthetic unfinished and pending-follow-up records verified blocked actions, batch isolation, both languages, mutation-lock error/retry and Escape closing; these UI fixtures do not claim a real process interruption | `ui-history-inspection-acceptance/run02/gui-trash-verification.json`, `gui-conflict-verification.json`, `gui-restore-verification.json`, `gui-final-verification.json` and Computer Use observations |
| Unfinished and failed summaries | A synthetic executing/pending record displayed Unfinished cleanup, one item needing verification and zero skipped; restore/removal remained disabled. A failed record displayed one failure, zero skipped and two localized diagnostic lines. Chinese → English → Chinese history states switched immediately. All 11 record hashes in the independent store copy remained unchanged | `ui-history-inspection-acceptance/run02/gui-results-verification.json` |
| Responsive initialization | Local-store initialization now runs off the main thread. While `openat` was blocked for an independent Documents store, the window rendered, sidebar navigation worked and Command-Q exited normally. Sampling showed the main event loop and background store initialization. The specific blocking cause is unknown; system permissions were not changed | `history-inspection-startup-responsive-sample.txt`, `ui-history-inspection-acceptance/run02/startup-responsive-verification.json` |
| Final history-inspection installation | Updated `/Applications/Shou.app`; signature/product checks passed. All 36 configuration/history record hashes matched after installation and read-only GUI checks. Cold launch, inspecting an existing generated target, Escape closing and returning to the Chinese home page passed. Both languages passed checks for 619 resource keys. This pass cleaned no real user data and performed no further permanent removal | `desktop-history-inspection-final-install.json`, `ui-history-inspection-acceptance/run02/installed-gui-final-verification.json` |
| Read-worker lifecycle | Core checks verified the two-live-child cap, rejection of a third request and capacity recovery after cancellation. Separately, the installed CLI scanned 100,008 generated file entries. Its requesting parent exited with code 86 after receiving progress and before any result existed. The worker was observed absent about 0.275 seconds later, with no result published. Eight seed-file hashes, hard-link counts and the file-entry count were retained | `history-inspection-native-location-final.log`, `read-worker-parent-exit-acceptance/run01/verification.json`, `read-worker-parent-exit.log` |
| Codex-session rule workflow | This Codex session read installed capabilities/schema, generated a personal rule, inspected a structured error for an unsupported shell action, corrected it, validated and imported a disabled draft, then previewed it. Only the intended `.build-cache` matched; the project itself remained unclassified. Creating a plan from the draft preview was rejected. All three fixture file hashes matched, no plans/history were created and no real data or global agent configuration changed | `codex-cli-acceptance/run01/verification.json` and per-command JSON |
| Execution cancellation boundaries | Core 108/108 and installed CLI contract 80 checks passed. Follow-up tests cancel before an item, during verification, after intent persistence and after restoration; unstarted items remain unchanged and the original receipt stays intact. Native Trash with a read worker also passed cancellation immediately after the first moving intent: one moved, one pending, followed by exact restoration. Catalog coverage remains 74 rules and 460 patterns; purge disabled | `operation-lifecycle-native-final.log`, `operation-lifecycle-installed-cli.log` |
| Desktop quit and window close | In an independent app/store, Keep Open during cleanup allowed all 24 generated targets to finish and be restored. Stop and Quit during moving recorded three moved and 21 pending, no failures, and the process exited. Stop and Close separately recorded three moved and 21 pending; native logs proved the window closed while the app remained running. Each stopped batch was restored through separate GUI confirmation; all 12,336 original file hashes matched and exact old Trash paths were absent | `ui-operation-lifecycle-acceptance/run01/gui-keep-open-verification.json`, `gui-initial-restore-and-close-issue.json`, `gui-stop-quit-verification.json`, `gui-stop-quit-restore-verification.json`, `gui-stop-close-verification.json`, `gui-stop-close-restore-verification.json`, `stop-close-final-native.log` |
| Lifecycle fixes and retained failures | The first Stop and Quit attempt incorrectly recorded Scan cancelled during mutation verification; native traversal now distinguishes cancellable reads from a journaled mutation. The first Stop and Close attempt safely stopped but its completion sheet blocked performClose; confirmed closing now dismisses that sheet and closes directly. Both failed observations remain retained. A later English full-batch Trash/restore passed, but restoration completed before the next UI observation, so it does not verify stopping during restore | `ui-operation-lifecycle-acceptance/run01/gui-stop-quit-cancellation-issue.json`, `gui-stop-close-sheet-issue.json`, `gui-full-english-trash-verification.json`, `gui-full-english-restore-verification.json` |
| Lifecycle installation | Updated `/Applications/Shou.app` with an old-package backup. Signature and distinct-product checks passed; all 36 configuration/history record hashes remained unchanged after Chinese cold launch, idle window close/reopen, read-only History and normal quit. All 12,336 lifecycle fixture files still matched their initial hashes at final inspection. Two languages passed checks for 627 resource keys; no real data cleanup or further permanent removal | `desktop-operation-lifecycle-install.json`, `ui-operation-lifecycle-acceptance/run01/installed-gui-final-verification.json`, `installed-idle-close-native.log` |
| English restore-stop workflow | A later run verified the English quit alert with Keep Open, then completed all 24 Trash targets. Immediately requesting close after confirming restoration stopped during read-only verification, before the first follow-up intent: zero restored, all 24 targets retained at their exact recorded Trash locations, no follow-up records and all 12,336 file hashes matched. Native logs proved the window closed. Reopening and separately confirming restoration completed all 24; every original hash matched and old exact Trash paths were absent. The application returned to Chinese and exited normally | `ui-operation-lifecycle-acceptance/run01/gui-restore-immediate-stop-verification.json`, `restore-immediate-stop-native.log`, `gui-restore-immediate-stop-final-verification.json` |
| Cleanup outline keyboard and large list | An independent 2,000-project fixture verified Space selection, protected-item refusal, a 2,000-item build group with another category retained, sorting with candidate identity preserved, page/end scrolling, Chinese/English labels and high-risk help, reviewed-preview Escape cancellation and normal quit. Shift-F10 revealed the exact ordinary and Unicode long-path targets in Finder. Initial menu/focus failures and two layout timeouts were retained; the passing version batches group changes into one observation. An idle sample showed the main event loop, CPU 0% and RSS 156,016 KiB at that observation | `ui-keyboard-acceptance/run01/` Computer Use observations, `keyboard-menu-sort-issues.json`, `group-selection-layout-issue.json`, `group-selection-layout-second-issue.json`, `idle-resource-observation.json`, `final-interaction-idle-sample.txt` |
| Keyboard improvements installation | The final build was installed at `/Applications/Shou.app` with an old-package backup, verified ad-hoc signature and distinct desktop/CLI executables. Chinese cold launch, read-only History and returning to the home page passed; all 36 existing record hashes and all 6,007 original keyboard-fixture hashes matched. Two languages passed checks for 629 resource keys. The installed app contains no fixture data-directory environment | `desktop-keyboard-final-install.json`, `ui-keyboard-acceptance/run01/gui-final-verification.json`, `final-scan-verification.json`, `installed-gui-final-verification.json` |
| App Reduce Motion and status accessibility | The localized switch persisted through restart and Chinese/English switching. In app reduced-motion mode, scanning retained real stage/count updates with a static dot field, Stop returned to a stopped state, and a fresh scan completed without automatic selection. Forty generated targets completed reviewed GUI Trash → location verification → separately reviewed GUI restoration; all 10,320 original hashes matched at final inspection. Execution exposed localized progress names/counts; indeterminate restoration displayed a static hourglass and removed the progress region on completion. Turning the preference off restored the moving sweep in consecutive observations; scanning then returned to static results. This build was installed with a backup, distinct-product/signature checks, Chinese launch, read-only History and all 36 real record hashes preserved. Two languages passed checks for 632 keys | `motion-accessibility-native-build.log`, `motion-accessibility-stage.log`, `desktop-motion-final-install.json`, `ui-motion-acceptance/run01/gui-final-verification.json`, `trashed-verification.json`, `restored-verification.json`, `installed-gui-final-verification.json` |
| Follow-up progress and history batch selection | Core 110/110, CLI contract 80, four cancelled TTY confirmations and native CLI Trash/restore passed. Progress tests prove saved-intent cancellation, monotonic selected-item totals and failed-outcome counting without overwriting a restore destination. An independent desktop run verified native mixed selection (0 → 1 → 48 → 0), separately reviewed restoration of 48 items and selection isolation from completed batches. A later 100,000-file target verified GUI Stop after its restore intent was saved and before its completion: the current item finished, the second never started, and all 112,644 fixture file hashes matched their exact original or recorded Trash locations. Two earlier stop attempts arrived after completion and are retained as timing failures, not passes | `followup-progress-core-native.log`, `followup-progress-cli.log`, `followup-progress-tty.log`, `followup-progress-native-cli.log`, `ui-followup-acceptance/run01/gui-observations.json`, `hundred-thousand-restore-stop-observer.jsonl`, `durable-stop-verification.json` |
| Follow-up installation and final integrity | The unstarted item was restored through a new one-path preview and confirmation. All 112,644 original file hashes matched at their original locations, all 52 follow-ups completed restoration, recorded old Trash paths were absent and original execution receipt hashes were unchanged. The independent app exited normally. The tested build was installed with an old-package backup; signatures, distinct desktop/CLI executables, Chinese launch and read-only history passed, all 36 existing record hashes were preserved, and 636 keys passed in two languages. The attempted installed English switch was interrupted by an app-state change and is not counted as a new language-switch pass | `desktop-followup-final-install.json`, `ui-followup-acceptance/run01/gui-final-verification.json`, `restored-verification.json`, `installed-gui-final-verification.json` |
| Desktop batch and execution stop | 24 generated targets completed Trash → GUI restore. A second run stopped after the first completed item: two moved, 22 left unprocessed and zero failures; the two moved items were then restored through the GUI. All 12,336 file SHA-256 hashes matched after each restoration | `ui-cleanup-acceptance/gui-batch-restore-verification.json`, `gui-execution-stop-verification.json` and `gui-execution-stop-restore-verification.json` |
| Standard scan | Two runs reached the aggregate result page with zero initial selections: the earlier run estimated 10.45 GB with timeout warnings; the final package estimated 38.95 GB and reported incomplete coverage for a registered project | Computer Use observations; `desktop-responsive-install.json`, `ui-cleanup-acceptance/gui-final-ui-verification.json` |
| Standard-scan cancellation | Stop at the previously stalled QQ root returned to the start page without an error alert; another scan could start immediately | Computer Use observations |
| Localization | Installed application switched Chinese → English → Chinese immediately; 543 resource keys checked in two runtime languages | Computer Use observations and localization checker |
| Path actions and analysis navigation | Native project-row menu revealed the exact fixture target in Finder and copied its absolute path. First-use space analysis now scans automatically and retains the requested target; reviewing it returns to cleanup with that item selected. Excluding the fixture Next.js output triggered a fresh scan and disabled its checkbox with a protection reason | Computer Use observations; `desktop-acceptance-install.json` |
| Appearance and support | Light and dark themes rendered; dark preference survived restart, then system appearance was restored. Feedback and repository links opened their intended public GitHub destinations | Computer Use observations |
| Follow-up availability | After restoring the stopped batch's two moved items, Restore and Permanently Remove were disabled. Its 22 unprocessed items displayed as skipped in history while the original receipt retained `pending` | Computer Use observations; `gui-execution-stop-restore-verification.json` |
| Filtered bulk selection and compact layout | Build-category selection included four eligible items and no other categories. Searching Rust reduced it to two items; ordinary selection excluded those high-risk items. Searching npm selected only one item. All selections were cleared; compact category navigation and the fixed action bar remained usable | `ui-cleanup-acceptance/gui-final-ui-verification.json` |
| Desktop permanent removal | A separate generated 106,496-byte target completed GUI scan → reviewed Trash → separately reviewed permanent removal after explicit user confirmation. The follow-up completed, the exact Trash target disappeared, both retained source-file hashes matched, and history disabled further restore/removal | `ui-cleanup-acceptance/gui-permanent-removal-verification.json` |
| Startup discovery first stage | Core 114/114, CLI contract 84, four cancelled TTY confirmations and native CLI Trash/restore passed. New cases cover bounded XML/binary definition reads, unknown states, omitted secret arguments/environment values, duplicate labels, system opt-in, invalid input, links/FIFO/oversized files and explicit budget gaps. A damaged cleanup-store path does not block the read-only CLI. Independent desktop acceptance verified 44 local definitions, search by name/source/executable, exact Finder reveal/copy, no-match state, coverage, refresh, Chinese/English switching and default/narrow layouts. Opting into Apple sources returned 873 definitions across five sources with 19 explicit issues. The public settings action opened the native Login Items & Extensions page without changing controls. Initial fixture permissions, missing translations and overflowing table layout were retained and corrected; final app/store runs exited normally | `startup-inventory-core-native-final.log`, `startup-inventory-cli-final.log`, `startup-inventory-tty-final.log`, `startup-inventory-native-cli-final.log`, `ui-startup-acceptance/run03/gui-final-verification.json`, `ui-startup-acceptance/run04/gui-final-verification.json` |
| Startup discovery installation | Installed at `/Applications/Shou.app` with an old-app backup, exact staged/package-manifest match, signature and distinct-product checks. Final localized resources contain 693 keys in two runtime languages. Installed Chinese cold launch, 44-definition read, Chinese coverage, immediate English/Chinese switching, native Login Items settings navigation and CLI partial/exit 6 passed. All 36 real record hashes and 882 inspected startup-definition hashes remained unchanged. The test app exited; the installed app remained idle on Chinese Startup Items. Configured/runtime states remain unknown; direct control, complete registration coverage, GUI startup Stop timing, VoiceOver, Windows and release gates are not established by this run | `desktop-startup-final-install.json`, `startup-inventory-production-stage.log`, `ui-startup-acceptance/run04/installed-gui-final-verification.json`, `installed-cli-default.json` |

Standard scan completion here means the workflow reached its result page. Its status was **partial**: inaccessible or time-limited roots were reported rather than treated as fully scanned. No real user caches or projects were cleaned. Moving test targets to Trash did not count as released disk space.

Independent rule/history buttons and the history result action were verified after replacing the previous grouped accessibility structure with plain native layout containers. The earlier Computer Use native-service crash is not evidence of a Shou crash; Shou's sampled main thread was idle. Remaining gates include VoiceOver, system Reduce Motion, actual third-party agent clients and production distribution. Desktop permanent removal passed only for the separately authorized generated target; this does not cover CLI purge or emptying Trash.

The app Reduce Motion pass does not establish VoiceOver announcement delivery or behavior when the macOS setting changes at runtime. System settings and the production app preference were unchanged. Scan/execution announcements use native accessibility notifications at operation boundaries; speech, focus and all accessibility combinations still require acceptance. The earlier E30 integrity anomaly remains unresolved and is not superseded by this independent fixture.

The 100,000-file follow-up pass covers the observed large-target scan/result and restore-stop boundary. Its retained Computer Use sequence lacks a separate Trash-confirmation observation, so confirmation-flow acceptance relies on the separately retained 48-item and earlier passes. The first two stop attempts finished before the stop click could take effect. A verifier initially treated reuse of the Trash pathname of a restored object by a new batch as a failure; the corrected check compares device/inode, and all file hashes matched. Both observations remain retained. These independent results do not explain the older E30 or temporary-fixture anomalies.

The large-list pass is limited to the listed interactions and a single idle resource observation. It does not establish latency percentiles, long-duration resource stability, VoiceOver completion or a 100,000-row GUI result. The final build's keyboard Copy Path action was verified by pasting through Finder's Edit menu: the exact Unicode long path matched. An earlier shortcut-based paste retained the previous value and remains recorded separately. No Trash, restoration or permanent removal was requested in this fixture run.

The Codex check means this session called the installed CLI through its command tool. It does not establish compatibility across every Codex client, Claude Code or WorkBuddy.

Reproduce the read-worker parent-exit check separately. It runs no cleanup and retains generated fixtures. The evidence directory must not exist. Its 100,000 hard-link entries take metadata space and creation time, so it is not part of the quick checks:

```sh
python3 "scripts/verify-read-worker-lifecycle.py" \
  --bin "/Applications/Shou.app/Contents/Helpers/shou" \
  --evidence ".build/read-worker-parent-exit-acceptance/new-run"
```

This check does not simulate an uninterruptible kernel filesystem call or forced termination during cleanup. Normal quit/window-close during Trash and stopping restoration before the first intent have the separate GUI evidence above. Cancellation after a restore intent is covered by boundary tests and the separate 100,000-file GUI restore-stop evidence above. That run used Stop, not close/quit, and does not prove every lifecycle combination. Permanent-removal cancellation and forced termination inside a system Trash call remain unverified.

Final integrity inspection found an unresolved change in the stop fixture: its directories remained, but all 12,336 expected files were absent. A sample directory's modification time was 16:05:44 local time, after the successful 16:00:28 restore-time hash record and before this final installation pass. There was no newer Shou cleanup receipt or restore follow-up. The source for workspace removal only changes registration, bindings and presets; the original 1,035-file fixture remained hash-identical after its registration was removed. These observations do not establish the cause. Keep the earlier restoration evidence as a historical result and **do not mark final stop-fixture integrity as passed**. Evidence: `ui-cleanup-acceptance/gui-final-registration-and-hash-verification.json`.

The first temporary history-inspection GUI fixture was later found missing its workspace and saved records before any GUI cleanup had been confirmed. Its cause is unknown and that attempt is not counted as a passed cleanup/restore test. Keep `ui-history-inspection-acceptance/incomplete-temporary-fixture.json` and the original fixture manifest. The independently created `run02` fixture lives under the build directory and has separate integrity evidence. New inspection results neither explain this change nor resolve the earlier stop-fixture anomaly. Outcomes inside a system Trash call with no recorded returned path remain unknown; inspection does not search Trash or create recovery authority.

## 12. v0.2.0 candidate verification

The frozen v0.2.0 source passed 127/127 debug checks, 89 real CLI contracts and four cancellation confirmations. All 74 built-in rules and 460 patterns completed native Trash → restore → Trash → explicit purge using generated fixtures; retained files and restored hashes matched. The native uninstall CLI separately verified five components, personal-data consent, TTY refusal/cancellation and independent restoration.

A fresh 100,103-file target completed native Trash and restoration with all 100,204 manifest entries, descendant metadata, sentinel hashes and retained source verified. The parent-exit check retained 100,008 generated entries and published no result after the read worker stopped.

An isolated copy of the public v0.1.0 binary downloaded a signed localhost update to the v0.2.0 candidate debug application, installed it and restarted. The executable matched the update and all five baseline configuration/workspace files retained their hashes. A subsequent update check reported v0.2.0 current. Bottom settings, Command-comma, language switching and exclusion scope/compatibility notices passed. A new generated desktop application completed exact five-component review → explicit personal-data selection → confirmed Trash → independently confirmed history restoration. Every file hash and the unrelated sentinel matched; exact old Trash paths were absent and repeat restoration was disabled.

Evidence is retained locally under `.shou-local/`: `v0.2.0-debug-tests.log`, `v0.2.0-large-tests.log`, `v0.2.0-worker-lifecycle/verification.json`, `v0.2.0-upgrade-verification.json`, `v0.2.0-gui-trashed-verification.json` and `v0.2.0-gui-restored-verification.json`. These passes do not resolve the older fixture anomalies above. Universal release packaging, signature checks and native Intel execution remain separate release gates; GitHub Actions must complete them before publication.
