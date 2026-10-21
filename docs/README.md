# Shou documentation

English | [简体中文](zh-CN/README.md)

Shou lets an existing coding agent turn a user's needs into inspectable, reusable cleanup rules. The agent asks focused questions and writes the rules; Shou validates, previews and executes them locally.

## Status and conventions

- Updated: 2026-10-21. Status: active development; the native application, core, and CLI have source implementations. Complete release acceptance remains pending.
- Confirmed constraints: native Swift macOS and C#/WPF Windows UI, independent desktop and CLI workflows, a monorepo, and no model integration or agent development. Windows remains a development implementation pending native acceptance.
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
| Build the native Windows client | [Windows stack, implementation and acceptance](engineering/windows.md) |

## Next version

[0.9.0 delivery plan and progress](engineering/next-version-0.9.0.md) tracks implementation, verification and remaining delivery gates item by item.

## Product principles

1. Agent-authored reusable rules and automatic discovery are the core product. The bundled Skill guides investigation without requiring users to write JSON or manage workspaces. Enabled rules join subsequent Smart Cleanup recommendations.
2. Rules update independently within existing engine capabilities.
3. Existing coding agents use public interfaces; Shou integrates no models, builds no agents, and uploads no data automatically.
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
