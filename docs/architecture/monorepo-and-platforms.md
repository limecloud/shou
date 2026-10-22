# Monorepo and platform boundaries

English | [简体中文](../zh-CN/architecture/monorepo-and-platforms.md)

Status: active implementation. macOS ships first; the native Windows development implementation has separate acceptance gates.

## 1. Organization principles

Organize native entry points, shared business logic, platform adapters, contracts, scripts, documentation, examples, and assets separately. Native interfaces consume shared behavior rather than reimplement rules. A structured process bridge can cross language boundaries.

Next-stage built-in cleanup AI separates investigation, model adaptation and credentials according to the [architecture](system-design.md); SDK types stay outside rules/execution. Mobile projects and general agent hosting are outside this stage. Build success, native runtime success and complete distribution acceptance remain separate evidence.

## 2. Target layout

The root Swift package builds macOS/CLI/core/platform and Windows-native check targets. The WPF client uses its own .NET solution. See [local development](../engineering/development.md) and [Windows implementation](../engineering/windows.md).

```text
shou/
├── apps/
│   ├── macos/                  Swift / SwiftUI / AppKit
│   ├── cli/                    Swift CLI with current-platform adapters
│   └── windows/                C# / .NET 10 / WPF Fluent / MVVM
├── packages/
│   ├── shou-core/              Portable domain services and state machines
│   ├── shou-platform/          Concrete filesystem and permission adapters
│   └── shou-contracts/         Schemas and language-independent contracts
├── tests/fixtures/             Fictional filesystem and protocol cases
├── scripts/                    Verification, build, package, benchmark
├── examples/rules/             Reviewable declarative rules
├── skills/                     ShouAgentSupport and bundled rule-authoring Skill
├── assets/brand/               Brand sources
├── docs/                       English and localized technical docs
├── README.md
└── LICENSE
```

Use local SwiftPM dependencies for Swift packages and an Xcode project/workspace where signing/resources require it. A monorepo does not require one build tool for every language, JavaScript workspaces, or a web interface.

## 3. Dependency direction

```mermaid
flowchart TB
    Mac[apps/macos] --> Core[packages/shou-core]
    Mac --> Platform[packages/shou-platform]
    CLI[apps/cli] --> Core
    CLI --> Platform
    Mac --> AgentSupport[skills / ShouAgentSupport]
    CLI --> AgentSupport
    Platform --> AgentSupport
    Windows[apps/windows WPF] -.JSON process bridge.-> CLI
    Core --> Protocols[Core-owned capability protocols]
    Platform --> Protocols
    Contracts[packages/shou-contracts] -.Machine definitions.-> Core
    Contracts -.Discovery and results.-> CLI
```

Core owns its required protocols; adapters depend on core and implement them. Schema files are authoritative data contracts, not a runtime service. Avoid scattered platform conditionals throughout domain logic.

`ShouAgentSupport` owns bundled instruction resources and reads, independently of the cleanup engine. `ShouPlatform` owns local Skill installation and macOS ZIP export; desktop and CLI share those operations. Client loading contracts and diagrams are in [Skill distribution](../ai/skill-distribution.md).

## 4. Shared versus platform responsibilities

| Shared core | Platform adapters |
| --- | --- |
| Rules, versions, provenance, normalization | Permission panels, TCC/ACLs, access credentials |
| Pattern/condition semantics and risk | Traversal, identities, links, volume boundaries |
| Exclusions, deduplication, immutable plans | Allocated-size and volume-availability queries |
| Confirmation binding and state machines | Trash/Recycle Bin, restoration, permanent removal |
| Structured errors, results, next actions | Locks, durable writes, process cancellation, data roots |

Portable Foundation usage must be verified on Windows. Shared code must not import SwiftUI, AppKit, Darwin, or Win32 directly.

## 5. Windows direction

Windows uses a native desktop UI and `shou.exe`, with the same rule, plan, error, and state semantics. Platform-specific rules declare their applicability.

Prefer a structured process bridge to the shared Swift CLI rather than an early Swift/C# ABI bridge or duplicate engine. Use argument arrays, bounded JSON stdin/stdout, explicit exit handling, and no concatenated Shell command.

The UI decision is C# / .NET 10 LTS / WPF Fluent / MVVM, reusing the structured-process practice from Zhiban. The initial target is Windows 11 x64 with Swift 6.2.3. Full File ID/SID, ACL, LockFileEx and IFileOperation adapters are implemented; native behavior and distribution still require Windows evidence.

The request-scoped confirmation bridge binds a one-use challenge and digest. Read operations cancel their owned process; mutations stop cooperatively with durable receipts. Recycle Bin mutations default to unavailable pending native acceptance. See [protocol and verification boundaries](../engineering/windows.md). Swift language support does not make Apple frameworks portable.

## 6. Path contract

Rules use `/`-separated relative patterns. Reject absolute paths, `..`, drive/UNC/device syntax, and alternate-data-stream syntax. Respect actual filesystem case behavior and identity rather than string folding.

Do not follow root/ancestor symlinks, junctions, or unknown reparse points. Known internal POSIX symlinks are opaque entries. Never cross volumes, including mount points. Cloud placeholders and network volumes are outside the initial executable scope.

## 7. Capability discovery

Expose platform, build, contract versions, actual supported operations, and reasons for unavailable capabilities. Recycle Bin and permanent removal are separate explicit operations; a failed Recycle Bin implementation must never silently fall back to permanent deletion.

The rule schema accepting `windows` expresses applicability only. Windows support requires native build, runtime, filesystem-safety, UI, and clean-install evidence.

## 8. Repository and release boundaries

Review entry points and contracts together. Keep application and rule-format versions distinct. Do not commit real workspace scans or generated distributions as fixtures. Verify macOS signing/notarization and Windows signing/runtime/installation independently.

Skill copying is explicitly initiated by the user. Integration does not install global plugins or edit coding-agent settings files.

## 9. Evolution

Define contracts and minimal interfaces, implement the macOS CLI loop, then native UI. Check core portability continuously. Prototype the Windows core/CLI before native adapters and UI. Reuse fictional semantic fixtures while independently testing platform behavior.

Isolate real dependencies now; avoid a speculative universal plugin framework.
