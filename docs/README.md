# Shou documentation

English | [简体中文](zh-CN/README.md)

Shou uses AI investigation of major storage consumers to turn user needs into inspectable, reusable cleanup rules, validated and executed deterministically on the device. The working tree contains a first built-in investigation implementation alongside external-agent/CLI/Skill access. Next work prioritizes the AI switch, Jev-first routing and native interaction.

## Status and conventions

- Updated: 2026-10-22. Status: active development; the native application, core, and CLI have source implementations. Complete release acceptance remains pending.
- Confirmed constraints: native Swift macOS and C#/WPF Windows UI, independent desktop and CLI workflows, a monorepo and one deterministic Core. Initial AI integrates an SDK and selected live services; the switch, Jev-first routing and contextual experience remain implementation work. Windows acceptance is separate.
- macOS 14+, module boundaries, rule fields, command names, and budgets are design baselines subject to recorded decisions.
- Performance, safety, language, and compatibility statements below are acceptance targets, not verified runtime capabilities.
- Example projects, paths, IDs, and capacity ranges are illustrative.

## Reading paths

| Goal | Documents |
| --- | --- |
| Install and enable complete scanning | [Installation and disk access](product/installation-and-access.md) |
| Understand the product | [PRD](product/prd.md) → [Unified daily cleanup](product/unified-cleanup.md) → [Stories and use cases](product/user-stories-and-use-cases.md) |
| Understand developer storage | [Developer scenarios](product/developer-space-scenarios.md) → [Rules](rules/rule-specification.md) |
| Inspect startup sources | [Startup discovery](product/startup-items.md) → [CLI contract](ai/agent-and-cli-contract.md) |
| Uninstall an application | [Application uninstall](product/application-uninstall.md) → [Safety](security/cleanup-safety.md) |
| Design the interface | [macOS experience](product/macos-experience.md) → [Reference design](engineering/reference-design.md) → [Workflows](architecture/workflows-and-sequences.md) |
| Plan localization | [Internationalization](product/internationalization.md) → [Acceptance](engineering/acceptance-and-testing.md) |
| Implement shared behavior | [Architecture](architecture/system-design.md) → [Data model](architecture/data-model.md) → [Rules](rules/rule-specification.md) |
| Understand platform boundaries | [Monorepo](architecture/monorepo-and-platforms.md) → [Architecture](architecture/system-design.md) |
| Support existing agents | [Agent workflow](ai/coding-agent-integration.md) → [CLI contract](ai/agent-and-cli-contract.md) → [Safety](security/cleanup-safety.md) |
| Install the agent Skill | [Skill installation and distribution](ai/skill-distribution.md) |
| Plan implementation | [Milestones](engineering/implementation-plan.md) → [Testing](engineering/acceptance-and-testing.md) |
| Build and verify locally | [Development guide](engineering/development.md) |
| Understand scan performance | [Storage scan performance and concurrency](engineering/storage-scan-performance.md) |
| Design space discovery for external agents | [Space analysis and proposed three-view workflow](engineering/space-analysis-agent-design.md) |
| Design AI interaction | [Stories, use cases and switch/UI contract](product/embedded-ai.md) → [Architecture, routing, flows and sequences](architecture/embedded-ai.md) → [Acceptance matrix](engineering/embedded-ai-acceptance.md) |
| Check AI delivery status | [Implementation and live evidence](engineering/embedded-ai-implementation.md) → [Protocol research/design](engineering/embedded-ai-investigation.md) |
| Select a cleanup Agent Core | [Related software, SDK comparison and prototype gates](engineering/agent-core-selection.md) (selection evidence; Swift AI SDK currently used) |
| Build the native Windows client | [Windows stack, implementation and acceptance](engineering/windows.md) |

## Next version

Built-in cleanup AI follows [AI01–AI10](engineering/implementation-plan.md), with AI07–AI10 covering switches, Jev First, contextual interaction and specialist acceptance. The [0.9.0 delivery plan and progress](engineering/next-version-0.9.0.md) continues to track existing implementation, verification and remaining delivery gates.

## Product principles

1. AI investigation and personal rules are central: the next-stage built-in Agent investigates major consumers, asks focused questions and proposes independent rules. External-agent/Skill access remains supported; enabled rules join subsequent Smart Cleanup recommendations.
2. Rules update independently within existing engine capabilities.
3. Built-in cleanup AI uses user-selected models and bounded investigation tools; external agents retain CLI/public rule access. Users explicitly enable investigation with provider/transmission scope explained; ordinary scans and cleanup remain offline-capable.
4. Rule validation never grants deletion permission; execution binds confirmation to a concrete plan.
5. Desktop interactions follow native platform conventions.
6. Occupied bytes, trashed bytes, and available-space changes remain distinct.
7. Desktop fixed rules use scan → Clean Recommended → one confirmation, with an explicit Trash or permanent action; custom desktop choices and CLI/agent automation expose the underlying preview/plan checkpoints.
8. Desktop and CLI independently complete that loop through shared services.
9. Applications, shared business logic, platform adapters, scripts, and documentation have explicit boundaries.
10. Documentation defaults to English; localized entry points and runtime translations are maintained against the same contracts.

## Documentation ownership

The PRD owns product scope and priorities. The rule specification owns matching semantics; the CLI contract owns machine interfaces. The data model owns entities and states. Safety applies across every entry point. Implementation and acceptance documents own milestones and required evidence.

Synchronize identifiers, states, fields, defaults, and safety constraints when changing either technical language edition. Render diagrams with a Mermaid-capable Markdown viewer.

- [Space analysis and explicit removal](product/space-analysis.md)

- [Reference capability map and implementation gates](engineering/reference-capability-map.md)

- [Privacy cleaning and source contracts](engineering/privacy-cleaning.md)
- [Operation progress and feedback](product/operation-progress.md)
- [Mole application inventory and rule coverage](engineering/mole-rule-coverage.md)
