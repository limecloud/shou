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

Project cleanup checks Git tracking through a standard local Git installation and checks build process activity using native process identities and verified working directories. Git runs with bounded pipes, a deadline, a job object and sanitized Git environment variables; it is never resolved through the workspace or PATH. Unreadable process parameters, missing Git in a repository, changing evidence or unsupported process layouts remain blocking facts. Native Windows runtime acceptance of these adapters is still outstanding.

A failed Recycle Bin operation must not fall back to permanent deletion. Restoration must not overwrite an existing destination. Revalidate tree and identity evidence before mutation, journal intent first, and persist the observed outcome. Unknown outcomes remain unknown and are not automatically retried. Windows race boundaries, recycle receipts and system behavior require native validation.

Recycle Bin and restoration stay disabled by default. An explicit `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1` process setting is accepted only for isolated native validation; it is not a user-facing production toggle. Permanent removal is enabled by default. The cleanup page offers separate Recycle Bin and permanent-delete buttons, and history offers restoration plus separately confirmed permanent removal of recorded Recycle Bin items when a validated Recycle Bin session is enabled. Every mutation still requires a current scope review. Permanent removal is irreversible.

Permanent removal verifies the complete manifest, pins all reviewed objects with native handles, and checks the original volume, full File ID, SID and metadata before any deletion. It removes known members from children to parents with `SetFileInformationByHandle`, without recursive wildcard deletion. Only a direct parent's timestamps/size are refreshed after removing its own reviewed child; other metadata remains checked. New children stop directory removal. Recycle Bin purge also pins and removes only that item's paired `$I` metadata record. Partial removal retains an unknown/pending journal state and blocks replay.

## Desktop process protocol

The desktop bridge uses the shared core without fabricating terminal input or adding a global `--yes` switch. Confirmation binds an operation, plan or receipt digest, exact selection, one-use challenge and expiry within the same process. Changes invalidate consent. Public CLI mutation keeps its interactive current-scope terminal review.

Use a bundled absolute executable path, argument arrays, UTF-8 JSON, bounded input/output and structured errors. stdout is protocol-only; stderr is drained concurrently with bounded retained diagnostics. Read requests may terminate their owned process on cancellation or timeout. Mutations request cooperative cancellation and stop at item boundaries with durable receipts. A timeout does not prove that nothing changed.

Requests are one JSON line with `bridge_version: 1`, a unique `request_id`, `operation` and object `input`. Events contain the same version/ID, `kind` (`progress`, `confirmation`, `result`) and `value`. Result values retain the public CLI `api_version: "1.0"` envelope. Consent carries the challenge and digest from the current review; cancellation and EOF invalidate it. Input is limited to 1 MiB, one event to 8 MiB and client output to 64 MiB. Confirmation expires after 120 seconds.

Connected operation groups include capabilities/configuration, workspace registration, `system.scan`/`system.clean`, `scan`/`scan.results`/`scan.target`, plans, paged history and follow-ups, personal rule preview/import, `rules.set`/`rules.location-set`, exclusions, and storage scan/directory/page/map/context/remove. `storage.large-files` provides query-bound cursors, size/type filters and per-file removal protection; the WPF large-file page shares the existing storage removal plans, exact confirmation and receipts. Candidate pages contain at most 100 items; large-file pages contain at most 500. Removal plans accept at most 5,000 explicit paths, matching the shared macOS core. The bridge remains an internal transport; public CLI terminal confirmation is independent.

`cleanup.review` projects the same `CleanupReview` used by macOS. It groups categories, rules and directories, resolves overlapping roots and continued-directory evidence, and exposes selectable/recommended counts with attributed capacity. Search, category/rule scope and recommended-only filters page 500 sources at a time; continuation offsets bind to the scan IDs, refinements and query digest. WPF maintains concrete selections independently of visible pages and filters, including three-state group selection and total selected capacity. High-risk, incomplete and otherwise blocked evidence is excluded from recommendations. The projection grants no execution authority; `system.clean` still creates and revalidates plans and rejects overlapping selections.

Default Windows space measurement streams native directory cursors into a private SQLite catalog, without the deletion-manifest entry cap. Only a bounded page of directory work is loaded at a time; immediate siblings are indexed before descent. The full 128-bit File ID, volume and owner SID survive serialization, and hard links deduplicate by full object identity. Read errors, reparse points, directory changes, depth/time limits and cancellation preserve explicit coverage gaps or abort publication. File removal review hashes large files incrementally with bounded memory, cancellation and a deadline; it does not inherit the 16 MiB metadata-file read limit. Native runtime acceptance remains outstanding.

## Completion and retry parity

The WPF completion overlay follows the shared desktop contract. A successful cleanup shows the completion icon, measured bytes when the receipt provides them (otherwise the processed count), a short outcome sentence and `Done`. It does not force a History visit. Partial, cancelled, failed or verification-blocked receipts additionally show processed, skipped, failed and needs-verification counters, collapsed item details, `Rescan`, `View History` and `Close`. Rescan clears the stale candidate page and performs a fresh scan before a new plan is created; it never replays the previous plan. The overlay and receipt fields are intentionally aligned with the macOS `CleanupResultView` so a CLI or agent can reason about both clients from the same states.

## Current development scope

| Capability | Implementation status |
| --- | --- |
| Native directory selection, paged scans and review | WPF source and shared-core bridge connected |
| Rule drafts, enable/disable, global exclusion add/remove | Connected; imported rules stay disabled |
| Complete built-in catalog and cache rule controls | Browsable before choosing a root; cache and personal/project rules remain separately scoped |
| Cleanup discovery and directory continuation | Shared fair discovery, narrow target reads and `scan.target` connected |
| Cleanup grouping, search and selection | Shared categories/rules/directories, overlap deduplication, three-state groups, recommendations and cross-page selection connected |
| Large-file UI | Scan/reuse analysis, threshold/type filters, paging, cross-page selection, reviewed deletion and history connected |
| Directory space analysis | Native cursors and private SQLite catalogs retain full Windows identity; legacy bounded snapshots remain readable |
| History and conflict-safe restoration | Connected; Recycle Bin and restoration are disabled by default |
| Recycle Bin | Native implementation; explicit isolated validation switch only |
| Permanent removal | Native manifest-bound removal, CLI, desktop review and recorded Recycle Bin purge connected and enabled |
| Applications, startup, privacy, embedded AI UI, full localization and updates | Not connected; interface remains Simplified Chinese |
| Project Git ownership/build activity evidence | Windows adapters implemented; uncertainty stays blocked; native runtime acceptance pending |

Capability availability and release acceptance are separate. Permanent removal is open in the development build; Recycle Bin and restoration require the explicit validation switch, and Windows runtime and distribution evidence remains required for a release.

## Implementation and acceptance

1. Build Windows targets; implement full identity, private records and shared-contract compatibility.
2. Connect WPF scope selection, rules, scans, candidate review and plans.
3. Validate explicit confirmation, recycling, permanent removal, history, restoration, cancellation and failure journals with generated fixtures.
4. Connect space analysis, large files and exclusions; expose only actual capabilities.
5. Validate native Windows APIs and UI, then signing, upgrades and clean installation.

`scripts/build-windows.ps1` builds the production core and WPF client, then runs process checks and generated native permanent-removal protocol fixtures. It currently skips `shou-windows-tests` because of a Swift 6.2.3 Windows SIL compiler crash; those specialized ACL/junction/locking/Recycle Bin/evidence tests must not be counted as executed. `scripts/package-windows.ps1` publishes self-contained .NET, copies SwiftPM resources and the PE dependency closure from explicit official runtime directories, writes SHA-256 inventory and probes the engine with a restricted runtime search path. Windows 11 supplies `winsqlite3.dll`. See [build instructions](../../apps/windows/README.md).

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

Current alignment work, 2026-10-22, is separate from the previously published v0.10.0 ZIP. Verified on the macOS host:

- WPF Release cross-compilation succeeds with zero warnings/errors using the repository-local .NET SDK. This is not a Win32 UI run.
- Thirteen process checks cover transport, confirmation, cancellation and read request deadlines. Shared discovery, target continuation and refinement checks pass on isolated macOS fixtures.
- The native C++ files pass strict x64 and ARM64 cross-compilation syntax checks. Windows-only Swift branches and native test sources also pass a supplementary host type check with explicitly selected branches; this does not prove Windows Foundation/SDK compilation or native behavior.
- The historical successful Windows run [39695066200](https://github.com/limecloud/shou/actions/runs/39695066200) used `windows-2022` at commit `185cec99954bd2d516533d9d6c40327965af7135`. It covered production builds, native protocol fixtures, ZIP/runtime closure and WPF layout loading, and predates these worktree changes.

Current Windows Swift production/native-target builds, complete native safety fixtures, current Windows CI, WPF button journeys/accessibility, Windows 11 clean installation, signing and upgrades still require evidence. Full Windows/macOS parity has not been achieved. Recycle Bin and restoration remain disabled by default.

## Built-in AI parity

WPF now integrates the shared investigation service: gating, connections/Credential Manager, three protocols, decision-first Jev routing, questions, stopping, local records and individual rule previews. The independent CLI exposes all twelve AI commands. Existing Windows CI now includes synthetic AI contracts in its Check stage; this revision still requires native CI and UI acceptance. See [implementation/evidence](embedded-ai-implementation.md) and the [acceptance matrix](embedded-ai-acceptance.md).
