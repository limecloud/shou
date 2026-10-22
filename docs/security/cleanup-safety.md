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

Scan explicit workspaces rather than expand to home roots, other users, or volumes. Registration is not OS authorization. Check GUI, terminal, TCC, ACL, and actual process access independently. Never auto-elevate through `sudo` or a privileged helper.

Executable scope initially excludes unsupported/network/cloud-placeholder filesystems. Rules cannot remove exclusions, enable link following, or enlarge roots.

### Read-worker boundary

The desktop delegates root identity and bounded traversal to short-lived instances of its packaged CLI. This internal entry performs reads only, opens no record store and cannot plan, confirm, move, restore or purge. It has the current user's privileges; it grants no extra filesystem access and does not bypass TCC. Platform access must still be verified for the packaged processes.

Temporary IPC uses a `0700` directory and `0600` files. Readers require current-user regular files with one link, reject symlink following and enforce size limits. Request/result version and request identity, the requesting parent, progress bounds and snapshot paths/coverage are validated. Invalid, foreign, incomplete or unavailable results fail closed; progress is never authorization.

Cancellation/timeout terminates only the owned read child, without waiting for kernel exit. A two-live-child cap and parent/deadline watchdog prevent unbounded accumulation; they cannot force an outstanding kernel call to finish immediately. This is a responsiveness boundary, not protection from an equally privileged malicious process. Confirmed mutations remain in the parent with live native verification. Automated cancellation/timeout and live-child-cap checks passed; the packaged desktop also passed stopping at the previously stalled scan location. These results do not establish behavior for every blocked kernel call; see [acceptance](../engineering/acceptance-and-testing.md).

## 4. Protection

Block workspace/home/volume roots, system locations, other-user data, out-of-scope targets, root/ancestor links, and unknown link types. Protect identified version metadata, keys/credentials, keychains, Shou configuration/receipts, user source/project roots and their manifests/lockfiles, persistent databases, and container/VM disks.

A parent containing protected/excluded descendants is blocked as a whole. Changed access, identity, manifests, rules, or exclusions invalidate eligibility.

No classifier can recognize all source, hand-saved artifacts, databases, or offline dependencies. Naming and size are clues, not permission. Clean Git state and old access/modification times do not prove recoverability.

Distinguish user project manifests from third-party dependency manifests without blindly exempting entire dependency trees. Reviewed ordinary `node_modules` remains high-risk. Unknown ownership or persistent content blocks processing.

Known internal POSIX symlinks such as npm `.bin` are opaque entries. Do not traverse their targets. Moving the containing directory moves links; permanent removal unlinks them only. Outside objects remain untouched. Unknown Windows reparse types require separate support.

## 5. Plans and confirmation

Read-only scans may persist evidence without moving targets. An incomplete target is never executable. A partial scan may retain independently complete, policy-valid siblings; plans require positive subtree coverage and unchanged full manifests for every selected target. Legacy partial records without coverage do not gain eligibility. Cleanup-mode discovery completion is not proof of whole-tree measurement. Plans bind exact paths, identity, full manifests, rules, configuration, action, digest, and expiry; resolve duplicates and parent/child conflicts first.

Changing selection or configuration invalidates old confirmation. Local files require verification; persisted `approved=true` is never authority.

GUI uses native confirmation; CLI requires a controlling terminal and explicit current-plan confirmation. Disabled import, enabled rules, and presets carry no standing deletion permission. TTY does not authenticate a human; external agents still follow their own policies. A “GUI-only” label is not a security boundary.

## 6. Execution and race gate

Acquire a cross-process lock; verify scope, configuration, root/object identity, manifests, and access. Recheck near each operation and refuse unverifiable changes. Persist intent first, record actual result identities/locations, and stop new work on journal failure. Unknown outcomes require reconciliation, not blind retry.

Persist the per-item `moving` boundary before calling Trash and the per-item `purging` boundary before permanent removal. A pre-call journal failure prevents that call; a post-call write failure leaves a started, unfinished record. Native Trash errors are known failures only when the original manifest can still be reproduced; otherwise record an unknown outcome. Permanent execution uses the original path and the immutable manifest, never a recursive path fallback. History inspection obtains the same mutation lease and reads only exact saved locations. It cannot infer an unrecorded system Trash destination or authorize retries, and never enumerates unrelated Trash contents. Pending follow-up intents remain blocked even if later observations suggest restoration completed.

Prototype the interaction between `FileManager.trashItem`, descriptors, identity binding, and directory replacement. If constraints cannot be met, narrow supported scenarios or ship read-only functionality. Permanent removal must stay bounded to verified manifest entries, never an unbounded recursive fallback.

Generated-source exceptions require an exact trusted bundled rule and native ownership/activity facts; imported rules cannot request them. Recognized Rust `OUT_DIR` and Swift generated products do not exempt nearby source checkouts, manifests, credentials or repositories. Cargo extracted sources additionally require an unchanged source inventory, verified checksums and matching retained local archive. Missing tools, active build processes, tracked content, modifications or unavailable evidence fail closed.

Execution stop is cooperative at safe item boundaries. Do not promise to interrupt a single in-progress system Trash call. Reconcile that call, retain completed results and mark remaining items accurately; a stop request is not a rollback.

Read/preflight work remains cancellable. After a Trash or restore intent is persisted, native path and manifest checks finish the current item without inheriting scan-worker cancellation; identity, no-follow, ownership, budgets and no-overwrite checks remain enforced. No next item starts after cancellation, and an unstarted restore has no follow-up intent. Permanent removal can stop between descendants: an interrupted item is failed/partial, not successfully removed. Desktop quit/close waits for execution and retains the window on errors or unknown outcomes; it never grants recovery authority or retries unfinished intents.

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

Independently validate ACLs, long/Unicode paths, case behavior, junctions/reparse points, mounted volumes, occupied files, Recycle Bin identities, restoration conflicts, locks/durability, runtime delivery, and clean installation.

Unavailable recycling returns a capability error, never permanent-delete fallback. macOS simulations and cross-compilation do not establish Windows safety.

## Startup discovery

The first startup stage only reads fixed launchd definition directories; it cannot alter registration, terminate processes, enable services or delete files. Ancestor/leaf links and special files are rejected. File/source identity changes, permission failures, invalid definitions and entry/time limits remain visible in coverage; each file is limited to 256 KiB. Default budgets are 2,000 entries and five seconds, with cancellation between operations. Blocking kernel calls may outlast cooperative cancellation.

Only a printable absolute executable path is retained from Program or the first ProgramArguments element. Remaining arguments and environment values are not retained or returned. Current-user LaunchAgents may include bounded, point-in-time `launchctl` state observations; unavailable observations remain unknown and never authorize a mutation. Disabled in the plist remains a definition hint. Login Items, background registrations and embedded helpers require the native System Settings view. Discovery uses no cleanup store or new permissions. See [startup discovery](../product/startup-items.md).


## Application uninstall

Uninstall uses exact application identity and bundle-identifier associations rather than cache-rule exceptions. Personal data needs separate consent and explicit component selection. Known duplicate identifiers protect associated data; incomplete discovery warns and prevents automatic component selection. Shared group containers enter only after native metadata confirms the selected identifier; unverified containers, external registrations and orphan-only discovery remain outside this stage. System/current apps, current-account running executables/helpers, unknown activity, other-owned content, special or multiply linked files, protected storage and exclusions block processing.

The ordinary workspace-root policy is not relaxed for `/Applications`. Each receipt item validates its exact component-kind origin; application parents use a separate fixed installation-directory capability. Standalone files require bounded content evidence, at most 16 MiB. Shared durable intent, native Trash result verification and no-overwrite recovery apply to files and directories. Uninstall receipts permit restoration only; no new purge flow is introduced. Coverage, process limitations and cancellation behavior are specified in [application uninstall](../product/application-uninstall.md).


## Explicit space-analysis removal

Space analysis now supports local volume/folder discovery and direct explicit file/directory removal, independently of cleanup-rule workspaces. Desktop list and treemap share navigation and normalized selection. Current manifests and exclusions are checked before confirmation and execution. It reuses existing mutation journals and history. See [space analysis architecture, flow and sequence](../product/space-analysis.md).
