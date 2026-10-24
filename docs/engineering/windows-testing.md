# Windows diagnostics and testing

English | [简体中文](../zh-CN/engineering/windows-testing.md)

This defines diagnostic and acceptance entry points, not complete Windows feature support. Executed evidence belongs in [SYNC.md](../../SYNC.md). Keep the cloud desktop in `StopCharging` during local work and prepare checks and synchronization before starting native validation.

## Diagnostics

GUI and CLI share `%LOCALAPPDATA%\Shou\Diagnostics\application.jsonl`, retaining the current and previous files at up to 1 MiB each. Versioned JSON events contain timestamps, app/OS versions, architecture, process/session, operation/parent IDs, stage, elapsed time, outcome, counts, error codes, HRESULT, inner Win32 codes and method stacks. Exceptions consumed by presentation state are observed. Partial coverage, cancellation, failure and unfinished operations stay distinct. The suffix of CLI `request_id` after `request_` matches its root operation ID; Smart Cleanup shows a diagnostic reference on failure.

Raw paths, SIDs, general exception messages, command arguments, file/browser contents and credentials are excluded. Paths use a per-process random HMAC key. Explicit `SHOU_XAML_STARTUP_DIAGNOSTICS=1` enables bounded XAML parse messages for local diagnosis; CI alone does not enable them.

Directories/files require private current-user ACLs, verified handles and single-link files without reparse traversal. Operational logging is best effort and reports dropped-event counts; E2E fails on missing or dropped evidence. Durable mutation intent journals retain their independent fail-closed safety semantics.

Provisioned LocalAppData and an existing Shou container may be SYSTEM/Administrators owned. Default paths accept only pinned ancestors without foreign write principals; ownership and ACLs are never repaired. Data/Diagnostics leaves and files still require private current-user ownership. Explicit `SHOU_DATA_DIR`/`SHOU_DIAGNOSTICS_DIR` overrides retain strict current-user parent checks. Scan/cache-root ownership checks remain unchanged and unavailable locations remain coverage issues.

## Test layers

| Layer | Entry and assertions | Does not establish |
| --- | --- | --- |
| Generated/static contracts | Localizations, design generator, docs, CLI arguments/envelopes | Native UI/system behavior |
| Core/Presentation | Scope, selection, state, stop, late results, current confirmation, faults and diagnostic correlation | Windows ACL/handle behavior |
| Native Platform | First records, diagnostics before registration, admin-owned generated ancestors, foreign-write rejection, hard links, bounded rotation, locks/adapters | User interaction |
| Publish smoke | Self-contained version/capabilities, window startup/normal close | A working scan or other pages |
| Desktop E2E | Real controls, generated fixtures, confirmed cleanup and recorded history, results/filtering, setting persistence, recovery, screenshots and integrity | Generated MSI/task mutation scripts, visual parity, signing/installation |

Run `sh scripts/test-windows-core.sh` on macOS and `scripts/windows/test.ps1` on Windows. Native and elevated fixture checks explicitly skip unsupported hosts/tokens; skips are not passes and the product should not be elevated to scan. Windows tests collect available TRX/diagnostics even on failure. CI separately retains publish diagnostics.

`pwsh -NoProfile -File scripts/windows/test-e2e-harness.ps1` checks the E2E runner's rejection correlation and evidence validation using isolated generated logs; the Windows main test script runs it too. It does not launch the app or perform system mutations and is not native desktop E2E evidence.

## Interactive E2E

Use the logged-in, unlocked Windows user session. Session 0 and non-STA execution are rejected:

```powershell
powershell.exe -NoProfile -STA -File scripts/windows/test-desktop-e2e.ps1 `
  -PublishRoot "C:\ShouBuild\win-x64\publish" `
  -ArtifactsRoot "C:\ShouBuild\e2e"
```

Each run uses private isolated records and a generated project. UI Automation targets only the launched process and stable control IDs. Timeouts, page failures, crashes, missing controls/logs, changed fixture bytes and abnormal close fail the run. Screenshots, the process UI tree, JSON logs, command outputs, hashes and per-step results are retained. Failure to locate a native picker also fails; results must not be injected into the page. Each step atomically saves `checkpoint.json` with the active step and observed results, explicitly marked `verification_complete=false`. Only final `verification.json` is complete acceptance evidence. Export checkpoints before the cost cutoff rather than leaving the desktop running for final collection.

Each generated-folder journey normally closes and relaunches the app before selection, so a cached result page cannot hide the initial picker button. Cleanup completion has a separate screenshot before Back. Noninteractive-confirmation and replay rejections require matching exit/error codes, CLI `request_id` and diagnostic parent operation ID, with exactly one correlated log saved separately. Other requests, UI failures and unsupported capabilities have no blanket exemption from log-health checks.

| Journey | Current E2E assertions |
| --- | --- |
| First Smart Cleanup | Click Start, observe completed location preparation, distinguish legitimate empty/complete/partial from setup failure |
| Generated cleanup project | Register, import/enable personal rule, scan, exact single-item plan, confirm permanent deletion, verify target removal/retained bytes/history, reject replay |
| Smart results | Find generated target, expand groups, empty nonmatching search and restore; clear through the selection menu, then prepare and confirm from the cleanup action. New assertions require a separate completion page, hidden stale results/raw details and working Back; native revalidation is pending |
| Space analysis | Choose generated folders through the native picker; start/stop, complete scan/tree, cancel/confirm generated-file deletion and verify retained bytes; blocked by the picker in this run |
| Large files | Native picker, complete generated scan/list and confirm generated-file deletion; not reached in this run |
| Applications/startup | Real inventory complete/partial, empty nonmatching search, no real uninstall/control |
| Rules/history | Rule search; read-only work creates no execution history |
| Privacy | Create only a random new Chromium profile and generated Cookie database; check Cookie review gating, selection counts/clear/revocation, independent current permanent-deletion/sign-out consent, unchanged database digest after cancellation, confirmed removal, a separate completion receipt and SQL preservation of old rows/unrelated tables, then restore the receipt from privacy history after normal relaunch; not reached in this run |
| Settings | Persist Reduce Motion and observe it after normal close/relaunch; scan-location/exclusion actions enter real editors. New assertions have not run natively |
| Fault/recovery | Generated ordinary file conflicts with data-directory location; structured consumed UI exception, unchanged bytes, recovery with valid records |
| Integrity/log health | Generated payload hashes remain intact, no unexpected failures or dropped logs, exact payload hashes |

These are source cases until executed and reviewed on Windows. The generated cleanup journey uses only its own temporary target; MSI uninstall and task control keep their separate explicit opt-in scripts in [Windows development](windows.md). Unexecuted storage/large-file/privacy source cases are not passes. Real application-uninstall/task-switch UI mutation is not yet covered. Actual UI execution interruption, language switching, all filters/pagination, full keyboard/accessibility, DPI/light/dark/high contrast, ARM64, signing/install/update and per-page Mac 1:1 comparisons require independent evidence.

Failure-tree evidence includes app/root/element process IDs, native handles, class names, frameworks and supported automation patterns to diagnose native-picker ownership and permission differences. Observation failures are retained explicitly.

## Evidence

```powershell
./scripts/windows/collect-diagnostics.ps1 -OutputRoot "C:\ShouBuild\evidence" `
  -TestResultsRoot "C:\ShouBuild\tests\results" `
  -PublishRoot "C:\ShouBuild\win-x64\publish"
```

The manifest preserves summary counters and individual `UnitTestResult.outcome` counts in `result_counts`; xUnit can report summary `notExecuted=0` while actual results are `NotExecuted`. Report those skips explicitly. It also includes logs, architecture, disk space, missing evidence and payload SHA256. Namespaced TRX counters are read through XML attributes rather than treating an empty object as a pass. E2E also produces `verification.json`, screenshots and command receipts. Screenshots/UI trees may include visible application names/paths; retain them privately and review before sharing. Collection success is not acceptance. Export before applying the user's latest stop/retain or release choice.
