# Tool management reference review

English | [简体中文](../zh-CN/engineering/tool-management-review.md)

Reviewed on 2026-10-26 using supplied screenshots, read-only FlyEnv source and public CC Switch `main`. Reference implementations, Electron/Vue/Rust code, scripts and visual assets were not executed or incorporated. Shou retains its native SwiftUI/AppKit and WinUI/.NET boundaries.

FlyEnv declares seventeen categories and distinct Homebrew, MacPorts, SDKMAN, local and archive installation paths. Its `Base/index.ts` online/archive pipeline and Nginx service/configuration/log implementation establish capabilities beyond one package command. Visibility and actual service activity are independent states.

The CC Switch reference `package.json` reports 4.0.21; this is source analysis of the observed branch, not a shipped-artifact claim. Its README distinguishes provider switching/coexistence, MCP, Skills, prompts, sessions and usage. `commands/misc.rs` enumerates installations and npm mappings; `tool_uninstall.rs` anchors a plan to each installation without a different-manager fallback; `tool_node_requirement.rs` checks target Node requirements. Runtime probes and shell installers are reference evidence, not implementations suitable for direct reuse.

Observed source identities and reference digests are retained in `output/reviews/developer-tools-2026-10-26/`. Unverified references do not produce installer actions; static observations do not replace execution-time checks.

| Reference idea | Shou decision |
| --- | --- |
| Tool/source/version hierarchy | Catalog, Installed and My Workspace with native details/review |
| Visibility switches | Favorites affect presentation only, separately from installation/service/login state |
| Multiple copies | Preserve locations and versions; deduplicate proven manager-directory aliases |
| CLI version probes | Initially read registration/npm metadata without executing discovered programs; runtime health stays unknown |
| Source-specific removal | Connected sources only; no arbitrary-directory deletion fallback |
| AI management | Separate AI Workbench; credentials/configuration require independent adapters and authority |
| Complete environment services | Track outstanding service/site/database/container/certificate/task work explicitly |

Small native domain/platform interfaces do not introduce a shared shell engine. Catalog, localization and design resources remain canonical. Generated fixtures establish arguments, authorization, journals, outcomes and retained-data semantics, not every real package, native installer, runtime or advanced feature. The Windows native-installer gate stays closed pending separate acceptance. Actual platform/source/screenshot evidence is tracked in [SYNC.md](../../SYNC.md).

The newer screenshot request takes precedence over card layouts. FlyEnv `src/render/core/ASide.ts` routes `switchChange` to module start/stop; its capsule is a service action, not a favorite. Shou adopts the grouped rail plus persistent source/version table for both developer and AI tools, binds each switch to a verified installation, and awaits real state while preserving login registration. The macOS generated-manager tests and Windows SCM source/gate do not establish full native service acceptance.

## Packaged REA and complete source inventory, 2026-10-26

Installed FlyEnv is 4.18.2; the clean checkout is 4.20.2 at `1d63e3300628eb1a4aa14050d3a3319fce527119`. Source review inventories all seventeen categories, 71 root routes and 38 internal utilities, with separate [UI](../../output/reviews/developer-tools-2026-10-26/flyenv-source-ui.md), [service](../../output/reviews/developer-tools-2026-10-26/flyenv-source-services.md) and [AI](../../output/reviews/developer-tools-2026-10-26/flyenv-source-ai.md) ledgers. These are static source findings, not runtime acceptance.

REA CLI 6.7.0 inspected the installed ASAR (SHA-256 `85120a41680fb11c137ef1549b99b40fb3b9d3e4b84e3247735c06d3cbc582d6`): manifest/main/fork and 82 service-related renderer sources. Evidence IDs are `ev_5151fcbd2d9af721209c3063c8721547f4a08c416af376ba5a5ab2c4ce6786dd` and `ev_7f186816388e3a6eac04c7aaa03bf481e04d825b169abbf75e8edf54451f4a07`. Complete package inventory is distinct from selected source analysis; accumulated result limits left some renderer semantic analysis unstarted. Ten unpacked native integrity contradictions were retained as untrusted observations, never executed. Full evidence and the initial refusal remain in `.build/references/flyenv/`; the [portable summary](../../output/reviews/developer-tools-2026-10-26/flyenv-reference-evidence.json) preserves limits. Existing CLI was used without changing global MCP registration or installing engines.

Computer Use only viewed the already-running 4.18.2 Nginx service page, its stop/restart actions and configuration/log tabs. No reference mutation was clicked. Its self-managed Nginx was running while Homebrew reported its own job stopped, corroborating why installation origin and service lifecycle are separate. Ordinary AI CLI installation and copied commands do not imply daemon support; OpenClaw/Hermes gateways have distinct lifecycles. Configuration mutation, provider switching, skill edits and database deletion remain independent permissions.

## Per-software review and adapters, 2026-10-27

The new [module capability review](../../output/reviews/developer-tools-2026-10-26/flyenv-module-capabilities-detail.md) indexes 71 roots and details 59 non-AI modules, with 385 source references bound to an exact commit. Separate [installation/AI](../../output/reviews/developer-tools-2026-10-26/flyenv-install-ai-detail.md) and [service UX](../../output/reviews/developer-tools-2026-10-26/flyenv-service-ux-detail.md) reviews distinguish MySQL database/grants, password records/maintenance, backups and groups; Mailpit Static uses an intermediate history API whose server-side asset filtering remains unknown. ENV, manager defaults, aliases and notes are separate capabilities.

Additional packaged REA selected four Mailpit/MySQL/group/phpMyAdmin renderer sources: 21,314 bytes, 5,763 AST nodes, no parse failures; evidence `ev_bdde0d876ad63f42a0d92e6649573f057919e3fa938e058dad7d88b8b798c2eb`. Semantic coverage remains partial. Two semantic traces of a fork stop function retained only the seed and established no full call edges; behavioral findings rely on explicit source chains, not a claim of complete decompilation. No reference service or downloaded program was executed.

[Per-software adapter design](developer-tool-adapters.md) separates installation sources, runtime lifecycle, dedicated business capabilities and native views. Four small recipe strategies reuse shared authorization/journals and lifecycle logic. Views share visual/state semantics and compose connected tasks without using a generic installation list as a substitute for complete management.

## Current source scope refresh, 2026-10-27

The reference checkout is now `71288acf873fbade9889b14c25c78561362d9aab`, still marked 4.20.2. Two subsequent commits change twenty files; root registration and views are unchanged. This refresh checks 71 roots, 38 internal utilities and the separate counting boundaries for Composer/Maven, toolchain managers, plugins and custom modules. Changed code includes adjustable common stop deadlines, dedicated Consul/Neo4j/Cloudflare Tunnel waiting, and ClickHouse companion error handling.

The [current report](../../output/reviews/developer-tools-scope-2026-10-27/REPORT.md) records capabilities and Shou gaps for every root; the [full domain map](developer-tool-capability-map.md) is the scope entry point. Complete source is inspected with ordinary repository tools as required by the REA skill, reusing prior call-chain evidence for unchanged files. No reference software was executed and no new binary analysis or native acceptance is claimed. File fingerprints do not establish function-level semantic coverage.
