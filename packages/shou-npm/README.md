# @limecloud/shou

Shou's native cleanup CLI for **macOS 14 or later**, on Apple Silicon and Intel.
The package contains a universal executable, cleanup rules, schemas, localization
and the Shou rule-authoring Skill. No Swift compiler, desktop app, install scripts,
or additional binary downloads are required. Node.js 18 or later is required for
the npm launcher.

```sh
npx @limecloud/shou@0.11.0 --version
npx @limecloud/shou@0.11.0 --help
npx @limecloud/shou@0.11.0 capabilities --json
```

For a persistent terminal command:

```sh
npm install --global @limecloud/shou
shou --help
shou skills read --json
```

Cleanup and restoration retain the native CLI's explicit interactive confirmation.
Installation does not scan or change your files, install the desktop app, grant
Full Disk Access, or enable AI connections. Ordinary scanning and cleanup run
locally without a model. Optional AI investigation uses an explicitly configured
service.

The executable is ad-hoc signed and not Apple-notarized. Terminal privacy access
and desktop privacy access are independent. Linux and Windows are not supported
by this npm package; Windows users can use the project's separate portable
desktop distribution.

- [Shou project and desktop downloads](https://github.com/limecloud/shou)
- [CLI contract](https://github.com/limecloud/shou/blob/7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc/docs/ai/agent-and-cli-contract.md)
- [Installation and permissions](https://github.com/limecloud/shou/blob/7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc/docs/product/installation-and-access.md)

## Building this package

The published npm `0.11.0` payload was built from commit
`7c7dd0b6aa3f09a3cfbfd3a3ea0e32a8b6ef09dc`. npm versions are immutable;
later repairs to the GitHub `v0.11.0` release do not replace that npm payload.
The receipt in `releases/0.11.0.json` records its source and registry integrity.
Updated native code requires a new npm version before it can be published.

Build both CLI architectures from an unchanged checkout of the recorded commit
(or the matching release tag for an unpublished npm version) with Swift 6.2.3 or later:

```sh
swift build --jobs 4 -c release --arch arm64 --product shou
swift build --jobs 4 -c release --arch x86_64 --product shou
```

From the repository root, stage the npm payload and pack it:

```sh
python3 "scripts/package-npm.py" --source "/path/to/tag-checkout" --output ".build/npm-0.11.0"
npm pack "./.build/npm-0.11.0" --pack-destination ".build"
```

The staging script verifies that the source matches the recorded commit or release tag, combines
both architectures, signs the executable, and checks its version and resources.
`BUILD.json` records the native source commit and payload hashes. Publish only
after testing the packed tarball in an isolated npm installation.

Apache-2.0. The bundled Swift AI SDK license is included separately.
