# @limecloud/shou

One installation entry and one `shou` command for platform-native cleanup tools.
The launcher selects an exact-version native package for the current system and
Node.js architecture. macOS uses Swift; Windows uses a self-contained .NET CLI.
Node.js 18 or later is required for the launcher. No compiler, desktop application,
install script or additional binary download is required to run a staged package.

```sh
npx @limecloud/shou --help
npx @limecloud/shou capabilities --json
```

For a persistent terminal command:

```sh
npm install --global @limecloud/shou
shou --help
shou capabilities --json
```

Cleanup and restoration retain the native CLI's explicit interactive confirmation.
Installation does not scan or change your files, install the desktop app, grant
Full Disk Access, or enable AI connections. Ordinary scanning and cleanup run
locally without a model. Optional AI investigation uses an explicitly configured
service.

Version `0.19.0` supports **macOS 14 or later only**, on Apple Silicon
and Intel, using an ad-hoc signed executable without Apple notarization. Terminal
and desktop privacy access are independent. Windows packages are not published.
The source template is private and must be staged before publication. Routing and
packaging source do not establish Windows release support. Minimum Windows support is Windows 11 build
22000 on x64 or ARM64, subject to native acceptance.

The [npm distribution plan](https://github.com/limecloud/shou/blob/main/docs/engineering/npm-distribution.md) defines
platform selection, local staging, native payloads and release acceptance.
Each binary reports its actual features through `capabilities --json`.

- [Shou project and desktop downloads](https://github.com/limecloud/shou)
- [CLI contract](https://github.com/limecloud/shou/blob/main/docs/ai/agent-and-cli-contract.md)
- [Installation and permissions](https://github.com/limecloud/shou/blob/main/docs/product/installation-and-access.md)

## Building this package

Each release records native source state and final hashes in `BUILD.json`.
Registry publication receipts live in `releases/`. npm versions are immutable;
updated native code requires a new npm version.

Do not publish this source template directly. From the repository root, stage
one native package per OS/architecture, then stage the launcher with their exact
versions. For an existing Windows x64 development payload:

```sh
sh "scripts/build-windows-cli.sh" win-x64
python3 "scripts/package-npm.py" platform --development --version 0.19.0 \
  --platform win32-x64 --payload ".build/windows/publish/win-x64/cli" \
  --licenses ".build/windows/publish/win-x64/cli/notices" --output ".build/npm/win32-x64"
python3 "scripts/package-npm.py" launcher --development --version 0.19.0 \
  --platform-package ".build/npm/win32-x64" --output ".build/npm/launcher"
```

On the matching native system, verify the local tarballs and installation:

```sh
python3 "scripts/verify-npm-distribution.py" --launcher ".build/npm/launcher" \
  --platform-package ".build/npm/win32-x64" --output ".build/npm/verification"
```

Development output remains private and is never promoted to a release by this
script. `BUILD.json` records source state, architecture, native/signature checks
and hashes of final files. Release staging requires matching native execution,
pre-signed artifacts and a clean source checkout. It preserves executable bytes.
Complete all release checks before publishing native packages, then the launcher.

Apache-2.0. Native platform packages include their dependency notices.
