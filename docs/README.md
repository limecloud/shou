# Shou documentation

English | [简体中文](zh-CN/README.md)

Shou provides storage analysis, reviewable cleanup and reusable rules. AI investigation is optional; deterministic services own validation, confirmation and execution.

## Current platform status

| Area | Status |
| --- | --- |
| macOS | SwiftUI/AppKit application, Swift domain services and independent CLI have source implementations; acceptance remains evidence-specific |
| Windows | C# / .NET 10 LTS / WinUI 3 portable previews; x64/ARM64 native suites and window startup passed (SYNC.md); full UI and signed distribution pending |
| Runtime languages | Simplified Chinese and English |
| Documentation | 11 README languages; English and Simplified Chinese technical editions |

## For users and product contributors

| Goal | Read |
| --- | --- |
| Install and enable scanning | [Installation and access](product/installation-and-access.md) |
| Understand product scope | [PRD](product/prd.md) → [Daily cleanup](product/unified-cleanup.md) → [User stories](product/user-stories-and-use-cases.md) |
| Explore storage | [Space Analysis](product/space-analysis.md) → [Developer scenarios](product/developer-space-scenarios.md) |
| Manage applications and developer projects | [Apps & Projects](product/apps-and-projects.md) |
| Manage developer environments and AI software | [Developer Tools](product/developer-tools.md), [AI Workbench](product/ai-workbench.md), [Full capability map](engineering/developer-tool-capability-map.md), [Per-software adapters](engineering/developer-tool-adapters.md) |
| Inspect live resources and processes | [System monitor and desktop summaries](product/system-monitor.md) |
| Manage applications or startup | [Application cleanup](product/application-uninstall.md), [Update discovery and software upgrades](product/application-updates.md), [Startup](product/startup-items.md) |
| Understand AI and rules | [AI journeys](product/embedded-ai.md), [Rule specification](rules/rule-specification.md) |
| Understand safety and results | [Cleanup safety](security/cleanup-safety.md), [Progress](product/operation-progress.md) |

## For engineers and AI development

| Task | Required reading |
| --- | --- |
| Establish module ownership | [System architecture](architecture/system-design.md) → [Platform boundaries](architecture/monorepo-and-platforms.md) |
| Implement a workflow | [Flows and sequences](architecture/workflows-and-sequences.md) → [Data contracts](architecture/data-model.md) |
| Build the Windows application | [Windows overview](engineering/windows.md) → [Native implementation plan](engineering/windows-native-plan.md) → [SYNC.md](../SYNC.md) |
| Build and validate macOS | [Development](engineering/development.md) → [Acceptance](engineering/acceptance-and-testing.md) |
| Plan delivery | [Implementation plan](engineering/implementation-plan.md), [Capability ownership](engineering/capability-plan.md), [Cleanup delivery](engineering/cleanup-delivery.md) |
| Plan the next release | [Capability improvements, priorities and development packages](engineering/next-release-plan.md) |
| Diagnose and use terminal support | [Read-only reports, privacy and shell completion](engineering/user-diagnostics.md) |
| Implement native presentation | [Interface design](engineering/interface-design.md), [macOS experience](product/macos-experience.md), [Localization](product/internationalization.md) |
| Improve scan and deletion performance | [Implementation and measurements](engineering/storage-scan-performance.md), [Research report](engineering/storage-performance-research.md), [Architecture proposal](engineering/storage-performance-architecture.md), [Space investigation](engineering/space-analysis-agent-design.md) |
| Work on AI | [AI architecture](architecture/embedded-ai.md) → [Implementation boundaries](engineering/embedded-ai-implementation.md) → [Acceptance](engineering/embedded-ai-acceptance.md) |
| Integrate external agents | [CLI contract](ai/agent-and-cli-contract.md), [Agent integration](ai/coding-agent-integration.md), [Skill distribution](ai/skill-distribution.md) |
| Maintain rules | [Schema](../packages/shou-contracts/rule.schema.json), [Rule coverage](engineering/rule-coverage.md) |
| Release | [Signing, packaging and updates](engineering/releasing.md) |
| Distribute the CLI through npm | [Unified npm entry and platform packages](engineering/npm-distribution.md) |

## Documentation contract

The PRD owns scope; rules own matching semantics; safety constrains all entry points; data contracts own identities/states; CLI documentation owns public machine operations. Native implementation plans own module and toolchain decisions. Keep each fact in its owning document and link to it.

Read the relevant contracts before code changes. Implement the smallest complete slice, update shared resources through their source, and record actual tests with revision, OS, architecture and limitations. Update both technical editions and the platform ledger together. Source, build success, runtime behavior and release acceptance are separate statuses.

MySQL administration: [instance, schema, account, configuration and backup contract](product/mysql-administration.md).
