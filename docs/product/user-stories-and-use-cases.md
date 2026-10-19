# User stories and use cases

English | [简体中文](../zh-CN/product/user-stories-and-use-cases.md)

Status: design draft. Requirement identifiers refer to the [PRD](prd.md).

## User stories

| ID | Story | Acceptance | Requirements |
| --- | --- | --- | --- |
| US01 | Find the projects consuming limited storage | Project ranking, unclassified directories, explicit measurement basis | F01–F02 |
| US02 | Clear inactive artifacts while preserving current work | Project evidence, retention, exclusions, preview | F04, F09, F12 |
| US03 | Define rules for personal tools without waiting for a release | Create, validate, and enable within the existing format | F03 |
| US04 | Ask an existing agent to draft a rule and inspect its effect | Disabled draft, actionable validation, exact preview | F03, F05, F11 |
| US05 | Understand why a directory is eligible and what rebuilding costs | Evidence, prerequisites, risks, and unknowns | F05–F06 |
| US06 | Reuse reviewed selection logic | Preset, fresh scan, new confirmation | F06, F10 |
| US07 | Actually regain available space | Explain Trash; separately confirm permanent batch removal | F07–F08 |
| US08 | Restore an item still present in Trash | Verify identity, avoid overwrite, explain unavailable recovery | F10 |
| US09 | Share rules without personal paths | Export no absolute bindings or access credentials | F03 |
| US10 | Complete tasks with keyboard and assistive technology | Focus, shortcuts, VoiceOver, non-color status indicators | F01–F10 |
| US11 | Complete cleanup entirely in the terminal | Independent management, scanning, execution, history, recovery | F01–F11 |
| US16 | Understand risks in a supported language | Localized human text, invariant machine results and decisions | F19 |

US12–US15 are defined with [developer workspace scenarios](developer-space-scenarios.md).

## UC01: Discover project storage

**Actors:** user, desktop application, system permission panel, scanner.

**Preconditions:** no workspace has been added.

1. Select a development directory through the system panel.
2. Inspect access scope and exclusions without granting whole-disk access by default.
3. Start a cancellable scan.
4. Inspect project/directory usage, distinguishing rule matches from unclassified data.
5. Read path, size basis, project markers, and evidence.
6. Exclude an unfamiliar directory or start a personal-rule draft.

**Exceptions:** show unreadable ranges as partial, disappearance as a skip/error rather than zero bytes, and links without following them. Space exploration uses full scope; cleanup snapshots explain their sparse coverage. An incomplete candidate cannot enter a plan, while an independently complete, policy-valid sibling may. Missing legacy coverage never grants eligibility.

**Outcome:** a read-only storage view; no target moved or removed.

## UC02: Review inactive Rust artifacts

**Actors:** developer, rule engine, scan/planning services.

**Preconditions:** an authorized workspace contains Rust projects.

1. Inspect the `target` template and rebuild/offline limitations.
2. Set retention, minimum size, and current-project exclusions.
3. Match `target` with parent `Cargo.toml` evidence.
4. Review concrete paths, conditions, estimates, and risks.
5. Select targets, create a plan, and confirm moving to Trash.
6. Revalidate objects; detected activity or changed state blocks or skips them.
7. Inspect item outcomes and optionally save selection logic as a preset.

**Exceptions:** custom `CARGO_TARGET_DIR` needs separate review. Hand-saved files are not proven rebuildable. Incomplete age evidence fails eligibility. No detected activity is not proof of inactivity.

**Outcome:** only confirmed, revalidated targets are processed; source remains outside the reviewed scope.

## UC03: Add a personal-tool rule

**Actors:** tool author, rule editor, validator, scanner.

**Preconditions:** the user understands the directory purpose.

1. Start rule creation from an unclassified directory.
2. Describe producer, purpose, rebuild prerequisites, and content to preserve.
3. Bind an existing workspace and precise relative pattern.
4. Set retention, minimum size, and exclusions.
5. Validate structure, boundaries, risks, and budgets.
6. Inspect matches and reasons for non-matches.
7. Save and explicitly enable after review.

Advanced users may paste generated JSON through the same validator. Unknown purpose remains a disabled draft; protected targets are blocked. Required custom cleanup commands are unsupported in the script-free initial format.

**Outcome:** an independently stored rule; no cleanup starts automatically.

## UC04: Add a rule through an existing agent

**Actors:** user, existing coding agent, CLI, optional desktop UI.

1. Provide an inspected directory summary or description to the external tool.
2. The agent drafts declarative JSON, not a deletion script.
3. Validate through CLI and inspect machine errors.
4. Import a disabled draft and preview within actual CLI permissions.
5. Review and decide whether to enable; then rescan and create a concrete plan.
6. Confirm in either the terminal or desktop interface.

Reject script fields, out-of-scope paths, and unknown fields. Missing CLI access is not replaced with assumed GUI access. Instruction-like filenames are untrusted data.

**Outcome:** external assistance with drafting; user authorization and engine policy still govern execution.

## UC05: Reuse a daily preset

Select a preset → inspect rule versions/bindings → rescan current state → inspect differences → explicitly select targets → confirm → inspect receipt.

A changed rule, root, exclusion, or stale plan requires a new preview. Presets store logic, not reusable deletion permission.

## UC06: Regain space on a full disk

**Preconditions:** verified items have been moved to Trash and have durable receipts.

Explain that a same-volume move usually does not free space. The user selects this batch, separately confirms irreversible removal, and the engine verifies each recorded object before processing. Report processed estimates separately from observed volume availability.

If intent cannot be persisted, do not start. Missing, moved, or replaced objects are skipped. Snapshots, clones, open files, and concurrent activity may reduce or distort apparent space recovery.

## UC07: Restore or resolve a failure

Select a restorable receipt → verify the object → inspect original destination → restore only if available. If occupied, choose a different verified location or cancel; never overwrite.

Permanent removal, external Trash emptying, missing objects, or permission changes may make restoration unavailable. Batch execution is not a transactional rollback facility.

## UC08: Work entirely in the terminal

**Preconditions:** installed CLI and actual target access.

Register a workspace, configure exclusions, import/review/enable rules, scan, query results, select candidate IDs, create and inspect a plan, run interactive execution, then query history or separately confirm recovery/permanent removal.

No desktop process is required. No TTY means destructive execution is refused. No automatic elevation or reuse of stale confirmation. GUI and CLI may have different system permissions.

## UC09: Separate Node.js dependencies and outputs

Inspect project composition; distinguish installed dependencies, caches, and deliverables. Draft separate rules with explicit reinstall/rebuild conditions. Treat whole dependencies as high-risk and review offline/private-package/local-change limitations.

Preserve current projects, source, and needed deliverables. Build a deduplicated plan and confirm. Do not infer disposability from `dist`, treat all package managers as ordinary npm, follow dependency links, or process unverifiable types.

**Outcome:** reusable rules and presets, with a fresh scan next time. Shou runs no automatic reinstall or build commands.
