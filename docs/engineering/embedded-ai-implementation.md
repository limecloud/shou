# AI implementation boundaries

English | [简体中文](../zh-CN/engineering/embedded-ai-implementation.md)

Status: the macOS desktop and Swift CLI have investigation source implementations. Windows investigation is planned as a separate .NET service.

## Current modules

`packages/shou-ai` owns routing, bounded provider transports and investigation orchestration. `packages/shou-core` owns evidence and rule/cleanup contracts. `packages/shou-platform` owns local credentials and records. The macOS desktop owns contextual entry points, questions, state rendering and settings. The CLI supports independent configuration, testing, investigation, continuation and cancellation.

Connections separate protocol, API root, model and credential reference. Credentials do not appear in command arguments, saved investigation output or ordinary diagnostics. Local handling, optional structured decision services and the selected main model report actual usage independently. Offline rules and cleanup remain available.

## Execution boundary

AI output is untrusted. A proposal becomes a disabled rule draft, passes the closed parser, receives an independent preview and needs explicit enablement and a fresh scan. Model output cannot bypass protection, confirmation, expiry or native identity verification.

Cancellation revokes future requests and preserves actual task state. Provider errors, incomplete evidence, unavailable credentials and exhausted budgets remain distinct from completion. Investigations must not silently resend evidence to a different provider.

## Verification

Run `python3 scripts/verify-ai-investigation.py` after the Swift build for generated loopback-provider checks. Core tests cover scope, provider replacement, revocation and private credentials. These establish their actual synthetic scope; live service compatibility, model quality, native interaction, accessibility and distribution require separate evidence in the [acceptance matrix](embedded-ai-acceptance.md).

## Windows implementation

Use independent .NET orchestration and native credential adapters, aligned with the same product states, disclosures and rule contract. Do not adopt the Swift SDK as a Windows runtime dependency. Implement after the read-only Windows foundation and record parity in [SYNC.md](../../SYNC.md).
