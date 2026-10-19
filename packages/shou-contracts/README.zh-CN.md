# Shou 公开合同

[English](README.md) | 简体中文

状态：设计草案。这里保存语言无关的结构合同，不包含模型、Agent 或业务执行代码。

- [规则 JSON Schema](rule.schema.json)：规则格式 `1.0` 草案。
- [规则语义](../../docs/zh-CN/rules/rule-specification.md)：路径、条件、保护与版本约束。
- [CLI 合同](../../docs/zh-CN/ai/agent-and-cli-contract.md)：能力发现、命令、结果与错误。
- 规则样例：[Rust 构建目录](../../examples/rules/rust-target.rule.json)、[高风险 npm 依赖](../../examples/rules/npm-node-modules.rule.json)，均为禁用草稿用途。

Schema 是结构字段的单一事实源。通过 Schema 不代表路径获得授权、目录可安全删除或应用已实现该格式；这些由语义校验、运行时证据和用户确认决定。
