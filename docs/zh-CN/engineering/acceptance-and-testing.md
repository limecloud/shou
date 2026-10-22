# 验收与测试计划

内置 AI 的开关、Jev 优先路由、用户故事／用例和完整原生状态使用[专项需求与验收矩阵](embedded-ai-acceptance.md)。已有服务测试、真实连接观察和待实施项分别记录；文档／构建通过不代表新增界面或路由通过。

[English](../../engineering/acceptance-and-testing.md) | 简体中文

## 0.9.0 实现与卡顿修复（2026-10-21）

[计划 N01–N09](next-version-0.9.0.md)均已有源码实现。目录读取／汇总纳入同一有界调度器后，完整原生生成夹具回归 **233/233** 通过，包含 210 个 macOS 模板／660 模式的废纸篓、恢复及明确永久删除。空间扫描另通过 **4/4** 性能／取消与 **4/4** catalog 专项；不可变回执依赖通过 **2/2**，覆盖损坏／写入失败拒绝、引用保护与原生恢复。Windows 固定缓存另有正反例夹具；WPF Release 交叉构建零警告／零错误，11 项进程 bridge 检查及路径展示通过。真实 Windows Swift／C++／GUI 运行仍待该环境。

真实永久删除采样暴露了完整清单反复 JSON 编码，现先持久化不可变大清单，再发布小状态回执。同规模 12,000 文件、交替顺序的 Release 对照中，执行中位数 **4.101 → 2.808 秒（约减少 32%）**；保留文件哈希一致，所选目标确实消失。1,399 字节主回执仍关联 3,303,949 字节清单，不能声称总记录空间减少 99%。该轮未证明扫描提速，且候选早于后续遍历优化。

真实全盘扫描另发现独立无界汇总队列触达 GCD 64 线程软限制。读取与就绪汇总现共享最多八个执行槽，父目录不占槽等待子目录。独立同树 **18,449 条目／8,192 文件**夹具四次扫描的计数／容量一致，全部文件哈希不变；基线两次进程采样峰值为 **10／46**，候选为 **11／11**。热缓存扫描中位数 **1.021／0.992 秒**包含 ps 开销，不足以证明产品整体提速。首轮诊断与回归并行且采样器覆盖不足，已排除。

正常用户环境的 Computer Use 验证了生成目录精确选择、清理后列表移除目标、历史恢复审阅／确认、已恢复状态及历史结果页返回。两个生成目录均恢复，**三个原始 SHA-256** 全一致，记录的废纸篓路径已不存在。期间有用户并行操作，最初废纸篓确认与首次完成过渡未独立留存。另已检查设置、记录维护入口、中英即时切换并还原中文及外部 Agent 交接。独立残留审阅在应用身份覆盖不完整时拒绝推断孤儿；这不等于无残留，也不能一概归因为权限。最终构建加入中文说明与覆盖范围跳转。

证据：`.build/next-version-core-final02.log`、`.build/next-version-journal.log`、`.build/next-version-finalizer-storage.log`、`.build/next-version-finalizer-catalog.log`、`.build/next-version-many-file-benchmark/result.json`、`.build/next-version-finalizer-benchmark-isolated/result.json`、`.build/next-version-current-scan-worker-sample.txt`、`.build/next-version-ui-20261021/gui-verification.json`。最终包与安装证据汇总于 `.build/next-version-verification.json`。


最终本机复验：覆盖安装核对 **138 个包内文件**，保留当时 **226 份既有记录**；本次未创建旧包备份，另按既有要求清除了核实属于 Shou 的 0.5.0 遗留备份。两份真实用户操作回执的 SHA-256 仍一致。最终安装 helper 独立通过 **158 项 CLI、20 项空间分析、原生 bridge 全套及硬链接永久删除**。本机只读扫描在 2,970,960 项时成功停止并返回起点；重启后统计 **5,430,048 项**并到达结果页，整理阶段观察到 25% 进度。450 个覆盖问题令结果保持 partial，不能视为无缺口整盘扫描；2:31 是整理中的观察值，不是最终耗时基准。实际采样为八个读取线程，未出现原先的线程软限制报告。最终中文残留说明 → 覆盖范围详情 → 返回已走通，应用留在正常用户环境的中文智能清理入口。证据：`.build/next-version-installed-scan-verification.json` 与 `.build/next-version-verification.json`。

以上结果不代表真实未保存文档退出提示、个人工具数据清理、本机真实孤儿删除、全部强制中断组合、真实 Windows 或 Developer ID／公证已通过。下文旧夹具完整性异常继续保留，新夹具通过不能解释旧异常；下列历史版本记录仍保留原验收边界。

永久删除问题诊断（2026-10-21）：已安装的 **0.8.0** 在新建夹具中删除两条硬链接的第一条后停止，另一条残留，记录为部分完成。对既有失败记录的只读检查也发现：部分删除的 `node_modules` 中出现相同的链接数与 ctime 变化。修复后，仅在一次执行内认可从同一文件描述符观测到的 unlink 变化，覆盖同批后续目标及有记录的废纸篓永久移除；其他元数据与内容变化仍阻止删除。桌面端每次尝试规则清理后均作废旧扫描，覆盖永久删除成功与部分失败的情况。

验证结果：**213/213 项完整 Core 检查**、**7/7 原生永久删除专项**、**153 项 CLI 合同检查**、原生 CLI 的终端确认 → 废纸篓 → 恢复 → 永久删除检查、Windows WPF Release 交叉编译及 **12 项进程桥检查**通过。本机 helper 实际移除了两个生成的硬链接目标，所选 inode 的**剩余链接数为 0**，未选择文件哈希不变，重新扫描无候选。Computer Use 走通生成目录选择 → 原生废纸篓 → 完成 → 返回 → 操作记录恢复；返回列表不再显示已移除目录，恢复后 **3 个原始文件的 SHA-256** 全部一致。覆盖安装 **0.8.0** 核对 **138 个包内文件**、保留 **839 份既有记录**，没有保留旧版应用；独立记录目录的 GUI 验证结束后，已重新打开日常安装入口。证据目录：`.build/deletion-diagnostics-20261021/`，包括 `hardlink-before.json`、`installed-hardlinks-final/result.json`、`gui/result.json`、原生与合同检查日志、Windows 日志和 `install.log`。没有重试真实项目中先前失败的清理；未运行 Windows 原生删除与 UI。

使用尚不存在的证据目录复验已安装版的硬链接永久删除：

```sh
python3 "scripts/verify-permanent-hardlinks.py" \
  --engine "/Applications/Shou.app/Contents/Helpers/shou" \
  --evidence ".build/permanent-hardlinks-new-run"
```

检查只会生成并永久删除自己的所选夹具。验证文件名称与 inode 链接的实际移除，不承诺固定的可用空间增量：未选择的硬链接、尚未关闭的文件及文件系统快照仍可能占用数据块。

状态：验收计划持续执行中。第 11 节记录本机验证范围；隔离夹具的桌面与 CLI 永久移除路径已有通过结果，强制中断覆盖仍待完成。

规则扫描进度验证（2026-10-21）：**206/206 项完整 Core 回归**与 **6/6 项规则扫描进度专项**通过。生成夹具覆盖 worker 内部阶段百分比归零、累计发现数量、固定跨位置总量、读取失败、取消、登记顺序和部分结果。共享核心归一发现阶段事件，累计发现、匹配和保存的已完成阶段；桌面会话拒绝回退事件，中央与底部使用同一份累计数量。架构、流程及时序见[操作进度](../product/operation-progress.md)。证据：`.build/scan-progress-reset-20261021/`。

最终 **0.8.0** 覆盖安装核对 138 个包内文件，保留 810 份既有记录文件，不保留旧版备份。Computer Use 在一次只读智能扫描中观察到 **0% → 7% → 83% → 98%**，中央与底部计数一致，依次为 **0 → 102,942 → 156,062 → 256,066**，随后进入 916 个清理候选的结果页。另一轮扫描在累计 109,324 项时停止并返回可重新使用的入口。安装版 CLI 通过 **153 项合同检查**和桌面桥接套件，包含扫描计数不回退与固定三阶段总数检查；Windows Release 交叉构建和 **12 项进程桥接检查**通过，未运行原生 Windows 界面。macOS 使用可访问范围扫描，未修改隐私权限，结果保留部分覆盖状态；未执行真实文件清理。首次构建被并发版本更新打断的日志保留在 `macos-build.log`，成功构建、安装与验收记录见 `macos-build-final.log`、`installation.json`、`verification.json`。

紧凑布局验证（2026-10-21）：页面标题与主要动作统一进入原生工具栏，规则说明压缩为单行并按需展开。Computer Use 已检查中文智能清理、规则、启动项、应用卸载、隐私、操作记录和设置；补验中英文大文件与空间分析结果及正常／约 **902 × 672** 窗口：一个生成大文件显示 **70.7 MB**，四个空间目录的列表与树状图合计 **72.2 MB**。未勾选清理目标，**17 个生成文件 SHA-256** 全部匹配；已恢复中文与正常窗口尺寸。证据：`.build/storage-layout-20261021/gui-layout-verification.json` 及同目录构建／安装日志。Windows 布局变更通过 Release 交叉构建，原生 Windows 界面另行验收。

性能与路径中间省略验证（2026-10-21）：**208/208 项完整 Core 回归**通过，包括 **210 条规则、660 个匹配模式**的生成夹具原生废纸篓 → 恢复 → 废纸篓 → 永久删除。最终进度展示构建通过 **6/6 项进度专项**。最终包内 CLI 通过 **153 项合同检查**、**20 项空间分析检查**、**34 项大文件检查**及废纸篓、恢复、永久删除和历史清理的原生桌面桥接套件；已安装 CLI 独立重跑全部 153 项检查通过。百万行 catalog 检查通过。Release 扫描／查询对照、完整响应一致性、缓存条件和限制见[扫描性能](storage-scan-performance.md)。Windows WPF Release 交叉构建零警告、零错误，12 项进程桥接检查通过；Windows 实机运行仍未验证。

Computer Use 验证 70,001 项生成宽目录结果、全选 70,000 个文件、筛选后取消十项且保留 69,990 项、清空筛选后的混合选择状态及清空全部选择；70,000 个夹具文件均保留。最终安装版界面验证路径只出现一个中间省略号，保留开头及 `zh_CN.cshelpindex` 文件名；停止只读扫描后正常返回入口。未选择或删除真实清理目标。最终 **0.6.0** 覆盖安装核对 138 个包内文件，保留全部 787 个既有记录文件，不保留旧版应用备份。证据：`.build/performance-20261021/verification.json`、`gui-acceptance.json`、`gui-width-fixture-integrity.json`、`installation-middle-path.json` 和同目录日志。保留首次双省略号界面观察和 Windows 回调重写失败记录；最终使用 macOS 原生中间截断与 Windows 实测宽度适配。完整原生清理回归先于纯展示变更，后续进度专项覆盖展示修正；VoiceOver、Windows 原生执行、冷缓存及全盘性能仍为独立验收事项。

操作记录、扫描处理入口与清理返回验证（2026-10-21）：**201/201 项完整核心回归**、**6/6 项空间清理专项**、**4/4 项扫描权限专项**及 **3/3 项记录保留／覆盖说明专项**通过。最终安装包内 CLI 通过 **153 项合同检查**及原生桌面桥接套件，覆盖生成夹具的永久移除、废纸篓／恢复、仅删除历史元数据与已消费计划重复执行拒绝。独立空间分析 CLI 通过 20/20、大文件 CLI 通过 34/34。Windows WPF 交叉构建零警告、零错误，进程桥接检查 11/11 通过；未运行原生 Windows C++ 或 Windows 桌面界面。

Computer Use 验证了精简记录摘要、按需展开详情、**19 条记录／17.1 MB** 的记录清理预览及取消、进度短路径、清理过程中真实的 17% 阶段值、六个生成目录移入原生废纸篓、完成页返回、结果更新与从记录恢复。恢复后 **12,001 个原始文件 SHA-256 全部一致**；六条恢复后续记录完成，原废纸篓路径消失，原始回执保持不变。独立生成文件在扫描后变化时，准备流程在确认前拒绝清理；失败页提供返回和可用的重新扫描入口，重扫后恢复结果列表并清空选择。本机既有历史未被清理。首轮桌面执行发现广泛扫描隐私策略误拦无完全磁盘访问权限下的精确废纸篓回执核验；已保留失败证据，通过独立精确位置核验能力修复，并完成桌面复验。部分完成批次中未开始的项目显示为已跳过。最终直接覆盖 `/Applications/Shou.app` **0.6.0**，核对 138 个包内文件、保留 769 个既有记录文件，不保留旧版应用备份。证据：`.build/cleanup-history-ui-acceptance/run-20261021/verification.json` 及同目录日志、回执和哈希核验记录。该隔离验收不代表受保护磁盘完整覆盖或 Windows 运行时验收。

统一进度基线验证（2026-10-21）：当轮 **192/192 项完整核心回归**、**5/5 项进度专项**、**17/17 项应用卸载回归**及 **6/6 项隐私回归**通过。进度专项覆盖跨位置总数、部分结果边界、隐私事务提交、取消与恢复日志；本机安装包和 Computer Use 验收另行记录。进度架构、流程与时序见[操作进度与反馈](../product/operation-progress.md)。证据：`.build/operation-progress-latest-core-regression.log`、`.build/operation-progress-latest-core.log`、`.build/operation-progress-application-tests.log`、`.build/operation-progress-privacy-tests.log`。


v0.5.0 候选验证（2026-10-20）：提交 `b218d1b` 通过 [Apple Silicon 与 Intel CI](https://github.com/limecloud/shou/actions/runs/39440323365)，覆盖原生文件系统、CLI、本地化、文档和包内可执行文件。另有 16 项生成浏览器夹具的隐私 CLI 检查通过，覆盖终端取消、限定删除、脱敏持久回执与重复执行拒绝。本地包内 CLI 的 5 项已安装应用缓存保护检查通过：应用清单不完整时拒绝动态发现与扫描，夹具哈希不变。本机存在不可读取或链接应用，无法执行该功能的正向原生路径；完整清单合同由 7 项生成夹具 Core 测试覆盖。证据：`.build/v0.5.0-privacy-cli-final/`、`.build/v0.5.0-installed-cache-cli-guards/`。

通用应用缓存接入后回归（2026-10-20）：**182/182 项核心回归通过**，新增通用缓存 7/7 项定向测试通过，GUI 独立完整类型检查通过。动态发现只覆盖真实安装包标识对应的当前用户标准缓存，复用既有规则计划、执行与回执，不卸载应用。此记录不替代最终安装版 CLI／GUI 验收。日志：`.build/current-core-regression.log`、`.build/installed-cache-tests.log`、`.build/current-ui-typecheck.log`。

应用卸载／隐私／规则回归（2026-10-20）：**180/180 项核心与原生文件系统检查通过**，其中 210 条规则、660 个模式逐项完成生成夹具的废纸篓 → 恢复 → 废纸篓 → 永久移除，并核对原始哈希和保留文件。独立定向检查另通过应用摘要／批量卸载 14/14、隐私数据库 6/6、Mole 规则边界 2/2，来源验证器拒绝 6 类篡改夹具。这是通用实装应用缓存发现加入前的完整回归；后续新增领域仍需独立验收。隐私测试只修改生成数据库，不代表所有浏览器版本支持。日志：`.build/current-core-native-tests.log`、`.build/application-batch-20261020/applications-tests.log`、`.build/privacy-tests.log`、`.build/mole-rules-tests.log`。

MangoDisk 对照实装（2026-10-20）：本轮补齐原生大文件入口、按扩展名分类及占用阈值筛选、保存索引查询、稳定分页、已载入三态全选、跨页匹配全选、快速查看与共享清理确认。首页调整为分组导航、磁盘容量摘要、扫描方式菜单、类别选择与固定操作栏。安装版另通过中英即时切换、类别取消与混合状态、展开规则的路径复选框及选择动作、底栏容量联动和清空后禁用清理。**6/6 项大文件核心测试、4/4 项访问边界测试、安装版 CLI 34/34 项大文件合同及 20/20 项原空间分析回归通过**。这些定向结果不替代下文仍有失败的完整脚本记录。证据：`.build/storage-large-files-20261020/README.md` 及同目录日志。

生成大文件的原生桌面闭环通过中文可访问范围引导、50/100 MiB 筛选、AI 模型分类、离页返回、快速查看、单项／三态／全部匹配选择、精确三路径永久确认取消、主动选择废纸篓后 3 项执行成功及历史中 3 项恢复完成。全部 4 个原文件哈希相同，原废纸篓路径均不存在。另验证空间分析的列表和树图一致，大文件直接复用同一扫描结果得到 3 项、246.4 MB，初始无选择。**本轮没有执行 GUI 永久删除，也未删除真实用户内容**。证据：`.build/large-files-ui/20261020-192821/gui-verification.json` 及同目录夹具、执行、恢复记录；统一汇总见 `.build/mangodisk-implementation-verification.json`。

百万条截止问题已由流式 SQLite catalog 修复，以下早期 100 万条限额记录保留为历史。之后真实主目录只读扫描保存 **5,049,012 条**，根分配容量 **340,146,507,776 字节**，212 个直接子项之和与根一致；Documents 与 Library 均已显示。存在 **144 个覆盖问题**，状态仍为 partial，不代表整盘无缺口。局部重复测量中，50,982 节点 Rust HTML 样本中位耗时由 2.390 秒降至 1.528 秒，82,753 节点 Cargo 样本由 2.697 秒降至 2.528 秒；超过 110 万 catalog 行与 69,037 普通文件的独立计量对照无差异。未重新测量整盘耗时，不能外推整盘提升或宣称达到参考软件速度。证据：`.build/storage-catalog-verification.json`、`.build/storage-performance-20261020/README.md`。

REA 包清单、被动运行观察和源码对照分别保留证据；运行观察 ID 为 `ev_d10f9814fdd19dd882d7b38fdd2ac46d1cb05aadbf769f85b69eac0f75e5a8be`，只支持参考应用已暴露的入口和控件事实。精确重复、应用／系统隐私清理、孤儿残留、通用二进制瘦身、系统优化／维护与资源监控仍未实现，详见[参考功能对照](reference-capability-map.md)。本轮不是完整复刻或全功能验收。

安装版大扫描验证（2026-10-20）：正式构建已安装到 `/Applications/Shou.app`，签名和安装文件一致性检查通过，真实 CLI 通过 **20/20 项空间分析检查**。Computer Use 观察启动数据卷的真实只读扫描达到 **1,000,000 条**后，显示“正在加载统计结果”及覆盖不完整提示，随后进入目录列表与空间图，界面显示约 **132.25 GB 分配容量估计**。已保存的扫描包含 **100 个条目页**，状态为部分完成；本轮未选择或删除任何项目，全部 **302 个原有记录文件哈希**保持一致。这项结果验证达到限额后的结果转换，不代表整盘完整覆盖或可释放容量。证据：`.build/local-install/20261020-171205/verification.json`、`.build/storage-progress-verification.json`、`.build/storage-progress-installed-cli.log`。

v0.4.0 发布跟进（2026-10-20）：提交 `e437d20` 已通过 Apple Silicon 与 Intel 上的[主干 CI](https://github.com/limecloud/shou/actions/runs/39396939377) 和标签 CI，分别包含 **149/149 项核心与文件系统测试**、**130 项 CLI 合同检查**、**20 项空间分析 CLI 检查**，以及包内 CLI、本地化和文档检查。[发布流水线](https://github.com/limecloud/shou/actions/runs/39396895934) 的两个架构任务也已通过显式启用的原生永久移除套件和独立的 10 万文件废纸篓／恢复回归。原始打包失败由直接比较 Foundation 的 `/var` 路径与 Python 的 `/private/var` 路径引起；修复后解析文件系统别名，并核对精确的随包 Skill 目录及三个文件的源码一致性。通用打包、签名和发布由该流水线的后续独立任务负责。

大扫描进度回归（2026-10-20）：**5/5 项针对性检查**通过，覆盖真实限额与阶段反馈、只读 Worker 分页证据、加载期间取消、带摘要的持久化分页读回、损坏分页拒绝、取消时不发布残缺扫描元数据，以及可取消的索引计量；原有 **4/4 项空间操作检查**另行通过。生成的 **1,000,000 条元数据**已分段保存并完整读回。本机高负载下该次测试耗时 308.79 秒，不作为性能基准，也不代表整盘已完整覆盖。测试仅使用生成夹具。日志：`.build/storage-progress-tests.log`、`.build/storage-operation-tests.log`、`.build/storage-million-tests.log`；汇总：`.build/storage-progress-verification.json`。

空间分析本机安装（2026-10-20）：重新打包并更新 `/Applications/Shou.app`，保留旧版备份，通过本地临时签名校验与分发文件逐项一致性检查，应用包没有测试环境配置。真实 `~/.local/bin/shou` 入口通过 20 项空间分析 CLI 检查。Computer Use 验证安装版中文入口、生成目录扫描、三态选择、默认永久删除、精确两路径的不可恢复确认、取消后保留选择，以及无选择地返回 Macintosh HD 入口；未请求 GUI 永久执行。全部 4 个夹具文件哈希与全部 251 个原有记录文件哈希一致；本次只读／预览流程仅新增 2 个分析与计划记录。证据：`.build/local-install/20261020-124412/verification.json`、`.build/storage-installed-cli-verification.log`。这是本地构建，尚非公证发布版。

空间分析验证（2026-10-20）：最新完整脚本尝试通过 **141/141 项核心与文件系统测试**，含 74 条内置规则、460 个模式的原生废纸篓／恢复／永久移除闭环，另通过 **130 项 CLI 合同检查**、**20 项空间分析 CLI 检查**、启动入口安装检查和 4 项取消的真实 TTY 确认。脚本随后在卸载集成中因未得到 5 个可选组件失败，保留的审阅记录报告 `application_activity_unavailable`。独立重试曾通过 5 组件卸载及恢复，另一次在执行时返回 `plan_stale`。因此完整脚本**不能计为全部通过**，也未放宽活动或归属核验。证据：`.build/storage-final-full-verification.log`、`.build/storage-uninstall-retry.log`、`.build/storage-final-uninstall-quiet.log`。

4 项独立空间核心测试通过，覆盖选择、保护根、过期与部分结果、新增排除后代、20 MiB 文件、原生废纸篓／恢复、永久删除及永久历史核验。独立真实 TTY 的 CLI 废纸篓／恢复／永久移除也通过，含 Unicode 路径、文件哈希与外部链接保留。证据：`.build/storage-targeted-tests-final.log`、`.build/storage-cli-tests-final.log`、`.build/storage-final-native-cli.log`。

隔离原生桌面流程通过目录选择、扫描／停止、列表与树图联动及三态复选框、筛选／排序、跨目录选择、快速查看、浏览区 ⌘A／Escape、搜索框文本编辑、携带精确目录的 Agent 请求、中英切换、主动选择废纸篓后的实际执行、共享历史恢复与刷新。恢复后全部 4 个生成文件哈希一致，2 个原废纸篓路径不存在。默认永久删除确认展示了精确范围，随后取消；**本轮空间分析不计 GUI 永久执行通过**。没有响应的 ⌘Delete 处理及其产品承诺已移除，永久删除仍通过操作按钮审阅。证据：`.build/storage-ui-verification/run02/fixture.json` 及同目录的 `gui-trash-verification.json`、`gui-restore-verification.json`，以及保留的 Computer Use 观察。本轮计数优先于下文早期记录，未解释旧 E30 或临时夹具异常。

CLI 安装更新（2026-10-20）：已安装的 `~/.local/bin/shou` 通过 130 项合同检查、4 项取消的真实 TTY 确认，以及生成夹具的原生废纸篓／恢复，覆盖 Unicode 路径、文件哈希与外部链接保留；本轮安装更新未运行 purge。分层帮助、具名 Skill 读取和不依赖存储的能力发现通过；启动入口安装器另行通过迁移资源、带引号路径、重复安装及冲突保留。桌面与终端共用同一随包二进制，更新版已中文启动；安装期间保留全部 251 个原有本地记录文件哈希。证据：`.build/local-install/20261020-110539/verification.json`。启动入口执行二进制真实路径，避免符号链接导致资源回退；已有不同终端入口会被保留。

此前验证（2026-10-20）：`sh scripts/test.sh --native-trash-purge` 通过 137 项核心测试、114 项 CLI 检查、4 项终端确认检查，以及生成夹具的原生卸载／恢复、CLI 废纸篓／恢复／永久移除。规则目录闭环覆盖 74 条规则与 460 个模式。Skill 安装测试在临时客户端目录中验证重复安装、备份更新、本地修改冲突、链接与 ZIP 内容。`/Applications/Shou.app` 已备份更新，签名与分发文件一致性通过；安装期间保留全部 233 个原有本地记录文件哈希。UI 与外部客户端的独立有限证据见 [Skill 安装与分发](../ai/skill-distribution.md)。安装证据：`.build/local-install/20261020-103623/verification.json`；同目录下 `ui-verification/export-verification.json` 保存隔离 GUI 导出核验。下文旧记录保留其历史范围，本轮结果不代表强制退出恢复或真实缓存清理安全已通过。

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
| AC16 | F07 | 固定规则桌面快速动作自动选中符合条件的内置候选，通过一次审阅确认执行具体永久清理计划；废纸篓为主动选择的替代操作 |
| AC17 | F08 | 永久动作绑定精确清单，需要 `PURGE`/原生不可逆确认，并持久化逐项结果 |

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
| S21 | CLI 与桌面标准扫描 | CLI `scan` 默认 full，`system scan` 默认 cleanup 且 projects=false；桌面自动发现常见开发目录并复用记住的策略，无工作区前置步骤 |
| S22 | 审阅后改变永久计划动作 | 摘要不匹配或复核失败；绝不能静默把废纸篓动作改成永久移除 |
| S23 | 永久移除项目变化、缺失或扩展 | 跳过/失败并保留 `partial`/`unknown`；绝不退回无界递归删除 |
| S24 | 无 TTY 执行永久计划 | 返回 `confirmation_required`、退出码 7，目标不发生变化 |

任何越界处理、未确认破坏性操作、错误覆盖或不可解释的自动重试均为阻断项。测试范围内通过不能推导为对任意文件系统无风险。

## 6. CLI 与 Agent 实测

永久清理还需验证 `plan create --mode permanent`、结果中的 `action=permanent` 和摘要绑定、`PURGE <plan-id>` 确认、`operation=permanent_cleanup`、平台调用前的 `purging`、成功落盘后的 `purged`、部分失败、取消以及禁止任意 Shell/路径删除。无交互 Agent 可以创建和查看永久计划，但不能执行它。

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
| 启动项发现与受限控制安装 | 已备份并更新 `/Applications/Shou.app`，暂存与安装包完整清单一致，签名及桌面／CLI 独立产物检查通过；核心启停合同、CLI 能力发现及当前用户 LaunchAgent 平台适配通过，执行前重新核验 plist、所有者、标签和父目录并要求 TTY 确认。发现阶段现在对当前用户 Agent 有界执行只读 `launchctl print-disabled` 和准确服务查询，展示 `enabled`、`disabled`、`loaded`、`running`、`not_loaded` 或 `unknown`。安装版中文冷启动、44 项只读列表、状态标签、中文覆盖、英文／中文即时切换、原生登录项设置跳转及 CLI partial／退出码 6 通过；36 份真实记录与 882 份已检查启动配置文件哈希均保留。当前用户 LaunchAgent 详情显示独立“启用／停用”按钮和二次确认说明。没有对用户真实启动项执行 launchctl 改动。完整注册覆盖、启动项 GUI 控制时机、VoiceOver、Windows 或发布门槛仍待验收 | `desktop-startup-final-install.json`、`startup-inventory-production-stage.log`、`ui-startup-acceptance/run04/installed-gui-final-verification.json`、`installed-cli-default.json`、`startup-control-contract-acceptance.json`、当前核心／CLI 测试输出 |
| 应用卸载核心与 CLI | 核心 127/127、真实 CLI 合同 89 项及原生 CLI 卸载／恢复通过，覆盖安装物理身份、确切标识关联、个人数据同意、配置／目标变化拒绝、活动与系统保护、文件内容摘要、父目录身份、无覆盖恢复及卸载 purge 拒绝。原生 CLI 实测个人数据同意、无 TTY 拒绝、TTY 取消、5 组件 Trash、独立恢复、保留哨兵与原始哈希；既有原生 CLI 清理／恢复回归同样通过，没有 purge | `uninstall-core-native-final02.log`、`uninstall-cli-reviewed-final.log`、`uninstall-native-cli-reviewed-final.log`、`uninstall-regression-native-cli-final.log` |
| 桌面应用卸载闭环 | 独立应用／存储验证应用发现、确切路径／标识搜索、个人数据独立同意和撤销后清空选择，中英切换保留 5 项选择，默认与约 904 × 672 布局可用。预览取消后文件不变、历史为空；再次审阅确认后，仅 5 个生成组件实际移入原生废纸篓，估计分配容量 819,200 字节，程序包最后处理。历史展示完整原路径且不提供永久移除，5 项位置核验均匹配；再单独预览并确认 GUI 恢复，5 条逐项后续记录完成，包含保留哨兵的 8 个原始文件哈希全一致，旧 Trash 路径不存在、原始回执字节不变。包含系统来源后发现 112 个应用；Calculator 及其容器受保护，无法选择或预览卸载 | `ui-uninstall-acceptance/run04/gui-observations.json`、`gui-trashed-verification.json`、`cli-inspection-before-restore.json`、`gui-restored-verification.json`、`gui-final-verification.json` |
| 应用卸载安装 | 已备份旧包并更新 `/Applications/Shou.app`；验收版与安装版可执行载荷一致，暂存／安装包清单一致，签名与独立产物检查通过，包内无测试存储环境。安装版中文冷启动、应用管理、英文／中文即时切换、既有历史只读、重读与空匹配搜索通过，包内只读 CLI 如实返回 partial／退出码 6。36 份真实配置／历史／后续记录哈希均保留。完整恢复后的生成应用与数据归档至验收目录，8 个文件哈希一致，应用列表不再匹配其标识；781 个资源键通过双语检查 | `desktop-uninstall-final-install.json`、`uninstall-final-install.log`、`ui-uninstall-acceptance/run04/installed-package-manifest.json`、`installed-gui-final-verification.json`、`installed-cli-applications.json`、`fixture-archive-verification.json` |
| 个人规则向导与清理闭环 | 核心 `shou-tests --native-trash` 131/131 通过，独立 CLI 检查 89 项通过。独立桌面夹具验证了 NSOpenPanel 精确目录、工作区相对模式、父目录标记、容量／年龄条件、非法边界输入、多行重建说明、子项排除、只读预览解释、可取消且保持禁用的草稿、显式启用、全新扫描、审阅后的原生废纸篓、历史位置核验与单独确认恢复。预览得到 1 项符合、1 项受保护、1 项缺少标记；实际只清理符合项。恢复后 9 个夹具文件哈希、原始回执和 36 份生产记录哈希均未变化。两种运行语言通过 837 个资源键检查；安装包更新时未带测试存储环境，英文／中文向导入口均已复核 | `.build/personal-rule-wizard-core-native.log`、`.build/personal-rule-wizard-cli.log`、`.build/ui-rule-wizard-acceptance/run01/`、`.build/desktop-personal-rule-wizard-final-install.json`、Computer Use 观察 |
| 公共更新源与安装版“已是最新”路径 | 公共 Sparkle feed 返回带 enclosure 签名字段的 0.3.0 条目，已发布 DMG／CLI 资产可访问。已安装 0.3.0 应用从设置页查询更新并显示本地化“您使用的就是最新版！”对话框。本次只验证查询，没有安装更新 | `.build/public-appcast-acceptance.xml`、`.build/public-appcast-fetch.json`、Computer Use 观察 |
| 卷重挂载后的工作区身份 | 根目录 inode 稳定而设备标识变化时，只在本次扫描上下文接受该根目录，不改写持久化配置摘要；根目录被替换时仍由原身份门禁拒绝。发布构建在 `/Applications/Shou.app` 完成项目扫描并到达 partial 结果页，选择一个生成的构建目标后打开确认审阅，随后在任何真实文件变更前取消。 | `.build/debug/shou-tests`（128/128）、安装版 `/Applications/Shou.app`、Computer Use AX 观察 |

桌面永久移除已对一个独立生成目标验证：确认后确切废纸篓对象消失，保留文件哈希一致。该结果不覆盖 CLI 永久执行、平台调用内永久移除取消、强制终止后的核对或真实用户数据安全。CLI 合同与核心路径已编译并写入文档，但破坏性 CLI 永久验收仍是开放测试项。应用卸载本轮覆盖已安装应用的受支持确切关联和经系统元数据确认的共享组容器；原应用已不存在时的无主残留发现、外部辅助服务注销、其他账户／自定义路径、卸载 GUI 停止时机、VoiceOver、Windows 与发布门槛仍未通过验收。上述验收未涉及模型接入或内置 Agent，不能作为新 AI 能力的验收证据。卸载回执支持恢复，卸载永久移除仍被阻止，详见[卸载合同](../product/application-uninstall.md)。

保留的早期卸载记录暴露了导航路由缺项、禁用控件 AX 回调和父目录时间戳比较过严；最终构建复核导航及禁选，父目录比较路径／设备／inode，目标清单继续严格检查，旁边语言偏好写入不再令计划失效。首次恢复核验脚本误以为只有一条聚合后续记录，修正后严格要求 5 条不同项目的完成记录。安装版一次重读尝试返回 `noWindowsAvailable`，应用进程仍在；重开窗口后重读及搜索通过，该中断原因未确定。早期失败观察、E30 与旧临时夹具异常继续保留。

这里的标准扫描跑完指流程到达结果页，实际状态为 **partial**：无法访问或超时的位置被明确列出，没有冒充完整扫描。本轮没有清理用户真实缓存或项目；测试目标移入废纸篓不记作已释放磁盘空间。

将原分组辅助结构改为普通原生布局容器后，规则／历史的独立按钮与历史查看结果操作已通过实测。此前 Computer Use 原生服务崩溃时 Shou 采样主线程空闲，不能将其视为 Shou 崩溃证据。VoiceOver、系统减少动态效果、第三方 Agent 实际客户端及生产分发仍分别验收。桌面永久移除仅对单独确认的生成目标通过，CLI 永久计划与清空废纸篓仍不计入通过。

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
