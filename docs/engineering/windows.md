# Native Windows implementation

English | [简体中文](../zh-CN/engineering/windows.md)

## Technology decision

Use C#, .NET 10 LTS, WPF with its Fluent theme, and MVVM presentation state. Keep rules, exclusions, scan orchestration, plans, execution state machines and receipts in the existing Swift core. The Windows UI accesses the bundled `shou.exe` through a versioned JSON process protocol. Win32/COM belongs to platform adapters; C# does not duplicate the rule engine.

The Zhiban project informs the native UI separation, structured process bridge and real subprocess tests. Shou independently implements file identity, cleanup consent, Recycle Bin operations and restoration. Its Windows product does not require Zhiban's mathematics reader, WebView2, Python, receiver or model integration.

The initial validation target is Windows 11 x64. ARM64, older Windows releases, network volumes, cloud placeholders and cross-volume operations require separate evidence.

The reviewed Zhiban practices were `AgentProcessClient.cs` (argument arrays, simultaneous pipe draining and bounded strict JSON), `WorkspaceClient.cs` (capability discovery), `zhiban_io.c` (native locking and durable records), and its Windows acceptance document. That project also separates macOS cross-build evidence from Windows runtime and distribution acceptance.

## Responsibilities

| Location | Responsibility |
| --- | --- |
| `apps/windows/Shou.Windows` | WPF views, native folder picker, explicit confirmation, scans and history |
| `apps/windows/Shou.Windows.Services` | Bounded transport, contract validation, discovery and presentation models |
| `apps/windows/Shou.Windows.Checks` | Real subprocess, confirmation rejection and shared-core integration checks |
| `apps/cli` | Independent CLI and desktop bridge with current-platform composition |
| `packages/shou-core` | Single domain implementation and language-independent state semantics |
| `packages/shou-platform` | Windows filesystem, private records and native operations |
| `packages/windows-native` | Minimal Win32/COM C interface consumed by Swift |

## Filesystem and safety

Preserve the volume serial number, full 128-bit File ID and owner SID. Do not truncate Windows identity into POSIX inode/UID fields. Keep old macOS records readable, and exclude Windows identity from the macOS remount compatibility rule. Record storage requires a private current-user ACL, stable process locks, atomic replacement and durable writes.

Never follow junctions, symbolic links, mount points or unknown reparse points, or hydrate cloud placeholders. Permission errors and exhausted traversal budgets produce partial evidence, which cannot authorize an incompletely measured target.

The first adapter rejects case-sensitive directories rather than pretending their names are case-insensitive. It accepts fixed local drive paths, and refuses UNC/device paths, alternate data streams and reserved device names. System locations, user-profile roots, sensitive directories, configured OneDrive roots and Shou records are protected.

AppData root registration is limited to exact bundled cache roots. Mutation grants cover only the bundled rules' cache subtrees and their descendants; browser profiles, VS Code user data and arbitrary personal rules cannot expand this access. Cache root matching and binding reuse preserve Windows path casing/separator equivalence. Discovery and fair target budgets use the same algorithm as macOS, with platform-specific no-follow reads. Incomplete matched directories can be continued independently; their new evidence replaces only the selected directory in the UI.

Windows declares 19 fixed locations for Chrome, Edge, Brave, Vivaldi, Firefox, Slack, Discord, Notion, Postman, VS Code, VS Code Insiders, Cursor, npm, pip, Gradle, NuGet, Cargo, Yarn and uv, plus 16 shared project rules. Only named cache subdirectories in default user locations are included. Browser profiles, chat/workspace data, editor user data, credentials, installed tools and development environments are retained. Custom data locations, other distribution channels and undeclared applications are not implied coverage. Application cache cleanup also requires activity evidence for the corresponding Windows executables; missing mappings or failed process inspection remain blocking facts.

Project cleanup checks Git tracking through a standard local Git installation and checks build process activity using native process identities and verified working directories. Git runs with bounded pipes, a deadline, a job object and sanitized Git environment variables; it is never resolved through the workspace or PATH. Unreadable process parameters, missing Git in a repository, changing evidence or unsupported process layouts remain blocking facts. Native Windows runtime acceptance of these adapters is still outstanding.

A failed Recycle Bin operation must not fall back to permanent deletion. Restoration must not overwrite an existing destination. Revalidate tree and identity evidence before mutation, journal intent first, and persist the observed outcome. Unknown outcomes remain unknown and are not automatically retried. Windows race boundaries, recycle receipts and system behavior require native validation.

Recycle Bin and restoration stay disabled by default. An explicit `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1` process setting is accepted only for isolated native validation; it is not a user-facing production toggle. Permanent removal is enabled by default. The cleanup page offers separate Recycle Bin and permanent-delete buttons, and history offers restoration plus separately confirmed permanent removal of recorded Recycle Bin items when a validated Recycle Bin session is enabled. Every mutation still requires a current scope review. Permanent removal is irreversible.

Permanent removal verifies the complete manifest, pins all reviewed objects with native handles, and checks the original volume, full File ID, SID and metadata before any deletion. It removes known members from children to parents with `SetFileInformationByHandle`, without recursive wildcard deletion. Only a direct parent's timestamps/size are refreshed after removing its own reviewed child; other metadata remains checked. New children stop directory removal. Recycle Bin purge also pins and removes only that item's paired `$I` metadata record. Partial removal retains an unknown/pending journal state and blocks replay.

## Desktop process protocol

The desktop bridge uses the shared core without fabricating terminal input or adding a global `--yes` switch. Confirmation binds an operation, plan or receipt digest, exact selection, one-use challenge and expiry within the same process. Changes invalidate consent. Public CLI mutation keeps its interactive current-scope terminal review.

Use a bundled absolute executable path, argument arrays, UTF-8 JSON, bounded input/output and structured errors. stdout is protocol-only; stderr is drained concurrently with bounded retained diagnostics. Read requests may terminate their owned process on cancellation or timeout. Mutations request cooperative cancellation and stop at item boundaries with durable receipts. A timeout does not prove that nothing changed.

Requests are one JSON line with `bridge_version: 1`, a unique `request_id`, `operation` and object `input`. Events contain the same version/ID, `kind` (`progress`, `confirmation`, `result`) and `value`. Result values retain the public CLI `api_version: "1.0"` envelope. Consent carries the challenge and digest from the current review; cancellation and EOF invalidate it. Input is limited to 1 MiB, one event to 8 MiB and client output to 64 MiB. Confirmation expires after 120 seconds.

Connected operation groups include capabilities/configuration, workspace registration, `system.scan`/`system.clean`, `scan`/`scan.results`/`scan.target`, plans, paged history and follow-ups, personal rule preview/import, `rules.set`/`rules.location-set`, exclusions, and storage scan/directory/page/map/context/remove. `storage.large-files` provides query-bound cursors, size/type filters and per-file removal protection; the WPF large-file page shares the existing storage removal plans, exact confirmation and receipts. Candidate pages contain at most 100 items; large-file pages contain at most 500. Removal plans accept at most 5,000 explicit paths, matching the shared macOS core. The bridge remains an internal transport; public CLI terminal confirmation is independent.

`locations.scan` is a metadata-only inventory of automatically discovered projects, extra included folders and present built-in cache roots, with availability and a configuration revision. The WPF Scan Scope page supports search, source filters, folder inclusion and copying paths. Only extra folders can be stopped with `workspace.remove`: one-use confirmation binds the folder and reviewed revision, and the store lock checks the revision again. Unregistering detaches its bindings, presets and workspace exclusions while retaining files, rule definitions, other workspaces and cleanup history. Automatic locations and built-in caches remain managed by discovery.

`storage.browse` returns up to 200 directory items with the shared core's current removal reasons; the initial `storage.scan` response is also paged. Name search filters every immediate child before paging, treats wildcard punctuation literally and binds continuation to the scan, directory and query. `storage.selection` is read-only and reuses macOS parent/child normalization, including preserving siblings when a covered child is unchecked. Paths and resulting selections are limited to 5,000; excessive expansion is refused without publishing a truncated set. WPF shows partial checkboxes and deduplicated selected capacity, keeps selection across navigation and filters, and resets it for a new scan. Back/forward history commits after the directory loads; breadcrumbs, parent navigation, explicit paging, selecting visible eligible items, copying paths, Explorer selection and coverage details are connected. Map-only nodes stay unselectable until their directory protection has been read. Browsing and selection grant no execution authority; existing fresh manifests, confirmation and receipts still govern removal.

`storage.preview` reads one exact saved-analysis item locally without mutation confirmation. UTF-8/UTF-16 text is limited to a 256 KiB prefix; supported images are limited to 4 MiB, with WPF decode dimensions also bounded. Directories, unsupported formats and executables display metadata. Native reads reject links, placeholders and changed file identities; cancellation terminates the read-only bridge process. Preview content is not exposed to AI investigation tools. Windows native/UI acceptance remains subject to the evidence below.

`cleanup.review` projects the same `CleanupReview` used by macOS. It groups categories, rules and directories, resolves overlapping roots and continued-directory evidence, and exposes selectable/recommended counts with attributed capacity. Search, category/rule scope and recommended-only filters page 500 sources at a time; continuation offsets bind to the scan IDs, refinements and query digest. WPF maintains concrete selections independently of visible pages and filters, including three-state group selection and total selected capacity. High-risk, incomplete and otherwise blocked evidence is excluded from recommendations. The projection grants no execution authority; `system.clean` still creates and revalidates plans and rejects overlapping selections.

Default Windows space measurement streams native directory cursors into a private SQLite catalog, without the deletion-manifest entry cap. Only a bounded page of directory work is loaded at a time; immediate siblings are indexed before descent. The full 128-bit File ID, volume and owner SID survive serialization, and hard links deduplicate by full object identity. Read errors, reparse points, directory changes, depth/time limits and cancellation preserve explicit coverage gaps or abort publication. File removal review hashes large files incrementally with bounded memory, cancellation and a deadline; it does not inherit the 16 MiB metadata-file read limit. Native runtime acceptance remains outstanding.

## Completion and retry parity

The WPF completion overlay follows the shared desktop contract. A successful cleanup shows the completion icon, measured bytes when the receipt provides them (otherwise the processed count), a short outcome sentence and `Done`. It does not force a History visit. Partial, cancelled, failed or verification-blocked receipts additionally show processed, skipped, failed and needs-verification counters, collapsed item details, `Rescan`, `View History` and `Close`. Rescan clears the stale candidate page and performs a fresh scan before a new plan is created; it never replays the previous plan. The overlay and receipt fields are intentionally aligned with the macOS `CleanupResultView` so a CLI or agent can reason about both clients from the same states.

History now keeps each item's identity, allocated size and restore/purge eligibility. Nothing is selected initially; users can select individual items, select eligible items or clear the selection. Confirmation receives exactly the selected IDs, with a maximum of 500 per request. An empty, oversized or mixed-ineligible selection is refused as a whole. Changing records or refreshing receipts clears the selection; loading another page preserves the current record. Application-uninstall purge restrictions and unfinished-action blocks remain in the shared core.

`history.inspect` exposes the existing shared, read-only position check with one execution ID and an optional strict scan budget. The WPF dialog shows exact original/recorded Recycle Bin paths, content matches, changed or missing objects, restore conflicts, unfinished follow-ups and unavailable observations. It can be checked again or closed to cancel the owned read. Inspection never rewrites receipts, retries mutations or grants new eligibility. Package verification includes populated history layouts, selection reset and the inspection dialog; this still requires native Windows UI acceptance. Cleanup, space, extension and large-file size columns sort by raw bytes, and extension percentages sort by their numeric ratios.

## Current development scope

| Capability | Implementation status |
| --- | --- |
| Native directory selection, paged scans and review | WPF source and shared-core bridge connected |
| Rule drafts, enable/disable, global exclusion add/remove | Connected; imported rules stay disabled |
| Personal rule authoring and revisions | Three-step wizard, read-only unimported draft previews, full JSON revision editing and exclusive export connected; Windows UI journeys pending |
| Presets, source filters and workspace exclusions | All/built-in/personal filters, saving enabled selections and fresh scans, global/workspace/project exclusions and inherited protection display connected; Windows UI journeys pending |
| Complete built-in catalog and cache rule controls | Browsable before choosing a root; cache and personal/project rules remain separately scoped |
| Cleanup discovery and directory continuation | Shared fair discovery, narrow target reads and `scan.target` connected |
| Cleanup grouping, search and selection | Shared categories/rules/directories, overlap deduplication, three-state groups, recommendations and cross-page selection connected |
| Large-file UI | Scan/reuse analysis, threshold/type filters, paging, cross-page selection, reviewed deletion and history connected |
| Directory space analysis | Native cursors and private SQLite catalogs retain full Windows identity; legacy bounded snapshots remain readable |
| Scan scope management | Automatic/included/cache inventory, source filters and revision-bound removal of extra folders; native UI acceptance pending |
| Space navigation and selection | Back/forward, breadcrumbs, full-directory name search, 200-item pages, shared hierarchical selection, protection, coverage details and bounded local read-only file preview; Windows native/UI journeys await acceptance |
| Removal from space analysis | WPF connects permanent removal only; the macOS Trash action has no equivalent entry here |
| History and conflict-safe restoration | Explicit item subsets, capacity, read-only position verification and conflict display connected; Recycle Bin and restoration are disabled by default |
| Recycle Bin | Native implementation; explicit isolated validation switch only |
| Permanent removal | Native manifest-bound removal, CLI, desktop review and recorded Recycle Bin purge connected and enabled |
| Embedded AI | WPF investigation, connections, system credentials, questions, stopping, history and rule previews connected; native Windows journeys pending |
| Startup inventory and controlled toggles | Registry, Startup folders, login/boot tasks and optional machine services connected; exact current-user tasks require confirmation and definition readback, other sources use system management; native journeys pending |
| Application discovery, uninstall and standalone leftovers | WPF/CLI registry and MSIX read-only inventory, search/filtering, versions/publishers, registered size and coverage connected with a system application-management entry; direct uninstall, data ownership and independent leftovers remain unconnected; Windows native inventory acceptance pending |
| Privacy cleaning | Windows browser database adapters and WPF entry points are not connected |
| Windows tool-specific cleanup and close/verify/retry | Not connected; process detection alone does not provide an application-close workflow |
| Project Git ownership/build activity evidence | Windows adapters implemented; uncertainty stays blocked; native runtime acceptance pending |
| External AI setup and terminal integration | Bundled CLI/Skill resources can be read; no equivalent macOS setup UI, Skill ZIP export is macOS-only, and the CLI installer still expects a macOS bundle and shell launcher |
| Complete settings and localization | WPF primarily hardcodes Simplified Chinese; language switching, reduced motion and complete settings are absent; shared localization resources do not establish WPF integration |
| Permissions and controlled system operations | Runs as an ordinary user with `asInvoker`; system startup items use Windows management entry points, with no constrained UAC operation helper |
| Distribution, signing and updates | Published v0.10.0 x64 portable ZIP; installer, signing, automatic updates and ARM64 distribution remain incomplete; the old ZIP excludes current source changes |

Capability availability and release acceptance are separate. Permanent removal is open in the development build; Recycle Bin and restoration require the explicit validation switch, and Windows runtime and distribution evidence remains required for a release.

## Implementation and acceptance

### Personal rule authoring and revisions

The WPF wizard selects an exact folder or relative patterns, collects size/age/marker/preservation conditions, and presents a read-only preview. Shared `PersonalRuleDraft` constructs the declaration and the sole closed rule parser validates it. Windows case, separators and drive boundaries use the shared path helper after native normalization. Construction neither imports nor enables a rule, and a preview cannot produce an executable plan. Preview counts cover all matching/protected/out-of-condition rows, displays at most 200 rows, and retains partial coverage and issues. Field changes, stopping, version conflicts and stale configuration invalidate saving evidence.

Revision editing exposes complete JSON and a shared-core suggestion for an unused patch version, including metadata editing when the original workspace is no longer registered. Validation preserves the rule ID; import checks the reviewed configuration revision and version uniqueness again under the store lock. New versions remain disabled and existing versions/bindings remain intact. Preview, enablement and a fresh scan still precede cleanup. Export creates a new file exclusively and preserves existing or concurrently created destinations. Built-in rules remain immutable.

The bridge adds `rules.draft`, `rules.validate`, `rules.revision` and `rules.draft.preview`; `rules.import` can require a new version and bind the reviewed configuration revision. `scripts/verify-rule-authoring.py` exercises this chain on generated fixtures in macOS and Windows Check. Windows package verification also loads all three wizard layouts and the JSON editor, which does not replace button journeys or accessibility acceptance.

The rule page filters all/built-in/personal sources. Saving enabled rules asks the shared core to collect the workspace's actual enabled rules under the store lock and verify the configuration revision reviewed by the UI; C# does not recalculate that set. `presets.scan` resolves the stored ID and workspace into a fresh scan. Disabled rules cause refusal rather than enablement or scope expansion. Selections retain rule IDs and use the currently enabled versions, matching macOS.

Exclusions support all workspaces, the current workspace and a project. Projects require an exact relative directory; leaving the pattern empty protects the whole project. Inherited global exclusions are displayed separately and managed in the all-workspaces scope. `exclusions.set` reuses shared validation and rejects invalid explicit scope types, unknown scope fields and projects without a workspace, preventing accidental global changes. Removal uses the exact stored pattern. Changes invalidate old cleanup results. Package verification also loads the rule page in all three exclusion scopes.

### Native acceptance

`WindowsRegisteredApplications` validates the bounded native source contract from `applications.cpp`. Four registry sources cover current-user/machine installations and 32/64-bit views; ordinary machine-wide programs require neither the system-components option nor elevation. Current-user MSIX packages use public WinRT `PackageManager`, not internal AppModel registry structures. Identical registration/evidence aliases across registry views are collapsed while distinct same-name installations remain separate. Registry sources and individual metadata are checked before and after reading, retaining coverage issues when they change. Entries, duration, output and issues are bounded, cancellation cooperates, and the desktop request is treated as read-only.

`applications.scan` and Windows CLI `applications list` operate before opening the cleanup store. They register no workspaces, inspect no installation payloads and expose no uninstall command. Declared installation locations are display metadata rather than ownership proof. `EstimatedSize` is explicitly installer-reported; MSIX measured size and uninstall availability remain unknown. Framework/resource/bundle components are hidden by default, while Windows decides whether system packages are removable. WPF supplies search, source filtering, column sorting, details, coverage and a fixed Installed Apps settings entry. `application_inventory` is distinct from full `applications`, which remains false; inventory does not establish uninstall or leftover-cleanup support.

`scripts/verify-windows-applications.py` runs in Windows Check. Its native branch only reads actual registration/package sources, verifies entry budgets and CLI behavior, and never creates registrations, uninstalls or accepts a mutation confirmation. On macOS it checks input refusal and the platform boundary only. Package verification adds application-page layout loading and `application_inventory_layout_loaded`; these checks are connected in source but have not been run on Windows for this revision.

1. Build Windows targets; implement full identity, private records and shared-contract compatibility.
2. Connect WPF scope selection, rules, scans, candidate review and plans.
3. Validate explicit confirmation, recycling, permanent removal, history, restoration, cancellation and failure journals with generated fixtures.
4. Connect space analysis, large files and exclusions; expose only actual capabilities.
5. Validate native Windows APIs and UI, then signing, upgrades and clean installation.

`scripts/build-windows.ps1` builds the production core and WPF client, then runs process checks and generated native permanent-removal protocol fixtures. It currently skips `shou-windows-tests` because of a Swift 6.2.3 Windows SIL compiler crash; those specialized ACL/junction/locking/Recycle Bin/evidence tests must not be counted as executed. `scripts/package-windows.ps1` publishes self-contained .NET, copies SwiftPM resources and the PE dependency closure from explicit official runtime directories, writes SHA-256 inventory and probes the engine with a restricted runtime search path. Windows 11 supplies `winsqlite3.dll`. See [build instructions](../../apps/windows/README.md).

Startup adds `startup.scan`/`startup.control` and a WPF page using the shared coverage/state models. Reads are independent of cleanup storage, and configuration digests plus one-use confirmation bind the selection and action. Native controls use the public Task Scheduler interface and do not modify StartupApproved or whole-system permissions. See the [startup product contract](../product/startup-items.md) for sources, unknown states, shortcut parsing and control boundaries. Windows Check runs `verify-windows-startup.py` for read-only discovery, forged/stale-selection refusal and cancellation; the verifier never accepts mutation confirmation.

Windows CLI help and focused capabilities expose the implemented `startup list` and `startup control` commands. Discovery describes both platforms and keeps unsupported application mutations, privacy and tool commands hidden. The Windows startup verifier checks this discovery contract before inspecting native sources.

End users must not need a developer toolchain. Development output, cross-compilation, macOS bridge tests and configured Windows CI are separate from clean-system installation evidence. Runtime redistribution licenses, signing, an installer, upgrades and uninstall still require acceptance.

The Windows GitHub workflow runs static resource checks, native Swift/WPF builds, and generated-fixture/process checks as separate gates. `scripts/build-windows.ps1 -Stage Build` and `-Stage Check` expose those gates; omitting `-Stage` runs both. The .NET SDK follows `apps/windows/global.json`, while Swift and Python versions are declared in the workflow. A failed gate prevents development artifact upload, and a newer run cancels an older run for the same ref.

## Official references

- [WPF overview](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)
- [WPF Fluent theme](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net90)
- [MVVM Toolkit](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/)
- [Swift Windows installation](https://www.swift.org/install/windows/)
- [Windows file identity](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)
- [Security identifiers](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-identifiers)
- [IFileOperation](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ifileoperation)
- [LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex)

## Verification status

Current alignment work, 2026-10-22, is separate from the previously published v0.10.0 ZIP. Windows has not reached full macOS parity. The matrix above checks platform facts, shared core, bridge, WPF entry points and release evidence; command or page presence alone does not establish support. Verified on the macOS host:

- WPF Release cross-compilation succeeds with zero warnings/errors using the repository-local .NET SDK. This is not a Win32 UI run.
- Scan-scope and storage-browsing follow-up passes 290 shared core tests, 22 process contracts, 159 CLI contracts, isolated scope-removal/browsing protocols and the desktop Trash/restore/permanent fixture loop on macOS. A later focused rerun also verifies whole-request refusal when unchecking a covered child would expand a 5,002-item folder. WPF still requires native UI acceptance; full-directory name search and read-only file preview remain outstanding.
- Seventeen process checks cover transport, confirmation, cancellation, read request deadlines, rule authoring/preview classification, validation issue details, cross-page cleanup selection and AI partial/cancelled results. Shared discovery, target continuation and refinement checks pass on isolated macOS fixtures.
- Four Windows cache checks cover all 19 declared locations, retained profiles/settings/credentials/environments, aliases/bindings and mapped executable activity gates using generated fixtures and simulated process evidence. They do not execute Win32 process inspection or mutate real application data.
- Four shared startup checks cover source coverage, unknown states, identity/digests, control boundaries and configuration changes using generated evidence only; no real startup configuration changed. Storage checks pass 8/8 and focused personal-rule checks 6/6. After rule management completion, the full 282/282 core suite, 76 real rule protocol requests, 159 CLI contracts and the shared desktop protocol pass, covering unimported previews, the 200-row display budget, stale-save refusal, retained bindings, saved enabled selections and global/workspace/project exclusion isolation. File changes use isolated fixtures. The preceding 94 AI contracts and desktop cancellation checks passed with local synthetic providers.
- Three application inventory checks cover identity, source coverage, unknown facts and malformed evidence; the full core suite reaches 285/285, with 159 CLI contracts, 17 process contracts and the shared desktop protocol passing. The Windows-specific script checks input and platform boundaries on this host; native registry/MSIX branches have not run.
- All five native C++ files pass strict x64 and ARM64 cross-compilation and linking, and the Windows application-inventory Swift branch passes a supplementary host type check with explicitly selected branches. An unused duplicate `IReference<boolean>` definition in the MinGW WinRT headers is suppressed by a cross-command-only macro; production source does not include that macro. These checks do not prove Windows Foundation/SDK compilation or native behavior.
- The historical successful Windows run [39695066200](https://github.com/limecloud/shou/actions/runs/39695066200) used `windows-2022` at commit `185cec99954bd2d516533d9d6c40327965af7135`. It covered production builds, native protocol fixtures, ZIP/runtime closure and WPF layout loading, and predates these worktree changes.

At commit `7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc`, [Windows CI 39773069460](https://github.com/limecloud/shou/actions/runs/39773069460) completed production Swift/WPF builds but failed with `store_corrupt` when the AI contract reopened a space catalog. The worktree adds private SQLite file creation with explicit current-user ownership and a private ACL, creates new files only, retains existing-object refusal and read identity checks, and checks cancellation before creation. The fix passes the cross-linking and supplementary type checks above, but has no subsequent Windows runtime result. New native checks cover reopening, current-user identity, overwrite refusal and no index creation after cancellation; the specialized target's compiler crash prevents counting them as executed.

The same commit's [macOS CI 39773069452](https://github.com/limecloud/shou/actions/runs/39773069452) failed on a `swift-ai-sdk` `Iterator.Element?` Sendable compilation error, and [release 39773069577](https://github.com/limecloud/shou/actions/runs/39773069577) also failed. At review time v0.10.0 remains the latest published release; v0.11.0 has not been published. Those remote runs exclude the current uncommitted fixes.

Complete native builds/checks of current Windows source, native safety fixtures, WPF button journeys/accessibility, Windows 11 clean installation, signing and upgrades still require evidence. Recycle Bin and restoration remain disabled by default. Cross-compilation and old-version CI do not establish full parity or release acceptance.

## Built-in AI parity

WPF now integrates the shared investigation service: gating, connections/Credential Manager, three protocols, decision-first Jev routing, questions, stopping, local records and individual rule previews. The independent CLI exposes fifteen AI commands, including configuration inspection, recoverable deletion and restoration. Existing Windows CI now includes synthetic AI contracts in its Check stage; this revision still requires native CI and UI acceptance. See [implementation/evidence](embedded-ai-implementation.md) and the [acceptance matrix](embedded-ai-acceptance.md).
