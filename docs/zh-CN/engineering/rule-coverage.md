# 规则目录与覆盖范围

[English](../../engineering/rule-coverage.md) | 简体中文

## 覆盖含义

规则声明描述有界路径模式与适用条件，不代表已验证所有相关应用的兼容性或原生删除。规则数、模式数与真实应用测试数分别计量。

内置声明维护在 `packages/shou-core/Sources/Resources/builtin-rules.json`，精确根位于 `known-locations.json`，结构合同为 `packages/shou-contracts/rule.schema.json`。Windows 适用字段仅表示资源声明，Windows 运行支持仍待实现。

## 安全合同

每条规则具有稳定标识、版本、精确根关联、闭合模式、重建说明、限制和平台适用性。个人数据、凭据、项目、游戏存档、会话和持久工具状态保持受保护。通用缓存发现必须有经过验证的已安装所有者及活跃状态，目录名为 cache 不构成授权。静态规则不能执行任意工具命令。

规则和计划记录 Shou 自有版本化目录来源，新标识由产品统一拥有。每次范围变化补充正例选择和反例保留夹具；原生生成夹具另行验证执行与恢复。

## Windows Rust 产物

Windows 的 Rust `target` 扫描支持狭窄的生成源码布局。只有与当前包内 `shou.builtin.rust-target` 定义摘要完全一致的规则可以识别 `debug|release/build/<crate-hash>/out/` 下的 `.rs`、`.c`、`.cc`、`.cpp`、`.h` 和 `.hpp` 文件，可带一层架构目录。必须同时观察到父目录 `Cargo.toml`、目标内的 `CACHEDIR.TAG`、`.rustc_info.json` 和对应 profile 的 `.fingerprint` 目录。其他源码、项目清单、凭据、仓库、排除项、链接、多重硬链接和外部所有者保护继续有效；个人规则和改写后的内置定义不能申请例外。布局只提供识别依据，不证明任意内容可重建。

准备计划、整批预检及每项执行前，均独立重查文件占用、构建进程和 Git 跟踪状态；二进制产物也要求 Git 检查。原生适配直接有界读取目标祖先的 `.git/index`，不执行 Git、不加载仓库配置，也不从 PATH 查找程序。当前仅接受校验和有效的 SHA-1 v2/v3 完整索引，最多 4 MiB、50,000 条目和三秒。按路径分量保守忽略大小写，嵌套仓库不能掩盖外层跟踪内容。无索引、worktree 指针、v4／split／sparse 索引、大小写敏感祖先、其他版本控制标记、不可读或不安全元数据均阻断；可忽略的大写可选扩展不参与权限判断。

扫描记录不保存可复用的 Git 许可；即使变更适配器承担最终清单核验，每项之前仍须重新取得 Git 事实。`tracked_artifact_content` 表示存在跟踪内容，`artifact_evidence_unavailable` 表示无法完成检查，两者要求保留目标并重新审阅，不把它们显示为构建进程正在运行。共享的中英文原因沿用当前工作台的行内错误展示。公开 Windows 变更门禁仍关闭；实际测试、原生系统及 UI 限制见 [SYNC.md](../../../SYNC.md)。Swift、Node 生成源码与 Cargo 解包源码的 Windows 专用例外尚未实现。

## 验证

```sh
python3 "scripts/verify-rule-catalog.py" --self-test
".build/debug/shou-tests" --rule-catalog-only
```

离线校验器检查重复 ID、路径边界、平台关联与错误夹具。Swift 领域测试检查候选适用性和保护数据；这些均不能代替 Windows 文件系统、UI 或分发验收。
