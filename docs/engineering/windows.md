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

A failed Recycle Bin operation must not fall back to permanent deletion. Restoration must not overwrite an existing destination. Revalidate tree and identity evidence before mutation, journal intent first, and persist the observed outcome. Unknown outcomes remain unknown and are not automatically retried. Windows race boundaries, recycle receipts and system behavior require native validation.

## Desktop process protocol

The desktop bridge uses the shared core without fabricating terminal input or adding a global `--yes` switch. Confirmation binds an operation, plan or receipt digest, exact selection, one-use challenge and expiry within the same process. Changes invalidate consent. Public CLI mutation keeps its interactive current-scope terminal review.

Use a bundled absolute executable path, argument arrays, UTF-8 JSON, bounded input/output and structured errors. stdout is protocol-only; stderr is drained concurrently with bounded retained diagnostics. Read requests may terminate their owned process on cancellation or timeout. Mutations request cooperative cancellation and stop at item boundaries with durable receipts. A timeout does not prove that nothing changed.

Requests are one JSON line with `bridge_version: 1`, a unique `request_id`, `operation` and object `input`. Events contain the same version/ID, `kind` (`progress`, `confirmation`, `result`) and `value`. Result values retain the public CLI `api_version: "1.0"` envelope. Consent carries the challenge and digest from the current review; cancellation and EOF invalidate it. Input is limited to 1 MiB, one event to 8 MiB and client output to 64 MiB. Confirmation expires after 120 seconds.

Connected operations: `capabilities`, `configuration`, `workspace.add`, `scan`, `scan.results`, `plan`, `plan.execute`, `history`, `history.restore`, `rules.import`, `rules.set`, `exclusions.set`, `storage.scan`, `storage.directory`. Candidate pages contain at most 100 items. The bridge remains an internal desktop transport; public terminal confirmation is independent.

## Current development scope

| Capability | Implementation status |
| --- | --- |
| Native directory selection, paged scans and review | WPF source and shared-core bridge connected |
| Rule drafts, enable/disable, global exclusion add/remove | Connected; imported rules stay disabled |
| Directory space analysis | Bounded in-memory traversal and navigation; streaming SQLite catalogs are unavailable |
| History and conflict-safe restoration | Connected; mutation capability is disabled by default |
| Recycle Bin | Experimental native implementation; enable only for isolated Windows validation with `SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1` |
| Permanent removal | Unavailable on Windows, including direct platform calls |
| Applications, startup, privacy, large-file UI, full localization | Not connected; initial interface is Simplified Chinese |
| Rust/Swift generated-source ownership/activity evidence | Unavailable on Windows; affected built-in candidates remain blocked |

This development gate is deliberate: a native implementation without Windows execution evidence must not silently authorize production cleanup.

## Implementation and acceptance

1. Build Windows targets; implement full identity, private records and shared-contract compatibility.
2. Connect WPF scope selection, rules, scans, candidate review and plans.
3. Validate explicit confirmation, recycling, history, restoration, cancellation and failure journals with generated fixtures.
4. Connect space analysis, large files and exclusions; expose only actual capabilities.
5. Validate native Windows APIs and UI, then signing, upgrades and clean installation.

`scripts/build-windows.ps1` builds the core and WPF client, runs generated native fixtures, process checks and real protocol integration. `scripts/package-windows.ps1` publishes self-contained .NET, copies SwiftPM resources and the PE dependency closure from explicit official runtime directories, writes SHA-256 inventory and probes the engine with a restricted runtime search path. Windows 11 supplies `winsqlite3.dll`. See [build instructions](../../apps/windows/README.md).

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

Verified on macOS arm64 with Swift 6.2.3 and .NET SDK 10.0.401:

- The complete WPF solution builds with zero warnings and errors. This validates compilation, not Windows rendering or interaction.
- All 11 real-process bridge checks pass, including UTF-8, output limits, strict JSON, timeout, confirmation and cooperative mutation cancellation.
- The real Swift protocol passes 105-directory pagination, disabled import/enablement, exclusions, space navigation, refused/foreign/mismatched/EOF consent, and confirmed native macOS Trash → history → restoration using generated fixtures.
- The core regression executable passes 191/191 cases, including full Windows identity/SID semantics, old-record compatibility, rejected volume rebinding and uncertain-result receipt/replay behavior.
- Documentation pairing and local links pass verification.

Not executed here: Windows Swift/C++ compilation, native ACL/junction/lock/Recycle Bin fixtures, PowerShell build/package scripts, the Windows CI job, WPF UI/accessibility, Windows 11 clean installation, signing and upgrades. Recycle Bin capabilities therefore remain disabled by default. Windows cleanup, restoration and production distribution are not accepted releases.
