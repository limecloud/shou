# Third-party application update discovery

English | [简体中文](../zh-CN/product/application-updates.md)

Inline app details and the independent macOS CLI offer user-initiated Homebrew Cask catalog queries. They compare observed app versions with public catalog versions and provide an official catalog entry. [SYNC.md](../../SYNC.md) records source, tests, native UI and distribution separately. Windows has independent registration matching, official stable-release queries, CLI and inline WinUI source as scoped below.

## Source and identity

The first source is the fixed HTTPS JSON API at `formulae.brew.sh`. The built-in [mapping](../../packages/shou-core/Sources/Resources/application-update-sources.json) matches exact bundle identifiers and bundle filenames for six stable apps: Visual Studio Code, Firefox, iTerm, Chrome, VLC and Postman. Beta channels, renamed bundles, system apps and unverifiable metadata do not match automatically. Matching proves neither Homebrew installation nor the local app's developer signature.

Local reads reuse bounded, no-follow app inventory metadata. Checks reread the current app before querying; the GUI also binds the row's complete observed identity. Local identity is read again after network success or failure. Changes invalidate the observation and require rescanning.

## Queries and privacy

Expanding details does not contact the network. Check Homebrew Catalog explains the destination and sends a request only when clicked. Each request sends one mapped cask token, never local paths, installed versions, usernames, inventories or credentials. It does not execute `brew`, Shell commands, packages or app updaters, or open business record stores.

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

## Implementation and verification boundaries

Core owns mapping, strict version comparisons, platform constraints, unknown states and identity rechecks. Platform owns native app metadata and bounded fixed-source networking. UI owns inline presentation, cancellation and user-initiated official-page opening. Follow the [current design](../engineering/interface-design.md) without another top-level update page.

Generated fixtures cover source/bundle mismatches, equal/higher/lower and ambiguous versions, platform variants, system constraints, app changes during requests, cancellation, offline/errors, JSON type and response size. Real catalog connectivity, GUI, accessibility and installed behavior need separate evidence; simulated networking and successful builds cannot replace them. Automatic installation and additional sources remain separate future capabilities.

## Windows source and differences

The initial Windows source is `https://api.github.com/repos/microsoft/vscode/releases/latest`, observing stable Visual Studio Code releases only. Built-in matching requires the exact x64 current-user or 64-bit machine registration key, display name and `Microsoft Corporation` publisher. Portable, Insiders, other architectures, renamed and unknown registrations do not match. Registration matching does not prove installation provenance or signatures. The identifiers can be checked against [GitHub Desktop’s Windows editor catalog](https://github.com/desktop/desktop/blob/development/app/src/lib/editors/win32.ts); this implementation neither executes external commands nor copies its source.

Expanding details reads only local source facts. Check Release Catalog requests the fixed public endpoint with no authentication, cookies or application list. It rejects redirects, applies ten-second HTTP/fifteen-second total deadlines and a streaming 1 MiB bound, and accepts only HTTP 200 JSON. Core verifies non-draft/non-prerelease metadata, the exact repository release page and numeric tags. Package URLs are unused; the official entry is fixed to `https://code.visualstudio.com/updates`. A release-version observation does not establish package compatibility with this Windows system.

```sh
shou applications updates source --application-id ID --json
shou applications updates check --application-id ID --allow-network true --json
```

A fresh complete inventory is read before and after each query. Incomplete inventory or changed registration rejects the conclusion. `source` never connects and reports recognized but unqueried sources as `not_checked`; unknown `check` results remain partial with exit `6`. Cancellation or switching app rows prevents stale publication. Native registrations, WinUI and packaged CLI need separate evidence.
