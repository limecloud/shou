# Cleanup safety and data boundaries

English | [简体中文](../zh-CN/security/cleanup-safety.md)

Status: design draft. These are required constraints, not implemented guarantees.

## 1. Assets and trust

Protect source, uncommitted changes, credentials, persistent business data, deliverables, and the ability to continue working under disk pressure.

Imported/generated rules, filenames, directory layouts, project text, and writable local plans are untrusted. A declaration of rebuildability is not proof. Shou calls no models and hosts no agents; external callers use the same policy.

## 2. Threat model

| Risk | Control | Remaining limitation |
| --- | --- | --- |
| Overbroad or incorrect rules | Schema, scope validation, protection, concrete preview | Users can misclassify business purpose |
| Link/volume escape | No ancestor following, verified entry types, no cross-volume traversal | Platform behavior requires testing |
| Target replacement after scanning | Identity, full manifests, near-operation checks | Checks alone cannot eliminate all races |
| Active work | Exclusions, activity evidence, retention, revalidation | Not all processes/use can be detected |
| Executable rule content | No scripts or Shell expansion | Commands run outside Shou are uncontrolled |
| Prompt/terminal injection | Treat content as data; escape output | External agent permissions remain external |
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

Persist the per-item `moving` boundary before calling Trash. A pre-call journal failure prevents that call; a post-call write failure leaves a started, unfinished record. Native Trash errors are known failures only when the original manifest can still be reproduced; otherwise record an unknown outcome. History inspection obtains the same mutation lease and reads only exact saved locations. It cannot infer an unrecorded system Trash destination or authorize retries, and never enumerates unrelated Trash contents. Pending follow-up intents remain blocked even if later observations suggest restoration completed.

Prototype the interaction between `FileManager.trashItem`, descriptors, identity binding, and directory replacement. If constraints cannot be met, narrow supported scenarios or ship read-only functionality. Permanent removal must stay bounded to verified manifest entries, never an unbounded recursive fallback.

Generated-source exceptions require an exact trusted bundled rule and native ownership/activity facts; imported rules cannot request them. Recognized Rust `OUT_DIR` and Swift generated products do not exempt nearby source checkouts, manifests, credentials or repositories. Cargo extracted sources additionally require an unchanged source inventory, verified checksums and matching retained local archive. Missing tools, active build processes, tracked content, modifications or unavailable evidence fail closed.

Execution stop is cooperative at safe item boundaries. Do not promise to interrupt a single in-progress system Trash call. Reconcile that call, retain completed results and mark remaining items accurately; a stop request is not a rollback.

Read/preflight work remains cancellable. After a Trash or restore intent is persisted, native path and manifest checks finish the current item without inheriting scan-worker cancellation; identity, no-follow, ownership, budgets and no-overwrite checks remain enforced. No next item starts after cancellation, and an unstarted restore has no follow-up intent. Permanent removal can stop between descendants: an interrupted item is failed/partial, not successfully removed. Desktop quit/close waits for execution and retains the window on errors or unknown outcomes; it never grants recovery authority or retries unfinished intents.

## 7. Trash, permanent removal, restoration

Default to system Trash, recording actual returned locations rather than guessing names. If Trash fails, do not fall back to deletion. A same-volume move usually does not free storage.

Permanent removal of this cleanup batch is separate, explicitly confirmed, and irreversible. Reverify recorded objects/manifests; skip missing/replaced/expanded items. Never empty unrelated Trash contents.

Report estimated processed bytes and observed volume availability separately. APFS clones, hard links, snapshots, open files, and other processes affect outcomes.

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

Only a printable absolute executable path is retained from Program or the first ProgramArguments element. Remaining arguments and environment values are not retained or returned. Configured/runtime states stay unknown, and Disabled is only a definition hint. Login Items, background registrations and embedded helpers require the native System Settings view. Discovery uses no cleanup store or new permissions. See [startup discovery](../product/startup-items.md).


## Application uninstall

Uninstall uses exact application identity and bundle-identifier associations rather than cache-rule exceptions. Personal data needs separate consent and explicit component selection. Known duplicate identifiers protect associated data; incomplete discovery warns and prevents automatic component selection. Shared group containers, external registrations and orphan-only discovery are outside this stage. System/current apps, current-account running executables/helpers, unknown activity, other-owned content, special or multiply linked files, protected storage and exclusions block processing.

The ordinary workspace-root policy is not relaxed for `/Applications`. Each receipt item validates its exact component-kind origin; application parents use a separate fixed installation-directory capability. Standalone files require bounded content evidence, at most 16 MiB. Shared durable intent, native Trash result verification and no-overwrite recovery apply to files and directories. Uninstall receipts permit restoration only; no new purge flow is introduced. Coverage, process limitations and cancellation behavior are specified in [application uninstall](../product/application-uninstall.md).
