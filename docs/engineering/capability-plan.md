# Capability ownership and delivery

English | [简体中文](../zh-CN/engineering/capability-plan.md)

## Product boundaries

| Capability | Domain responsibility | System-specific responsibility | Acceptance |
| --- | --- | --- | --- |
| Storage analysis | Accounting, paging, coverage, exact selection | Enumeration, identity and allocated size | Partial results remain honest; stable pagination and bounded cancellation |
| Daily cleanup | Rules, exclusions, ownership gates and plans | Access, application activity and native mutation | Current complete targets only; durable item outcomes |
| Personal rules | Closed schema, disabled import, preview and enablement | Explicit scope access | Cannot broaden scope or override protected data |
| Tool-managed cleanup | Fixed typed operations and impact disclosure | Pinned local executable, context and bounded output | No arbitrary command execution or remote context |
| Applications | Exact ownership and independent personal-data consent | Bundle or installer/registry semantics | Unknown owners remain unknown; explicit per-platform scope |
| Startup | Registration state and supported control review | OS-specific registration/query/control APIs | No inferred running/enabled state or unsupported mutation |
| Privacy | Explicit source, time range and sign-out consent | Profile access, database locks and schema | Narrow records only; no broad profile deletion |
| AI investigation | Evidence budgets, questions, routing and disabled drafts | Credentials and model transport | Offline cleanup works; no model mutation authority |
| History | Durable intent, per-item outcome and protected references | Private storage, atomic writes and locks | Interrupted work reconciled; restore never overwrites |

## Delivery policy

Implement one vertical slice from native entry to domain, platform and recorded result. Domain tests and native tests provide different evidence. Add pages only when their domain and platform behavior are available. User-facing availability reflects verified capability.

macOS uses Swift services; Windows uses independent C# services under its [implementation plan](windows-native-plan.md). Shared contracts and generated assets align behavior. Track every safety change and intentional difference in [SYNC.md](../../SYNC.md).

## Priorities

Prioritize scan correctness, bounded work, exact-scope confirmation, durable outcomes and recovery before expanding coverage. Retention must protect active plans and recovery evidence. Performance changes require complete-result parity and cancellation checks. Distribution requires clean-machine installation and update evidence for each supported architecture.
