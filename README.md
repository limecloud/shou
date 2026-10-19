# Shou · 收

**Tidy up. That’s it.**

A native macOS cleaner with inspectable, reusable rules for development projects and applications.

English · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

> **Status: design stage.** The application and CLI are not available yet. Features and commands below describe the planned product. See the [implementation plan](docs/engineering/implementation-plan.md).

## Why Shou

Build outputs, installed dependencies, and temporary directories accumulate across projects. On a 500 GB Mac, finding and evaluating the same directories repeatedly can become a daily task.

Personal tools and project layouts rarely fit a fixed cleanup catalog. Shou turns a reviewed cleanup decision into a reusable rule:

**Discover → Understand → Define a rule → Preview → Confirm → Reuse.**

Rules can change without an application release when the current rule format can express them. New engine capabilities still require an upgrade.

## Planned capabilities

| Capability | Purpose |
| --- | --- |
| Project space analysis | Find large directories and distinguish artifacts, dependencies, source, and unclassified data |
| Personal rules | Describe custom tools, project layouts, retention conditions, and exclusions |
| Explainable previews | Inspect exact paths, matching evidence, size estimates, risks, and rebuild costs |
| Independent CLI | Manage rules, scan, review plans, confirm cleanup, and inspect history without the desktop app |
| Agent-friendly interfaces | Let existing Codex, Claude Code, WorkBuddy, and similar tools add rule drafts through CLI and JSON |
| Reusable presets | Save reviewed selection logic and rescan before each cleanup |
| Native desktop experience | Swift and SwiftUI with AppKit integration; Windows is a future platform target |

The initial focus is developer workspaces: Rust `target`, Node.js project caches, reviewed `node_modules`, and personally verified `dist` or Electron outputs. Uninstalling applications, broader cache templates, and startup management follow later.

## Review before cleanup

- Scan explicitly selected workspaces; rules cannot expand operating-system permissions.
- Import generated rules as disabled drafts, then validate and preview them.
- Separate scanning, immutable plans, confirmation, and execution.
- Move items to Trash by default. Permanently removing this cleanup batch requires a separate confirmation.
- Report moved bytes separately from observed available disk space.
- Preserve protected data and exclusions; directory names or sizes alone never establish cleanup eligibility.

See [cleanup safety](docs/security/cleanup-safety.md) for constraints and limitations.

## Architecture

- **Native macOS:** Swift, Swift 6 concurrency checking, SwiftUI, and AppKit.
- **Shared core:** portable Swift business logic with separate platform filesystem adapters.
- **Two independent entry points:** desktop and CLI share rules, plans, policies, and history.
- **Open rules:** versioned declarative JSON; no embedded Shell or executable scripts.
- **Local data:** no required account, cloud scanning, or default telemetry in the initial scope.
- **Agent boundary:** Shou integrates no models and develops or hosts no agents. Existing tools operate its public CLI.
- **Monorepo:** applications in `apps/`, shared components and contracts in `packages/`.
- **Platforms:** macOS first, with macOS 14+ as the provisional baseline; native Windows support requires separate implementation and validation.
- **Internationalization:** English documentation by default, localized READMEs, and Simplified Chinese technical documentation. Runtime languages have separate release criteria.

## Documentation

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md)

| Document | Scope |
| --- | --- |
| [Product requirements](docs/product/prd.md) | Background, objectives, benefits, requirements, and scope |
| [User stories and use cases](docs/product/user-stories-and-use-cases.md) | Desktop, terminal, personal rules, and failure scenarios |
| [Developer space scenarios](docs/product/developer-space-scenarios.md) | Rust, Node.js, build outputs, and inactive projects |
| [macOS experience](docs/product/macos-experience.md) | Native navigation, tables, inspectors, and accessibility |
| [Internationalization](docs/product/internationalization.md) | Language coverage, localization, terminology, and locale contracts |
| [System architecture](docs/architecture/system-design.md) | Shared services and platform boundaries |
| [Monorepo and platforms](docs/architecture/monorepo-and-platforms.md) | Repository layout and the Windows roadmap |
| [Workflows and sequences](docs/architecture/workflows-and-sequences.md) | Discovery, rules, confirmation, execution, and recovery |
| [Data model](docs/architecture/data-model.md) | Rules, snapshots, plans, and execution receipts |
| [Rule specification](docs/rules/rule-specification.md) | Declarative matching semantics and examples |
| [CLI contract](docs/ai/agent-and-cli-contract.md) | Discovery, commands, JSON, and errors |
| [Existing-agent workflow](docs/ai/coding-agent-integration.md) | Adding rules through existing coding agents |
| [Cleanup safety](docs/security/cleanup-safety.md) | Permissions, protection, races, Trash, and recovery |
| [Implementation plan](docs/engineering/implementation-plan.md) | Milestones, decisions, and unresolved questions |
| [Acceptance and testing](docs/engineering/acceptance-and-testing.md) | Required evidence and release gates |

## Development and contributions

The repository currently contains documentation, draft contracts, and rule examples. Application projects and build commands will be added during implementation.

Report concrete cleanup scenarios through [Issues](https://github.com/limecloud/shou/issues). Describe the toolchain, directory purpose, rebuild requirements, and retention needs. Remove personal and customer information from shared paths.

Translations are welcome. Keep commands, identifiers, safety constraints, and product status consistent across languages. See the [internationalization specification](docs/product/internationalization.md).

## Acknowledgements

- [Mole](https://github.com/tw93/mole) — developer-oriented terminal workflows and multilingual project presentation.
- [Pulse](https://pulse.egoist.dev/) — clear native macOS information design and space summaries.
- [BuhoCleaner](https://www.drbuho.com/buhocleaner) — disk exploration and grouped cleanup presentation.

These acknowledgements recognize product and design inspiration; they do not imply affiliation or code dependencies.

## License

[Apache License 2.0](LICENSE).
