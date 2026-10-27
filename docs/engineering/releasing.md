# Releases and online updates

English | [简体中文](../zh-CN/engineering/releasing.md)

## Version and artifacts

Set both `CFBundleShortVersionString` and `CFBundleVersion` in `apps/macos/Info.plist` and `ShouCLI.version` to the release version. The Git tag must be `v` followed by that version. The build number increases with every release so Sparkle can compare versions.

The release produces a universal macOS DMG, app ZIP, independent CLI archive, signed `appcast.xml` and `SHA256SUMS`. macOS 14 is the deployment minimum. macOS ZIP and DMG contain the same app; the CLI archive includes its rules, schema and localization resources. v0.20.0 also includes self-contained Windows x64/ARM64 portable preview ZIPs. CI stages macOS npm packages; registry publication is recorded separately.

## Signing

The application embeds a Sparkle Ed25519 public key in `SUPublicEDKey`. Put the matching base64 private seed in the repository secret `SPARKLE_PRIVATE_KEY`; never commit it. Preserve a protected backup: existing installations trust that public key for future updates.

The workflow reads the secret into a temporary file with mode `0600`, uses it to sign updates, and removes that temporary copy. Sparkle verifies archives before extraction and requires signed feeds. The app's update feed points at the latest GitHub release's `appcast.xml`. Both archive URLs and checksums refer to the immutable versioned release.

Sparkle update signatures are separate from Apple Developer ID signing and notarization. The initial packaging script uses an ad-hoc application signature. Downloads and release notes disclose that installation limitation.

## Verification and publication

1. Run `sh scripts/test.sh --native-trash-purge` and review the actual logs. This explicitly enables native catalog cleanup, restoration, and permanent removal of generated fixtures. Default catalog checks restore without purging; some CLI checks independently remove their own generated fixtures permanently. No checks may target personal data.
2. Run `sh scripts/release-macos.sh v0.20.0 /absolute/path/to/private-key-file`. This builds both CPU architectures, tests the release core and packaged CLI, inspects the DMG/ZIP/CLI archives, checks signatures, and rejects modified update archives and feeds.
3. Review all source, documentation, runtime resources, and release notes before committing. Obtain any user-required submission approval before commit, push, or publication.
4. Push the version tag. `.github/workflows/release.yml` runs all tests, including native cleanup and restoration of over 100,000 files, and release packaging on Apple Silicon and Intel, then builds and validates the universal release. Only successful jobs reach publication. Manual reruns require an existing tag.
5. The publication job checks transferred SHA-256 checksums, stages assets in a draft, and publishes after upload. It refuses to replace a published release. Confirm the final release downloads and check updates from an installed app.

Windows release jobs build WinUI and the independent CLI from the exact source commit for x64 and ARM64. x64 runs Core/Presentation/native Platform/CLI checks and verifies window startup/normal closing; ARM64 cross-publishing does not establish ARM64 runtime acceptance. `package-windows.py` checks PE architecture, self-contained .NET 10, Windows App SDK resources, versions, dependency metadata, archive bytes and SHA-256. Each ZIP includes a source-bound `BUILD.json` with capability limits and actual native-check status. Both Windows builds and all macOS jobs must succeed before assets/checksums are combined and published.

Windows downloads are unsigned portable previews: `Shou-<version>-windows-<arch>.zip` for the app and `shou-cli-<version>-windows-<arch>.zip` for the CLI. Extract the app and run `Shou.Windows.App.exe`; no separate .NET or Windows App SDK installation is needed. There is no installer or automatic updater, and public cleanup/uninstall/startup mutation gates remain closed. Complete dual-architecture runtime, Authenticode, Velopack and clean-system acceptance in the [Windows plan](windows-native-plan.md) before claiming full Windows support.

Manual preparation can set `prepare_only=true` and `source_commit` to a full 40-character source SHA. It runs the same verification and signed packaging jobs, skips publication, and leaves the tag and public assets untouched. Source overrides are rejected outside preparation mode. Normally published versions remain immutable. If the user explicitly requests a same-version replacement, preserve the original tag, release metadata and all asset bytes, verify the complete candidate, then promote those exact bytes as a recorded manual exception. Already installed `0.19.0` builds will not discover another `0.19.0` as an update; npm versions cannot be overwritten.

## npm channel

The public CLI package remains `@limecloud/shou`. v0.20.0 references matching `shou-darwin-arm64` and `shou-darwin-x64` platform packages. Follow the [npm distribution plan](npm-distribution.md) for platform selection, native tarball tests and publication order. npm manages the CLI channel independently of desktop updates. Windows packages join a future version after native acceptance.

## Desktop update behavior

Shou self-updates start at Settings → About Shou → Check for Updates…, separately from [update discovery for other installed apps](../product/application-updates.md). macOS uses Sparkle's native window for the icon, installed/latest versions, scrollable release notes, skipping a version and installation; reminders are available when automatic checks are enabled. Settings displays the result and last check time, and synchronizes automatic checks/downloads with Sparkle. Automatic download/install is off by default and unavailable when automatic checks are off. Installation relaunch waits for ongoing Shou operations to finish.

`.github/release-notes.md` is the release-note source. `scripts/render-update-notes.py` converts paragraphs, headings and lists into escaped offline HTML. The release script embeds it in the signed feed; artifact checks require it to match the source. Notes cannot execute HTML/scripts or load remote images. This applies to feeds created by future runs of the updated pipeline; existing release assets are not modified.

Windows queries the fixed official GitHub latest stable release endpoint only after a user clicks the Settings entry. Its native dialog presents progress, versions and plain-text notes. Core compares versions numerically and requires the exact architecture, repository, version tag and ZIP filename; previews, redirects, oversized metadata and missing architecture assets are rejected. Only Download Update opens the corresponding official ZIP in a browser. Portable builds still require quitting the app and replacing its folder; settings and records live outside that folder. Automatic replacement, background reminders and downgrades are not supported, and a download is never reported as a completed installation.

For local installation rehearsal, run `python3 scripts/prepare-update-acceptance.py /path/to/Shou.app --fixture-key`. It creates isolated app identities/data and a temporary test key, then serves a signed localhost update. Only the two test copies receive the temporary public key; the private key is removed after signing without accessing production keys or the keychain. By default the installed copy is assigned version `0.0.9`, exercising the update chain with the same candidate build. Pass `--installed-app /path/to/previous/Shou.app` to establish actual previous-release compatibility. The original explicit private-key-file invocation remains available. Production feed delivery and “up to date” behavior still require checks after publication.

## v0.20.0 release target

This release uses version `0.20.0`: Git tag `v0.20.0`, macOS app, Swift CLI, `@limecloud/shou` and both macOS platform packages report that version. The Windows version is owned by `apps/windows/Directory.Build.props` and also reports `0.20.0`. GitHub distributes portable previews; Windows npm staging remains private development output. Version changes require rebuilding native payloads; changing npm metadata alone is insufficient.

[SYNC.md](../../SYNC.md) and the [Windows implementation stages](windows-native-plan.md#implementation-stages) own Windows scope and gaps. Windows 11 x64 and ARM64 each require actual runtime, controlled generated fixtures, WinUI, signing, clean installation and update evidence. Mac checks and cross-publishing cannot establish full native support; portable previews expose only verified builds and explicitly limited capabilities. Any unavailable capabilities must remain accurately described in documentation and capability discovery; a version number does not establish support.

The release workflow builds, verifies signatures and installs each native npm package offline on Apple Silicon and Intel. After both pass, it assembles the launcher with those exact dependencies and uploads `shou-npm-release`. Publish its verified tarballs to npm, platform packages before launcher. GitHub credentials do not grant npm publication rights; authenticate the npm account separately.

Before publication, align native versions, source state, documentation and update metadata, sign native payloads and recompute final-byte hashes. Follow the [npm release contract](npm-distribution.md#release-and-acceptance): publish accepted exact-version platform packages before the launcher, then verify registry installation, `npx`, version and capabilities. GitHub Release uses verified native payloads of the same version. Desktop updates and npm retain separate lifecycles. Record the tag, registry integrity, final hashes and actual acceptance after publication.
