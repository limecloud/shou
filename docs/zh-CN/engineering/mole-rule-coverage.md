# Mole 软件清单与路径覆盖

[English](../../engineering/mole-rule-coverage.md)

本次于 2026-10-20 核对 Mole 提交 [`7b2a196061e1be7fae4ba422cd9102313fcb321d`](https://github.com/tw93/mole/tree/7b2a196061e1be7fae4ba422cd9102313fcb321d) 和官网的 [Mac 实测软件清单](https://mole.fit/zh/tested-apps)。机器可读的[覆盖映射](../../engineering/mole-coverage.json)保留全部 844 项、原始搜索提示、逐项指南链接、规则引用和明确的未覆盖原因。

## 844 的含义

Mole 将这 844 项描述为作者亲手测试和核查过的 Mac 软件。这是上游应用清单，不是 844 条清理规则，也不能证明 Shou 安装、运行或卸载过这些应用。Mole 当前清理逻辑分散在 `lib/clean/*.sh` 的过程代码中；卸载所有权识别属于另一项能力。

其中 628 项的搜索字段含明确的反向域名标识提示，216 项仅有名称、别名、cask token 或文件名。映射完整保留原始字段，对缺失标识记录缺口，不根据名称猜测。即使是反向域名搜索提示，也只是发现元数据；卸载归属仍须以实际安装包证据确认。

| 指标 | 本次核对结果 |
| --- | ---: |
| 上游实测软件条目 | 844 |
| 保守映射到 Shou 缓存或日志声明的条目 | 83 |
| 尚无安全缓存或日志路径映射的条目 | 761 |
| 本次审查前 Shou 规则 | 74 |
| 本次独立声明的新增规则 | 136 |
| 当前 Shou 规则目录 | 210 |
| 当前相对路径模式 | 660 |
| 当前 macOS 明确扫描位置 | 65 |

“已映射”仅表示至少一处具名缓存或诊断路径有静态声明。83 项不是运行时缓存发现的上限：智能清理还会依据当前安装包、唯一归属与运行状态证据，发现已安装应用的精确 `~/Library/Caches/<bundleID>`，包括 844 项清单之外的应用。这不表示覆盖全部版本、辅助程序、用户 profile、卸载残留或持久数据位置。应用移除仍属于独立流程。

## 路径迁移

静态维护声明继续采用 `builtin-rules.json` 与 `known-locations.json`。运行时已安装应用缓存规则由 `InstalledApplicationCaches` 依据真实安装包生成，不计入 210 条静态模板。研究映射不授予文件系统权限，也不由清理引擎加载。136 条静态新增规则均在 `importedRuleSources` 中给出固定提交的函数或路径来源；十个已审查清理模块均保留内容摘要。

| 类型 | 声明范围 | 保留边界 |
| --- | --- | --- |
| 应用缓存 | `~/Library/Caches` 下的明确应用路径；部分厂商通配符仅收敛到有限标识 | 宽泛厂商根目录、未确认的通配标识、安全组件与共享归属 |
| 浏览器 profile | Dia、Helium、Yandex、QQ 浏览器和 Firefox 的缓存叶子；既有 Chromium 范围仍明确列出 | 整个 profile、Cookie、密码、历史、会话、扩展状态、IndexedDB、Local Storage |
| 编辑器与桌面支持目录 | Zed、CodeBuddy CN、Qoder、Sketch、Spacedrive、Filo、Antigravity 的具名生成缓存 | 工作区、设置、插件安装、数据库、对话状态与备份 |
| 游戏与媒体 | Steam 缓存叶子、Minecraft 网页缓存、PCSX2 着色缓存、Battle.net 和 Stremio 缓存叶子 | 游戏安装、存档、记忆卡、模组、截图与账号状态 |
| 诊断日志 | 具名应用支持日志目录，以及 `~/Library/Logs` 下明确的 Zed、Claude、JetBrains 子目录 | 未确认归属的日志、个人文档与应用保存状态 |
| 开发缓存 | pyenv、rbenv、Bundler、Hex、Opam、Expo、Android、BuildX 和前端工具的具名下载或分析缓存 | 已安装工具链、环境、虚拟设备、签名密钥、配置与源码树 |

腾讯会议和 DingTalk 原有窄规则没有扩为整个缓存父目录。Adobe/Common、Group Containers、安全软件、AI 模型、浏览器模型库和持久 Agent 目录不作为整目录目标导入。Quark、mihomo-party 和 CodeBuddy Extension 的归属证据不足，明确暂缓。

当前源文件含 716 处静态**路径引用**，其中包含存在性检查和发现提示，不代表有 716 条清理规则。逐处结论见 `pathReferences`：

| 分类 | 引用数量 | 含义 |
| --- | ---: | --- |
| `declared-path` | 252 | 有精确路径声明；仍须通过运行安全检查 |
| `narrower-declaration` | 70 | 仅声明具名后代或有限标识 |
| `deferred-owner-or-state-review` | 258 | 仍需确认持久状态、所有权或版本事实 |
| `deferred-dynamic-selector` | 63 | 通配、年龄或当前版本筛选需要额外合同 |
| `deferred-runtime-or-privileged` | 53 | 超出用户主目录，或依赖安装包、运行态、权限证据 |
| `retained-personal-or-sensitive` | 20 | 可能包含凭据、会话、个人数据、模型或持久工具状态 |

包管理器裁剪、Docker/Nix 清理、模拟器管理等 Owner 命令，以及签名浏览器副本、固件和旧应用版本，不能用目录通配符代替；`behaviorGaps` 明确记录这些差异。本次没有新增 Windows 位置。

## 已安装应用缓存发现

Mole 的 `clean_user_essentials` 独立于官网实测清单发现用户缓存根的子目录。Shou 采用更窄的合同：完整的当前应用目录盘点必须确认唯一实装 Owner、合法 Bundle ID，以及安装包和 Info.plist 身份；随后只有当前用户目录下精确匹配的缓存目录可以加入普通扫描、计划、执行与历史链路。名称别名、实测清单提示、Group Containers 和应用支持目录均不提供额外执行权限。

静态维护规则优先，包括已禁用规则及只覆盖特定后代的窄模式。通用发现不能把腾讯会议或 DingTalk 扩为整个缓存父目录，也不能绕过关闭的声明。系统／Apple 应用和 Shou 自身保持受保护；应用正在运行或状态无法验证时，候选不能执行。管理员拥有的应用包仍可产生当前用户的可清缓存；缓存所有权及清单策略独立于安装包所有权检查。

当前唯一归属策略要求应用盘点完整。盘点不可用或不完整时，不生成通用候选，并通过 `scanKnownLocations` 明确报告 `application_discovery_unavailable` 或 `application_discovery_incomplete`；静态规则继续可用。重复 Bundle ID 仅跳过这些通用 Owner，并报告 `ambiguous_application_owner`。因此文件系统快照可以完整，但应用发现仍有缺口，系统汇总结果为部分完成。已知应用目录不代表覆盖任意自定义安装位置或其他账户。

快照及已选计划保存可选的实装身份字段。创建计划和执行前重新盘点应用；每项变更前重新读取具体安装包及运行状态。缓存清理不会选择或移除 `.app`。共享链路见[日常清理架构与时序](../product/unified-cleanup.md)和[数据模型](../architecture/data-model.md)。

## 安全与验证

新增规则保持为需要审阅的目录目标，复用普通清理的永久移除与废纸篓计划；桌面默认永久清理，废纸篓为主动选择的替代动作。应用规则保留声明式运行标识，运行状态不可用时继续由现有检查阻止执行。禁止跟随符号链接和跨文件系统遍历；受保护源码、凭据、不完整扫描、排除项和过期证据仍会阻止处理。“cache”目录名不能绕过这些保护。

规则目录校验唯一标识、平台内唯一路径、明确位置引用、支持平台和受限路径模式。新增 macOS 声明不会因通用默认值误报支持 Windows 执行。

离线检查映射与负向夹具：

```sh
python3 "scripts/verify-mole-coverage.py" --self-test
```

对照本次下载重现来源校验：

```sh
python3 "scripts/verify-mole-coverage.py" --self-test \
  --source-checkout ".build/mole-reference" \
  --tested-apps-html ".build/mole-tested-apps.html"
```

`shou-tests --mole-rules-only` 使用独立编写的游戏、profile 和开发状态正反例，并检查每条新增声明中的受保护后代。既有原生规则目录套件会将每个模式展开为生成目标，核验废纸篓与恢复行为。这些入口不等于第三方应用兼容性证据；原生与桌面验收必须依据实际执行结果单独报告。

`shou-tests --installed-caches-only` 使用生成的实装包夹具，覆盖动态发现、普通清理／历史／恢复而不卸载应用、运行态与身份变化、静态规则优先、缺失或歧义盘点、保护边界及旧可选字段摘要兼容。实际运行结果单独写入[验收记录](acceptance-and-testing.md)。

后续更新须固定新的上游提交和清单 HTML 摘要，逐项审查变化路径与行为差异，同步更新声明和映射，再执行这些校验及受影响的原生验收。数量变化不能自动把应用名称或 bundle ID 转成清理目标。

## 署名与许可证

感谢 [tw93](https://github.com/tw93) 创建的 [Mole](https://github.com/tw93/mole) 提供公开可审查的路径与安全参考。Mole 使用 [GNU GPL 第 3 版](https://github.com/tw93/mole/blob/7b2a196061e1be7fae4ba422cd9102313fcb321d/LICENSE)，本研究保留未经修改的[上游许可证全文](../../../third-party/mole/LICENSE)与来源署名。

Shou 的 Swift 实现和 JSON 声明依据核对过的路径事实独立编写，不分发 Mole 的 Shell 实现、软件图标或指南正文。映射仅保存名称、标识提示、来源链接与原创审查结论。另查询 Zed、Antigravity、Minecraft、Spacedrive、Stremio 的 Homebrew cask 元数据以核对标识别名，没有导入其 zap 删除列表；链接与响应摘要见 `additionalIdentitySources`。
