# Product requirements

English | [简体中文](../zh-CN/product/prd.md)

Current desktop navigation and automatic discovery follow [Unified daily cleanup](../product/unified-cleanup.md).

Status: active product contract · Version: 0.1 · Updated: 2026-10-20.

## 1. Product definition

**Shou · 收拾一下** is a native macOS cleanup tool built with Swift, centered on cleanup rules tailored by an existing coding agent. Users describe their needs and answer focused questions; the agent investigates and writes reusable rules, and Shou validates, previews, and executes them locally.

**Tidy up. That’s it. / 收好，就好。**

The primary audience is developers maintaining multiple projects on limited-capacity computers. macOS ships first; Windows is a future native platform target. A portable core and explicit platform adapters are required from the outset.

## 2. Background

### Developer workspace storage

On a 500 GB Mac, project caches, installed dependencies, and build outputs can exhaust storage repeatedly. Rust `target` directories may reach tens of gigabytes; Node.js dependencies and frontend or Electron outputs can each occupy gigabytes.

Toolchains and layouts differ. A directory called `dist`, `build`, or `cache` may contain reproducible artifacts, a unique deliverable, or persistent data. Rebuilding depends on source, tooling, network access, private registries, and local modifications. Large-directory discovery alone does not resolve these decisions.

Fixed catalogs cannot capture every personal tool or project layout. Repeated manual commands are difficult to review, reuse, and audit. See [developer scenarios](developer-space-scenarios.md).

### Existing-agent workflows

Codex, Claude Code, WorkBuddy, and similar existing products can help describe directories and draft rules, but need stable contracts for discovery, validation, previews, and state queries.

Shou supplies that deterministic local interface. It integrates no models and develops, launches, or hosts no agents. External products own inference, authentication, conversations, and tool authorization.

## 3. Objectives and benefits

| Objective | User benefit | Evidence |
| --- | --- | --- |
| Reduce repeated investigation | Reuse reviewed project cleanup decisions | A saved preset produces a fresh inspectable plan |
| Cover personal layouts | Add rules without changing application code | Import and preview a custom rule |
| Explain eligibility | Understand scope, rebuild costs, and unknowns | Every candidate exposes evidence and limitations |
| Support existing agents | Add rule drafts through structured operations | Discovery, validation, import, and preview work through CLI |
| Keep execution controlled | Know exactly what will be processed | Confirmation binds a concrete plan and current object state |
| Support both workflows | Stay in either the desktop app or terminal | Each independently completes the core task |
| Reach global users | Understand instructions and risks in supported languages | Localized text with invariant machine contracts |

No fixed reclaimed-space amount or speedup percentage is promised.

## 4. Users and core job

Primary users are multi-project developers, authors of personal tools, and developers who already work with coding agents. General Mac users and teams sharing templates follow later; enterprise device management is outside the initial scope.

Core job: when storage runs low, find meaningful project-level opportunities, save reviewed selection logic, and inspect a fresh cleanup plan without repeating the entire investigation.

## 5. Principles

1. Separate intent, evidence, plans, confirmation, and filesystem operations.
2. Rules cannot override engine protection or operating-system permissions.
3. Size and naming do not prove disposability.
4. Built-in, handwritten, and agent-generated rules follow the same validation path.
5. GUI users need neither JSON editing nor a model account.
6. Scans are cancellable; the desktop quick-clean path hides internal planning steps while keeping one native confirmation. Unattended destructive execution is outside the initial scope.
7. CLI is independent, not a desktop launcher.
8. Native interfaces share contracts while following platform conventions.

## 6. Requirements

P0 is required for the initial usable release; P1 extends the validated loop; P2 is a later platform or product direction.

| ID | Capability | Priority | Minimum acceptance |
| --- | --- | --- | --- |
| F01 | Workspace access | P0 | Explicit selection/registration, access state, removal |
| F02 | Project analysis | P0 | Large directories by project/type; consistent tables and treemap data; completeness |
| F03 | Personal rules | P0 | Create, import, edit, validate, enable, disable, export |
| F04 | Deterministic matching | P0 | Roots, relative patterns, project markers, age, size, exclusions |
| F05 | Explainable candidates | P0 | Paths, evidence, versions, risks, size basis, unknowns |
| F06 | Plans and previews | P0 | Explicit selection, deduplication, fixed scope and rule/configuration digests |
| F07 | Confirmed execution | P0 | Choose Trash or permanent action, revalidate identities/manifests, and record item outcomes |
| F08 | Immediate space recovery | P0 | Separately confirm permanent removal of a verified cleanup batch, whether directly from a plan or later from recorded Trash items |
| F09 | Protection and exclusions | P0 | Global/workspace/project exclusions; explain blocked targets |
| F10 | Presets and history | P0 | Fresh scans, receipts, and verified recovery where available |
| F11 | Independent CLI and agent contract | P0 | Workspace/rule management, scan, plan, interactive execution, history, JSON |
| F12 | Developer templates and personal outputs | P0 | Rust artifacts, specific Node.js caches, reviewed npm dependencies, personal outputs |
| F13 | Broader cache templates | P1 | Evidence, platform constraints, risks, regression fixtures |
| F14 | Uninstall and associated files | P1 | [macOS first stage](application-uninstall.md): exact associations, verified shared group containers, separate personal-data consent, duplicate-identifier protection, native Trash and per-component restoration; orphan-only discovery and external registrations remain pending |
| F15 | Startup management | P1 | First-stage launchd discovery and restricted current-user LaunchAgent enable/disable with native settings guidance implemented; system sources, complete registration inventory and runtime control require separate acceptance |
| F16 | Sharing and additional protocols | P2 | Strip local information; add protocols only for demonstrated integration needs |
| F17 | Monorepo and platform boundaries | P0 | Shared core excludes Apple/Windows-specific APIs |
| F18 | Native Windows and CLI | P2 | Actual Windows build/runtime, paths, ACLs, links, Recycle Bin, distribution |
| F19 | Internationalization | P0 | English default docs, multilingual READMEs, initial English/Simplified Chinese UI and CLI targets |

### Exclusions

No mandatory account, cloud scanning, default telemetry, executable rule scripts, root cleanup, SIP bypass, memory cleaning, automatic global Trash emptying, or unattended permanent deletion. No direct generic deletion of database, container, or virtual-machine storage. No name-based automatic selection of `node_modules`, `dist`, Downloads, or entire workspaces.

**Long-term boundary:** no model integration, agent development, chat assistant, or model orchestration platform.

## 7. Functional behavior

### Discovery and personal rules

Scan selected workspaces, not the entire home directory by default. Show unclassified large directories even without a matching rule. Permission failures, cancellation, limits, and incomplete statistics remain visible.

Merge multiple matches for the same object and resolve parent/child conflicts before counting or executing. **Rules → Customize with AI** hands the shipped Skill, local CLI path and workspace to the user's existing agent. The Skill guides questions about purpose, rebuild steps, active projects, retention and keep paths, then drives validation, disabled import and preview. The wizard and manual import remain under Advanced. Shareable rules contain logical roots rather than personal absolute paths. New or changed rules remain drafts until reviewed; new engine predicates or native adapters still require upgrades.

### Cleanup and recovery

The desktop common-app flow scans explicit fixed locations once, preselects verified built-in matches, and exposes **Clean & Free Space** as the primary action. Users can open **Review Details** to adjust categories and paths; personal rules participate after one-time enablement. The immutable plan, manifest, and preflight checks remain inside the action so the interface does not force every user through a planning screen. A reusable preset saves selection logic, never deletion permission. CLI and agent workflows retain explicit scan, plan, and execute checkpoints.

Desktop cleanup defaults to permanent removal after one exact-scope irreversible confirmation. Move to Trash is an explicit alternative and does not reclaim space; history follow-up can also permanently remove verified Trash items. Restoration remains a separate confirmed operation and never overwrites destinations. Missing, changed, or permanently removed items may be unrecoverable. Never equate trashed bytes with available disk space.

### Existing agents

Noninteractive calls may discover capabilities, query data, validate/import disabled rule drafts, and preview. Destructive CLI execution requires explicit interactive confirmation; there is no `--yes` or `--force` bypass in the initial scope. Project text and model output remain untrusted data. Shou uploads nothing automatically.

## 8. Experience and internationalization

Use native windows, sidebars, tables, inspectors, file panels, menus, keyboard behavior, and accessibility. Support light/dark appearance and supported language preferences. Explain actions with concrete labels rather than vague optimization claims.

English and Simplified Chinese are initial runtime targets. Additional runtime languages require reviewed resources and interaction tests; translated READMEs do not establish runtime support. See [macOS experience](macos-experience.md) and [internationalization](internationalization.md).

## 9. Measures, risks, and validation

Evaluate first-task completion, reduced steps on repeat tasks, rule expressiveness for real needs, user understanding of eligibility, safety-case outcomes, and fixed-fixture performance. Use consented studies and local benchmarks rather than default telemetry. Isolated core, filesystem and CLI checks exist; release and broader usability acceptance remain pending.

Key risks are incorrect directory classification, misleading capacity estimates, active builds, different CLI/GUI permissions, filesystem races, and template maintenance cost. Address them through conservative scope, explicit unknowns, revalidation, platform prototypes, and evidence-based release gates.

See [implementation](../engineering/implementation-plan.md), [acceptance](../engineering/acceptance-and-testing.md), and [safety](../security/cleanup-safety.md).

## First-use delivery requirement

The first scan of a selected workspace must discover common build artifacts and caches through built-in rules. Personal rules extend coverage. Provide separate categorized cleanup and space-analysis entry points, navigable directory lists and area maps, and direct drafting of rules for unknown large folders. Start with no selected candidates, keep installed Node.js dependencies high risk, and preserve protection gates for built-in matches.

The default desktop entry scans explicit application/developer-cache locations and automatically discovered and remembered projects in one action, using cleanup scope without implicit home-wide discovery. After the scan, verified built-in matches are selected for **Clean Recommended**; enabled personal rules participate automatically; disabled drafts stay out. The catalog contains 74 templates and 35 fixed locations, including project outputs, npm, Cargo, developer tools, Xcode, browsers and specific application caches. Whole application-support roots, chat history, active agent sessions and virtual-machine data are not disposable caches.

Desktop and CLI share root discovery, rule matching, bounded scans, application-activity checks, plans and receipts. Missing locations are skipped; permission failures and incomplete scans remain visible. The desktop quick-clean action groups locations into one visible result and one exact-path confirmation; its action choice routes to Trash or `PermanentExecution`. CLI and agents use explicit plans for machine-readable checkpoints. Completion shows moved, permanently removed, skipped, failed and unverified items separately. Moving to Trash does not mean disk space has been freed; restoration uses the recorded verified object and never overwrites an existing destination.

Cleanup discovery follows rule prefixes and fully measures matched targets. `complete` in this mode is not a whole-tree usage result; space analysis requires `full`. Partial scans may contribute only independently complete, policy-valid targets, with no eligibility inferred from missing legacy coverage. Execution exposes actual progress and a stop request that takes effect at a safe item boundary, without promising interruption of an in-progress system Trash call.

Broader application-cache coverage, accessibility, performance baselines and release acceptance remain separate deliverables; isolated checks do not replace them.


## Explicit space-analysis removal

Space analysis now supports local volume/folder discovery and direct explicit file/directory removal, independently of cleanup-rule workspaces. Desktop list and treemap share navigation and normalized selection. Current manifests and exclusions are checked before confirmation and execution. It reuses existing mutation journals and history. See [space analysis architecture, flow and sequence](../product/space-analysis.md).
