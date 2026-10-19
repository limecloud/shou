# Shou documentation

English | [简体中文](zh-CN/README.md)

Shou turns personal cleanup decisions into inspectable, reusable rules for local workspaces.

## Status and conventions

- Updated: 2026-10-19. Status: design draft; application, engine, and CLI implementation are pending.
- Confirmed constraints: native Swift macOS UI, independent desktop and CLI workflows, a monorepo, future Windows support, and no model integration or agent development.
- macOS 14+, module boundaries, rule fields, command names, and budgets are design baselines subject to recorded decisions.
- Performance, safety, language, and compatibility statements below are acceptance targets, not verified runtime capabilities.
- Example projects, paths, IDs, and capacity ranges are illustrative.

## Reading paths

| Goal | Documents |
| --- | --- |
| Understand the product | [PRD](product/prd.md) → [Stories and use cases](product/user-stories-and-use-cases.md) |
| Understand developer storage | [Developer scenarios](product/developer-space-scenarios.md) → [Rules](rules/rule-specification.md) |
| Design the interface | [macOS experience](product/macos-experience.md) → [Workflows](architecture/workflows-and-sequences.md) |
| Plan localization | [Internationalization](product/internationalization.md) → [Acceptance](engineering/acceptance-and-testing.md) |
| Implement shared behavior | [Architecture](architecture/system-design.md) → [Data model](architecture/data-model.md) → [Rules](rules/rule-specification.md) |
| Understand platform boundaries | [Monorepo](architecture/monorepo-and-platforms.md) → [Architecture](architecture/system-design.md) |
| Support existing agents | [Agent workflow](ai/coding-agent-integration.md) → [CLI contract](ai/agent-and-cli-contract.md) → [Safety](security/cleanup-safety.md) |
| Plan implementation | [Milestones](engineering/implementation-plan.md) → [Testing](engineering/acceptance-and-testing.md) |

## Product principles

1. Personal rules and explicitly selected workspaces are the core product.
2. Rules update independently within existing engine capabilities.
3. Existing coding agents use public interfaces; Shou integrates no models, builds no agents, and uploads no data automatically.
4. Rule validation never grants deletion permission; execution binds confirmation to a concrete plan.
5. Desktop interactions follow native platform conventions.
6. Occupied bytes, trashed bytes, and available-space changes remain distinct.
7. The initial loop is workspace → scan → rule → preview → confirmation → receipt.
8. Desktop and CLI independently complete that loop through shared services.
9. Applications, shared business logic, platform adapters, scripts, and documentation have explicit boundaries.
10. Documentation defaults to English; localized entry points and runtime translations are maintained against the same contracts.

## Documentation ownership

The PRD owns product scope and priorities. The rule specification owns matching semantics; the CLI contract owns machine interfaces. The data model owns entities and states. Safety applies across every entry point. Implementation and acceptance documents own milestones and required evidence.

Synchronize identifiers, states, fields, defaults, and safety constraints when changing either technical language edition. Render diagrams with a Mermaid-capable Markdown viewer.
