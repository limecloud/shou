# Developer workspace storage scenarios

English | [简体中文](../zh-CN/product/developer-space-scenarios.md)

Status: design draft. Capacity ranges illustrate workload scale, not measured benchmarks or guaranteed reclaimable space.

## 1. Storage characteristics

Developer storage spans project artifacts, installed dependencies, tool caches, and persistent data.

| Directory category | Illustrative scale | Requirement |
| --- | --- | --- |
| Release or candidate checkout | Tens of GB | Inspect internal composition; a version-like name never authorizes removing the project |
| Rust `target` | Tens of GB | Find nested projects, explain ownership, apply retention/exclusions, reuse rules |
| `node_modules` | Several GB | Classify installed dependencies separately and explain reinstall/local-change risks |
| `dist` | Several GB | Distinguish reproducible output from unique deliverables |
| `dist-electron` | Hundreds of MB to several GB | Cover personal toolchain layouts without waiting for every built-in adapter |
| `.git`, documentation, internal sources | Hundreds of MB or more | Preserve source and version metadata regardless of size |
| Hidden tool directories | Variable | Determine purpose; hidden/tool-owned does not imply disposable |

Aggregate within one scan snapshot and measurement basis. Nested paths, hard links, shared blocks, or different scan times must not produce unexplained double counting.

## 2. Classification

| Category | Examples | Policy |
| --- | --- | --- |
| Rebuildable artifacts | Reviewed Rust, frontend, or Electron outputs | Evidence, complete preview, rebuild cost, retention |
| Reinstallable dependencies | Reviewed ordinary npm installation | High-risk review; verify prerequisites, local changes, and offline needs |
| Tool caches | Verified compiler or Node.js caches | Identify producer, exact scope, and invalidation consequences |
| Persistent project data | Source, documents, databases, unique deliverables | Preserve; identified protection cannot be overridden |
| Unclassified directories | Personal tools or unfamiliar project data | Analysis only until purpose and boundaries are established |

A lockfile cannot guarantee reinstallability. Private registries, package removal, network loss, install scripts, and local edits matter.

## 3. Core scenarios

### D01: Rust artifacts across projects

Find nested paths such as `project/rust-part/target`; explain ownership through parent `Cargo.toml` and relevant evidence. Support current-project exclusions and user-selected retention. Document custom `CARGO_TARGET_DIR` limitations. Rescan before reusing a preset.

Age is optional and configurable. For a known artifact that must be cleared today, users may omit age conditions, stop relevant builds, and review a current plan. Runtime validation and rebuild costs still apply. Recent modification is not proof of activity, and old modification is not proof of disposability.

### D02: Node.js dependencies versus caches

Treat `node_modules` as installed dependencies, distinct from its internal caches. `.next`, `.nuxt`, `.turbo`, and `.vite` are clues requiring verified context, not universal delete rules.

Global npm caches, pnpm stores, shared dependencies, and Yarn zero-install require separate support. Do not recursively delete them generically. Reviewed ordinary npm directories may use a high-risk draft. Known `.bin` symlinks are opaque entries: never follow their targets. Unknown link types, protected data, incomplete evidence, or uncertain reinstall prerequisites block the item.

### D03: Multiple build outputs

One repository may contain frontend output, Electron output, Rust artifacts, and personal caches. Establish separate context-bound rules and combine them in a preset. Preserve unique packages, hand-maintained files, or deliverables; `dist` alone says nothing about reproducibility.

### D04: Inactive projects and checkouts

Aggregate by project and show matching, excluded, protected, and unclassified storage. Names containing `release`, `candidate`, or dates do not establish inactivity or Git worktree status. Protect shared worktree metadata, including `.git` pointer files. Whole-project archival and worktree removal need dedicated future workflows.

## 4. Interaction

Use a sortable directory table, optional treemap, and inspector. Provide project/type/size filters, breadcrumbs, and back navigation. Treemap clicks locate items without implicitly selecting them for cleanup. Showing hidden files changes presentation only.

Offer rule creation and an inspectable summary for existing agents. CLI returns equivalent classification and hierarchy. Charts supplement accessible tables; all views use the same measurement basis and indicate partial or unknown values.

## 5. Capacity accounting

Distinguish total directory usage, rule-eligible estimates, selected estimates, and processed estimates. Explain differences through exclusions, protection, unselected items, incomplete measurements, or accounting limits.

Deduplicate repeated matches and parent/child targets. Hard links and APFS clones can still complicate attribution; summed estimates are not a reclaimed-space promise.

## 6. User stories

| ID | Story | Acceptance |
| --- | --- | --- |
| US12 | Find artifact-heavy inactive projects without navigating every folder | Project aggregation and nested-artifact filters |
| US13 | Decide separately about caches, dependencies, and deliverables | Distinct classification, rules, risks, and exclusions |
| US14 | Exclude a current project while processing others | Explicit exclusions survive preset reuse |
| US15 | Ask an existing agent to add a personal build rule | CLI imports a disabled draft and returns a concrete preview; no model call inside Shou |

## 7. Acceptance fixture

Use a fictional monorepo with Rust output, ordinary npm dependencies, frontend caches, `dist`, Electron output, `.git`, source, documents, and unknown tool data. Verify classification, nested discovery, deduplication, protection, personal-rule expressiveness, and consistent GUI/CLI evidence. Neither size nor naming alone grants execution eligibility.
