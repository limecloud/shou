# Shou public contracts

English | [简体中文](README.zh-CN.md)

Status: design draft. Language-independent definitions; no model integration, agent implementation, or cleanup execution.

- [Rule JSON Schema](rule.schema.json): draft format `1.0`.
- [Rule semantics](../../docs/rules/rule-specification.md): paths, conditions, protection, versions.
- [CLI contract](../../docs/ai/agent-and-cli-contract.md): discovery, inputs, results, errors.
- [Internationalization](../../docs/product/internationalization.md): stable machine identifiers and localized text.
- Examples: [Rust artifacts](../../examples/rules/rust-target.rule.json), [high-risk npm dependencies](../../examples/rules/npm-node-modules.rule.json).

Schema validation establishes structural conformance only. Actual access, eligibility, current state, confirmation, and implementation support require separate checks. Do not create translated copies of machine contracts.
