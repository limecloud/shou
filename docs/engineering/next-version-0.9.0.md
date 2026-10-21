# 0.9.0 delivery plan and progress

English | [简体中文](../zh-CN/engineering/next-version-0.9.0.md)

Updated: 2026-10-21. Target: daily cleanup efficiency and reusable agent-authored rules. N01–N09 are implemented with the listed automated checks. Installed interaction, actual Windows execution and public distribution retain their own acceptance gates.

## Scope and tracking

| ID | Deliverable | Implementation and checks | Remaining acceptance boundary |
| --- | --- | --- | --- |
| N01 | Bounded derived-record retention and lightweight history summaries | Complete; reference protection, expiry/quota, corruption, paging, CLI and desktops | Installed settings entry checked; recovery evidence is protected |
| N02 | Bounded concurrent Smart Cleanup | Complete; four locations, stable ordering, monotonic progress, cancellation/partial results, native evidence parity | Timing conditions below; no full-disk multiplier |
| N03 | Graceful owner close, verification and scoped retry | Complete; identity-bound 120-second plans, fresh verification, successful results/unrelated selection retained; 1/1 focused check | Actual unsaved-document quit interaction needs independent GUI acceptance |
| N04 | Docker build cache, Homebrew, Conda cache and unused Rust toolchains | Complete; fixed local commands, previews/plans/receipts, process groups and bounded time/output; 3/3 checks | No personal owner-tool data cleaned |
| N05 | Agent discovery → draft → measured preview → enablement → desktop reuse | Complete; evidence, deduplicated incremental benefit, disabled import, explicit enablement and persistence; 1/1 loop | Bundled Skill/handoff checked; no hosted model or agent |
| N06 | Windows fixed caches and one-task standard cleanup | Complete; eight caches, project discovery, select all, cross-root consent/scoped retry; WPF and bridge checks | Actual Windows Swift/C++/desktop execution awaits that environment |
| N07 | Independent orphan application leftovers | Complete; exact bundle association, owner absence/registration/activity checks, separate personal-data consent, shared deletion/recovery; 2/2 checks | Incomplete identity coverage blocks absence inference and offers coverage review; no real leftovers deleted |
| N08 | Version, diagrams, regressions and local replacement | Implementation/integration complete; 0.9.0, 233/233 Core, 158 CLI, native bridge, hard-link deletion, package/install checks | GUI claims limited to observed scope; Developer ID/notarization separate |
| N09 | Many-file deletion, journal persistence and scan thread contention | Complete; live sampling, immutable dependencies, postorder deletion, traversal optimization and shared bounded read/finalize scheduling | Two fixture comparisons below; no claim that every stall or full-disk latency is resolved |

Exact duplicates, FSEvents/USN reuse, additional privacy types/UI languages, model-version management and further typed cleaners remain later increments. Existing functions keep the shared Core. Destructive tests use generated fixtures, not personal caches, real Docker data or installed applications.

## Architecture and delivery order

```mermaid
flowchart LR
    N01[Retention and paged history] --> N02[Bounded concurrent scanning]
    N02 --> N03[Close and scoped retry]
    N03 --> N04[Typed tool cleanup]
    N04 --> N05[Agent rule loop]
    N05 --> N06[Windows standard cleanup]
    N06 --> N07[Orphan review]
    N07 --> N09[Journal and scan scheduling optimization]
    N09 --> N08[Regression and replacement installation]
```

Core owns evidence, immutable plans, execution and outcomes; adapters own filesystem/process/tool interactions. Desktop and CLI share these contracts. Routine cleanup remains one task with appropriate consent; internal phases do not require cumbersome extra pages. The [architecture](../architecture/system-design.md), [flows and sequences](../architecture/workflows-and-sequences.md) and [acceptance records](acceptance-and-testing.md) are maintained together.

## Completion log

### N01 — retention and history

Derived records default to seven days/256 MiB, with automatic maintenance at most hourly during scans. Active plans, history dependencies and recovery evidence are reference-protected. CLI `records preview/collect`, settings and macOS/Windows paged summaries are integrated. 3/3 focused checks passed; N09 adds dependency protection. The initial six-collection development inventory contained 2,992,132,938 serialized bytes, not typical-user growth or physical allocation.

### N02 — concurrent Smart Cleanup

Up to four independent locations run concurrently, with registration before evidence capture, stable result order and monotonic aggregate progress. 7/7 concurrency/progress/cancellation/partial-result checks passed. A native eight-root, 1,024-file fixture took 0.151s serially and 0.060s with four workers: warm cache, serial first, no cold-cache or product-wide multiplier. Evidence: `.build/next-version-native-concurrency.log`.

### N03 — graceful close and scoped retry

Identity-bound graceful-close plans expire after 120 seconds. Fresh owner/helper checks precede scoped refresh/retry, retaining successful outcomes and unrelated selection. 1/1 focused check covers digest confirmation, identity change, remaining processes and no filesystem mutation. Actual unsaved-document dialogs are not counted as independently accepted.

### N04 — typed tool cleanup

Fixed local Docker default-context build cache, Homebrew 30-day policy, Conda cache and reviewed Rust toolchains exclude current/default/override toolchains. Project rust-toolchain pins still require review. Native adapters use fixed locations/commands, bounded output/time and owned process groups. Timeouts remain unknown without plan replay. Desktop/CLI share plans and separate tool receipts. 3/3 focused checks include generated native processes for UTF-8 output, descendant-group timeout after launcher exit and output-limit termination. No personal owner-tool data was cleaned.

### N05 — agent customization loop

`rules opportunities` returns uncovered-directory evidence and covered-child flags; unknown directories never become automatically eligible. Previews deduplicate file identity on the same observed tree and distinguish existing coverage from incremental benefit. Import remains disabled until explicit enablement; the desktop reuses persisted rules. 1/1 generated-fixture loop covers zero duplicate benefit and reuse by a new engine. The bundled Skill covers discovery, typed-tool routing and benefit reporting. Installed agent handoff was checked without changing global agent configuration.

### N06 — Windows synchronization

Eight fixed Windows caches cover Chrome, Edge, npm, pip, Gradle, NuGet, Cargo and VS Code. Project discovery deduplicates using platform case semantics; native process snapshots gate Chrome/Edge/Code. WPF standard scan, select all, cross-root single consent, scoped retry and shared receipts are integrated. Release cross-build: zero warnings/errors; 11 process-bridge checks and path presentation passed. Actual Windows-native execution remains separate.

### N07 — orphan leftovers

Maintained and previously verified exact bundle associations combine standard application directories, registration and running status to establish absence. No name guessing or shared-container removal. Personal data needs separate consent, with fresh preflight and item-boundary verification. 2/2 generated-fixture checks cover permanent/Trash/recovery, a returning app, changed contents, exclusions, personal data and unknown-name retention. Installed read-only review found incomplete application identity coverage: this is not an empty result or necessarily a permission problem. Localized guidance now routes to coverage details. Unregistered custom installations remain an explicit limitation.

### N09 — stalls and many-file performance

- During real permanent removal, 1,091 of 3,007 background execution samples were in final full-receipt JSON encoding. This is a sample share, not a whole-operation timing percentage. The main thread mostly awaited events.
- Manifests larger than 1,024 entries become immutable `history-manifests` dependencies, written only when changed. Small state receipts publish after dependencies are durable. Full loads verify ID/count/SHA-256, legacy inline records remain readable, retention protects dependencies and explicit history removal includes them. 2/2 checks cover write failures, unknown intent, corrupt evidence refusal, retention and restoration.
- Reverse lexical postorder removes repeated path splitting during deletion sorting. Measurement skips unnecessary per-file matching; depth-first completed paths compact only the array tail. Per-file identity and no-link checks remain.
- Alternating Release comparison on equal-size 12,000-file generated trees: execution median **4.101 → 2.808s, about 32% lower**. Main receipts shrank **3,305,065 → 1,399 bytes**, retaining a **3,303,949-byte** immutable manifest; total records did not shrink by 99%. Scan medians were 0.583 → 0.758s, establishing no scan speedup. This candidate predates later traversal optimization. Binary hashes/conditions: `.build/next-version-many-file-benchmark/result.json`.
- A live full-volume scan separately reached GCD's 64-thread soft limit through unbounded finalizers. Readers and finalizers now share at most eight scheduler slots. Child completion triggers enqueueing; parents do not hold slots while waiting.
- Isolated directory-heavy comparison: **18,449 entries/8,192 files**, same warm APFS tree, alternating order, eight requested workers and equal ps-sampling overhead. Baseline sampled thread peaks were **10/46**, candidate **11/11**. Scan medians **1.021 → 0.992s** do not establish product-wide acceleration. Counts/allocation matched on every run; all file hashes remained unchanged. Evidence: `.build/next-version-finalizer-benchmark-isolated/result.json`. An initial diagnostic run overlapped the full regression and was excluded from this conclusion.

### N08 — integration, replacement and observed interaction

Latest full Core: **233/233**, including generated-fixture native Trash → restore → permanent removal for 210 macOS templates/660 patterns. Windows negative fixtures are separate; the combined catalog has 218 templates/686 patterns, not 844 tested applications. Final scheduling passed 4/4 performance/cancellation and 4/4 catalog checks; the full regression passed again. Evidence: `.build/next-version-core-final02.log`.

The installed product passed 158 CLI contracts, native bridge refusal/cancellation/cross-root single consent/permanent/Trash/restore/history checks, plus permanent removal of two hard-linked targets with zero links remaining on their selected inode and unchanged retained-file hashes. Final installation/check manifests are summarized in `.build/next-version-verification.json`. `/Applications/Shou.app` is replaced without retaining an old application.

Computer Use checked settings/retention entry, immediate English/Chinese switching with Chinese restored, agent handoff, generated-target selection, history restoration and result-page return. In the normal user environment, both generated directories were restored and all three original SHA-256 hashes matched. Concurrent user interaction means the initial Trash confirmation and first completion transition were not independently retained; they are not counted as independent confirmation acceptance. Evidence: `.build/next-version-ui-20261021/gui-verification.json`.

Developer ID/notarization, actual Windows execution, personal owner-tool cleanup, unsaved-document quit behavior and all forced-interruption combinations remain separate gates. Earlier unexplained fixture anomalies remain in the acceptance document; fresh passing fixtures do not explain them.

Final installed verification: replacement matched **138 packaged files** and preserved the **226 records present at installation**. No backup was created; the separately identified legacy Shou 0.5.0 backup was removed as previously requested. Both real user-operation receipt SHA-256 hashes still match. The final helper independently passed **158 CLI, 20 storage, the complete native bridge suite and permanent hard-link deletion**. A read-only disk scan stopped normally at 2,970,960 entries and returned to start; restarting reached results with **5,430,048 entries**, with 25% observed during organization. Its 450 coverage issues retain partial status, not gap-free disk coverage; 2:31 was an observation during organization, not final elapsed timing. Installed sampling showed eight reader threads and no earlier soft-limit report. Localized orphan guidance → coverage details → return passed; the app remains in normal user storage at the Chinese Smart Cleanup entry. Evidence: `.build/next-version-installed-scan-verification.json` and `.build/next-version-verification.json`.
