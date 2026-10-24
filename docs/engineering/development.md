# Local development

English | [简体中文](../zh-CN/engineering/development.md)

This guide covers the current macOS source project. Windows implementation follows the [native plan](windows-native-plan.md). A source build is distinct from native interaction and release acceptance.

## Prerequisites

Use macOS, Swift 6.2.3 and the macOS SDK. The deployment baseline is macOS 14; CI selects Xcode 26.2 and checks its Swift version. SwiftPM pins Swift AI SDK `0.20.0` and Sparkle `2.10.0` in `Package.resolved`. macOS supplies SQLite through the system SDK.

Read the [architecture](../architecture/system-design.md), [module ownership](../architecture/monorepo-and-platforms.md) and affected product/safety contracts before editing. Ordinary scanning and cleanup require no model credentials, network or running desktop process.

## Build and run

Run from the repository root:

```sh
swift --version
swift build --jobs 4
".build/debug/shou" capabilities --json
sh "scripts/build-macos.sh" debug
open "dist/Shou.app"
```

`swift build` builds the desktop, independent CLI and fixture-test executable. Packaging places the CLI and required resource bundles beside the app helpers. Keep the full bundle intact. The desktop binary is `ShouDesktop`; the CLI binary is `shou`, avoiding collisions on case-insensitive filesystems.

## Standard verification

```sh
sh "scripts/test.sh"
```

This runs localization/catalog/document checks, a Swift build, domain and generated native-fixture tests, public CLI contracts, synthetic AI protocols, terminal confirmation and relevant cleanup domains. Native Trash fixtures exercise moving and restoration; some default CLI checks permanently remove only their own generated temporary files. No test enumerates or empties the user's Trash.

Focused checks after a successful build:

```sh
".build/debug/shou-tests" --rule-catalog-only
".build/debug/shou-tests" --storage-catalog-only
".build/debug/shou-tests" --ai-safety-only
python3 "scripts/verify-cli.py"
python3 "scripts/verify-ai-investigation.py"
```

With explicit authorization, `sh "scripts/test.sh" --native-trash-purge` additionally exercises irreversible removal of generated fixture manifests. The separate `--native-large-trash-only` executable option creates over 100,000 generated files and tests Trash/restoration; it is outside the default suite.

Record exact revision, OS, architecture, executed checks, outcomes and limitations. Passing fixtures do not establish accessibility, personal-workspace safety, another platform or release signing. See [acceptance](acceptance-and-testing.md).

## Source and generated resources

| Source | Rule |
| --- | --- |
| `packages/shou-contracts/rule.schema.json` | Canonical machine schema |
| `packages/shou-core/Sources/Resources/builtin-rules.json` | Versioned declarative rule catalog |
| `packages/shou-core/Sources/Resources/known-locations.json` | Exact platform-scoped discovery roots |
| `packages/shou-core/Localizable.xcstrings` | Canonical English/Simplified Chinese text |
| `assets/design/tokens.json` | Shared design values, including cleanup artwork size, path width and motion period, generating WinUI XAML and SwiftUI constants; both checked by the resource generator |
| `assets/brand` | Native brand sources |

Generate and check localization resources with:

```sh
python3 "scripts/update-localizations.py"
python3 "scripts/update-localizations.py" --check
python3 "scripts/generate-windows-resources.py" --check
python3 "scripts/verify-rule-catalog.py" --self-test
python3 "scripts/verify-docs.py"
```

Do not hand-edit generated `.strings`, `apps/windows/Generated` or `apps/macos/Sources/ShouDesign.generated.swift`. Language changes cannot alter IDs, matching, digests or execution decisions. After changing shared sources, regenerate native resources with `python3 scripts/generate-windows-resources.py` and check the resulting digests. The regular macOS test entry also checks these generated resources.

## Local data and isolation

The normal macOS data root is `~/Library/Application Support/Shou`. Generated CLI fixtures use `SHOU_DATA_DIR` pointing to a dedicated absolute directory. Record storage requires current-user ownership, mode `0700` for directories and `0600` for files, atomic durable writes and a cross-process mutation lock.

Use generated disposable files for native mutation tests. Do not scan or modify personal projects to prove deletion behavior. Model tests use fake local providers and synthetic keys unless actual service use was explicitly authorized.

## Package and release

`sh "scripts/build-macos.sh" release universal` builds both macOS architectures into a bundle. `python3 "scripts/install-macos.py" --check` verifies a prepared local bundle without installing it. Local installation, signed distribution and public updates are separate actions. Follow [release instructions](releasing.md) for signing, archives, feed validation and publication.

## Windows development boundary

Run `sh scripts/test-windows-core.sh` on Mac for C# Core/Presentation tests, Platform reference compilation, bundled-resource checks and framework-dependent CLI contracts. Windows-native tests explicitly skip on Mac. WinUI compilation and native behavior require Windows; x64 and ARM64 acceptance remain separate. Windows-local build/test commands are in the [Windows guide](windows.md); no Windows release package is available. Source, artifacts, cache and toolchain ownership follow the [native plan](windows-native-plan.md).
