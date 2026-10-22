# 规则目录与覆盖范围

[English](../../engineering/rule-coverage.md) | 简体中文

## 覆盖含义

规则声明描述有界路径模式与适用条件，不代表已验证所有相关应用的兼容性或原生删除。规则数、模式数与真实应用测试数分别计量。

内置声明维护在 `packages/shou-core/Sources/Resources/builtin-rules.json`，精确根位于 `known-locations.json`，结构合同为 `packages/shou-contracts/rule.schema.json`。Windows 适用字段仅表示资源声明，Windows 运行支持仍待实现。

## 安全合同

每条规则具有稳定标识、版本、精确根关联、闭合模式、重建说明、限制和平台适用性。个人数据、凭据、项目、游戏存档、会话和持久工具状态保持受保护。通用缓存发现必须有经过验证的已安装所有者及活跃状态，目录名为 cache 不构成授权。静态规则不能执行任意工具命令。

规则和计划记录 Shou 自有版本化目录来源，新标识由产品统一拥有。每次范围变化补充正例选择和反例保留夹具；原生生成夹具另行验证执行与恢复。

## 验证

```sh
python3 "scripts/verify-rule-catalog.py" --self-test
".build/debug/shou-tests" --rule-catalog-only
```

离线校验器检查重复 ID、路径边界、平台关联与错误夹具。Swift 领域测试检查候选适用性和保护数据；这些均不能代替 Windows 文件系统、UI 或分发验收。
