# 扫描与删除性能调研

[English](../../engineering/storage-performance-research.md) | 简体中文

日期：2026-10-29。状态：源码与官方资料调研，包含本机基准。本文的固定源码表描述优化前基线；随后实施的重复处理优化与验收状态见[架构方案](storage-performance-architecture.md)和[性能记录](storage-scan-performance.md)，不把后续实现改写为原始证据。

## 结论与证据等级

Shou 有优化空间，但现有证据不支持承诺首次扫描或永久删除提升十倍。推荐先减少重复证据处理和逐条开销，再验证读取与持久化流水线，最后增加可失效的增量索引。Windows 单独评估 NTFS 快速发现，不能把这一能力外推到 macOS。

本文使用三种标识：**实测**表示实际运行并保存结果；**源码／文档事实**表示阅读了对应实现或原始说明；**设计假设**表示需要实现和基准验证。没有引用未核验的论文，也没有把项目 README 的宣传倍数当作 Shou 的收益。

来源为五个项目的源码和十二份官方文档。四个网络源码仓库固定到提交，MangoDisk 本地文件与固定提交字节比对通过。下载地址、22 份源码／配套文件及官方 HTML 的 SHA-256、十二次基准原始结果保存在共享[证据清单](../../engineering/storage-performance-evidence.json)。官方网页可能更新，摘要标识本次读取版本；源码链接均使用固定提交。

## 已有实测与适用范围

Apple M1，MacBookPro17,1，8 核、16 GiB，macOS 15.8.1，APFS。两款优化 Release 原生 Core 探针，三轮交替顺序，独立同内容夹具和新状态，普通用户、刷新全量扫描。计时排除夹具生成和进程启动。

| 生成夹具 | Shou 扫描中位数 | MangoDisk 扫描中位数 | Shou 准备＋永久删除 | MangoDisk 准备＋永久删除 |
| --- | ---: | ---: | ---: | ---: |
| 32,768 个小文件，16 个内部目录 | 0.151930 s | 0.109242 s | 4.906515 s | 2.740331 s |
| 4,096 个文件，4,608 个内部目录 | 0.470129 s | 0.109714 s | 2.425797 s | 0.995084 s |

**实测：**扫描耗时比分别为 1.39、4.29；准备与删除为 1.79、2.44。Shou 准备中位数为 0.583384、0.566699 s，执行为 4.323131、1.813331 s。分阶段中位数相加不必等于总耗时中位数。全部十二次运行核对文件数、配对分配容量、目标移除及同级／范围外哨兵内容和 inode。

这些结果存在以下限制：

- 两款产品合同不同。Shou 保存完整持久化 catalog、不可变清单和执行日志；MangoDisk 使用内存目录聚合、有界文件保留，并在删除准备时固定当前目标身份。不能把差值归因为语言或单一算法。
- 未清系统缓存，其他桌面负载未控制。Shou 目录密集扫描原始范围为 0.263–1.000 s；三次样本不足以估计可靠的尾延迟或置信区间。
- 全探针峰值 RSS 中位数为 Shou 55.0／52.3 MiB、MangoDisk 18.6／14.3 MiB，不是单独扫描阶段内存。
- 未进行阶段归因的 profiler／系统调用跟踪，尚不能断言 SQLite、JSON、锁或 `unlinkat` 各占多少时间。
- 没有 GUI、全盘、冷缓存或 Windows 性能实测。本次没有运行 dua、dust、gdu、WinDirStat 的性能测试。

此前同机 Debug／Release 的 2.41／1.42 倍差异是构建模式对照，不能计为算法收益。详细条件与原始结果见[现有记录](storage-scan-performance.md#2026-10-29-shou-与-mangodisk-原生流程实测)。

## Shou 优化前基线

以下链接固定到 `6f24e7796af1263823e77518ffb584f2c4867cb5`。基线探针的未发布 warning 修复不改变本节扫描与删除算法；后续工作区优化与此表分开记录。

| 阶段 | 源码／文档事实 | 性能含义与尚未验证的假设 |
| --- | --- | --- |
| macOS 枚举 | [NativeStorageMeasurement](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-platform/Sources/NativeStorageMeasurement.swift) 使用批量目录元数据、最多八个目录 worker、128 条写入批次 | 原生批量读取已实现；增加线程不等于成倍提升 |
| 写入与汇总 | 同文件的 `StorageParallelState.append` 持锁逐条调用 catalog；后序汇总由同一调度器派发 | 活跃并发有界，但 pending 工作并无独立字节配额；锁竞争、队列峰值需要测量 |
| catalog | [StorageCatalog](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/StorageCatalog.swift) 单事务、预编译语句、父 ID＋文件 basename、末尾建查询索引；单文件绑定身份、容量和时间等字段 | 已避免每条事务提交；不应再次提出“加事务即可”。逐条绑定、临时数值数组和目录 UPDATE 是待测成本 |
| 小扫描发布 | [StorageOperations.scanStorage](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/StorageOperations.swift#L180) 对不超过 10,000 条的 catalog 再读全量明细、排序、内联保存 | 明确存在重复表示；是否主导 8,707 条夹具耗时尚未归因 |
| 准备与历史 | [StorageRemovalPlanRecords](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/StorageRemovalPlanRecords.swift)、[FileManifestRecords](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/FileManifestRecords.swift)、[ReceiptJournal](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/ReceiptJournal.swift) 使用 4,096 条不可变页；计划／历史分别保存清单 | 首次写历史有再次编码、hash 和写入机会；后续状态更新已复用清单，不能称每次状态都重写全树 |
| macOS 删除 | [NativeFileSystem.purge](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-platform/Sources/NativeFileSystem.swift#L617) 完整现场比较后按逆序清单移除；普通文件在循环和 `unlinkFile` 内相邻读取元数据 | 可以评估收敛重复比较；紧邻系统调用的身份检查仍须保留，硬链接分支不能套用普通文件优化 |
| 删除祖先 | [PermanentRemovalDirectories.parent](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-platform/Sources/PermanentRemovalDirectories.swift#L75) 复用 FD，但逐条检查锚路径及各层挂接身份 | 深树含约 `Σ depth(entry)` 的祖先检查工作；没有证明可安全跳过这些检查 |
| Windows 扫描 | [StorageScanner](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Core/StorageScanner.cs) 显式 stack，顺序等待目录读取，保留完整观测、身份和完成集合 | 没有 macOS 的磁盘 catalog 流水线；不能声称两端已具有同一内存／并发架构 |
| Windows 原生读取与删除 | [NativeDirectoryReader](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Platform/NativeDirectoryReader.cs) 已有 64 KiB 批量名称读取；[WindowsCleanupMutation](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Platform/WindowsCleanupMutation.cs) 完整核验目标树，再逐句柄 disposition 并核对移除，重复检查 context | 批量名称读取不等于批量取得所有身份字段；公开变更门禁仍关闭，不能以源码存在宣称原生清理体验通过 |

派生 catalog 当前使用 `journal_mode=OFF` 和 `synchronous=FULL`，并在封存后发布。它与不可丢失的执行意图日志有不同生命周期，不能用一条“关闭同步”建议同时处理两者。

Windows [WindowsFileSystem.ReadDirectoryAsync](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Platform/WindowsFileSystem.cs#L67) 已用容量 128 的 Channel 连接原生生产者与消费者，授权通道也有有界传递。新增方案针对跨目录调度、全量内存保留和磁盘索引，不应重复建设已有的目录内背压。

## 同类实现可以借鉴什么

### MangoDisk：减少需要保留的工作

固定提交：`4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b`。已读取 [analysis.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-platform/src/macos/analysis.rs)、[bulk_directory.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-platform/src/macos/bulk_directory.rs)、[index_projection.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-core/src/storage/analysis/index_projection.rs)、[deletion.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-core/src/storage/analysis/deletion.rs) 和 [permanent_delete.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-core/src/filesystem/permanent_delete.rs)。本地仓库未修改。

**源码事实：**批量元数据、目录并发与内存聚合，有限保留文件索引；导航投影可以补读。删除准备固定当前目标身份；扫描计量不等同于 Shou 的完整冻结后代清单。

**可借鉴：**将目录聚合、查询投影和执行证据分开；避免 UI 导航重复构造全树。**边界：**Shou 现有完整文件列表和历史比较仍需要明细。若以后提供只保留目录的快速概览，必须明确其覆盖与能力，不能冒充完整快照或删除证据。原生批量读取和八路并发并非本轮待引入的新能力。

### dua：紧凑记录与有界事件通道

MIT，提交 `467f3ec158a8bdc3fd4f79d7d885841beacf6ea3`。[TreeNode／Tree](https://github.com/Byron/dua-cli/blob/467f3ec158a8bdc3fd4f79d7d885841beacf6ea3/src/traverse.rs#L129) 把节点放入连续 arena，名称单独存一次，用索引连接父子；源码注释声明支持的 64 位目标上节点为 64 字节。[BackgroundTraversal.start_inner](https://github.com/Byron/dua-cli/blob/467f3ec158a8bdc3fd4f79d7d885841beacf6ea3/src/traverse.rs#L1041) 使用容量 100 的 crossbeam 通道、后台 dispatcher，状态有 250 ms 节流。

**可借鉴：**批次所有权转移、背压、名称与结构字段分开保存。**边界：**64 字节是该项目的节点设计说明，不是 Shou 内存实测；Shou 的身份、权限、时间、完整性字段更多，不能直接承诺相同大小。本文未据此推断底层 walker 使用 jwalk。

### dust：后序依赖计数与元数据复用

Apache-2.0，提交 `c5e1855143a27c3f7b5e20441fc479fb07e387c8`。[PendingDir／walk_dir／finalize_chain](https://github.com/bootandy/dust/blob/c5e1855143a27c3f7b5e20441fc479fb07e387c8/src/dir_walker.rs#L64) 使用 pending 计数、单个根的 Rayon scope 和扁平后代任务；最后完成者向上汇总。`cached_metadata`、`prefetched` 避免部分过滤和汇总路径重复 stat。

**可借鉴：**不让父任务阻塞等子任务、把已取得的只读元数据交给同次计算。**边界：**不说明整个任务积压有字节上限，也不允许把扫描元数据复用为后续删除授权。其可跟随链接的模式不符合 Shou 的默认范围。

### gdu：并行策略需要与合同一起比较

MIT，提交 `b723b703fe3b756a9d1422e37495d68d0eb2a4b6`。[ParallelAnalyzer](https://github.com/dundee/gdu/blob/b723b703fe3b756a9d1422e37495d68d0eb2a4b6/pkg/analyze/parallel.go) 用 `2*GOMAXPROCS` 信号量限制活动目录处理，但为排队子目录创建 goroutine。活动处理数有界不代表任务数、内存有界。

[ItemFromDirParallel](https://github.com/dundee/gdu/blob/b723b703fe3b756a9d1422e37495d68d0eb2a4b6/pkg/remove/parallel.go) 用 `3*GOMAXPROCS` 限制子目录 `os.RemoveAll`，等待后处理父目录，只保留首个错误。可用于提出“独立子树并发是否有效”的实验，不能替换 Shou 的精确清单、完整错误回执和取消边界。

### WinDirStat：Windows 可以改变发现路径

GPL-3.0，提交 `5a90f5eaae3253993cc7cfd501655f51829ec820`。[FinderNtfs](https://github.com/windirstat/windirstat/blob/5a90f5eaae3253993cc7cfd501655f51829ec820/windirstat/FinderNtfs.cpp#L155) 打开卷，查询 `FSCTL_GET_NTFS_VOLUME_DATA`，通过 `$MFT::$DATA` 和 `FSCTL_GET_RETRIEVAL_POINTERS` 获取数据段，用 4 MiB 对齐缓冲读取 MFT，再构造记录与名称索引。[CItem.ScanItems](https://github.com/windirstat/windirstat/blob/5a90f5eaae3253993cc7cfd501655f51829ec820/windirstat/Item.cpp#L1351) 在快速引擎可用且项不要求 basic 时选 NTFS finder，否则选 basic 等后端。

这是**原始 MFT 读取**，不能写成“WinDirStat 使用 `FSCTL_ENUM_USN_DATA`”。可借鉴按卷选择后端与失败回退；本轮不复制 GPL 源码，不把复杂的原始文件系统解析列为第一阶段方案。

## 官方资料核查

| 编号与实际来源 | 文档明确支持的结论 | 对 Shou 的限制 |
| --- | --- | --- |
| D1 [Apple FSEvents 使用指南](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) | `MustScanSubDirs` 需要递归重扫；`KernelDropped`／`UserDropped` 需要完整重扫监控范围；根变化与 ID 回绕需要处理 | 增量缓存必须能失效，事件不提供删除授权，也不使首次全扫自动变快 |
| D2 [FSCTL_ENUM_USN_DATA](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-fsctl_enum_usn_data) | 在指定 USN 边界枚举 MFT 记录；该页要求 NTFS | 是快速发现候选方案，不能推断所有卷或 ReFS 支持 |
| D3 [Change Journals](https://learn.microsoft.com/en-us/windows/win32/fileio/change-journals) | NTFS 变更日志可帮助维护索引；日志可以创建、删除、重新创建 | 不存在或重建的日志需要重新建立基线 |
| D4 [USN_JOURNAL_DATA_V0](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-usn_journal_data_v0) | `UsnJournalID`、`FirstUsn`、`NextUsn`、`LowestValidUsn` 提供日志身份和范围信息 | 必须检查游标连续性与日志身份，不能只保存“最后扫描时间” |
| D5 [USN_RECORD_V2](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-usn_record_v2) | 记录文件／父引用、USN、事件时间、原因、SecurityId、属性与名称 | 结构中没有完整逻辑／分配容量、owner SID 和 ACL；事件时间不等于文件修改时间。不能直接生成现有完整证据 |
| D6 [GetFileInformationByHandleEx](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex) | 按信息类向调用方缓冲返回元数据，包含目录信息类 | 这是 Shou 当前 `NativeDirectoryReader` 的入口；需要按实际类读取／补齐字段 |
| D7 [NtQueryDirectoryFile](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntquerydirectoryfile) | 一次缓冲可包含多个目录记录，数量受缓冲和匹配条目限制 | 是另一底层 API 的资料，不代表 Shou 已直接调用它或换用后必然更快 |
| D8 [CreateFileW，Physical Disks and Volumes](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew) | 直接卷／磁盘访问受限，文档列出管理员权限、共享模式和非缓存对齐要求 | 快速卷发现必须经过统一 Platform 授权；拒绝授权仍支持普通遍历 |
| D9 [SQLite Atomic Commit](https://www.sqlite.org/atomiccommit.html) | 原子提交依赖写入次序与刷盘等保证 | 可重建索引与执行日志应分开分析；不能取消执行意图的持久性 |
| D10 [SQLite FAQ 19](https://www.sqlite.org/faq.html#q19) | 多条操作同一事务可以摊薄提交成本；原文还明确提示早期数值过时 | Shou 已在同一事务插入，不能用该文章的历史吞吐宣称本轮收益 |
| D11 [35% Faster Than The Filesystem](https://www.sqlite.org/fasterthanfs.html) | 特定约十万份、8–12 KiB 小 BLOB 的 SQLite 与单文件读写实验 | 不是目录元数据遍历或 Shou 测试，标题不能证明 SQLite 在本场景必快／必慢 35% |
| D12 [POSIX unlink／unlinkat](https://pubs.opengroup.org/onlinepubs/9799919799/functions/unlink.html) | 删除目录项并减少链接数；最后链接移除后，打开引用仍可延后内容回收 | 必须区分调用完成、目录项消失、估计移除容量与卷可用容量 |

## 提速上限如何判断

设计分析使用工作量模型，不借外部文章的百分比作预测。设 `N` 为条目数、`D` 为目录数、`B` 为批量页数、`dᵢ` 为各条目的祖先深度：

```text
全扫工作 ≈ B 次批量读取 + 必要的补充元数据 + N 次记录处理 + D 次汇总 + 索引封存
串行端到端 ≈ 枚举 + 记录 + 汇总 + 封存 + 发布
理想流水线 ≈ max(读取阶段, 写入阶段) + 依赖／封存／发布开销
永久删除 ≈ 准备证据 + 发布意图 + 目标现场完整比较
           + Σ(祖先检查 dᵢ + 紧邻身份检查 + 移除调用) + 结果持久化
重复增量 ≈ 事件处理 + 受影响条目／目录复核 + 祖先汇总 + 索引提交
```

这些是成本分解，**不是测得的耗时占比**。若某项只占总时间 20%，即使完全消除，总收益上限也只有 `1/(1−0.2)=1.25` 倍。必须先测占比，不能将若干优化的宣传倍数连乘。

几十倍的合理研究方向是改变工作量：例如有效增量只重扫很小一部分目录，或消除经实测确认的重复／随深度放大的处理。但事件汇总、重命名、硬链接传播和封存仍有成本；“变化 1%”不自动等于 100 倍。

首次完整扫描需要取得现有完整合同要求的事实；永久删除在现有路径中至少处理已选目录项。后台 rename 可能缩短用户看见目录的时间，但不等于清理已完成或空间已释放，不能作为几十倍物理删除的证据。

## 方案选择

| 方案 | 结论 | 依据与进入条件 |
| --- | --- | --- |
| 去掉小 catalog 的重复内联明细 | 优先验证 | 存在明确重复路径；先审计全部读取方和旧记录兼容 |
| 不可变清单在计划与历史间共享 | 优先设计 | 避免重复编码／写入；必须先落实引用生命周期和崩溃恢复 |
| 批次通道＋单写入器 | 测到锁等待后实施 | 参考 dua 背压；保留单 writer，避免为未证实问题增加线程层 |
| 目录依赖计数／投影分离 | 随流水线实施 | 参考 dust 与 MangoDisk；完整明细和覆盖仍保存 |
| 删除合并相邻重复普通文件读取 | 独立小实验 | 仅收敛重复检查，保留最后检查、硬链接和竞态回归 |
| 独立目标／子树并发删除 | 后续受控实验 | 从 1／2／4 并发比较，先证明共享身份、日志、失败和取消合同 |
| FSEvents／USN 增量 | 数量级提升的主要候选 | 仅针对重复分析；需要可靠基线、连续性检查和强制全扫回退 |
| Windows NTFS USN 发现 | 独立原型 | 先量化补齐完整字段后的总耗时，不能只测 FRN 枚举 |
| 原始 MFT 自行解析 | 后置 | 高权限、解析与一致性复杂；先验证官方 API 路径 |
| 只留 top 文件、直接 `rm`／`RemoveAll`、无限并发、关闭执行日志刷盘 | 不纳入现合同 | 丢失明细或破坏范围、资源、恢复／回执合同 |
| 全部改用 Rust | 无证据支持 | 对照合同不同，语言重写无法保证减少实际工作量 |

实施文件、数据生命周期、故障处理、基准矩阵和停止条件见[架构方案](storage-performance-architecture.md)。
