# Releases and online updates

English | [简体中文](../zh-CN/engineering/releasing.md)

## Version and artifacts

Set both `CFBundleShortVersionString` and `CFBundleVersion` in `apps/macos/Info.plist` and `ShouCLI.version` to the release version. The Git tag must be `v` followed by that version. The build number increases with every release so Sparkle can compare versions.

The release produces a universal macOS DMG, app ZIP, independent CLI archive, signed `appcast.xml` and `SHA256SUMS`. macOS 14 is the deployment minimum. macOS ZIP and DMG contain the same app; the CLI archive includes its rules, schema and localization resources. v0.11.0 publishes macOS only; Windows release implementation is pending.

## Signing

The application embeds a Sparkle Ed25519 public key in `SUPublicEDKey`. Put the matching base64 private seed in the repository secret `SPARKLE_PRIVATE_KEY`; never commit it. Preserve a protected backup: existing installations trust that public key for future updates. The initial local backup is in the ignored `.shou-local/sparkle-private-key` file.

The workflow reads the secret into a temporary file with mode `0600`, uses it to sign updates, and removes that temporary copy. Sparkle verifies archives before extraction and requires signed feeds. The app's update feed points at the latest GitHub release's `appcast.xml`. Both archive URLs and checksums refer to the immutable versioned release.

Sparkle update signatures are separate from Apple Developer ID signing and notarization. The initial packaging script uses an ad-hoc application signature. Downloads and release notes disclose that installation limitation.

## Verification and publication

1. Run `sh scripts/test.sh --native-trash-purge` and review the actual logs. This explicitly enables native catalog cleanup, restoration, and permanent removal of generated fixtures. Default catalog checks restore without purging; some CLI checks independently remove their own generated fixtures permanently. No checks may target personal data.
2. Run `sh scripts/release-macos.sh v0.11.0 /absolute/path/to/private-key-file`. This builds both CPU architectures, tests the release core and packaged CLI, inspects the DMG/ZIP/CLI archives, checks signatures, and rejects modified update archives and feeds.
3. Review all source, documentation, runtime resources, and release notes before committing. Obtain any user-required submission approval before commit, push, or publication.
4. Push the version tag. `.github/workflows/release.yml` runs all tests, including native cleanup and restoration of over 100,000 files, and release packaging on Apple Silicon and Intel, then builds and validates the universal release. Only successful jobs reach publication. Manual reruns require an existing tag.
5. The publication job checks transferred SHA-256 checksums, stages assets in a draft, and publishes after upload. It refuses to replace a published release. Confirm the final release downloads and check updates from an installed app.

Windows packages and release automation are not implemented. Follow the [Windows native plan](windows-native-plan.md) for x64/ARM64, self-contained .NET and Windows App SDK, Authenticode, Velopack and clean-machine acceptance before publishing.

## npm channel

The public CLI package remains `@limecloud/shou`. Its published `0.11.0` payload supports macOS only. Follow the [npm distribution plan](npm-distribution.md) for future platform packages, exact-version coordination, native tarball tests and publication order. npm manages the CLI channel independently of desktop updates.

## Desktop update behavior

The update installation is postponed while Shou has an operation in progress. Automatic download/install is disabled by default; users can control scheduled update checks in Settings. For a local installation rehearsal, `scripts/prepare-update-acceptance.py` creates isolated application copies and serves a signed update on localhost. Pass `--installed-app /path/to/previous/Shou.app` to verify an actual previous release upgrading to the candidate; the candidate version is read from its Info.plist. Production feed delivery and “up to date” behavior must also be checked after publication.
