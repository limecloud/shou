# Mole inventory and path coverage

[简体中文](../zh-CN/engineering/mole-rule-coverage.md)

Reviewed on 2026-10-20 against Mole commit [`7b2a196061e1be7fae4ba422cd9102313fcb321d`](https://github.com/tw93/mole/tree/7b2a196061e1be7fae4ba422cd9102313fcb321d) and the published [Mac tested-app inventory](https://mole.fit/zh/tested-apps). The machine-readable [coverage manifest](mole-coverage.json) preserves all 844 published entries, their original search hints, individual guide URLs, declared rule references, and explicit gaps.

## What 844 means

Mole describes 844 Mac applications that its author tested and checked. This is an upstream application inventory, not a list of 844 cleanup rules. It is not evidence that Shou installed, exercised or uninstalled those applications. Mole's current cleanup implementation is procedural code distributed across `lib/clean/*.sh`; uninstall ownership resolution is a separate capability.

Of the 844 snapshot entries, 628 contain an explicit reverse-DNS identity hint in the inventory search field; 216 provide only names, aliases, cask tokens or filenames. The original field is retained. Missing identifiers are recorded as gaps rather than inferred from an application name. Even a reverse-DNS search hint is discovery metadata and requires installed-bundle evidence before uninstall attribution.

| Measure | Reviewed result |
| --- | ---: |
| Upstream tested applications | 844 |
| Inventory entries mapped conservatively to Shou cache/log declarations | 83 |
| Inventory entries with no mapped safe cache/log path | 761 |
| Shou rules before this review | 74 |
| Independently declared additions | 136 |
| Current Shou rule catalog | 210 |
| Current relative path patterns | 660 |
| Current explicit macOS scan locations | 65 |

A mapped entry means at least one named cache or diagnostic path has a static declaration. The 83 mappings are not a limit on runtime cache discovery. Smart Cleanup also discovers the exact `~/Library/Caches/<bundleID>` of an installed application when current bundle, unique ownership and activity evidence permit it, including applications absent from the 844-entry inventory. This does not establish every version, helper, profile, uninstall residue or persistent data location as supported. Application removal remains a separate workflow.

## Path migration

The implementation keeps `builtin-rules.json` and `known-locations.json` as the maintained declaration source. Runtime installed-application cache rules derive only from actual installed bundles through `InstalledApplicationCaches`; they are not additions to the 210-template count. The research manifest grants no filesystem authority and is not loaded by the cleanup engine. Each of the 136 static additions has a pinned source function or selector in `importedRuleSources`. The manifest also records file digests for all ten reviewed cleanup modules.

| Family | Declared scope | Retained boundary |
| --- | --- | --- |
| Application caches | Exact per-application names under `~/Library/Caches`, with finite identities for selected vendor wildcards | Broad vendor roots, unverified wildcard identities, security components and shared ownership |
| Browser profiles | Dia, Helium, Yandex, QQ Browser and Firefox cache leaves; existing Chromium browser scopes remain explicit | Whole profiles, cookies, passwords, history, sessions, extension state, IndexedDB and Local Storage |
| Editor and desktop support roots | Named Zed, CodeBuddy CN, Qoder, Sketch, Spacedrive, Filo and Antigravity generated caches | Workspaces, settings, plugin installations, databases, chat state and backups |
| Games and media | Steam cache leaves, Minecraft web caches, PCSX2 shader cache, Battle.net and Stremio cache leaves | Game installations, saves, memory cards, mods, screenshots and account state |
| Diagnostic logs | Named app support log directories and only Zed, Claude and JetBrains children of `~/Library/Logs` | Unnamed log owners, personal documents and saved application state |
| Developer caches | Named download/analysis leaves for pyenv, rbenv, Bundler, Hex, Opam, Expo, Android, BuildX and frontend tools | Installed toolchains, environments, virtual devices, signing keys, configuration and source trees |

Existing narrow Tencent Meeting and DingTalk rules remain narrow. They are not widened to delete their entire application cache parent. Generic Adobe/Common, Group Containers, security software, AI models, browser model stores and persistent agent directories are not imported as blanket targets. Unverified Quark, mihomo-party and CodeBuddy Extension ownership is deferred.

The reviewed source contains 716 static path **references**, including existence checks and discovery hints as well as cleanup selectors. These are not 716 rules. Their per-reference classification is in `pathReferences`:

| Classification | References | Meaning |
| --- | ---: | --- |
| `declared-path` | 252 | Exact path declaration exists; runtime safety gates still apply |
| `narrower-declaration` | 70 | Only named descendants or finite identities are declared |
| `deferred-owner-or-state-review` | 258 | Persistent state, ownership or version facts need further review |
| `deferred-dynamic-selector` | 63 | Wildcard, age or current-version selection needs an additional contract |
| `deferred-runtime-or-privileged` | 53 | Outside user-home roots or dependent on installed-bundle/runtime/privilege evidence |
| `retained-personal-or-sensitive` | 20 | Potential credentials, sessions, personal data, models or persistent tool state |

Owner commands such as package-manager pruning, Docker/Nix cleanup and simulator management, as well as signed browser clones, firmware and old application versions, cannot be replaced by directory globs. Those behaviors are explicitly listed in `behaviorGaps`. No Windows locations were added.

## Installed-application cache discovery

Mole's `clean_user_essentials` discovers children of the user cache root independently of its tested-app page. Shou implements a narrower contract: a complete current application-directory inventory must identify a unique installed owner with a valid bundle identifier and verified bundle/Info.plist identity. Only its exact current-user cache directory can join the ordinary scan, plan, execution and history path. No name aliases, tested-app search hints, Group Containers or application-support roots supply additional authority.

Maintained rules take precedence, including disabled rules and narrow descendant patterns. Generic discovery cannot widen Tencent Meeting or DingTalk to their whole cache parent, or bypass a disabled declaration. System/Apple applications and Shou itself remain protected; running or unverifiable activity blocks a candidate. An application bundle owned by an administrator can still have a disposable current-user cache: cache ownership and manifest policy are checked independently of bundle ownership.

The current unique-owner policy requires complete application inventory coverage. Unavailable or partial inventories omit generic candidates and report `application_discovery_unavailable` or `application_discovery_incomplete` through `scanKnownLocations`; static rules continue. Shared bundle identifiers omit only those generic owners and report `ambiguous_application_owner`. A complete filesystem snapshot can therefore coexist with an application-discovery issue, and the aggregate system result is partial. Known application directories do not cover arbitrary custom install locations or other accounts.

Snapshots and selected plans retain optional installed-application identity evidence. Plan creation and execution re-read the inventory; each mutation re-reads the concrete bundle and activity facts. Cache cleanup never selects or removes an `.app`. The [daily cleanup architecture and sequence](../product/unified-cleanup.md) and [data model](../architecture/data-model.md) describe this shared path.

## Safety and verification

Imported rules remain review-level, directory-only, trash actions. Application rules retain declarative activity identifiers; unknown application activity blocks execution through the existing gate. Symlinks and cross-filesystem traversal remain disabled. Protected source, credentials, incomplete scans, exclusions and stale evidence still block candidates. A directory whose name says “cache” does not override these protections.

The catalog validates unique identifiers, unique platform-scoped roots, explicit location references, supported platforms and closed path patterns. Imported macOS declarations no longer advertise Windows execution through a generic platform default.

Run the offline manifest checks and negative fixtures with:

```sh
python3 "scripts/verify-mole-coverage.py" --self-test
```

For reproducibility against the reviewed downloads:

```sh
python3 "scripts/verify-mole-coverage.py" --self-test \
  --source-checkout ".build/mole-reference" \
  --tested-apps-html ".build/mole-tested-apps.html"
```

`shou-tests --mole-rules-only` exercises independently authored positive/negative game, profile and developer-state fixtures, and protected descendants across every added declaration. The existing native catalog suite expands every pattern into generated targets and checks Trash/restore behavior. These test entry points do not establish third-party application compatibility. Native and desktop acceptance must be reported separately with actual results.

`shou-tests --installed-caches-only` adds generated installed-bundle fixtures for dynamic discovery, ordinary cleanup/history/restore without uninstall, activity and identity changes, static-rule priority, missing/ambiguous inventory, protection boundaries and legacy optional-field digest compatibility. Its actual execution result is recorded separately in [acceptance](acceptance-and-testing.md).

To refresh the review, freeze a new upstream commit and inventory HTML digest, re-evaluate every changed source selector and behavioral gap, update the declarations and manifest together, then run these checks and the affected native acceptance. A count change must not automatically generate cleanup targets from inventory names or bundle IDs.

## Attribution and license

Thanks to [Mole](https://github.com/tw93/mole), created by [tw93](https://github.com/tw93), for the publicly reviewed path and safety references. Mole is licensed under [GNU GPL version 3](https://github.com/tw93/mole/blob/7b2a196061e1be7fae4ba422cd9102313fcb321d/LICENSE); the unmodified [upstream license text](../../third-party/mole/LICENSE) is retained with this research attribution.

Shou's Swift implementation and JSON declarations were independently written from reviewed path facts. Mole shell implementation, application icons, screenshots and guide prose are not redistributed. The manifest stores names, identity hints, source links and original review decisions. Homebrew cask metadata for Zed, Antigravity, Minecraft, Spacedrive and Stremio was additionally consulted only to check identity aliases; cask zap deletion lists were not imported. Those URLs and response digests are in `additionalIdentitySources`.
