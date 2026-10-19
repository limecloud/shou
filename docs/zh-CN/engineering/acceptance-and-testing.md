# 验收与测试计划

[English](../../engineering/acceptance-and-testing.md) | 简体中文

状态：验收计划持续执行中。第 11 节记录已完成的本机验证范围，完整产品与发布验收仍未完成。

## 1. 验证分层

| 层级 | 验证内容 | 不能代替的证据 |
| --- | --- | --- |
| 文档与静态合同 | 本地链接、JSON、Schema 与样例一致 | 规则引擎运行、应用构建 |
| 核心单元 | 模式、条件、状态机、去重、风险与版本 | 平台权限和真实文件操作 |
| 文件系统集成 | 临时工作区、链接、身份、废纸篓、记录 | 原生 UI 与 Agent 客户端行为 |
| CLI 合同 | JSON、错误码、分页、取消与确认 | GUI 的可访问性和系统权限 |
| GUI 流程 | 授权、扫描、规则、计划、执行与恢复 | CLI 独立闭环 |
| Agent 操作 | 真实 Codex、Claude Code 等添加规则 | 所有客户端和版本的兼容性 |
| 平台/分发 | 签名、运行库、干净安装、更新与卸载 | 另一个操作系统的支持 |

使用虚构夹具和临时目录，不用开发者真实工作区当自动清理测试数据。

## 2. 产品验收矩阵

| 编号 | 对应需求 | 场景与通过条件 |
| --- | --- | --- |
| AC01 | F01 | GUI 选择目录、CLI 注册路径均可用；缺系统权限时如实报错 |
| AC02 | F02 | 同一虚构工作区的嵌套项目与大目录可发现，未知用途不被隐藏 |
| AC03 | F03 | GUI 与 CLI 创建/导入规则，无需修改应用代码或升级版本 |
| AC04 | F04 | 路径、项目标记、年龄、最小占用和排除条件语义一致 |
| AC05 | F05 | 每个目标具有命中版本、原因、风险、大小口径和局限 |
| AC06 | F06 | 同一目标多规则命中、父子范围冲突被正确处理，不双算 |
| AC07 | F07 | 两个入口独立确认执行，变化目标被阻断，逐项结果真实 |
| AC08 | F08 | 移入废纸篓不报已释放；单独确认只永久移除本次核验项 |
| AC09 | F09 | 全局、工作区、项目排除优先，规则不能撤销保护 |
| AC10 | F10 | 方案重新扫描；恢复不覆盖冲突位置；历史中断状态可查 |
| AC11 | F11 | CLI 命令发现、JSON、退出码、分页与独立闭环符合合同 |
| AC12 | F12 | Rust、Node.js 项目缓存、依赖审阅与个人输出规则有正反用例 |
| AC13 | F17 | 核心不依赖 Apple/Windows 专属 API，平台能力通过接口注入 |
| AC14 | F18 | Windows 后续具有本平台构建、文件安全、UI 与安装证据 |
| AC15 | F19 | 文档语言可切换；桌面与 CLI 文案覆盖目标语言；相同输入在不同 locale 下输出相同机器状态和安全决策 |

F13–F16 为后续能力，实现时添加对应验收，不提前计入首版完成率。

## 3. 规则验证用例

- 有效规则通过结构校验；未知字段、脚本、错误类型与未知版本失败。
- 同版本同内容重复导入幂等；同版本不同内容冲突。
- 拒绝绝对路径、`..`、`~`、环境变量、反斜杠、设备路径与非法模式。
- `**/target` 命中零层与多层目录；`*` 不跨路径段。
- 项目标记要求普通文件且不跟随链接。
- 年龄检查包含完整后代，新修改文件使目录不满足条件。
- 读取错误、预算截断和未知容量不能按满足条件处理。
- 草稿预览不能直接执行；启用后也必须重新扫描并确认计划。

## 4. 开发者场景夹具

```text
workspace/
├── current-project/             # 显式排除，含近期产物
├── idle-rust/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── src/
│   └── target/                  # 旧产物、近期子文件、人工文件等变体
├── web-desktop/
│   ├── package.json
│   ├── package-lock.json
│   ├── src/
│   ├── node_modules/            # 普通依赖、缓存、链接、保护内容变体
│   ├── dist/                    # 可重建与唯一交付物两种业务假设
│   ├── dist-electron/
│   ├── .next/
│   ├── .git/
│   └── unknown-tool-data/       # 只展示，不默认清理
└── candidate-copy/              # 名称不能推断可删除或 worktree 身份
```

容量数据使用可控夹具生成，不要求真的填满几十 GB。测试逻辑容量、分配容量时需分别建立普通文件、稀疏文件和支持平台上的克隆/硬链接用例。

## 5. 必须阻断发布的安全用例

| 编号 | 场景 | 预期 |
| --- | --- | --- |
| S01 | 目标或祖先路径是指向工作区外的链接 | 不遍历、不执行，边界外对象不变 |
| S02 | 扫描后将目标替换为其他目录或链接 | 计划失效或跳过，不处理替换对象 |
| S03 | 顶层目录时间未变但后代发生变化 | 完整清单复核发现变化，不能仅依赖顶层时间 |
| S04 | 父目录包含保护或排除子项 | 整个父目标阻断，不通过删除父目录绕过 |
| S05 | 用户更改规则、排除、选择或动作 | 旧确认失效，需要新摘要与确认 |
| S06 | 非交互 Agent 调用清理 | 返回确认错误，无目标文件变更 |
| S07 | 两个进程同时执行 | 一个获得执行锁，另一个明确冲突 |
| S08 | 同一计划重复提交 | 返回已有执行引用，不再次处理 |
| S09 | 意图日志无法落盘或磁盘满 | 不开始破坏性操作 |
| S10 | 操作后、结果落盘前崩溃 | 重启核对现场，不自动重放未知项 |
| S11 | 废纸篓位置被替换或加入新内容 | 恢复/永久移除拒绝变化项，不处理扩展范围 |
| S12 | 原恢复路径已存在文件 | 不覆盖，需选其他位置或取消 |
| S13 | 文件名含换行、转义序列或恶意指令文字 | 机器结果正确编码，终端显示安全转义 |
| S14 | 平台回收站能力不可用 | 返回不可用，不退回永久删除 |
| S15 | 覆盖部分失败或取消 | 不完整目标受阻；独立完整兄弟目标须有正向覆盖证据及完整清单 |
| S16 | 依赖树内含 `.bin` 符号链接及指向外部的已识别链接 | 仅记录/移动/解除链接条目，外部对象内容与身份保持不变 |
| S17 | 旧 partial 记录没有覆盖字段 | 缺少 `completedPaths` 不能获得执行资格 |
| S18 | 清理发现完成但目录树稀疏 | `scope=cleanup`、`treeComplete=false`；空间分析需要 `full`，界面说明未测范围 |
| S19 | Rust／Swift 生成源码或 Cargo 解包源码 | 精确受信规则及原生布局／活动／归属／完整性证据；受版本控制、修改或未知内容受阻 |
| S20 | 单次系统废纸篓调用中请求停止 | 到安全边界后不启动新项；核对当前调用并保留真实结果 |
| S21 | CLI 与桌面标准扫描 | CLI `scan` 默认 full，`system scan` 默认 cleanup 且 projects=false；桌面仅纳入已登记项目，不隐式遍历主目录 |

任何越界处理、未确认破坏性操作、错误覆盖或不可解释的自动重试均为阻断项。测试范围内通过不能推导为对任意文件系统无风险。

## 6. CLI 与 Agent 实测

- `--json` stdout 恰好一个合法对象，stderr 进度不污染结果。
- 非零退出码、错误 `code`、`status` 与逐项明细一致。
- 每个持久业务入口可被发现，未实现功能不出现在可用列表。
- 非交互命令可添加禁用草稿、验证和预览，无需 GUI。
- 用户在交互终端独立完成确认、清理、历史和恢复。
- Codex、Claude Code 分别完成公开合同发现、草稿生成、校验修正、导入和预览。
- WorkBuddy 等另行记录其终端工具是否可用；不能从其他客户端测试推断兼容。
- 全部流程无 Shou 内部模型请求、Agent 启动或全局配置修改。

本机的 Codex 实测仅指本次 Codex 会话通过命令工具调用已安装的 CLI；不扩展为所有 Codex 客户端形态、Claude Code 或 WorkBuddy 的兼容性结论。

## 7. 原生 macOS 验收

- 浅色/深色、窗口缩放、侧边栏折叠和高分辨率显示正常。
- 表格排序、多选、右键菜单、路径复制和 Finder 定位符合系统习惯。
- 键盘、VoiceOver、焦点与按钮辅助说明可完成核心任务。
- 扫描不会阻塞主线程；关闭、取消、退出不隐藏仍在进行的删除。
- 权限过期、部分结果、未命中、计划过期和恢复冲突均有可操作状态。
- 矩形树图与列表的计量和选择一致，点击图形不隐式清理。
- 中文/英文文案正确区分依赖、缓存、构建输出、废纸篓与永久移除。

## 8. 性能预算

以下为初始工程目标，尚无实测结果，M0/M1 建立基线后可依据证据调整：

| 指标 | 初始目标 | 记录条件 |
| --- | --- | --- |
| 普通扫描 | 100,000 节点在 60 秒内完成只读扫描 | Apple Silicon、16 GB 内存、本地 APFS SSD；不含内容哈希 |
| 内存 | 上述扫描进程峰值 RSS ≤ 300 MiB | 记录结果条目、目录清单保存策略与缓存冷热 |
| UI 响应 | 常用操作主线程无明显阻塞，输入反馈目标 ≤ 100 ms | 使用主线程性能采样与交互延迟测量 |
| 取消 | 1 秒内停止派发新工作 | 已进入系统调用的单项可能仍需等待 |
| 大工作区 | 1,000,000 节点可受限完成或明确报预算不足 | 不无限增内存、不把截断当完整 |

每次报告写明设备、系统、构建、文件数量、存储类型、冷暖状态、耗时和错误。性能目标不是对所有用户磁盘的保证。

## 9. Windows 后续门槛

真实 Windows 环境验证共享核心与 CLI、原生 UI、ACL、文件占用、长路径、junction/reparse point、回收站和恢复、锁与崩溃、运行库、签名安装及升级卸载。

没有该平台证据时，状态为“待验证”，不记成已支持。macOS 的 Swift 单测与 C# 交叉编译不能替代 Windows 文件删除安全验证。

## 10. 证据与报告

未来报告至少包括构建版本、合同版本、平台、已执行用例、通过/失败/跳过、日志位置、已知限制及复现步骤。报告不得包含用户真实凭据或未经同意的项目路径。

文档/Schema 静态检查不能代替运行验证。已执行结果按下面的范围记录，不据此宣称 MVP、全面兼容性或任意目录的清理安全已验收。

## 11. 本机验证记录 — 2026-10-19

本记录补充验收计划，不代表完整产品或发布验收。环境：macOS 15.7.3（24G419）、Apple Silicon MacBookPro17,1、16 GiB 内存；本地 debug 应用安装于 `/Applications/Shou.app`，使用 ad-hoc 签名，未公证。

| 范围 | 实测结果 | 本地 `.build/` 下的证据 |
| --- | --- | --- |
| 核心与隔离只读 worker | 94/94 通过，包括协议拒绝、证据一致、取消与超时 | `read-worker-core-final.log` |
| 独立 CLI 合同 | 58 项通过，没有变更清理目标 | `read-worker-cli-contract.log` |
| 内置规则原生清理 | 80/80 用例中覆盖 74 条规则、460 个模式；真实 Trash → restore，保留文件和哈希一致，禁用 purge | `complete-cleanup-native-final.log` |
| 大目标原生操作 | 100,103 个文件、100,204 项清单；Trash → restore，核对后代元数据与哨兵哈希 | `large-target-trash-restore.log` |
| 安装版桌面清理 | 项目扫描 → 预览取消 → 明确确认 Trash → 历史 → 单独确认恢复，全部 1,035 个夹具文件 SHA-256 一致 | `ui-cleanup-acceptance/gui-restore-verification.json` |
| 个人规则 | 禁用草稿、只读预览、导出、启用与新扫描 → 明确确认清理 → GUI 恢复，同样 1,035 个哈希一致；重复导入幂等，无效 JSON 被拒绝 | `ui-cleanup-acceptance/gui-personal-rule-verification.json` 及 Computer Use 观察 |
| 个人规则版本编辑 | 独立应用及数据目录通过完整 JSON 编辑：无效 JSON、ID 改动、已有版本、负容量拒绝；文本变化使校验失效。0.1.1 禁用保存、0.1.0 绑定保留，双模式和排除等字段核对一致，旧结果与选择清除；新草稿不可执行，手动启用后重扫 → GUI Trash → GUI restore，5/5 文件 SHA-256 一致；中英切换及取消编辑通过 | `ui-rule-revision-acceptance/gui-save-verification.json`、`gui-trash-verification.json`、`gui-restore-verification.json` 及 Computer Use 观察 |
| 版本编辑回归 | 核心 96/96、CLI 合同 58 项通过；新增版本不能覆盖已有定义，新版本默认禁用，原绑定保留，旧扫描与旧计划拒绝执行，新预览不能执行，启用后可创建新计划；560 个资源键通过双语检查 | `rule-revision-core.log`、`rule-revision-cli.log` |
| 版本编辑安装 | 更新 `/Applications/Shou.app` 前确认应用已退出，签名与独立产物检查通过；安装期间配置和历史共 36 份记录哈希保持一致。安装版个人规则筛选、编辑器打开、校验通过、取消返回均经 Computer Use 复核，没有保存已有规则的修改 | `desktop-rule-revision-install.json` 及 Computer Use 观察 |
| 排除策略回归 | 核心 99/99、CLI 合同 73 项通过；全局保护覆盖当前及未来根、完整／清理扫描及草稿预览，项目排除保留同级项目资格。策略变化使旧证据失效，修改存储计划也不能绕过当前保护。配置升级为版本 2，清除最后一条全局模式仍不降级。实际旧 helper 可读取版本 1，在添加全局模式及移除最后一条模式后均拒绝版本 2 | `exclusions-core.log`、`exclusions-cli.log`、`ui-exclusions-acceptance/old-build-compatibility.json` |
| 桌面排除管理 | 独立 GUI 添加全局保护及后续工作区，核对受保护后代禁选、非法 `../demo` 拒绝、整个项目 `demo/**`、工作区保护和逐项独立移除，另一工作区仍可清理。变更清除旧结果与选择；规则／设置入口、重启持久化及中英文布局通过。保留不匹配的全局模式后，两项生成目标完成 GUI 预览 → Trash → 恢复，12/12 文件 SHA-256 一致，确切旧废纸篓路径不存在 | `ui-exclusions-acceptance/gui-policy-scans.json`、`gui-trash-verification.json`、`gui-restore-verification.json` 及 Computer Use 观察 |
| 排除管理安装 | 更新 `/Applications/Shou.app`，签名／产品检查通过，36 份配置与历史记录哈希保留；安装版范围切换、兼容说明、非法项目拒绝和关闭不保存通过。上述 UI 检查没有升级用户已有配置；两种运行时语言共 582 个资源键通过检查 | `desktop-exclusions-install.json`、`ui-exclusions-acceptance/gui-final-verification.json` 及 Computer Use 观察 |
| 中断历史与位置核验回归 | 核心 105/105、CLI 合同 80 项通过；覆盖逐项意图写入前后失败、恢复完成后回执写入失败，以及独立子进程在移动隔离夹具后立即以 86 退出。存储意图保持未完成，旧计划不能重放。原生全目录用例覆盖 74 条规则、460 个模式，并检查恢复前后确切原位置／废纸篓对象的目录清单。独立原生 CLI TTY Trash → 恢复也通过 | `history-inspection-native-location-final.log`、`history-inspection-cli-location-final.log`、`history-inspection-native-cli.log` |
| 桌面历史核验与恢复冲突 | 98,304 字节生成目标经 GUI 审阅 Trash → 核验 → 原恢复位置占用时拒绝 → 保留并移开冲突目录后单独审阅恢复；8 份源码／缓存文件哈希及冲突哨兵一致，确切旧废纸篓路径不存在，原始回执字节不变。合成未完成及 pending follow-up 记录验证动作禁用、批次隔离、双语、锁竞争错误与重试、Escape 关闭；这些 UI 夹具不冒充真实进程中断 | `ui-history-inspection-acceptance/run02/gui-trash-verification.json`、`gui-conflict-verification.json`、`gui-restore-verification.json`、`gui-final-verification.json` 及 Computer Use 观察 |
| 未完成与失败摘要 | 合成 executing/pending 记录显示“未完成的清理”、1 项需要核实、0 已跳过；恢复／永久移除不可用。失败记录显示 1 失败、0 跳过，两行原因均中文化。历史状态中文 → 英文 → 中文即时切换通过，独立数据副本的 11 份记录哈希不变 | `ui-history-inspection-acceptance/run02/gui-results-verification.json` |
| 初始化响应性 | 本地存储初始化移出主线程。独立 Documents 数据目录的 `openat` 阻塞期间，窗口可显示、边栏可切换、Command-Q 正常退出；采样显示主线程在事件循环，存储初始化在后台。具体阻塞原因未知，没有修改系统权限 | `history-inspection-startup-responsive-sample.txt`、`ui-history-inspection-acceptance/run02/startup-responsive-verification.json` |
| 历史核验最终安装 | 最新包已更新至 `/Applications/Shou.app`，签名／产品核验通过，36 份配置与历史记录安装及只读 GUI 复核后哈希不变。冷启动、既有生成目标的只读位置核验、Escape 关闭及返回中文首页通过；619 个资源键通过双语检查。本轮没有清理真实数据或再次永久移除 | `desktop-history-inspection-final-install.json`、`ui-history-inspection-acceptance/run02/installed-gui-final-verification.json` |
| 只读子进程生命周期 | 核心用例已验证两个存活子进程的上限、第三个请求拒绝及取消后容量恢复。另用本机安装包内 CLI 扫描生成的 100,008 个文件条目，在收到进度且尚无结果时让发起进程退出 86；随后约 0.275 秒观察到 worker 不存在，未发布结果。8 份种子文件哈希、硬链接计数及文件条目总数保留 | `history-inspection-native-location-final.log`、`read-worker-parent-exit-acceptance/run01/verification.json`、`read-worker-parent-exit.log` |
| Codex 会话规则操作 | 当前 Codex 会话读取安装版能力和 Schema，生成个人规则，读取 shell 动作的结构化错误后修正为受支持动作，再校验、导入禁用草稿并预览。候选仅命中预期 `.build-cache`，项目本身仍未分类；从草稿预览建计划被拒绝。3 份夹具文件哈希一致，没有计划或清理历史，未修改真实数据或 Agent 全局配置 | `codex-cli-acceptance/run01/verification.json` 及逐命令 JSON |
| 执行取消边界 | 核心 108/108、安装版 CLI 合同 80 项通过。后续操作分别在项目开始前、核验中、意图写入后和恢复后取消；未开始项不变，原始回执保留。含只读 worker 的原生 Trash 在首个 moving 意图写入后立即取消，通过一项已移动／一项 pending 及精确恢复。仍覆盖 74 条规则、460 个模式；禁用 purge | `operation-lifecycle-native-final.log`、`operation-lifecycle-installed-cli.log` |
| 桌面退出与关闭窗口 | 独立应用／存储中，执行时“保持打开”允许 24 个生成目标完成并恢复；移动中“停止并退出”产生 3 项已移动／21 项 pending、0 失败，进程退出。另一次“停止并关闭”同为 3／21，原生日志确认窗口关闭而应用保留。两批均经 GUI 单独确认恢复，全部 12,336 个原始文件哈希一致，确切旧 Trash 路径不存在 | `ui-operation-lifecycle-acceptance/run01/gui-keep-open-verification.json`、`gui-initial-restore-and-close-issue.json`、`gui-stop-quit-verification.json`、`gui-stop-quit-restore-verification.json`、`gui-stop-close-verification.json`、`gui-stop-close-restore-verification.json`、`stop-close-final-native.log` |
| 生命周期修复及失败保留 | 首次“停止并退出”在变更核验中错误记录“扫描已取消”，原生遍历现区分可取消读取与已记录意图的变更；首次“停止并关闭”已安全停止，但完成面板阻止 performClose，现确认关闭时收起该面板并直接关窗。两次失败观察均保留。后续英文全批 Trash／restore 通过，但恢复在下次界面观察前已完成，不计为恢复中停止通过 | `ui-operation-lifecycle-acceptance/run01/gui-stop-quit-cancellation-issue.json`、`gui-stop-close-sheet-issue.json`、`gui-full-english-trash-verification.json`、`gui-full-english-restore-verification.json` |
| 生命周期安装 | 备份旧包后更新 `/Applications/Shou.app`，签名及独立产品检查通过。中文冷启动、空闲关窗／重开、只读历史和正常退出后，36 份配置／历史记录哈希不变；最终核对 12,336 个生命周期夹具文件全部匹配初始哈希。两种语言的 627 个资源键通过检查；没有清理真实数据或新增永久移除 | `desktop-operation-lifecycle-install.json`、`ui-operation-lifecycle-acceptance/run01/installed-gui-final-verification.json`、`installed-idle-close-native.log` |
| 英文恢复停止流程 | 后续一轮实测英文退出提示“Keep Open”，随后 24 项 Trash 全部完成。确认恢复后立即关窗，在首项意图写入前的只读核验阶段停止：0 项恢复，24 项保留在确切记录的 Trash 位置，无后续操作记录，全部 12,336 个文件哈希一致；原生日志确认窗口关闭。重新打开后独立确认恢复 24 项，原始哈希全部一致，旧确切 Trash 路径不存在；切回中文并正常退出 | `ui-operation-lifecycle-acceptance/run01/gui-restore-immediate-stop-verification.json`、`restore-immediate-stop-native.log`、`gui-restore-immediate-stop-final-verification.json` |
| 清理表格键盘与大列表 | 独立 2,000 项目夹具实测空格选择、保护项拒绝、构建组 2,000 项与其他类别选择保留、排序保持候选身份、翻页／末尾滚动、双语标签与高风险说明、预览 Escape 取消及正常退出。Shift-F10 在访达定位普通项目和 Unicode 长路径的确切目标。最初菜单／焦点问题及两次布局超时均保留，后续通过版本将分组选择合并为一次状态更新。空闲采样显示主事件循环，当次 CPU 为 0%、RSS 为 156,016 KiB | `ui-keyboard-acceptance/run01/` 的 Computer Use 观察、`keyboard-menu-sort-issues.json`、`group-selection-layout-issue.json`、`group-selection-layout-second-issue.json`、`idle-resource-observation.json`、`final-interaction-idle-sample.txt` |
| 键盘改进安装 | 最终构建已安装至 `/Applications/Shou.app` 并备份旧包，ad-hoc 签名与桌面／CLI 独立产品验证通过。中文冷启动、只读历史及返回首页通过；36 份既有记录及 6,007 个键盘夹具原始文件哈希均一致。629 个资源键通过双语检查，安装包不含夹具数据目录环境 | `desktop-keyboard-final-install.json`、`ui-keyboard-acceptance/run01/gui-final-verification.json`、`final-scan-verification.json`、`installed-gui-final-verification.json` |
| 应用内减少动态效果与进度辅助名称 | 本地化开关跨重启及中英切换保留。应用内静态模式保留扫描真实阶段／计数，点阵静止；停止后呈现已停止状态，重新扫描完成且不自动勾选。40 个生成目标经过 GUI 预览确认、移入废纸篓、位置核验、独立确认恢复，最终 10,320 个原始文件哈希全部一致。执行进度提供本地化名称／计数，不确定恢复进度显示静态沙漏，完成后进度区域消失。关闭开关后连续观察到点阵扫动，扫描结束回到静态结果。该构建已备份安装，签名／独立产品验证、中文启动、只读历史通过，36 份真实记录哈希保留；632 个资源键通过双语检查 | `motion-accessibility-native-build.log`、`motion-accessibility-stage.log`、`desktop-motion-final-install.json`、`ui-motion-acceptance/run01/gui-final-verification.json`、`trashed-verification.json`、`restored-verification.json`、`installed-gui-final-verification.json` |
| 恢复进度与历史批次选择 | 核心 110/110、CLI 合同 80 项、4 项 TTY 取消及原生 CLI Trash／restore 通过。进度测试验证意图已保存后取消、选择范围内的单调计数，以及恢复冲突失败计数且不覆盖目的地。独立桌面实测原生三态选择 0 → 1 → 48 → 0、单独审阅恢复 48 项及与已完成批次的选择隔离。后续 100,000 文件目标在恢复意图写入后、结果完成前经 GUI 停止：当前项完成，第二项未启动，112,644 个夹具文件在确切原位置或已记录废纸篓位置的哈希全部一致。此前两次停止晚于完成，保留为时机未命中的记录，不计停止通过 | `followup-progress-core-native.log`、`followup-progress-cli.log`、`followup-progress-tty.log`、`followup-progress-native-cli.log`、`ui-followup-acceptance/run01/gui-observations.json`、`hundred-thousand-restore-stop-observer.jsonl`、`durable-stop-verification.json` |
| 恢复改进安装与最终完整性 | 未启动项经新的一条路径预览和确认后恢复；112,644 个原始文件在原位置的哈希全部一致，52 条后续记录均完成恢复，旧废纸篓路径不存在，原始执行回执哈希不变，独立应用正常退出。该构建备份安装后，签名、桌面／CLI 独立产物、中文启动及只读历史通过，36 份既有记录哈希保留，636 个资源键通过双语检查。安装版英文切换尝试受应用状态变化中断，不新增语言切换通过结论 | `desktop-followup-final-install.json`、`ui-followup-acceptance/run01/gui-final-verification.json`、`restored-verification.json`、`installed-gui-final-verification.json` |
| 桌面批量操作与执行停止 | 24 个生成目标完成 Trash → GUI 恢复；再次执行时在首项完成后停止，最终移入 2 项、22 项未处理、0 失败，再经 GUI 恢复已移入的 2 项；两次恢复后全部 12,336 个文件 SHA-256 一致 | `ui-cleanup-acceptance/gui-batch-restore-verification.json`、`gui-execution-stop-verification.json`、`gui-execution-stop-restore-verification.json` |
| 标准扫描 | 两轮均抵达聚合结果页，默认选择为零；早期估算 10.45 GB 并显示超时提示，最终安装包估算 38.95 GB，明确提示一个已登记项目覆盖不完整 | Computer Use 观察；`desktop-responsive-install.json`、`ui-cleanup-acceptance/gui-final-ui-verification.json` |
| 标准扫描取消 | 在原先阻塞的 QQ 根停止后返回首屏，无错误弹窗，可立即再次扫描 | Computer Use 观察 |
| 国际化 | 安装版中文 → 英文 → 中文即时切换；两种运行时语言共 543 个资源键通过检查 | Computer Use 观察及本地化检查器 |
| 路径操作与分析导航 | 项目行原生菜单在访达选中确切夹具目标，并复制其绝对路径；首次空间分析会自动扫描并保留目标位置，“审阅此项目”返回清理页并选中对应项；排除夹具 Next.js 产物后自动重扫，该项显示保护原因且不可勾选 | Computer Use 观察；`desktop-acceptance-install.json` |
| 外观与支持入口 | 亮色、暗色显示通过，暗色偏好跨重启保留，随后恢复跟随系统；反馈与仓库链接打开预期的 GitHub 公开地址 | Computer Use 观察 |
| 恢复后的动作资格 | 停止批次中实际移入的两项恢复后，“恢复”与“永久移除”按钮禁用；22 个未处理项在历史中显示已跳过，原始回执仍保留 `pending` | Computer Use 观察；`gui-execution-stop-restore-verification.json` |
| 过滤后的便捷选择与紧凑布局 | 项目类别选择仅包含本类 4 个合格项；搜索 Rust 后缩小为 2 项，普通选择会排除这些高风险项；搜索 npm 后仅选中 1 项，随后全部清空；窄窗口分类切换与固定底栏仍可操作 | `ui-cleanup-acceptance/gui-final-ui-verification.json` |
| 桌面永久移除 | 独立生成的 106,496 字节目标完成 GUI 扫描 → 审阅后 Trash → 单独审阅永久移除并获得用户明确确认；follow-up 完成，确切废纸篓目标不存在，两份保留源码哈希一致，历史中恢复／移除按钮均禁用 | `ui-cleanup-acceptance/gui-permanent-removal-verification.json` |
| 启动项发现首阶段 | 核心 114/114、CLI 合同 84 项、4 项 TTY 取消及原生 CLI Trash／restore 通过。新增用例覆盖有界 XML／binary 配置读取、未知状态、私密参数／环境值不输出、同标签独立对象、系统来源主动包含、非法输入、链接／FIFO／超限文件及明确预算缺口；损坏的清理存储路径不阻止只读 CLI。独立桌面验证本机 44 项配置、名称／来源／可执行路径搜索、确切访达定位及复制、空匹配、覆盖说明、重读、中英切换与默认／窄窗口布局。包含 Apple 来源后发现 873 项、五个来源，19 个问题明确列出；公开 API 进入原生“登录项与扩展”页，没有修改控件。保留并修正首轮夹具权限、缺失翻译及表格布局溢出问题，最终独立应用正常退出 | `startup-inventory-core-native-final.log`、`startup-inventory-cli-final.log`、`startup-inventory-tty-final.log`、`startup-inventory-native-cli-final.log`、`ui-startup-acceptance/run03/gui-final-verification.json`、`ui-startup-acceptance/run04/gui-final-verification.json` |
| 启动项发现安装 | 已备份并更新 `/Applications/Shou.app`，暂存与安装包完整清单一致，签名及桌面／CLI 独立产物检查通过；693 个资源键通过两种运行语言检查。安装版中文冷启动、44 项只读列表、中文覆盖、英文／中文即时切换、原生登录项设置跳转及 CLI partial／退出码 6 通过；36 份真实记录与 882 份已检查启动配置文件哈希均保留。独立应用正常退出，本机停留中文启动项页且空闲。配置／运行状态仍未知，本轮不证明直接控制、完整注册覆盖、启动项 GUI 停止时机、VoiceOver、Windows 或发布门槛通过 | `desktop-startup-final-install.json`、`startup-inventory-production-stage.log`、`ui-startup-acceptance/run04/installed-gui-final-verification.json`、`installed-cli-default.json` |

这里的标准扫描跑完指流程到达结果页，实际状态为 **partial**：无法访问或超时的位置被明确列出，没有冒充完整扫描。本轮没有清理用户真实缓存或项目；测试目标移入废纸篓不记作已释放磁盘空间。

将原分组辅助结构改为普通原生布局容器后，规则／历史的独立按钮与历史查看结果操作已通过实测。此前 Computer Use 原生服务崩溃时 Shou 采样主线程空闲，不能将其视为 Shou 崩溃证据。VoiceOver、系统减少动态效果、第三方 Agent 实际客户端及生产分发仍分别验收。桌面永久移除仅对单独确认的生成目标通过，不扩展为 CLI purge 或清空废纸篓通过。

应用内“减少动态效果”通过不代表 VoiceOver 通知实际播报或 macOS 系统开关运行时切换已通过；本轮未修改系统设置或正式应用偏好。扫描／执行通知使用原生辅助功能通知，只在操作边界触发；实际语音、焦点及全部辅助功能组合仍待验收。E30 早期完整性异常继续保留，独立新夹具不能解释或替代该异常。

100,000 文件的后续操作验证范围为已观察的大目标扫描／结果与恢复停止边界。该轮保留的 Computer Use 序列没有独立的 Trash 确认观察，因此确认流程采用另行保留的 48 项及前序证据。最初两次停止均晚于完成，不计停止通过。核验脚本曾将新批次复用已恢复对象的废纸篓路径误记失败，修正后按设备／inode 区分对象，文件哈希全部匹配；两次观察均保留。这些独立结果不解释旧 E30 或临时夹具异常。

大列表通过范围限于已列交互及一次空闲资源观察，不代表延迟分位数、长期资源稳定性、VoiceOver 完整流程或十万行 GUI 已通过。最终构建的键盘“复制路径”经访达“编辑 → 粘贴”验证，完整 Unicode 长路径一致；此前快捷键粘贴保留旧值的观察单独留存。本轮夹具没有请求 Trash、恢复或永久移除。

只读 worker 的父进程退出检查可单独重现，不执行清理、不删除生成夹具。证据目录必须尚不存在；10 万个硬链接条目会占用元数据空间及创建时间，不并入快速检查：

```sh
python3 "scripts/verify-read-worker-lifecycle.py" \
  --bin "/Applications/Shou.app/Contents/Helpers/shou" \
  --evidence ".build/read-worker-parent-exit-acceptance/new-run"
```

这项检查不模拟内核中不可中断的文件系统调用，也不覆盖清理过程中的强制退出。废纸篓移动期间正常退出／关窗、首项恢复意图写入前停止已有上表独立 GUI 证据；恢复意图写入后的取消已有边界测试及上表独立 100,000 文件目标的 GUI 停止证据；该轮使用“停止”，不代表关窗／退出的所有组合均已通过。永久移除取消以及系统 Trash 调用内强制退出仍未验收。

最终完整性核对发现停止测试夹具存在尚未解释的变化：目录仍在，12,336 个预期文件均已不在原位置。抽查目录修改时间为本机 16:05:44，晚于 16:00:28 恢复时哈希核验成功记录，早于本次最终安装；Shou 没有更新的清理回执或恢复记录。工作区移除源码只修改登记、绑定与组合；原 1,035 文件夹具在移除登记后仍全部哈希一致。这些事实无法确定变化原因，应保留此前恢复结果的历史证据，**不能将停止夹具的最终完整性计为通过**。证据：`ui-cleanup-acceptance/gui-final-registration-and-hash-verification.json`。

首个临时目录历史核验 GUI 夹具在尚未确认任何桌面清理时，后续发现工作区与已保存记录缺失。原因未知，该次尝试不计入清理／恢复通过。保留 `ui-history-inspection-acceptance/incomplete-temporary-fixture.json` 及原始夹具清单；另行建立于构建目录的 `run02` 有独立完整性证据。新增核验不能解释这次变化，也不能解释此前停止夹具异常。若进程在系统废纸篓调用内退出且未记录返回路径，结果仍未知；核验不会搜索废纸篓或制造恢复权限。

## 12. v0.2.0 候选验收

固定的 v0.2.0 源码通过 127/127 调试检查、89 项真实 CLI 合同与四项取消确认。74 条内置规则、460 个模式在生成夹具上完成真实废纸篓 → 恢复 → 废纸篓 → 显式永久移除，保留文件与恢复哈希一致。原生卸载 CLI 另行通过五组件清理、个人数据同意、TTY 拒绝／取消与独立恢复。

新生成的 100,103 文件目标完成真实废纸篓与恢复，100,204 项完整清单、后代元数据、哨兵哈希和保留源码一致。父进程退出检查中读取子进程停止，没有返回结果，100,008 个生成文件条目保留。

独立的正式 v0.1.0 可执行文件从签名 localhost 源下载 v0.2.0 候选调试应用，完成安装与重启。安装后的可执行文件匹配更新，五个配置／工作区基线文件哈希保留，再次检查显示 v0.2.0 为最新。底部设置、Command-comma、语言切换及排除范围／兼容提示通过。新的生成应用通过精确五组件审阅 → 显式选择个人数据 → 确认移入废纸篓 → 历史记录独立确认恢复；全部文件哈希与外部保留文件一致，原废纸篓路径消失，重复恢复禁用。

本机证据位于 `.shou-local/`：`v0.2.0-debug-tests.log`、`v0.2.0-large-tests.log`、`v0.2.0-worker-lifecycle/verification.json`、`v0.2.0-upgrade-verification.json`、`v0.2.0-gui-trashed-verification.json` 与 `v0.2.0-gui-restored-verification.json`。本轮通过不解释上文旧夹具异常。通用 Release 打包、签名检查及 Intel 原生执行仍为独立发布门槛，GitHub Actions 必须完成后才能公开发布。
