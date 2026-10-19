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

## 4. Protection

Block workspace/home/volume roots, system locations, other-user data, out-of-scope targets, root/ancestor links, and unknown link types. Protect identified version metadata, keys/credentials, keychains, Shou configuration/receipts, user source/project roots and their manifests/lockfiles, persistent databases, and container/VM disks.

A parent containing protected/excluded descendants is blocked as a whole. Changed access, identity, manifests, rules, or exclusions invalidate eligibility.

No classifier can recognize all source, hand-saved artifacts, databases, or offline dependencies. Naming and size are clues, not permission. Clean Git state and old access/modification times do not prove recoverability.

Distinguish user project manifests from third-party dependency manifests without blindly exempting entire dependency trees. Reviewed ordinary `node_modules` remains high-risk. Unknown ownership or persistent content blocks processing.

Known internal POSIX symlinks such as npm `.bin` are opaque entries. Do not traverse their targets. Moving the containing directory moves links; permanent removal unlinks them only. Outside objects remain untouched. Unknown Windows reparse types require separate support.

## 5. Plans and confirmation

Read-only scans may persist evidence without moving targets. Partial/cancelled/limited scans are not executable. Plans bind exact paths, identity, full manifests, rules, configuration, action, digest, and expiry; resolve duplicates and parent/child conflicts first.

Changing selection or configuration invalidates old confirmation. Local files require verification; persisted `approved=true` is never authority.

GUI uses native confirmation; CLI requires a controlling terminal and explicit current-plan confirmation. Disabled import, enabled rules, and presets carry no standing deletion permission. TTY does not authenticate a human; external agents still follow their own policies. A “GUI-only” label is not a security boundary.

## 6. Execution and race gate

Acquire a cross-process lock; verify scope, configuration, root/object identity, manifests, and access. Recheck near each operation and refuse unverifiable changes. Persist intent first, record actual result identities/locations, and stop new work on journal failure. Unknown outcomes require reconciliation, not blind retry.

Prototype the interaction between `FileManager.trashItem`, descriptors, identity binding, and directory replacement. If constraints cannot be met, narrow supported scenarios or ship read-only functionality. Permanent removal must stay bounded to verified manifest entries, never an unbounded recursive fallback.

## 7. Trash, permanent removal, restoration

Default to system Trash, recording actual returned locations rather than guessing names. If Trash fails, do not fall back to deletion. A same-volume move usually does not free storage.

Permanent removal of this cleanup batch is separate, explicitly confirmed, and irreversible. Reverify recorded objects/manifests; skip missing/replaced/expanded items. Never empty unrelated Trash contents.

Report estimated processed bytes and observed volume availability separately. APFS clones, hard links, snapshots, open files, and other processes affect outcomes.

Before restoration verify source identity, destination, and permissions; never overwrite. Offer another verified location or cancellation. External Trash emptying, permanent removal, missing objects, and access changes can make recovery unavailable. Batch cleanup is not transactional rollback.

## 8. Local records and privacy

No account is required; initial scope has no default telemetry or upload. Record necessary IDs, phases, errors, and paths, not secret/source/business content. Prefer relative/redacted exports and never expose access credentials.

Protect temporary and durable data with current-user permissions. Validate locking, atomic writes, durability, crashes, and full-disk behavior rather than assuming a successful write call is enough. Deleting history never removes user files.

## 9. Windows acceptance

Independently validate ACLs, long/Unicode paths, case behavior, junctions/reparse points, mounted volumes, occupied files, Recycle Bin identities, restoration conflicts, locks/durability, runtime delivery, and clean installation.

Unavailable recycling returns a capability error, never permanent-delete fallback. macOS simulations and cross-compilation do not establish Windows safety.
