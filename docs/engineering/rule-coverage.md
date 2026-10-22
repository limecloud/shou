# Rule catalog and coverage

English | [简体中文](../zh-CN/engineering/rule-coverage.md)

## Meaning of coverage

A rule declaration describes a bounded path pattern and eligibility conditions. It does not establish installed-application compatibility or native deletion acceptance. Catalog counts, pattern counts and actual application tests are separate measurements.

Maintain built-in declarations in `packages/shou-core/Sources/Resources/builtin-rules.json`, exact roots in `known-locations.json`, and the structural contract in `packages/shou-contracts/rule.schema.json`. A Windows applicability field is a resource declaration; Windows runtime support remains pending.

## Safety contract

Each rule has a stable identifier, version, exact root association, closed patterns, rebuild notes, limitations and platform applicability. Personal data, credentials, projects, saved games, sessions and persistent tool state remain protected. Generic cache discovery requires verified installed-owner and activity facts; naming a directory cache cannot grant authority. A static rule never executes arbitrary owner commands.

Rules and plans must retain provenance within Shou's own versioned catalog. New identifiers are product-owned. Add positive selection and negative preservation fixtures for every changed scope. Native generated-fixture tests separately exercise execution and restoration.

## Verification

```sh
python3 "scripts/verify-rule-catalog.py" --self-test
".build/debug/shou-tests" --rule-catalog-only
```

The offline validator checks duplicate IDs, path boundaries, platform associations and malformed fixtures. Swift domain tests check eligibility and protected data. Neither substitutes for actual Windows filesystem/UI/distribution acceptance.
