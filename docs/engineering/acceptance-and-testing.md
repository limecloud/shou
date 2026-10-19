# Acceptance and testing

English | [简体中文](../zh-CN/engineering/acceptance-and-testing.md)

Status: runtime verification pending. This document is a plan, not a test report.

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
| S15 | Partial or cancelled scan | No executable plan |
| S16 | Known dependency symlinks point outside | Process links only; preserve outside content and identity |

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
