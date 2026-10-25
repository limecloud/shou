# Next-release development plan

English | [简体中文](../zh-CN/engineering/next-release-plan.md)

Updated: 2026-10-26. Status: v0.15.0 published; remaining roadmap work is in progress. Read-only diagnostics, shell completion, analysis comparison and update discovery have independent macOS and Windows source implementations; owning contracts and SYNC record verification and platform differences. This document prioritizes the next release without changing product, safety, rule or release contracts. v0.15.0 includes the current workspace, diagnostics, completion, comparison and read-only catalog checks; other work packages remain in the roadmap.

## 1. Planning baseline and sources of truth

The published `v0.15.0` baseline is commit `ec91a357b6cadd8c286fe6ae38bed6adf8ff5350`. Remaining roadmap items and later working-tree edits are outside that tag. [SYNC.md](../../SYNC.md) owns actual checks, failures and native limitations; this plan is not an acceptance record.

| Source of truth | Responsibility |
| --- | --- |
| [PRD](../product/prd.md), [capability ownership](capability-plan.md) | Product scope, responsibilities and delivery sequence |
| [Rule coverage](rule-coverage.md), [cleanup safety](../security/cleanup-safety.md) | Declared scope, protected data and execution constraints |
| [System architecture](../architecture/system-design.md), [platform boundaries](../architecture/monorepo-and-platforms.md) | Platform ownership and shared-resource boundaries |
| [Current interface design](interface-design.md), [apps and projects](../product/apps-and-projects.md) | Latest navigation, page organization, visual and interaction baseline |
| [Acceptance](acceptance-and-testing.md), [platform ledger](../../SYNC.md) | Separate source, generated fixtures, native interaction, installation and publication evidence |
| [Windows plan](windows-native-plan.md), [release](releasing.md) | Native stages, distribution scope and release conditions |

Existing capabilities retain their owning contracts and implementations. Record source availability, generated-fixture results, native behavior and publication separately. Checks that have not run are not passes.

## 2. Product assessment

- Basic cleanup, storage visualization, application removal, startup management and CLI access have implementations. Prioritize quality and acceptance rather than rebuilding batch uninstall, administrator-owned app recycling or startup switches.
- Dedicated handling of valuable storage categories, third-party app updates, monitoring and resident utilities are separate expansion directions, prioritized by user value and implementation boundaries. Rule counts do not establish reclaimable capacity, accuracy or compatibility.
- Continue investing in developer storage investigation, reusable personal rules, consistent GUI/CLI execution and verifiable plans, outcomes and recovery. Measure value through completed user tasks.
- AI-tool data cleanup manages data created by tools; AI investigation uses models to explain storage and propose disabled rule drafts. Their responsibilities are independent, and one does not establish the other.

Follow the current workspace design: top-level and secondary navigation, a full-window teal-to-ice-blue background, original task illustrations, open content areas, full-width object rows with inline details, and a stable selection footer. Place diagnostics in Settings support and comparison in the analysis actions menu; future update discovery and dedicated review belong to existing object tasks. Shared tokens own dimensions and colors. Do not restore the old sidebar, dense small text or another parallel navigation system. Windows implementation and acceptance remain separate from resource generation.

Place additions within these existing tasks. Planned entries are not delivered features and must not appear as inactive placeholder actions.

| Work package | Placement and interaction requirements |
| --- | --- |
| NV02 Developer coverage | Smart Cleanup and Apps & Projects → Developer Projects share candidates and selection. Show paths, rebuild costs and unavailable reasons inline; the footer summarizes only the current task scope |
| NV03 Causes and diagnostics | Explain failures/partial results where they occur. Settings support opens read-only diagnostics with disclosure, copy and retry; never send automatically |
| NV04 AI investigation | Keep the existing investigation entry and independent draft review. Return to the current task for rescanning after enablement; investigation state is separate from deletion selection |
| NV06 Analysis comparison | An analysis action opens a separate comparison view with nearby history, coverage and changes. Closing retains original navigation/selection; comparison does not create cleanup selections |
| NV07 Update discovery (in progress) | Show catalog versions, sources and official entries inline in app rows, using existing search/disclosure rather than a new top-level update center |
| NV08 Dedicated review (planned) | Start AI-version review in the tool's Smart Cleanup details and installer review in a dedicated Large Files filter/details. Design and accept each workflow independently |
| NV09 Leftovers and completion | Keep leftovers in the existing app entry/component review. CLI completion prints static scripts without a graphical configuration page |

Reuse existing empty, loading, partial, failure and completion states. Once data exists, prioritize tools and results; illustrations belong to introductions or compact headings. Acceptance includes the current minimum window, long Chinese/English text, light/dark appearance, Reduce Motion and keyboard focus. Dimensions remain owned by the [design specification](interface-design.md) and shared tokens.

## 3. Capability improvements

“No implementation found” refers to the inspected contracts and relevant modules, not runtime test results. P0 means recommended for the next release; P1 means a subsequent small increment selected by value; P2 requires a separate product decision.

| ID / capability | Shou's current position | Improvement target | Priority and boundaries |
| --- | --- | --- | --- |
| GAP01 Daily/developer cleanup | Declarative rules, project discovery, installed-owner cache discovery and fixed Docker/Homebrew/Conda/Rust operations exist | Improve discovery of caches, logs, project outputs and package caches, explaining rebuild costs | P0: establish baselines for missed targets, wide directories, partial coverage and activity-evidence rejection; verify preservation cases before expanding app coverage |
| GAP02 Application removal and leftovers | Batch uninstall, component review, separate personal-data consent, Finder recycling for administrator-owned bundles and independent leftover workflows exist; app-specific compatibility evidence needs expansion | Establish app-by-app verification and add attributable residuals; evaluate Dock entries and data-only removal independently | P0: publish the verified scope. P1: add valuable app-specific residual handling. External helpers, extensions and shared data cannot be removed by name; data-only removal needs its own contract |
| GAP03 Third-party app updates | `AppUpdater` updates Shou itself through Sparkle; Homebrew Cask observations, inline controls and independent CLI source are added | Verify single-source identity, versions and official entries before assessing other sources | P1: finish read-only catalog checks; mapping does not prove installation source, signatures or compatibility. Design replacement and batch installation separately |
| GAP04 Startup management | App grouping, LaunchAgents, eligible third-party system daemons, native login controls and settings fallback exist | Specify supported login, launchd and background registrations and verify state against the system | P0: verify state readback, permission cancellation and unknown sources; do not rebuild from the older first-stage PRD description |
| GAP05 AI-tool data lifecycle | Codex/Claude/Cursor cache rules exist; sessions, memory, skills and persistent tool state are protected; no complete lifecycle service found | Evaluate rebuildable caches, obsolete versions and persistent-data maintenance under separate contracts | P0 only improves existing cache recognition/explanations; P1 may review obsolete versions independently. Sessions, worktrees, models and databases need dedicated future services, not broader cache globs |
| GAP06 Installer organization | Explicit selection exists in Space Analysis/Large Files; no dedicated installer classification and review found | Identify installers/archives by source, with age, purpose and uncertainty | P1: begin with read-only discovery and source/age information, followed by exact selection; a `.zip` suffix alone does not establish deletability |
| GAP07 System data and VM space | Current boundaries exclude root cleanup, system acceleration and direct deletion of internal VM storage; explicit storage analysis exists | Explain local snapshots, OS installation resources and virtual disks, linking to official management tools | P1: read-only attribution. P2: snapshot/virtual-disk mutations with independent adapters and contracts |
| GAP08 Storage analysis | Simple/detailed modes, treemaps, extension summaries, large files, coverage, durable indexes and exact explicit deletion exist; same-root historical comparison source is added | Improve failure handling and verify explanations of observed changes between comparable scans | P0: large directories, low free space, permissions and stopping. P1: verify growth explanations; old scans never authorize current deletion |
| GAP09 Live system status | No independent monitoring page/sampling service found | Evaluate user value from CPU, GPU, memory, disk, network, battery, processes and trends | P2: assess separately because benefits to freeing storage are indirect; scan progress is not live monitoring |
| GAP10 Menu bar and resident tools | No dedicated resident menu-bar entry found | Evaluate whether summaries, quick entries and reminders improve storage tasks | P2: decide keep-awake, screen cleaning and device-privacy alerts separately rather than adding a utility suite in one release |
| GAP11 Maintenance, fans and battery | These features are absent; some conflict with exclusions for root cleanup, system acceleration and memory cleanup | Independently assess product scope and hardware requirements for maintenance, fan and charge control | P2 or remain out of scope; require permission, exit restoration and failure contracts rather than one-click optimization |
| GAP12 Human-facing CLI | Discoverable commands, versioned JSON, pagination, rules/plans/history and interactive confirmation exist; Bash/Zsh completion is added, TUI remains unimplemented | Verify help and generated completion, then evaluate interactive terminal browsing | P1: help and shell completion. P2: TUI. App-binary modification and sudo authentication configuration are outside this release |
| GAP13 User diagnostics/support | Structured errors, item history and inspection exist; sanitized read-only Settings and CLI diagnostics are added | Complete native verification of previewable, copyable reports and relevant help | P0: the report initially covers disk capacity, access and record-directory safety; owning results still explain unknown activity and scan-specific issues |
| GAP14 Distribution/compatibility evidence | Packaging, signed update feeds, npm and dual-architecture workflows exist; initial Mac packaging remains ad-hoc, with Developer ID/notarization and post-publication upgrade evidence needing separate confirmation | Obtain independent evidence for actual download channels, supported architectures, installation/updating, and publish real-app verification scope | P0: Sparkle signatures are not Apple signing/notarization; generated rule fixtures are not real-app compatibility evidence |
| GAP15 Languages/interaction completion | Chinese/English runtime; 11 README editions are not 11 runtime languages; native interaction/accessibility source exists with acceptance pending | Complete existing language, keyboard and VoiceOver journeys, including long paths and narrow windows | P0: existing languages, long paths, minimum window and accessibility. P2: additional runtime languages |
| GAP16 Windows usability | Independent C#/WinUI implementation and portable preview exist; Server-generated MSI/task suites have passed; ordinary-user Windows 11 revalidation, UI, ARM64 and signed-install gaps remain | Complete system, UI, architecture and distribution acceptance for declared capabilities by native stage | P0: resolve blockers for capabilities actually claimed in the release; Mac tests/cross-builds cannot establish full support |

Shou's owning sources: [Daily cleanup](../product/unified-cleanup.md), [uninstall](../product/application-uninstall.md), [startup](../product/startup-items.md), [space analysis](../product/space-analysis.md), [AI](../product/embedded-ai.md), [privacy](privacy-cleaning.md), [CLI](../ai/agent-and-cli-contract.md) and [release](releasing.md).

## 4. Existing strengths to preserve and verify

1. **Personal rule workflow:** investigation, necessary questions, individual disabled drafts, independent previews, rescan after enablement and confirmation of the current plan. Personal directory knowledge becomes reusable policy instead of repeated model conversations.
2. **GUI/CLI consistency within a platform:** shared domain services, mutation lock and history reduce policy drift. Verify locking, state and outcome consistency with concurrency fixtures.
3. **Verifiable execution outcomes:** identity/manifest binding, expiry/replay prevention, durable intent, partial/unknown outcomes and recovery of verified Trash items. Make these understandable in the product.
4. **Models separated from mutation authority:** normal cleanup works offline, AI can be disabled, and rules cannot supply arbitrary commands. Developer tools use fixed local operations, not a Shell execution framework.
5. **Structured privacy cleanup:** dedicated source/time-window contracts, separate Cookie consent and preservation of unknown database schemas. State compatibility precisely; folder deletion cannot substitute for structure validation.

## 5. Recommended next-release scope

v0.15.0 includes the current workspace, NV03 diagnostics, NV06 comparison, NV07 read-only catalog checks and NV09 static completion. Retain remaining NV01–NV05 acceptance individually; Windows ships as a restricted preview with public mutations disabled. NV08 dedicated review and NV09 residual expansion remain subsequent candidates. P2 is outside this release commitment. Reuse small existing capability interfaces rather than building generic plugin, maintenance-task or updater frameworks.

### NV01: Freeze a releasable baseline and compatibility matrix (P0)

- **Problem:** some product documents describe earlier capability stages; newer workspace implementations do not yet have complete regression, native UI and distribution evidence.
- **Scope:** reconcile binary capabilities, owning contracts and SYNC; accurately state uninstall, startup, privacy and AI status. Establish representative app/developer scenarios before expanding samples by risk.
- **Responsible modules:** existing `tests/core`, platform tests, CLI verification scripts, acceptance docs and `SYNC.md`; do not reimplement existing services.
- **Acceptance:** record platform, architecture, app version, scope, commands and outcomes for every supported scenario. Count rule declarations, generated fixtures and real-app observations separately. Unresolved failures remain blockers. Reproduce host-process-budget rejection in a controlled environment without weakening activity thresholds.

### NV02: Improve useful developer-cleanup coverage (P0)

- **Problem:** users need large targets to be found, reasons for unavailability and rebuild-cost explanations rather than more templates.
- **Scope:** prioritize Rust `target`, Swift `.build`, Node outputs/dependencies, Xcode/package caches and existing AI-tool caches. Distinguish missed discovery, bounded depth, wide directories and unknown activity. New caches need evidence of rebuildability.
- **Responsible modules:** `NativeCleanupDiscovery`, Core `Rules`/`ArtifactSafety`, shared rule/location JSON and Smart Cleanup UI; validate the independent Windows implementation separately.
- **Acceptance:** each selected scenario has generated positive, preservation and changed-after-scan fixtures. Preserve source, credentials, edited dependencies, private packages, active builds and persistent state. Verify permanent-deletion confirmation, receipts and unrelated-file hashes. Report observed matched bytes and uncovered causes without unsupported extra-GB targets.

### NV03: Scan confidence, diagnostics and outcome explanations (P0)

- **Problem:** existing protection and structured errors may still leave users unable to understand a failed scan or unavailable selection.
- **Scope:** distinguish permissions, storage exhaustion, unknown activity, changed evidence and partial coverage, with actionable next steps. Add a previewable/copyable read-only diagnostic summary reusing current history/state. Never claim recovery without verifiable recovery evidence.
- **Responsible modules:** Core state/history summaries, bounded Platform read-only observation and macOS/Windows presentation; UI must not decide deletion eligibility again.
- **Acceptance:** Chinese/English causes, paths and retry/rescan routes. Reports exclude personal absolute paths, usernames, session content, credentials, process arguments and environment values by default and never upload automatically. Low-storage index append/sealing failures, permission denial, stopping and late callbacks retain true states. Failed scans cannot overwrite the previous analysis.

### NV04: Finish the AI investigation user journey (P0)

- **Problem:** the existing implementation must demonstrate useful reusable decisions about major storage branches rather than only display model responses.
- **Scope:** finish existing macOS investigation, questions, individual rules, preview, rescan after enablement and outcome verification. Plan AI-tool data lifecycle management as a separate package. Windows AI follows its separate .NET plan.
- **Responsible modules:** `packages/shou-ai`, Core investigation/draft services and existing AI UI/CLI; use the [existing AI acceptance matrix](embedded-ai-acceptance.md), without another interface layer.
- **Acceptance:** major branches in annotated cases have cleanup/optional/retain/investigate conclusions and evidence; missing information produces explicit questions. Deterministic/decision-service-sufficient cases do not call the primary model. Disabling, cancelling, timing out and offline operation retain true outcomes. Generated directories complete the native journey from one draft through confirmed execution and receipts. Actual-service checks use explicitly authorized synthetic evidence only.

### NV05: Native usability and distribution acceptance (P0)

- **Scope:** obtain installed native evidence only for capabilities, systems and architectures actually claimed in this release. macOS and Windows have independent exit criteria.
- **macOS:** verify installed scan, selection, cancellation, uninstall, startup, privacy, history and recovery. Cover Chinese/English, light/dark mode, long paths, minimum window, keyboard and VoiceOver. Verify official downloads, update feeds and data preservation after upgrading. Keep distribution limitations explicit until Developer ID/notarization is complete.
- **Windows:** generated fixtures on Windows Server 2025 x64 have verified the MSI-context correction, fresh task rereads and provisioned privacy AppData-anchor compatibility. Continue with regular-user Windows 11 reruns, the native picker and blocked downstream E2E. Obtain separate evidence for storage/large files, privacy, uninstall and startup, including stop/close and records after restarting. ARM64 execution, signing, installation and updating retain their independent native gates.
- **Responsible modules:** current adapters/UI, `scripts/windows`, packaging/update scripts and the [Windows plan](windows-native-plan.md).
- **Acceptance:** unaccepted Windows mutations cannot enter a supported-release claim. If shipping a restricted preview, its binary must actually disable unaccepted capabilities, consistently with discovery, UI, docs and attachments. Count actual skipped results; skipped MSI/task suites are not passes. All destructive checks use generated fixtures from this run.

### NV06: Explain storage growth (P1, preferred increment)

Reuse immutable scans/indexes to let users explicitly compare two analyses of the same root, showing major growth branches, observation times and coverage changes. Reject conclusions when root identity, accounting or coverage is incomparable. New/missing observations alone do not prove growth/deletion. Do not enable background full-disk scans by default or turn historical indexes into deletion authority. Verify pagination, hard-link/sparse-file accounting, partial coverage, invalidation after index removal and bounded retention before considering reminders.

### NV07: Discover third-party app updates (P1, in progress)

macOS uses the public Homebrew Cask catalog with exact built-in mappings for six stable apps. Windows uses the official stable Visual Studio Code release catalog with independent exact registration matching. The [update-discovery contract](../product/application-updates.md) owns networking, versions, identity and official-entry semantics. Record implementation and acceptance separately.

- **Scope:** begin with one verifiable source showing installed/available versions, source and official entry, without executing downloads or replacing apps. Unknown metadata, channel/architecture mismatches and ambiguous versions stay unknown.
- **Responsible modules:** Core update-observation models, a bounded read-only single-source Platform query, app inventory and inline app details, separate from Shou's own `AppUpdater`.
- **Prerequisites and acceptance:** freeze source, identity and version-comparison rules first. Cover offline use, timeouts, redirects, wrong channels/architectures, invalid versions and cancellation; failures must not claim an app is up to date. Explain network actions and their sources without uploading app inventories; open an external page/app only when the user chooses a trusted entry.
- **Later boundary:** independently design single-source identity, download integrity, signatures, running-app behavior, cancellation and failures before adding automatic installation.

### NV08: Review obsolete AI versions and installers (P1, subsequent candidate)

- **Scope:** split into two independently deliverable workflows: one AI tool's obsolete versions and one installer source. Start with read-only discovery showing paths, ownership, version/age, purpose, rebuild costs and uncertainty. Preserve running references and anything not provably idle.
- **Responsible modules:** Platform fixed-location/metadata discovery, Core classification/protection, shared declarations and existing object lists; do not introduce generic archive execution or maintenance frameworks.
- **Acceptance:** verify the current version and running references for obsolete versions. Installers need source and format evidence rather than suffix-only classification. Generated fixtures cover current versions, links, corrupt archives, denied access, truncated budgets and replacement after scanning. Never execute packaged programs or extract archives into user directories. Unreadable items are neither zero bytes nor cleanable.
- **Later boundary:** deletion requires independent selection and existing plans/confirmation/receipts. Old sessions, worktrees, memory/skills, models and SQLite data are outside this cache/obsolete-version work package.

### NV09: App-specific removal coverage and CLI completion (P1, independent candidates)

Extend uninstall one real app's explicit residual contract at a time, preserving shared components, other installed copies and personal data. Destructive engineering checks use generated data in isolated test environments. Generate CLI help/completion from current command definitions rather than maintaining another command specification. These candidates can ship independently; their priority does not bundle them together.

- **Responsible modules:** existing application/leftover domain services and native ownership adapters; CLI command-discovery definitions and completion generation.
- **Acceptance:** residual samples record app version, installation source and exact components, with preservation cases for shared, similarly named and active items. Verify completion against discovery, flags, enums, paths with spaces and untrusted input. Completion must not launch Shou or edit shell configuration. Record Bash/Zsh syntax and real interactive behavior separately.

## 6. Exclusions and safety boundaries

- Do not add unattended deletion, destructive `--yes` bypasses or default emptying of the whole Trash. Daily cleanup defaults to permanent deletion; application removal defaults to Trash, under their existing exact-scope confirmation contracts.
- Do not add generic root cleanup, memory cleanup, one-click acceleration, fan/battery writes, sudo configuration changes, app-binary slimming or deletion of internal virtual-disk files.
- Do not treat sessions, worktrees, skills, memory, models or databases as disposable caches. Future lifecycle features first need changes to their owning product/safety contracts and independent preservation, activity, recovery and native verification. This plan does not authorize those changes.
- Do not build monitoring, tray utility suites, multiple update-source frameworks or Windows AI scaffolding merely to match feature counts. Deliver independently verifiable slices first.

## 7. Implementation status and remaining delivery

As of 2026-10-26, this table describes existing work and next steps rather than replacing the acceptance ledger in [SYNC.md](../../SYNC.md) or marking entire packages complete.

| Work package | Existing implementation / verification | Remaining delivery |
| --- | --- | --- |
| NV01 Baseline and matrix | Current contracts/native failures reviewed; published-source Apple Silicon/Intel full CI, Windows main suites and Release workflow passed; generated rule fixtures recorded | App/scenario-specific real compatibility matrix. Retain the host Node activity refusal from one local regular-script run separately from clean CI results |
| NV02 Developer coverage | macOS prioritizes literal components/project markers in wide directories and rechecks policy for selected scope; 11 related generated-fixture checks passed | Representative scenarios and real read-only observations with missed-discovery/budget causes. Equivalent Windows discovery/policy changes and native verification remain pending |
| NV03 Causes and diagnostics | macOS Settings/CLI diagnostics, fixed-field reports and bilingual text implemented; 3 diagnostic and 24 CLI-support checks passed; native Chinese/light and English/dark views observed | Complete scan/activity-reason-to-next-step workflows, minimum window, keyboard/VoiceOver, and native Windows diagnostic acceptance |
| NV04 AI workflow | Reuses existing investigation, disabled drafts, preview, rescan contracts and validators | Native journeys and failures for this candidate against the existing matrix. Model replies and CLI checks do not establish UI acceptance |
| NV05 Native use and distribution | v0.15.0 published and installed locally; Windows 11 read-only UI and generated tasks 6/6 passed; a subsequent clean Windows Server 2025 x64 run passed MSI 6/6, tasks 6/6 and three privacy-anchor compatibility/rejection regressions | Regular-user Windows 11 complete journeys for the same follow-up build, privacy counts/actions, accessibility, ARM64, signing, installation and updates. Generated suites do not open public mutation gates |
| NV06 Analysis comparison | macOS Core/CLI/analysis-menu view implemented; 4 domain and 34 storage CLI checks passed; generated data exercised history, deltas and drilldown | Minimum window, keyboard/accessibility and failure UI. Windows has independent domain, CLI and WinUI source; native acceptance remains pending |
| NV07 Update discovery | Both platforms have catalog queries, strict version comparisons, inline controls and independent CLI. macOS passed 4 domain, 10 offline CLI and an earlier 11 public-catalog checks; Windows passed 16 domain and 5 HTTP fixtures | Native UI, complete failure journeys and Windows runtime acceptance remain pending; Shou's own updater does not count |
| NV08 Dedicated review | Unimplemented; existing cache rules/Large Files selection do not count | Separately freeze recognition/preservation contracts for one tool's obsolete versions and one installer source |
| NV09 Leftovers and completion | macOS CLI generates static Bash/Zsh completion from discovery; real Bash callbacks and syntax checks for both shells exercised | Real Zsh interaction, Windows PowerShell interaction and app-specific residual contracts/verification |

Suite counts overlap; do not sum them into compatible-app counts or complete end-to-end passes. Earlier macOS view observations have no archived screenshots; later Windows 11 screenshots retain their own exact source and scope. The fixed v0.15.0 scope is published and follow-up fixes do not move its tag. Incomplete work packages remain open; complete cross-platform acceptance has not passed.

## 8. Development and verification

Sequence: NV01 fixes scope and the failure inventory → NV02/NV03/NV04 deliver complete individual slices → NV05 validates the same candidate build → add NV06 only with remaining capacity. Functional changes still update owning bilingual contracts, relevant shared resources and `SYNC.md`. This document owns prioritization and work packages only.

| Check | Conditions and evidence |
| --- | --- |
| `python3 scripts/verify-docs.py` | Documentation links, bilingual editions, identifiers and code fences; required for this plan-only change |
| `python3 scripts/update-localizations.py --check`, `python3 scripts/generate-windows-resources.py --check` | After changing text/shared declarations, verify canonical sources and generated consistency |
| `sh scripts/test.sh` | Normal repository checks after macOS behavior changes; some CLI checks permanently remove their generated fixtures |
| `sh scripts/test-windows-core.sh` | Portable Windows domain/presentation evidence, not native system/UI acceptance |
| Native system, UI and distribution checks | Record commands, exact source/resource revisions, OS, architecture, pass/fail/skip and evidence paths. Follow the repository cloud-test skill for concentrated Windows acceptance; keep the cloud desktop off during development |

The additional native rule-catalog permanent-removal check, `--native-trash-purge`, still needs explicit authorization. MSI and task suites accept only fixtures generated by the current run and use the repository's explicit opt-ins. Documentation-only work does not start destructive tests, cloud desktops or publication.

Done means selected packages have observed results and limitations, users understand what was found, why it is selectable, its impact and the actual outcome, and can reuse their rule with a fresh scan. Unaccepted capabilities stay unavailable; more pages or rules do not substitute for delivery evidence.
