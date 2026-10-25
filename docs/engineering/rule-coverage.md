# Rule catalog and coverage

English | [简体中文](../zh-CN/engineering/rule-coverage.md)

## Meaning of coverage

A rule declaration describes a bounded path pattern and eligibility conditions. It does not establish installed-application compatibility or native deletion acceptance. Catalog counts, pattern counts and actual application tests are separate measurements.

Maintain built-in declarations in `packages/shou-core/Sources/Resources/builtin-rules.json`, exact roots in `known-locations.json`, and the structural contract in `packages/shou-contracts/rule.schema.json`. A Windows applicability field is a resource declaration; Windows runtime support remains pending.

## Safety contract

Each rule has a stable identifier, version, exact root association, closed patterns, rebuild notes, limitations and platform applicability. Personal data, credentials, projects, saved games, sessions and persistent tool state remain protected. Generic cache discovery requires verified installed-owner and activity facts; naming a directory cache cannot grant authority. A static rule never executes arbitrary owner commands.

Rules and plans must retain provenance within Shou's own versioned catalog. New identifiers are product-owned. Add positive selection and negative preservation fixtures for every changed scope. Native generated-fixture tests separately exercise execution and restoration.

## Windows Rust artifacts

Windows Rust `target` scanning recognizes a narrow generated-source layout. Only a rule whose digest exactly matches the current bundled `shou.builtin.rust-target` definition can recognize `.rs`, `.c`, `.cc`, `.cpp`, `.h` and `.hpp` files under `debug|release/build/<crate-hash>/out/`, optionally below one architecture directory. It also requires the parent `Cargo.toml`, target `CACHEDIR.TAG`, `.rustc_info.json` and the corresponding profile's `.fingerprint` directory. Other source, project manifests, credentials, repositories, exclusions, links, multiple hard links and foreign owners retain protection. Personal rules and altered built-in definitions cannot request the exception. Layout identifies the artifact; it does not prove arbitrary contents are rebuildable.

Planning, whole-plan preflight and each item independently recheck file use, build processes and Git tracking, including binary-only targets. The native adapter reads bounded ancestor `.git/index` files directly without executing Git, loading repository configuration or finding a program through PATH. It currently accepts checksum-valid complete SHA-1 v2/v3 indexes only, within 4 MiB, 50,000 entries and three seconds. Component-boundary comparisons conservatively ignore case; nested repositories cannot hide outer tracked content. Missing indexes, worktree pointers, v4/split/sparse indexes, case-sensitive ancestors, other VCS markers, unreadable or unsafe metadata all block eligibility. Ignorable uppercase optional extensions grant no authority.

Saved scans contain no reusable Git permission. Each item still obtains fresh tracking facts when the mutation adapter owns final manifest verification. `tracked_artifact_content` identifies tracked contents; `artifact_evidence_unavailable` identifies an incomplete check. Both require retaining and reviewing the target; neither is presented as a running build process. Shared bilingual reasons use the current workspace's inline error presentation. Public Windows mutation gates remain closed; actual tests, native-system and UI limits are recorded in [SYNC.md](../../SYNC.md). Windows-specific Swift/Node generated-source and Cargo extracted-source exceptions remain unimplemented.

## Verification

```sh
python3 "scripts/verify-rule-catalog.py" --self-test
".build/debug/shou-tests" --rule-catalog-only
```

The offline validator checks duplicate IDs, path boundaries, platform associations and malformed fixtures. Swift domain tests check eligibility and protected data. Neither substitutes for actual Windows filesystem/UI/distribution acceptance.
