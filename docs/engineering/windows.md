# Native Windows implementation

English | [简体中文](../zh-CN/engineering/windows.md)

## Technology decision

Use C#, .NET 10 LTS, WPF with its Fluent theme, and MVVM presentation state. Keep rules, exclusions, scan orchestration, plans, execution state machines and receipts in the existing Swift core. The Windows UI accesses the bundled `shou.exe` through a versioned JSON process protocol. Win32/COM belongs to platform adapters; C# does not duplicate the rule engine.

The Zhiban project informs the native UI separation, structured process bridge and real subprocess tests. Shou independently implements file identity, cleanup consent, Recycle Bin operations and restoration. Its Windows product does not require Zhiban's mathematics reader, WebView2, Python, receiver or model integration.

The initial validation target is Windows 11 x64. ARM64, older Windows releases, network volumes, cloud placeholders and cross-volume operations require separate evidence.

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

A failed Recycle Bin operation must not fall back to permanent deletion. Restoration must not overwrite an existing destination. Revalidate tree and identity evidence before mutation, journal intent first, and persist the observed outcome. Unknown outcomes remain unknown and are not automatically retried. Windows race boundaries, recycle receipts and system behavior require native validation.

## Desktop process protocol

The desktop bridge uses the shared core without fabricating terminal input or adding a global `--yes` switch. Confirmation binds an operation, plan or receipt digest, exact selection, one-use challenge and expiry within the same process. Changes invalidate consent. Public CLI mutation keeps its interactive current-scope terminal review.

Use a bundled absolute executable path, argument arrays, UTF-8 JSON, bounded input/output and structured errors. stdout is protocol-only; stderr is drained concurrently with bounded retained diagnostics. Read requests may terminate their owned process on cancellation or timeout. Mutations request cooperative cancellation and stop at item boundaries with durable receipts. A timeout does not prove that nothing changed.

## Implementation and acceptance

1. Build Windows targets; implement full identity, private records and shared-contract compatibility.
2. Connect WPF scope selection, rules, scans, candidate review and plans.
3. Validate explicit confirmation, recycling, history, restoration, cancellation and failure journals with generated fixtures.
4. Connect space analysis, large files and exclusions; expose only actual capabilities.
5. Validate native Windows APIs and UI, then signing, upgrades and clean installation.

Distribution must include .NET, Swift runtimes, SQLite dependencies and resources. End users must not need a developer toolchain. Development output, cross-compilation, macOS bridge tests and configured Windows CI are separate from clean-system installation evidence.

## Official references

- [WPF overview](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/)
- [WPF Fluent theme](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net90)
- [MVVM Toolkit](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/)
- [Swift Windows installation](https://www.swift.org/install/windows/)
- [Windows file identity](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)
- [Security identifiers](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-identifiers)

## Verification status

Implementation and checks performed for this change will be recorded before delivery. Windows cleanup, restoration and production distribution remain unverified until native execution evidence exists.
