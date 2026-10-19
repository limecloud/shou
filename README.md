<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>A little more room on your Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

A native macOS cleaner for application caches, development projects, and the folders that keep growing. See what takes space, review what can go, and keep your cleanup rules for next time.

## Download and install

Download Shou v0.2.0 for **macOS 14 or later**. The universal app runs on Apple Silicon and Intel Macs. Open the disk image and drag **Shou.app** into **Applications**. The interface is available in English and Simplified Chinese.

[**Shou v0.2.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.2.0/Shou-0.2.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.2.0/Shou-0.2.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.2.0/shou-0.2.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

This release uses an ad-hoc signature and is not Apple-notarized. If macOS blocks the first launch, check the download source, then review **System Settings → Privacy & Security → Open Anyway**.

## What Shou can do

| | |
| --- | --- |
| **Applications** | Review an app and its exact associated files before uninstalling. Personal data needs separate consent; moved components can be restored. |
| **Startup items** | Inspect startup definitions and open macOS Login Items settings. Shou does not enable or disable them. |
| **Exclusions** | Protect folders globally or within a project, and edit personal rules as disabled revisions. |
| **Application caches** | Review caches from browsers, chat apps, editors, and tools, including Chrome, Edge, Firefox, Codex, Claude, QQ, and WeChat. |
| **Developer tools and projects** | Find npm, Cargo, Xcode, Python, and Go caches, Rust target directories, Node.js dependencies, and Swift build products. |
| **Space analysis** | Explore folder sizes with a treemap and directory list. |
| **Personal rules** | Describe your own rebuildable folders, preview matches, and reuse reviewed rules. |
| **History and recovery** | Check results, restore selected items, or separately confirm permanent removal of this cleanup batch. |
| **Online updates** | Check for updates from Settings or the Shou menu. Updates are signature-verified before installation. |

## Clean up in three steps

1. **Scan** application caches or add a project workspace. Scanning does not remove files.
2. **Review** paths, sizes, risks, and rebuild requirements, then choose the items to clean.
3. **Confirm** moving the selection to Trash. Restore from History if needed.

Moving items to Trash does not immediately free disk space. Permanent removal requires a separate confirmation and cannot be undone. Protected content and exclusions block cleanup. Running apps and builds can prevent affected caches from being cleaned.

## Your files, your choice

Rules run locally and cannot execute shell commands. No account, model connection, or cloud scan is required. Rules and cleanup history stay on your Mac.

## Terminal

The app includes an independent CLI for rules, scans, plans, and history. Cleanup and recovery require interactive confirmation.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Documentation and contributions

Source builds, tests, rule examples, and CLI usage are covered in the documentation. Report problems and ideas through Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Acknowledgements

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## License

[Apache License 2.0](LICENSE).
