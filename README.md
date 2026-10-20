<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>A little more room on your Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

A native macOS cleaner with cleanup rules tailored by your existing AI agent. Tell Codex, Claude Code, or WorkBuddy what takes space and what to keep; it asks the missing questions and drafts reusable rules. Shou scans, validates, previews, and cleans locally.

## Download and install

Download Shou v0.5.0 for **macOS 14 or later**. The universal app runs on Apple Silicon and Intel Macs. Open the disk image and drag **Shou.app** into **Applications**. The interface is available in English and Simplified Chinese.

[**Shou v0.5.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.5.0/Shou-0.5.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.5.0/Shou-0.5.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.5.0/shou-0.5.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

This release uses an ad-hoc signature and is not Apple-notarized. If macOS blocks the first launch, check the download source, then review **System Settings → Privacy & Security → Open Anyway**.

The first-use guide explains Full Disk Access and optional CLI installation. You can continue with accessible folders and revisit **Settings → Setup Guide** at any time. See [installation and permissions](docs/product/installation-and-access.md).

## What Shou can do

| | |
| --- | --- |
| **Agent-authored cleanup** | Use the bundled Skill to investigate your own caches and build outputs, answer focused questions, and preview rules without writing JSON. |
| **Application uninstall** | Compare sizes and activity, expand exact components inline, select several apps and confirm once. Personal data needs separate consent; Trash items support restoration. |
| **Startup items** | Inspect startup definitions, manage current-user LaunchAgents with explicit confirmation, and open macOS Login Items settings for the remaining sources. |
| **Exclusions** | Protect folders globally or within a project, and edit personal rules as disabled revisions. |
| **Application caches** | Review caches from browsers, chat apps, editors, and tools, including Chrome, Edge, Firefox, Codex, Claude, QQ, and WeChat. |
| **Developer tools and projects** | Find npm, Cargo, Xcode, Python, and Go caches, Rust target directories, Node.js dependencies, and Swift build products. |
| **Large files** | Filter a saved scan by size and file type, preview files, select all matches across pages, and clean the exact selection. |
| **Space analysis** | Scan disks or folders, select files in the list or treemap, and remove or restore explicit items. |
| **Personal rules** | Let your coding agent draft rules for your own rebuildable folders, preview matches, and reuse reviewed rules. Manual import/editing remains available under Advanced. |
| **History and recovery** | Check results, restore selected items, or separately confirm permanent removal of this cleanup batch. |
| **Online updates** | Check for updates from Settings or the Shou menu. Updates are signature-verified before installation. |

## Clean up in three steps

1. **Scan** app caches, automatically discovered developer folders, and remembered locations together.
2. **Review** the recommended paths and rebuild costs. Built-in and enabled personal rules participate automatically.
3. **Confirm** once to clean and free space. Permanent deletion is the default; Move to Trash is an explicit alternative.

No workspace setup or per-project selection is required. Enable an Agent-authored rule once to include it in future cleanups. [Unified daily cleanup](docs/product/unified-cleanup.md) explains discovery and scope. Permanent removal cannot be undone; moving items to Trash does not immediately free disk space. Protected content, exclusions, running apps and active builds can block affected targets.

## Your files, your choice

Rules run locally and cannot execute shell commands. No account, model connection, or cloud scan is required. Rules and cleanup history stay on your Mac.

## Customize with your agent

In **Rules → Customize with AI**, select Codex or Claude Code and install the Skill, or export a ZIP to upload in WorkBuddy. Copy the prepared request into your existing coding agent. It reads the shipped [Shou Skill](skills/shou-rule-authoring/SKILL.md), investigates the chosen directory, asks about rebuild steps and keep paths, then validates, imports, and previews a disabled rule. You decide when to enable it and clean. Shou integrates no model and hosts no agent.

Install for the client you use, or read the instructions without installation:

```sh
"/Applications/Shou.app/Contents/Helpers/shou" skills install --agent codex --json
"/Applications/Shou.app/Contents/Helpers/shou" skills read --json
```

Use `$shou-rule-authoring` in Codex or `/shou-rule-authoring` in a local Claude Code session. See [installation and client instructions](docs/ai/skill-distribution.md). Mixed roots such as `Documents`, `Library`, `.codex`, `.colima`, `.nvm`, `.rustup`, `.local`, `go`, and `.cargo` need child-level analysis. They are not universal delete targets. See the [agent workflow](docs/ai/coding-agent-integration.md).

## Terminal

The app includes an independent CLI for rules, scans, plans, and history. Cleanup and recovery require interactive confirmation.

To make `shou` available in your terminal, run `python3 "scripts/install-cli.py"` from a source checkout after installing the app. It creates `~/.local/bin/shou` without editing shell settings; the entry follows app updates. See [CLI installation](docs/engineering/development.md#install-a-terminal-entry).

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Documentation and contributions

Source builds, tests, rule examples, and CLI usage are covered in the documentation. Report problems and ideas through Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

Privacy cleaning has a separate source/time-range workflow for supported history and Cookie schemas, with sign-out consent and aggregate receipts. See [support and limits](docs/engineering/privacy-cleaning.md).

## Acknowledgements

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

[Lark CLI](https://github.com/larksuite/cli) and [Vercel Skills](https://github.com/vercel-labs/skills) informed Skill distribution and discovery.

## License

[Apache License 2.0](LICENSE).

Space analysis supports local volumes and folders, linked list/treemap navigation, multi-selection, Trash/restore and explicitly confirmed permanent removal. See [space analysis](docs/product/space-analysis.md).

Mole path research, attribution and explicit coverage limits: [rule coverage](docs/engineering/mole-rule-coverage.md).
