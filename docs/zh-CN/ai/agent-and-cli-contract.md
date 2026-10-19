# CLI 与结构化操作合同

[English](../../ai/agent-and-cli-contract.md) | 简体中文

状态：接口 `1.0` 开发合同。命令已提供源码实现；请通过能力发现核验当前二进制，并按[本地开发指南](../engineering/development.md)构建。发布验收尚未完成。

## 1. 两个一等入口

Shou 支持原生桌面端与独立 CLI。两者共享工作区、规则、扫描、计划、保护策略与历史；CLI 完成清理不需要 GUI 进程。

Codex、Claude Code、WorkBuddy 等现有 Agent 在各自权限允许时调用 CLI。Shou 不调用模型、不启动或开发 Agent、不管理它们的登录与对话。

所有持久业务能力都应有可发现的结构化入口；窗口位置、列宽等临时视图状态除外。不能出现“GUI 能添加规则，但 Agent 只能模拟点击”的设计。

## 2. 全局合同

- 命令为 `shou`，未来 Windows 为 `shou.exe`。
- 人类可读文本支持 `--locale`；语言选择与回退遵循[国际化规范](../product/internationalization.md)，不改变机器字段和安全语义。
- `--help` 提供人类说明；`capabilities --json` 返回当前构建实际支持的命令、参数、限制和副作用等级。
- `--json` 使用 UTF-8，stdout 只输出一个版本化结果对象；进度、诊断与交互提示写 stderr 或控制终端。
- 路径、规则文本和错误消息按不可信数据处理，不能携带终端控制序列影响显示。
- 机器结果容量为整数 bytes、时间为 UTC ISO 8601；不输出本地化错误码。
- 大结果以稳定 cursor 分页；未知参数、未知字段和未知版本显式报错。
- `--json` 不意味着同意清理；没有 TTY 时，破坏性命令返回 `confirmation_required`。
- 终端执行与桌面执行都复核具体计划。首版无 `--yes`、`--force`、通配删除或无人值守执行入口。

## 3. 命令面

副作用等级：R 为只读业务状态；W 为配置、规则、扫描快照或计划的本地写入；D 为文件移动、恢复或永久移除。R 命令可产生必要的诊断，不修改清理目标。

| 命令 | 等级 | 目标 |
| --- | --- | --- |
| `capabilities` | R | 返回真实能力、平台限制、合同版本与输入定义 |
| `locations list` | R | 固定根、存在状态、规则 ID 与检查问题 |
| `system scan` | W | 以清理模式扫描可用固定根，可显式纳入已登记项目 |
| `workspaces list / show` | R | 查看根绑定与当前入口访问状态 |
| `workspaces add` | W | 注册明确路径与 `root_ref`，不等于系统授予访问权限 |
| `workspaces remove` | W | 取消注册工作区、绑定与方案，保留目标文件和清理记录 |
| `workspaces exclude add / remove` | W | 管理排除，变更使旧计划失效 |
| `rules schema` | R | 返回随当前构建固定的规则 Schema，不联网 |
| `rules validate` | R | 检查结构与静态语义，报告未验证的根绑定 |
| `rules import` | W | 添加版本化规则，默认禁用草稿 |
| `rules list / show / export` | R | 查询与导出规则，不导出工作区凭据 |
| `rules enable / disable` | W | 显式切换本机绑定，不自动执行清理 |
| `rules preview` | W | 对规则文件作只读扫描并保存预览，不要求先启用 |
| `scan` | W | `--workspace` 与 `--location` 必须二选一；`--scope full\|cleanup` 默认 `full` |
| `scan results` | R | 按 `scan_id` 分页查询候选与证据 |
| `plan create` | W | 从独立完整且符合策略的显式候选 ID 创建固定计划 |
| `plan show` | R | 展示路径、风险、动作、摘要、有效期与下一步 |
| `plan execute` | D | 在交互终端确认当前计划后执行 |
| `history list / show` | R | 查询执行和逐项结果 |
| `history restore` | D | 单独确认后恢复明确记录对应的项目 |
| `history purge` | D | 单独确认永久移除明确记录对应的本次项目 |
| `presets list / save / show / scan` | R/W | 复用规则组合；`scan` 只生成新扫描，不复用删除许可 |

CLI 参数、GUI 表单和错误均来自同一领域合同；实际命令支持范围必须由 `capabilities` 发现，不能只凭文档假定可用。

## 4. 终端操作示例

常用软件扫描无需选择目录：

```sh
shou locations list --json
shou system scan --max-entries 100000 --max-seconds 60 --json
shou scan --location "chrome" --scope cleanup --json
shou system scan --include-projects true --json
```

`locations list` 不注册目录。`system scan` 先注册全部存在的固定根，保留已有排除项及禁用规则，再返回 `locations`、`scans`、`issues`、`skipped_location_ids`。该命令使用清理模式。`--include-projects true|false` 默认 `false`，设为 `true` 时同时扫描已登记项目工作区；桌面标准扫描使用 `true`。两种入口均不隐式遍历主目录发现项目。每个扫描拥有独立工作区与证据。缺失根跳过，访问失败或不完整扫描返回 partial 信封与退出码 `6`；取消会停止操作。不会合成为用户主目录计划，也不隐式清理。已知应用运行中时阻止关联候选，执行前再次检查；机器原因码为 `application_running`、`application_activity_unavailable`。

`scan --scope full|cleanup` 为兼容已有调用默认 `full`。完整模式测量工作区目录树；清理模式沿已启用规则前缀发现，发现时剪枝 `.git`，命中目标后完整测量。清理结果即使发现已完成仍可能是稀疏数据，不能用于完整目录空间统计。

以下以虚构路径说明预期操作；返回的 ID 应来自真实上一步结果，不能复制示例 ID 作为现有对象。

```sh
shou capabilities --json
shou rules schema --json
shou workspaces add --path "/Users/alice/Developer" --root-ref "developer-workspaces" --json
shou rules validate --file "examples/rules/rust-target.rule.json" --json
shou rules import --file "examples/rules/rust-target.rule.json" --json
shou rules preview --file "examples/rules/rust-target.rule.json" --workspace "ws_example" --json
```

用户审阅后可在终端继续：

```sh
shou rules enable --rule-id "dev.rust-target" --workspace "ws_example" --json
shou scan --workspace "ws_example" --rule-id "dev.rust-target" --json
shou scan results --scan-id "scan_example" --limit 50 --json
shou plan create --scan-id "scan_example" --candidate "candidate_example" --json
shou plan show --plan-id "plan_example" --json
shou plan execute --plan-id "plan_example"
shou history show --execution-id "execution_example" --json
```

`rules preview` 产生的草稿预览不能直接用于执行；启用后重新扫描，再选择候选创建计划。`plan create` 没有缺省全选，多个候选通过重复 `--candidate` 显式提供。

## 5. 统一结果信封

```json
{
  "api_version": "1.0",
  "request_id": "request_example",
  "ok": true,
  "status": "success",
  "data": {
    "plan_id": "plan_example",
    "digest": "sha256:example-not-a-real-digest",
    "state": "ready",
    "item_count": 1,
    "allocated_bytes_estimate": 2147483648,
    "action": "trash",
    "confirmation_required": true
  },
  "warnings": [],
  "error": null,
  "next_actions": [
    {"command": "plan show", "arguments": {"plan_id": "plan_example"}},
    {"command": "plan execute", "arguments": {"plan_id": "plan_example"}, "requires_interactive_confirmation": true}
  ]
}
```

`status` 为 `success`、`partial`、`error` 或 `cancelled`；仅 `success` 时 `ok=true`。`next_actions` 是结构化建议，不是可直接执行的 Shell 字符串，也不构成授权。

错误对象至少包含 `code`、`message`、`details`、`retryable`。例如参数位置用 `details.field="match.relative_patterns[0]"`，范围失效用 `code="plan_stale"`。错误消息可本地化，错误码与参数键保持稳定。

## 6. 扫描结果要求

每个结果至少包含候选 ID、工作区 ID、相对路径、显示路径、文件身份摘要、容量口径、完整性、命中规则版本、条件证据、有效风险及保护结果。

扫描元数据区分 `scope` 与 `tree_complete`，快照保留独立完整子树的覆盖证据。partial 扫描只能为完整覆盖、符合策略且当前可复现完整清单的候选创建计划项目；旧记录缺少覆盖字段不能使不完整目标获得资格。清理模式的 `complete` 不代表整棵工作区已测量。完整扫描中的无规则大目录返回 `unclassified`，支持后续起草规则，不将其称为垃圾。

稳定分页使用不可变扫描快照，cursor 不能指向实时变化的遍历位置。Agent 应保存 ID，再按需查询详情，不依赖聊天里截断的终端表格。

## 7. 退出码

| 退出码 | 类别 | 典型错误码 |
| --- | --- | --- |
| `0` | 成功 | 无错误 |
| `2` | 输入、格式或合同错误 | `invalid_argument`、`invalid_rule`、`unsupported_schema` |
| `3` | 权限或工作区访问失败 | `permission_denied`、`access_expired` |
| `4` | 状态冲突或并发 | `plan_stale`、`already_executed`、`store_busy` |
| `5` | I/O 或本地状态故障 | `io_error`、`store_corrupt`、`journal_unavailable` |
| `6` | 不完整或资源限制 | `partial_result`、`resource_limit` |
| `7` | 缺少明确确认 | `confirmation_required` |
| `8` | 当前平台/构建不支持 | `unsupported_platform`、`capability_unavailable` |
| `130` | 用户取消或中断 | `cancelled` |

出现多类失败时返回主要阻断类别，逐项细节保留在 `data` 或 `error.details`。程序无法启动时无法保证有 JSON，调用者也必须检查进程失败。

## 8. 确认与执行

- 文本模式在 TTY 展示计划 ID、当前摘要、完整可检查范围、项目数、方式与风险；用户主动输入确认。
- `--json` 执行只在存在独立控制终端时允许交互提示，stdout 仍只有结果对象；无 TTY 则退出 7。
- 确认绑定当前计划摘要和动作，当前进程内一次性使用；改变计划必须重新确认。
- 复核失败后禁止自动扩大范围或重试删除；返回原因与新扫描入口。
- TTY 只能提供交互边界，不能证明操作者必然是人；能控制终端的外部 Agent 仍受其自身授权策略约束。
- 首版不向无交互调用提供持久删除令牌。若未来有真实自动化需求，另行设计限范围、限次、限时的授权合同。

## 9. 中断、恢复与幂等

- 扫描取消须保留不完整事实；不能把未测完目标当作可执行候选，也不能推断缺失的旧覆盖证据。
- `plan execute` 重复调用已执行计划返回 `already_executed` 及已有记录引用，不再操作文件。
- 部分成功、进程超时或意外退出后先查询历史与现场；不因没收到 stdout 就自动重新执行。
- 同 ID 同版本同内容导入返回已有规则；同版本不同内容返回冲突。
- 恢复与永久移除以执行记录及项目 ID 定位，每项重新核验；不能接受任意废纸篓路径。

桌面端显示真实执行阶段、当前路径、已处理／总项目数及明确的停止请求状态。Core 在安全项目边界停止启动新项；已开始的单次系统废纸篓调用可能先完成，再核验并记录结果。进度不是完成回执或已释放空间，也不改变 CLI 单个结果 JSON 信封合同。

## 10. 版本与兼容

规则格式版本、CLI API 版本和应用版本分别维护。新增可选字段需保持旧调用方可忽略；改变既有语义、必填字段或状态含义需升级合同版本。真实支持范围通过发现结果公开，不能预告未实现能力为可用。

## 内置识别与空间浏览

登记工作区后可以直接扫描，无需先导入个人规则。内置规则同样受保护策略、计划摘要与执行复核约束；它们不代表预先同意清理。`shou.builtin.` 是保留命名空间，不能通过个人规则导入覆盖。

| 命令 | 行为 |
| --- | --- |
| `rules catalog [--workspace <id>]` | 列出内置模板，或返回绑定到具体工作区的规则定义 |
| `analysis summary --scan-id <id>` | 返回空间根节点、非重叠清理分类、完整性和容量口径 |
| `analysis children --scan-id <id> [--path <relative>] [--limit <n>] [--cursor <cursor>]` | 按已分配空间排序并分页浏览直接子项；根路径默认 `.` |

`rules list` 同时返回 `builtin_templates`。通过现有 `rules disable / enable` 命令管理内置规则；默认启用仅表示允许扫描匹配。`analysis children` 的游标绑定扫描和具体目录，不能在不同目录之间复用。分析结果包含无清理规则的目录与文件，空间浏览不授予删除权限。

`analysis summary` 和 `analysis children` 需要完整模式快照，遇到清理模式快照返回 `partial_result`，应先运行 `scan --scope full`。完整模式本身若为 partial，仍须报告覆盖缺口，不能将缺失数据视为零。

```sh
shou rules catalog --workspace "ws_example" --json
shou scan --workspace "ws_example" --scope full --json
shou analysis summary --scan-id "scan_example" --json
shou analysis children --scan-id "scan_example" --path "." --limit 50 --json
```
