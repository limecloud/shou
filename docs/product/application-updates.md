# Third-party application updates and controlled upgrades

English | [简体中文](../zh-CN/product/application-updates.md)

Applications offers two separate update paths: read-only catalog discovery for an identified app, and reviewed upgrades of installed packages through a supported package manager. Neither path shares uninstall selection or cleanup authorization. Shou's [own updater](../engineering/releasing.md#desktop-update-behavior) is independent. [SYNC.md](../../SYNC.md) records source, tests, native UI and distribution separately.

The following sections retain the single-app discovery contract and CLI. The [managed-package sections](#managed-package-upgrades) describe the separate macOS Homebrew/mise and Windows WinGet implementations.

## Source and identity

The first source is the fixed HTTPS JSON API at `formulae.brew.sh`. The built-in [mapping](../../packages/shou-core/Sources/Resources/application-update-sources.json) matches exact bundle identifiers and bundle filenames for six stable apps: Visual Studio Code, Firefox, iTerm, Chrome, VLC and Postman. Beta channels, renamed bundles, system apps and unverifiable metadata do not match automatically. Matching proves neither Homebrew installation nor the local app's developer signature.

Local reads reuse bounded, no-follow app inventory metadata. Checks reread the current app before querying; the GUI also binds the row's complete observed identity. Local identity is read again after network success or failure. Changes invalidate the observation and require rescanning.

## Queries and privacy

For single-app discovery, expanding details does not contact the network. Check Homebrew Catalog explains the destination and sends a request only when clicked. Each request sends one mapped cask token, never local paths, installed versions, usernames, inventories or credentials. This catalog query does not execute `brew`, Shell commands, packages or app updaters, or open business record stores.

Requests disable cookies, caches and persistent credentials, retain system TLS validation, and refuse redirects and interactive authentication. Request timeout is ten seconds, with a fifteen-second resource deadline. Declared and streamed responses are limited to 1 MiB; only HTTP 200 JSON responses enter parsing. Failures retain fixed codes rather than arbitrary server errors or authentication details. Cancellation prevents late publication.

## Versions and results

Only dotted ASCII numeric versions with at most eight components and nine digits per component are comparable; numerically equal trailing zeros are ignored. Rolling versions, prereleases, comma build suffixes and ambiguous formats remain unknown. Known catalog variants and macOS requirements are selected for the current OS/architecture; this does not verify downloadable payload architecture, signatures or installation compatibility.

| `state` | Meaning |
| --- | --- |
| `newer_catalog_version` | A numerically higher catalog version exists; the official catalog page is available |
| `same_catalog_version` | Numeric versions match; this does not promise the app is up to date or immediately upgradeable on its channel |
| `installed_version_newer` | The installed version is ahead of the catalog; do not suggest downgrading |
| `unsupported` | No built-in source; make no network request and use the app's own updater |
| `unknown` | Network, identity, platform constraints, metadata or version format could not be verified; never report this as no update |

Reports use `format_version=1`, observation time, app identity, source, installed/catalog versions and fixed causes. Unknown reports have `status=partial` and CLI exit `6`. Other states describe completion of this observation rather than installation validation. Changes during the query return `application_changed`; cancellation uses the existing contract.

Open Homebrew Page opens only the fixed official cask page, never arbitrary response URLs. Installation stays with the app or official updater. This entry creates no download, replacement, installation, administrator or recurring-update authorization.

## CLI

```sh
shou applications updates source --path "/Applications/Visual Studio Code.app" --json
shou applications updates check --path "/Applications/Visual Studio Code.app" --allow-network true --json
```

`source` reads local identity/mapping only; `check` requires explicit `--allow-network true`. Unmapped apps make no network request even with that flag. Both use the [standard machine envelope](../ai/agent-and-cli-contract.md) without opening or creating cleanup stores.

## Read-only discovery implementation and verification

Core owns mapping, strict version comparisons, platform constraints, unknown states and identity rechecks. Platform owns native app metadata and bounded fixed-source networking. UI owns inline presentation, cancellation and user-initiated official-page opening. Follow the [current design](../engineering/interface-design.md) without another top-level update page.

Generated fixtures cover source/bundle mismatches, equal/higher/lower and ambiguous versions, platform variants, system constraints, app changes during requests, cancellation, offline/errors, JSON type and response size. Real catalog connectivity, GUI, accessibility and installed behavior need separate evidence; simulated networking and successful builds cannot replace them. This read-only path never becomes installation authority; the separate managed-package path below requires its own explicit selection and confirmation.

## Windows source and differences

The initial Windows source is `https://api.github.com/repos/microsoft/vscode/releases/latest`, observing stable Visual Studio Code releases only. Built-in matching requires the exact x64 current-user or 64-bit machine registration key, display name and `Microsoft Corporation` publisher. Portable, Insiders, other architectures, renamed and unknown registrations do not match. Registration matching does not prove installation provenance or signatures. The identifiers can be checked against [GitHub Desktop’s Windows editor catalog](https://github.com/desktop/desktop/blob/development/app/src/lib/editors/win32.ts); this implementation neither executes external commands nor copies its source.

Expanding details reads only local source facts. Check Release Catalog requests the fixed public endpoint with no authentication, cookies or application list. It rejects redirects, applies ten-second HTTP/fifteen-second total deadlines and a streaming 1 MiB bound, and accepts only HTTP 200 JSON. Core verifies non-draft/non-prerelease metadata, the exact repository release page and numeric tags. Package URLs are unused; the official entry is fixed to `https://code.visualstudio.com/updates`. A release-version observation does not establish package compatibility with this Windows system.

```sh
shou applications updates source --application-id ID --json
shou applications updates check --application-id ID --allow-network true --json
```

A fresh complete inventory is read before and after each query. Incomplete inventory or changed registration rejects the conclusion. `source` never connects and reports recognized but unqueried sources as `not_checked`; unknown `check` results remain partial with exit `6`. Cancellation or switching app rows prevents stale publication. Native registrations, WinUI and packaged CLI need separate evidence.

## Managed-package upgrades

Managed-package views list the packages recognized by their provider, installed and available versions, and current upgrade eligibility. Search and update-only filters change visibility, not authority. A package record does not establish ownership of a particular app bundle, uninstall registration or project. Without a reliable mapping, Shou keeps these records separate and does not merge them into app uninstall selection or count their contents again as cleanup capacity.

Users review an exact selection and its installation effects before confirming an upgrade. The reviewed selection is frozen into a short-lived, single-use plan; it is not a recurring permission, an unattended updater or a cleanup plan. Source, installation identity and target-version changes invalidate the affected authority. Every new attempt requires another check and review. Package managers and installers may download files, execute installation scripts, close apps and change dependencies or app data. Shou does not provide upgrade rollback or automatic computer restart.

### macOS: Homebrew and mise

Software Updates under Applications offers Homebrew and mise sources, separate from the installed-app list; checking starts only when clicked. The managed views offer a package list, search, update filtering, single-package review and selected/all-eligible review. Review All freezes the displayed inventory's eligible targets; execution still supplies an explicit package token for each command. It never invokes an unrestricted all-package upgrade. The review replaces the working selection inline and uses one Confirm Upgrade action.

| Provider | Inventory and target scope | Upgrade boundary |
| --- | --- | --- |
| Homebrew | Installed Formula, dependency and Cask records; available versions from the manager's JSON metadata | One `brew upgrade --formula TOKEN` or `brew upgrade --cask TOKEN` per reviewed package; pinned and unverified targets are ineligible |
| mise | Installed global tools and their configured requests | Only one active installed version with a verified supported user-global configuration requesting `latest`; one `mise upgrade --global --no-prune TOKEN` per reviewed tool |

Homebrew metadata can be cached: Shou disables automatic Homebrew catalog refresh, analytics and install cleanup for these processes. A check therefore does not promise the newest remote release. If target lookup fails, installed packages may remain visible with unknown update status, but cannot authorize an upgrade. The manager's configured taps/backends and installation scripts retain their own network and execution behavior; the single-app query's narrow request/privacy guarantees do not apply to these processes.

mise fixed versions, version ranges, project configuration and project lockfiles cannot enter this upgrade path. Inactive or ambiguous multi-version observations remain read-only. The manager may update its user-global lockfile; `--no-prune` is not a promise to preserve all global metadata.

Platform resolves only supported manager locations, verifies the current-user/root-owned executable and rejects group/other-writable executables. It uses fixed argument arrays without a Shell, bounded output/deadlines and no interactive standard input. It does not install a missing manager, accept agreements on the user's behalf or obtain administrator credentials. These controls constrain Shou's invocation; they do not sandbox a trusted manager or its plugins.

Core accepts observations from the current service for less than ten minutes and issues a 120-second plan. Execution consumes that plan before preflight, rechecks the whole frozen batch and each package's metadata and executable identity, then processes packages serially. The deadline is checked again immediately before each command; a slow inventory or earlier package cannot authorize dispatch after expiry. The command does not pin a version argument: the frozen target is the version Shou subsequently verifies, and the manager may also change dependencies. If an earlier package already installed another selected package's exact target, Shou verifies it without issuing a second upgrade.

Success requires observing the reviewed target among the installed versions after the command; a successful process exit alone is insufficient. A pre-dispatch block is failed, a dispatched but unverified attempt is unknown, and remaining unstarted packages are skipped after such a failure. Stopping or timing out can terminate Shou's process group after some files have changed. It provides no rollback and must not be shown as an unchanged installation. Results clear the old inventory and require a new check before retrying.

### Windows: official WinGet catalog

Software Updates under Applications provides the official WinGet source, checked only when clicked, using the Windows Package Manager COM API, not parsed localized CLI output. It connects only to the predefined official WinGet source, with fixed source identity `Microsoft.Winget.Source_8wekyb3d8bbwe`, `Microsoft.PreIndexed.Package` type and the official `winget.azureedge.net/cache` or `cdn.winget.microsoft.com/cache` HTTPS endpoints. It does not add, reset or repair sources, accept source agreements, or connect to Microsoft Store or arbitrary user sources.

The bounded inventory includes only installed packages that the official catalog can match. Upgrade eligibility requires a known installed version, verified user/machine scope, ProductCode or PackageFamilyName identity, a higher target in the same channel, one exact catalog/version/channel target and an applicable installer. Unknown identity, ambiguous targets, required package agreements or incomplete inventory prevent execution. These checks do not imply coverage of every installed app.

The inline page shows package ID, versions and installation scope, with a scrollable list and stable action footer. Review Selected Updates rechecks and freezes the selection, then displays every selected package, including those hidden by a search or filter. Search and selection are disabled during review. A blue Confirm Upgrade action authorizes this exact plan once, without a second dialog; Cancel returns to selection without dispatching an installer. Core re-reads before issuing the two-minute, single-use plan, before the batch and before each package; Platform rechecks the exact package and authorization deadline immediately before dispatch. It preserves the observed user/machine scope and exact target. Installation uses silent mode, skips automatic dependency installation and does not allow force, hash mismatch, unknown-version upgrades or automatic agreement acceptance. An installer can still request Windows administrator approval or affect its own data; Shou cannot make its behavior transactional.

Stop prevents new packages from starting. An already dispatched COM installation is awaited rather than canceled; the window remains open for its real result. Completion uses a separate bounded inventory read even after stop. Verified requires both manager success and the exact target version observed as installed. Failed does not promise that the installer made no changes. Unverified outcomes are unknown and stop subsequent packages; unstarted packages remain separately marked. A restart-required result is reported without restarting Windows. Another attempt requires a fresh check and review.

### Verification boundaries

Domain and isolated generated-manager fixtures cover frozen selection, identity/version changes, plan expiry/replay, fixed command construction, pinned or unsupported targets, cancellation and uncertain results. They must never upgrade existing personal applications as regression fixtures. Read-only catalog checks above keep their existing CLI contract; they do not grant a CLI package-installation capability.

macOS manager behavior, packaged UI, accessibility and installation effects require their own native evidence. This round read the official catalog through native COM on Windows 11 x64 and used Computer Use to verify selection, filtering, complete frozen-scope review and cancellation. No existing software was upgraded. Pure .NET tests and cross-compilation do not replace native execution, and this read-only acceptance does not establish installer, elevation, restart, ARM64 or full accessibility behavior. Current checks and remaining acceptance are tracked in [SYNC.md](../../SYNC.md).
