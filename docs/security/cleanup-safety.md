# Cleanup safety and data boundaries

English | [简体中文](../zh-CN/security/cleanup-safety.md)

Status: design draft. These are required constraints, not implemented guarantees.

## 1. Assets and trust

Protect source, uncommitted changes, credentials, persistent business data, deliverables, and the ability to continue working under disk pressure.

Imported/generated rules, filenames, directory layouts, project text and writable local plans are untrusted. A declaration of rebuildability is not proof. Next-stage built-in cleanup AI uses user-selected models and bounded investigation tools; external agents retain CLI access to the same core. Model suggestions authorize neither enablement nor deletion, and investigation tools cannot delete. Both routes follow the same rules, protection, current confirmation and execution checks. The first SDK-backed investigation uses only scoped saved metadata; see [implementation and limits](../engineering/embedded-ai-implementation.md).

The next [AI product contract](../product/embedded-ai.md) adds default-off desktop gating and Jev-first routing. Disabling blocks new desktop requests without retracting sent data, revoking keys or disabling independent CLI calls. Low cost/confidence never expands authority. Main-model escalation stays within disclosed destinations/scope; failures never silently forward evidence. Gating/routing/acceptance remain implementation work; see [architecture/sequences](../architecture/embedded-ai.md).

## 2. Threat model

| Risk | Control | Remaining limitation |
| --- | --- | --- |
| Overbroad or incorrect rules | Schema, scope validation, protection, concrete preview | Users can misclassify business purpose |
| Link/volume escape | No ancestor following, verified entry types, no cross-volume traversal | Platform behavior requires testing |
| Target replacement after scanning | Identity, full manifests, near-operation checks | Checks alone cannot eliminate all races |
| Active work | Exclusions, activity evidence, retention, revalidation | Not all processes/use can be detected |
| Executable rule content | No scripts or Shell expansion | Commands run outside Shou are uncontrolled |
| Prompt/terminal injection | Escape output; project content cannot change tool/path scope; locally validate model arguments | Models may still misinterpret purpose; external agents also follow their own authorization policies |
| Excessive investigation transmission | Explicit enablement and provider/scope disclosure; targeted reads, relative paths, field/content budgets; exclude full indexes, personal content and credentials by default | Paths/configuration fragments can still contain private information |
| Credential leakage or context forwarding | System credential stores, redacted logs, synthetic connection tests, no silent forwarding across providers | Explain each selected provider's retention policy separately |
| Destructive retries | Unique plans, receipts, state queries | Crash outcomes may be unknown |
| Misleading space accounting | Separate estimates, Trash, volume availability | Clones/snapshots/concurrency complicate attribution |
| Full disk or corrupt journals | Persist intent first; stop on failure | No universal atomic recovery guarantee |

User-scoped checks are not isolation from an equally privileged malicious local process.

## 3. Access

Scan explicit workspaces rather than expand to home roots, other users, or volumes. Registration is not OS authorization. Check GUI, terminal, TCC, ACL, and actual process access independently. macOS administrator application and system-startup operations use a process-bound consent worker, without installing a persistent privileged service. Full Disk Access remains a separate System Settings authorization.

Executable scope initially excludes unsupported/network/cloud-placeholder filesystems. Rules cannot remove exclusions, enable link following, or enlarge roots.

### Read-worker boundary

The desktop delegates root identity and bounded traversal to short-lived instances of its packaged CLI. This internal entry performs reads only, opens no record store and cannot plan, confirm, move, restore or purge. It has the current user's privileges; it grants no extra filesystem access and does not bypass TCC. Platform access must still be verified for the packaged processes.

Temporary IPC uses a `0700` directory and `0600` files. Readers require current-user regular files with one link, reject symlink following and enforce size limits. Request/result version and request identity, the requesting parent, progress bounds and snapshot paths/coverage are validated. Invalid, foreign, incomplete or unavailable results fail closed; progress is never authorization.

Cancellation/timeout terminates only the owned read child, without waiting for kernel exit. A two-live-child cap and parent/deadline watchdog prevent unbounded accumulation; they cannot force an outstanding kernel call to finish immediately. This is a responsiveness boundary, not protection from an equally privileged malicious process. Confirmed mutations remain in the parent with live native verification. Automated cancellation/timeout and live-child-cap checks passed; the packaged desktop also passed stopping at the previously stalled scan location. These results do not establish behavior for every blocked kernel call; see [acceptance](../engineering/acceptance-and-testing.md).

## 4. Protection

Block workspace/home/volume roots, system locations, other-user data, out-of-scope targets, root/ancestor links, and unknown link types. Protect identified version metadata, keys/credentials, keychains, Shou configuration/receipts, user source/project roots and their manifests/lockfiles, persistent databases, and container/VM disks.

Space Analysis permits explicit cleanup of direct, single-link regular `.sqlite` indexes under Shou's `storage-catalogs`, including the current index and indexes referenced by old plans. This narrow exception for rebuildable data does not expose record directories, configuration, credentials or execution/recovery journals. A freshly measured complete manifest enters the existing confirmation and live verification; dependent analyses and plans require a new scan after index removal, while independent history and recovery evidence remain. Windows disk indexes are not implemented, so this exception does not open Windows record protection.

A parent containing protected/excluded descendants is blocked as a whole. Changed access, identity, manifests, rules, or exclusions invalidate eligibility.

No classifier can recognize all source, hand-saved artifacts, databases, or offline dependencies. Naming and size are clues, not permission. Clean Git state and old access/modification times do not prove recoverability.

Distinguish user project manifests from third-party dependency manifests without blindly exempting entire dependency trees. Reviewed ordinary `node_modules` remains high-risk. Unknown ownership or persistent content blocks processing.

Known internal POSIX symlinks such as npm `.bin` are opaque entries. Do not traverse their targets. Moving the containing directory moves links; permanent removal unlinks them only. Outside objects remain untouched. Unknown Windows reparse types require separate support.

## 5. Plans and confirmation

- Windows read-only discovery can admit SYSTEM/Administrators-provisioned bundled cache roots only after current-user Known Folder, pinned identity and per-directory ACL checks. It never takes ownership or repairs permissions. Candidates from these roots must carry `scan_root_read_only` and cannot become cleanup plans. Custom roots, project collections and mutation ownership requirements remain strict; see [unified cleanup](../product/unified-cleanup.md#windows-scanning-and-review).
Discovery prioritizes literal rule components and project markers without expanding the total budget or target scope. Plan preparation spends expensive policy checks only on explicitly selected paths, retaining all context and outer-match precedence. Changed live safety facts reject the old selection with its path and reasons, rather than being mislabeled as corrupt rule evidence.

macOS Smart Cleanup also permits explicit manual review of matched directories outside automatic eligibility. This reuses Space Analysis direct-removal planning and its current owner, exclusion, protected-location, identity and complete-manifest checks. Such selections are never recommended. The list explains that selecting an entire directory is a user decision, not rule-verified rebuildability. Clicking deletion freezes those directories; preparation performs no deletion, and changes after plan creation remain blocked. Active-process and source-content rule reasons remain visible but do not themselves prohibit this explicit direct-removal choice. Draft previews and stale root/configuration bindings cannot enter this path.

Read-only scans may persist evidence without moving targets. An incomplete target is never executable. A partial scan may retain independently complete, policy-valid siblings; plans require positive subtree coverage and unchanged full manifests for every selected target. Legacy partial records without coverage do not gain eligibility. Cleanup-mode discovery completion is not proof of whole-tree measurement. Plans bind exact paths, identity, full manifests, rules, configuration, action, digest, and expiry; resolve duplicates and parent/child conflicts first.

Changing selection or configuration invalidates old confirmation. Local files require verification; persisted `approved=true` is never authority.

GUI confirms exact scope and consequences in its native interface. Smart Cleanup, Projects, application components, Space Analysis and Large Files review scope through checked list/map entries, show count and size estimates in the action bar, and explain irreversibility in the deletion button hints; clicking the explicit deletion button confirms and freezes those paths and that action before validation and execution, without a second dialog. Uninstall retains component/personal-data consent. Windows requires inline review of installation identity and installer-data impact before the click; Core still issues short-lived, single-use consent for that exact plan and public mutation gates remain unchanged. CLI requires a controlling terminal and explicit current-plan confirmation. Disabled import, enabled rules, and presets carry no standing deletion permission. TTY does not authenticate a human; external agents still follow their own policies. A “GUI-only” label is not a security boundary.

Application-cache rows marked `application_running` are unselectable in Smart Cleanup until the app exits and a fresh scan renews the evidence. Closing an application never grants deletion authority.

## 6. Execution and race gate

Acquire a cross-process lock; verify scope, configuration, root/object identity, manifests, and access. Recheck near each operation and refuse unverifiable changes. Persist intent first, record actual result identities/locations, and stop new work on journal failure. Unknown outcomes require reconciliation, not blind retry.

Persist the per-item `moving` boundary before calling Trash and the per-item `purging` boundary before permanent removal. A pre-call journal failure prevents that call; a post-call write failure leaves a started, unfinished record. Native Trash errors are known failures only when the original manifest can still be reproduced; otherwise record an unknown outcome. Permanent execution uses the original path and the immutable manifest, never a recursive path fallback. History inspection obtains the same mutation lease and reads only exact saved locations. It cannot infer an unrecorded system Trash destination or authorize retries, and never enumerates unrelated Trash contents. Pending follow-up intents remain blocked even if later observations suggest restoration completed.

Prototype the interaction between `FileManager.trashItem`, descriptors, identity binding, and directory replacement. If constraints cannot be met, narrow supported scenarios or ship read-only functionality. Permanent removal must stay bounded to verified manifest entries, never an unbounded recursive fallback.

Generated-source exceptions require an exact trusted bundled rule and native ownership/activity facts; imported rules cannot request them. Recognized Rust `OUT_DIR` and Swift generated products do not exempt nearby source checkouts, manifests, credentials or repositories. Cargo extracted sources additionally require an unchanged source inventory, verified checksums and matching retained local archive. Missing tools, active build processes, tracked content, modifications or unavailable evidence fail closed.

Windows now has an independent [Rust generated-source contract](../engineering/rule-coverage.md#windows-rust-artifacts). Layout identification is separate from current Git/activity facts; trusted rules grant no lasting permission. Planning, preflight and each mutation obtain fresh observations, retaining targets when index formats or native reads are unsupported. This source does not open public mutation gates or establish equivalent exceptions for other languages.

Execution stop is cooperative at safe item boundaries. Do not promise to interrupt a single in-progress system Trash call. Reconcile that call, retain completed results and mark remaining items accurately; a stop request is not a rollback.

Read/preflight work remains cancellable. After a Trash or restore intent is persisted, native path and manifest checks finish the current item without inheriting scan-worker cancellation; identity, no-follow, ownership, budgets and no-overwrite checks remain enforced. No next item starts after cancellation, and an unstarted restore has no follow-up intent. Permanent removal can stop between descendants: an interrupted item is failed/partial, not successfully removed. Individual permission or ordinary I/O removal failures within a verified manifest do not block other entries or later selected targets; unfinished directories remain, with partial results and bounded failure paths recorded. Identity changes and link replacement stop the affected item while independent items continue. Unknown outcomes, invalid root scope, cancelled authorization and journal failure stop further work. Desktop quit/close waits for execution and retains the window on errors or unknown outcomes; it never grants recovery authority or retries unfinished intents.

An operation-local evidence context avoids redundant policy/index work, never future revalidation. A native adapter may explicitly own the last complete manifest comparison; adapters without that capability retain Core's full check. Native deletion still rejects unplanned descendants and replaced roots/ancestors, checks every unlink, and records durable intent before mutation. Permanent pre-removal manifest reads remain cancellable. Immutable page digests, exact counts and parent-bound keys are checked before confirmation/execution; incomplete publication grants no authority. This boundary also applies to uninstall components and orphan cleanup, without replacing owner, absence, exclusion or activity checks.

## 7. Trash, permanent removal, restoration

Desktop cache/project cleanup and space-analysis removal default to permanent deletion with one exact-scope irreversible confirmation. System Trash is an explicit recoverable alternative, recording actual returned locations rather than guessing names. CLI defaults remain compatible; `--mode permanent` requests direct deletion. If Trash fails, do not fall back to deletion. A same-volume move usually does not free storage.

Permanent removal of a cleanup plan is a first-class `action=permanent` execution, separate, explicitly confirmed, and irreversible. Reverify the current configuration, activity, object identity and full manifest before each bound item. Skip or fail missing, replaced, expanded or unverifiable items and record `operation=permanent_cleanup`, `purging` and `purged`; never empty unrelated Trash contents.

Report permanently removed estimates and observed volume availability separately. APFS clones, hard links, snapshots, open files, and other processes affect outcomes; an estimate is not a promise of newly available bytes.

Before restoration verify source identity, destination, and permissions; never overwrite. Offer another verified location or cancellation. External Trash emptying, permanent removal, missing objects, and access changes can make recovery unavailable. Batch cleanup is not transactional rollback.

For a recorded Trash directory only, follow-up verification may ignore its top-level `ctime` change caused by asynchronous macOS metadata updates. The root identity and every other recorded root field must match, and the full descendant manifest must remain identical. Changed contents, new descendants, replacement objects and other metadata changes still block restoration or permanent removal. Ordinary scan and pre-Trash checks keep their original comparison.

## 8. Local records and privacy

No account is required; initial scope has no default telemetry or upload. Record necessary IDs, phases, errors, and paths, not secret/source/business content. Prefer relative/redacted exports and never expose access credentials.

Protect temporary and durable data with current-user permissions. Validate locking, atomic writes, durability, crashes, and full-disk behavior rather than assuming a successful write call is enough. Deleting history never removes user files.

## 9. Windows acceptance

The v0.15.0 restricted portable preview closes public GUI/CLI cleanup, uninstall, startup control and privacy/storage removal gates. Historical generated smart-cleanup UI confirmation/removal/history/replay checks passed; MSI source validation, the native picker and downstream journeys remain blocked and cannot be released as public mutation support. See [SYNC.md](../../SYNC.md).

Windows file-cleanup UI source composes the same Core current-confirmation and execution contract; GUI and CLI share a disabled native-acceptance gate. Normal closing requests stop and waits for the current task; forced termination cannot promise complete journaling. Actual outcomes returned after stop must remain visible. A missing readable result does not prove an absence of mutation and cannot restore execution eligibility or automatically replay a plan. State tests and C# reference compilation do not establish native confirmation, deletion or window-close acceptance.

Windows system uninstall and Shou file cleanup require separate authorization. Registry uninstall strings are never executable commands. Planning must revalidate exact MSI/MSIX identity against the reviewed digest and obtain separate acknowledgement of installer-managed data effects. That acknowledgement includes no extra residual files and is not current execution consent. Ordinary MSIX removal cannot promise data preservation and may remove unused dependencies. Review and expiring plans include bounded installation-directory activity observations; active or unknown results block planning. External components are outside this coverage, and an idle observation is not reusable execution authority. Execution source obtains current in-process consent, acquires the mutation lease, rechecks facts and persists intent before the system adapter rechecks actor/facts/deadline. Consent lasts at most one minute and can be consumed once; any existing intent blocks replay of that plan. Installer reports and installation observations remain separate; journal failure or unknown outcomes never prove no changes. System installers may stop managed apps/services and change data. Shou never kills MSI; MSIX only requests cooperative cancellation and awaits terminal status. WinUI confirmation defaults to Cancel; stopping still awaits the real outcome. Execution prevents leaving the applications page, and normal window closing requests stop while retaining the window. Forced termination can leave unfinished intent without establishing installer outcome. GUI and CLI share a disabled execution gate; native acceptance and restore remain pending. See [application uninstall boundaries](../product/application-uninstall.md#installation-identity-review-and-planning).

Independently validate ACLs, long/Unicode paths, case behavior, junctions/reparse points, mounted volumes, occupied files, Recycle Bin identities, restoration conflicts, locks/durability, runtime delivery, and clean installation.

Unavailable recycling returns a capability error, never permanent-delete fallback. macOS simulations and cross-compilation do not establish Windows safety.

## Startup discovery

Windows has a separate read-only startup path for ten registry/folder/scheduled-task/package-manifest sources. It never opens cleanup records, executes a registered command, resolves a shortcut or grants control permission. Raw registry data is bounded and reread; only an unambiguous executable clue enters Core, with arguments and environment values discarded. Directory metadata uses the native no-reparse adapter. Scheduled tasks use only current-identity local read-only COM, publish only boot/logon registrations and keep arguments/XML inside Platform. Manifest reads use bounded no-reparse handles and metadata rechecks; ordinary hard-linked manifests grant no mutation authority, while rule reads still reject multiple links. Packaged declarations requery registration and never derive effective state from manifest Enabled. Unknown budget consumption stops later sources. Enablement, process and orphan status remain unknown; excluded sources and incomplete coverage are explicit. Native fixture/UI checks remain pending. See the [Windows startup contract](../product/startup-items.md#windows-startup-contract).

Scheduled-task engine status is a separate read-only observation from public task properties. Double reads and path/XML rechecks constrain publication but do not provide an atomic snapshot. Status failure/change preserves the registration with an explicit gap; invalid enum/source claims are rejected at Core. No task is executed, enabled, disabled or registered, and task engine state does not infer startup trigger eligibility or application processes.

The first startup stage only reads fixed launchd definition directories; it cannot alter registration, terminate processes, enable services or delete files. Ancestor/leaf links and special files are rejected. File/source identity changes, permission failures, invalid definitions and entry/time limits remain visible in coverage; each file is limited to 256 KiB. Default budgets are 2,000 entries and five seconds, with cancellation between operations. Blocking kernel calls may outlast cooperative cancellation.

Only a printable absolute executable path is retained from Program or the first ProgramArguments element. Remaining arguments and environment values are not retained or returned. Current-user LaunchAgents may include bounded, point-in-time `launchctl` state observations; unavailable observations remain unknown and never authorize a mutation. Disabled in the plist remains a definition hint. Login Items, background registrations and embedded helpers require the native System Settings view. Discovery uses no cleanup store or new permissions. See [startup discovery](../product/startup-items.md).


## Application uninstall

Uninstall uses exact application identity and bundle-identifier associations rather than cache-rule exceptions. Personal data needs separate consent and explicit component selection. Known duplicate identifiers protect associated data; incomplete discovery warns and prevents automatic component selection. Shared group containers enter only after native metadata confirms the selected identifier; unverified containers, external registrations and orphan-only discovery remain outside this stage. System/current apps, current-account running executables/helpers, unknown activity, other-owned content, special files, protected storage and exclusions block processing. Shared-hard-link bundles permit whole-bundle Trash only with associated data kept; multiply linked associated components remain blocked.

The ordinary workspace-root policy is not relaxed for `/Applications`. Each receipt item validates its exact component-kind origin; application parents use a separate fixed installation-directory capability. Standalone files require bounded content evidence, at most 16 MiB. Shared durable intent, native Trash result verification and no-overwrite recovery apply to files and directories. Uninstall receipts permit restoration only; no new purge flow is introduced. Coverage, process limitations and cancellation behavior are specified in [application uninstall](../product/application-uninstall.md).


## Explicit space-analysis removal

Space analysis now supports local volume/folder discovery and direct explicit file/directory removal, independently of cleanup-rule workspaces. Desktop list and treemap share navigation and normalized selection. Current manifests and exclusions are checked before confirmation and execution. It reuses existing mutation journals and history. See [space analysis architecture, flow and sequence](../product/space-analysis.md).

Both desktops freeze selection and execute items in sequence without a whole-batch live-filesystem preflight. Desktop preparation may skip individual permission/ordinary I/O failures, disappeared targets, protected/excluded content or incomplete reads. Only independent selections with fully verified manifests enter the plan. Skipping grants no authority over an incomplete target or its unverified descendants; an entirely blocked selection creates no empty plan and does not fall back to splitting the directory. Invalid roots, cancellation, persistence failure and exhausted Windows shared budgets still abort. A replaced macOS target fails that item while independent items continue. Execution retains its unknown-outcome, identity and journal boundaries. Current results show skip reasons and disclose full paths on demand; strict CLI planning still refuses unavailable selections.

Windows startup discovery, task status and persisted review never authorize a task switch. In-memory review requires a current-user-owned boot/logon task with the literal current-user principal and explicit interactive/least-privilege declarations. Current-entry confirmation, leased reinspection and durable intent precede Enabled setting. Dispatch waits for the real result; uncertainty permits neither replay nor automatic rollback. The public gate remains disabled. The [startup contract](../product/startup-items.md#scheduled-task-switch-review-and-control) owns eligibility and race limits.

The Windows multi-location plan contract is owned by [daily cleanup](../product/unified-cleanup.md#windows-scanning-and-review). Every item binds an exact scan source; one digest covers all roots, rules and manifests, and current confirmation authorizes that plan once. Plan structure, scope, configuration, expiry and current confirmation are checked before batch intent; each source is freshly observed and its item is verified immediately before its own mutation. Known independent failures are recorded without suppressing other selected items. Once intent exists, the entire plan cannot replay. Filters and recommendations do not expand authority, and unknown outcomes stop later locations.

### Broken application shortcut exception

This exception permits only the shortcut whose target absence was verified. Ordinary workspace link rejection remains. macOS accepts terminal `.app` symlinks below fixed installation roots with exact metadata, readlink digest, parent identity, owner, exclusions/protection and target absence; its single-component permanent plan only unlinks. Windows independently reads fixed current-user shortcut sources, accepting statically verifiable local executable `.lnk` files while rejecting reparse points, hard links and targets requiring dynamic resolution. Denied access is never absence. Rechecked identity, byte digest and absence precede existing exact single-file permanent cleanup/history; public gates remain unchanged. Confirmation states shortcut-only scope and retained associated data. Damaged installers or metadata-missing bundles cannot be reclassified as shortcuts.
