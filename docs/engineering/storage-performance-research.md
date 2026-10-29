# Scan and deletion performance research

English | [简体中文](../zh-CN/engineering/storage-performance-research.md)

Date: 2026-10-29. Status: source and official-document research with local measurements. The pinned source table describes the pre-optimization baseline. Subsequent duplicate-work changes and acceptance are recorded in the [architecture proposal](storage-performance-architecture.md) and [performance records](storage-scan-performance.md), separately from the original evidence.

## Findings and evidence levels

Shou has optimization opportunities, but current evidence does not justify a tenfold improvement promise for initial full scans or permanent deletion. First reduce duplicate evidence processing and per-entry overhead, then validate a read/persistence pipeline, and finally add invalidatable incremental indexes. Evaluate NTFS discovery separately on Windows.

**Measured** means an executed test with retained results. **Source/document fact** means an inspected implementation or primary document. **Design hypothesis** requires implementation and measurement. No unverified paper is cited, and no project's advertised speedup is treated as Shou's expected gain.

Sources comprise five projects and twelve official documents. Four downloaded repositories are pinned to commits; inspected MangoDisk files were compared byte-for-byte with its recorded local commit. URLs, SHA-256 hashes for 22 source/supporting files and official HTML, and all twelve benchmark executions are retained in the shared [evidence inventory](storage-performance-evidence.json). Official pages can change; hashes identify the retrieved versions. Source links use fixed commits.

## Existing measurements and limits

Apple M1, MacBookPro17,1, eight cores, 16 GiB, macOS 15.8.1, APFS. Both native Core probes use optimized Release builds, three alternating rounds, fresh isolated state, matching generated fixtures, ordinary-user access and refreshed full scans. Timing excludes fixture generation and process startup.

| Generated fixture | Shou median scan | MangoDisk median scan | Shou preparation + permanent deletion | MangoDisk preparation + permanent deletion |
| --- | ---: | ---: | ---: | ---: |
| 32,768 small files, 16 internal directories | 0.151930 s | 0.109242 s | 4.906515 s | 2.740331 s |
| 4,096 files, 4,608 internal directories | 0.470129 s | 0.109714 s | 2.425797 s | 0.995084 s |

**Measured:** scan time ratios are 1.39 and 4.29; preparation/deletion ratios are 1.79 and 2.44. Shou preparation medians are 0.583384 and 0.566699 s; execution medians are 4.323131 and 1.813331 s. Phase medians need not sum to the total median. All twelve executions verify file counts, matching allocated totals, target removal, and sibling/out-of-scope sentinel contents and inode identity.

Limits:

- Contracts differ. Shou retains complete persistent catalogs, immutable manifests and execution journals. MangoDisk uses directory aggregation in memory, bounded file retention and current-target identity pinning during deletion preparation. Differences cannot be attributed to language or one algorithm.
- Caches were not cleared and concurrent desktop load was uncontrolled. Shou directory-heavy scans range from 0.263 to 1.000 s; three samples do not establish tail latency or a reliable confidence interval.
- Whole-probe median peak RSS is Shou 55.0/52.3 MiB and MangoDisk 18.6/14.3 MiB. This is not scan-phase memory.
- No stage-attributed profiler or syscall trace establishes the shares of SQLite, JSON, locks or `unlinkat`.
- There are no GUI, full-volume, cold-cache or Windows performance measurements. dua, dust, gdu and WinDirStat were inspected, not benchmarked.

Earlier 2.41/1.42 ratios compare Debug with Release, not new algorithms. Conditions and prior evidence are in the [existing records](storage-scan-performance.md).

## Shou before optimization

Links below pin `6f24e7796af1263823e77518ffb584f2c4867cb5`. Unreleased warning fixes in the baseline probe do not change these scan/removal algorithms; subsequent working-tree optimizations are recorded separately.

| Stage | Source/document fact | Implication and unverified hypothesis |
| --- | --- | --- |
| macOS enumeration | [NativeStorageMeasurement](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-platform/Sources/NativeStorageMeasurement.swift): bulk directory metadata, at most eight directory workers, batches of 128 | Bulk reads already exist; adding threads does not imply proportional improvement |
| Writes/aggregation | Its `StorageParallelState.append` invokes catalog inserts under a lock; postorder aggregation uses the same scheduler | Active concurrency is bounded, but pending work has no separate byte quota. Lock waits and queue peaks need measurement |
| Catalog | [StorageCatalog](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/StorageCatalog.swift): one transaction, prepared statements, parent ID + basename, query indexes built at sealing | Per-insert commits are already avoided. Binding overhead, temporary integer arrays and directory UPDATEs are candidates, not proven bottlenecks |
| Small-scan publication | [StorageOperations.scanStorage](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/StorageOperations.swift#L180) reads back, sorts and saves inline details for catalogs of at most 10,000 rows | Duplicate representation exists; its contribution to the 8,707-row workload is unmeasured |
| Plan/history evidence | [StorageRemovalPlanRecords](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/StorageRemovalPlanRecords.swift), [FileManifestRecords](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/FileManifestRecords.swift), [ReceiptJournal](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-core/Sources/ReceiptJournal.swift): immutable 4,096-entry pages, separate plan/history collections | Initial history persistence may encode/hash/write again. Later state updates already reuse manifests; they do not rewrite the whole tree every time |
| macOS removal | [NativeFileSystem.purge](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-platform/Sources/NativeFileSystem.swift#L617) compares the complete current tree, then removes reverse manifest order; adjacent metadata reads occur in the loop and `unlinkFile` | Consolidation is a candidate; the final identity check and hard-link handling remain required |
| Removal ancestry | [PermanentRemovalDirectories.parent](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/packages/shou-platform/Sources/PermanentRemovalDirectories.swift#L75) reuses FDs but checks anchor path and ancestor attachments per entry | Ancestry work includes approximately `Σ depth(entry)`; safe removal of these checks is not established |
| Windows scanning | [StorageScanner](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Core/StorageScanner.cs) uses an explicit stack, sequential directory awaits and complete observation/identity/completion collections | It does not have the macOS disk-catalog pipeline; the platforms do not yet share memory/concurrency architecture |
| Windows native operations | [NativeDirectoryReader](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Platform/NativeDirectoryReader.cs) already batches names in 64 KiB; [WindowsCleanupMutation](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Platform/WindowsCleanupMutation.cs) verifies the complete target tree, applies handle dispositions, checks removal and repeatedly verifies context | Name batching is not complete identity batching. Public mutation remains gated; source existence is not native product acceptance |

The derived catalog uses `journal_mode=OFF`, `synchronous=FULL` and publication after sealing. Its lifecycle differs from durable mutation intent; a generic “disable synchronization” recommendation must not cover both.

Windows [WindowsFileSystem.ReadDirectoryAsync](https://github.com/limecloud/shou/blob/6f24e7796af1263823e77518ffb584f2c4867cb5/apps/windows/src/Shou.Windows.Platform/WindowsFileSystem.cs#L67) already uses capacity-128 channels between native producers and consumers, including bounded authorized delivery. Proposed work addresses cross-directory scheduling, full in-memory retention and disk indexing, not rebuilding existing per-directory backpressure.

## Inspected implementations

### MangoDisk: retain less work where the contract permits

Commit `4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b`. Inspected [analysis.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-platform/src/macos/analysis.rs), [bulk_directory.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-platform/src/macos/bulk_directory.rs), [index_projection.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-core/src/storage/analysis/index_projection.rs), [deletion.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-core/src/storage/analysis/deletion.rs) and [permanent_delete.rs](https://github.com/harry0703/MangoDisk/blob/4285d46644f2b9e53dee4ddfa3b3b5374dd64e3b/src-tauri/crates/mangodisk-core/src/filesystem/permanent_delete.rs). Its local checkout remains unchanged.

**Source facts:** bulk metadata, parallel directories, in-memory aggregation, bounded file retention and navigation projections with supplementary reads. Deletion pins current target identity during preparation; scan accounting is not Shou's complete frozen descendant manifest.

**Transferable:** separate aggregation, query projections and execution evidence. **Limit:** Shou's complete lists and historical comparison require details. A future directory-only overview must state its capabilities and cannot masquerade as complete evidence. Bulk reads and eight-way concurrency are already implemented in Shou.

### dua: compact records and bounded events

MIT, commit `467f3ec158a8bdc3fd4f79d7d885841beacf6ea3`. [TreeNode/Tree](https://github.com/Byron/dua-cli/blob/467f3ec158a8bdc3fd4f79d7d885841beacf6ea3/src/traverse.rs#L129) uses a contiguous arena, separate name storage and indexed tree links. Its comments state a 64-byte node on supported 64-bit targets. [BackgroundTraversal.start_inner](https://github.com/Byron/dua-cli/blob/467f3ec158a8bdc3fd4f79d7d885841beacf6ea3/src/traverse.rs#L1041) uses a bounded crossbeam channel of 100, a background dispatcher and a 250 ms throttle.

Use ownership transfer, backpressure and separate name/structure storage as ideas. The 64-byte claim describes that implementation, not Shou memory: Shou requires additional identity, permission, timestamp and coverage fields. No conclusion about a jwalk backend is drawn here.

### dust: completion dependencies and metadata reuse

Apache-2.0, commit `c5e1855143a27c3f7b5e20441fc479fb07e387c8`. [PendingDir/walk_dir/finalize_chain](https://github.com/bootandy/dust/blob/c5e1855143a27c3f7b5e20441fc479fb07e387c8/src/dir_walker.rs#L64) uses pending counters, one Rayon scope per root, flat descendant tasks and upward finalization by the last completer. `cached_metadata` and `prefetched` avoid repeat stat calls in particular filtering/aggregation paths.

Use completion dependencies and metadata reuse within one observation. This does not establish a byte bound on all pending tasks or permit reuse as later deletion authority. Its link-following modes do not match Shou's default scope.

### gdu: compare concurrency together with its contract

MIT, commit `b723b703fe3b756a9d1422e37495d68d0eb2a4b6`. [ParallelAnalyzer](https://github.com/dundee/gdu/blob/b723b703fe3b756a9d1422e37495d68d0eb2a4b6/pkg/analyze/parallel.go) limits active directory processing with `2*GOMAXPROCS`, while creating goroutines for queued subdirectories. Bounded active operations do not imply bounded task memory.

[ItemFromDirParallel](https://github.com/dundee/gdu/blob/b723b703fe3b756a9d1422e37495d68d0eb2a4b6/pkg/remove/parallel.go) limits child-directory `os.RemoveAll` with `3*GOMAXPROCS`, waits before removing the parent and retains only the first error. This motivates an independent-subtree concurrency experiment; it cannot replace Shou's exact manifests, result accounting or cancellation boundaries.

### WinDirStat: a different Windows discovery path

GPL-3.0, commit `5a90f5eaae3253993cc7cfd501655f51829ec820`. [FinderNtfs](https://github.com/windirstat/windirstat/blob/5a90f5eaae3253993cc7cfd501655f51829ec820/windirstat/FinderNtfs.cpp#L155) opens the volume, queries `FSCTL_GET_NTFS_VOLUME_DATA`, obtains runs using `$MFT::$DATA` and `FSCTL_GET_RETRIEVAL_POINTERS`, reads MFT data using aligned 4 MiB buffers and builds record/name indexes. [CItem.ScanItems](https://github.com/windirstat/windirstat/blob/5a90f5eaae3253993cc7cfd501655f51829ec820/windirstat/Item.cpp#L1351) selects the NTFS finder when loaded and the item does not require basic handling, otherwise basic or other backends.

This is **raw MFT reading**, not `FSCTL_ENUM_USN_DATA`. Backend selection and fallback are useful design references. No GPL implementation is copied; raw filesystem parsing is deferred.

## Verified official documents

| Source | What it supports | Shou limit |
| --- | --- | --- |
| D1 [Apple FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) | `MustScanSubDirs` requires recursive rescanning; `KernelDropped`/`UserDropped` require full monitored-scope rescans; root changes and ID wrap need handling | Incremental caches need invalidation; events grant no deletion authority or initial-scan speedup |
| D2 [FSCTL_ENUM_USN_DATA](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-fsctl_enum_usn_data) | Enumerates MFT records within USN bounds; the page requires NTFS | A discovery candidate, not evidence for arbitrary filesystems or ReFS |
| D3 [Change Journals](https://learn.microsoft.com/en-us/windows/win32/fileio/change-journals) | NTFS journals support index maintenance and can be created, deleted or recreated | Missing/recreated journals require a new baseline |
| D4 [USN_JOURNAL_DATA_V0](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-usn_journal_data_v0) | Journal identity and bounds include `UsnJournalID`, `FirstUsn`, `NextUsn`, `LowestValidUsn` | Validate identity and cursor continuity, not just last scan time |
| D5 [USN_RECORD_V2](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-usn_record_v2) | File/parent references, USN, event timestamp, reasons, SecurityId, attributes and name | No complete logical/allocated sizes, owner SID or ACL; event time is not file mtime |
| D6 [GetFileInformationByHandleEx](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex) | Information classes return metadata into caller buffers, including directory classes | This is Shou's actual directory-reader entry point; required fields depend on the class and supplementary reads |
| D7 [NtQueryDirectoryFile](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntquerydirectoryfile) | Buffers can contain multiple directory records, bounded by matches and capacity | A different lower-level API; no claim that Shou directly calls it or switching must be faster |
| D8 [CreateFileW: Physical Disks and Volumes](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew) | Restricted direct volume access, administrator privileges, sharing and uncached alignment requirements | Use unified Platform authorization; preserve ordinary traversal when unavailable |
| D9 [SQLite Atomic Commit](https://www.sqlite.org/atomiccommit.html) | Write ordering and flushing underpin commit guarantees | Analyze rebuildable catalogs separately from durable mutation intent |
| D10 [SQLite FAQ 19](https://www.sqlite.org/faq.html#q19) | Transactions amortize commit cost; old numeric claims are explicitly outdated | Shou already batches inserts in a transaction |
| D11 [35% Faster Than The Filesystem](https://www.sqlite.org/fasterthanfs.html) | A particular roughly 100,000-object, 8–12 KiB BLOB experiment | Not directory traversal or Shou; its title establishes no 35% gain/loss here |
| D12 [POSIX unlink/unlinkat](https://pubs.opengroup.org/onlinepubs/9799919799/functions/unlink.html) | Removes directory entries and decrements links; open references can delay reclamation after the last link | Distinguish API completion, name removal, estimated bytes and actual volume free space |

## Reasoning about possible gains

The following is a workload model, not measured stage attribution. Let `N` be entries, `D` directories, `B` bulk pages and `dᵢ` each entry's ancestor depth:

```text
Full-scan work ≈ B bulk reads + required metadata supplements + N record operations
                 + D aggregations + index sealing
Serial elapsed ≈ enumeration + recording + aggregation + sealing + publication
Ideal pipeline ≈ max(read stage, write stage) + dependencies/sealing/publication
Permanent removal ≈ preparation + durable intent + full live manifest comparison
                    + Σ(ancestry dᵢ + final identity check + unlink) + result persistence
Repeated incremental ≈ event processing + affected-scope inspection
                       + ancestor aggregation + index commit
```

If a component takes 20% of elapsed time, eliminating it entirely can yield at most `1/(1−0.2)=1.25` times improvement. Measure fractions first; do not multiply unrelated advertised speedups.

Order-of-magnitude improvement is a reasonable research direction when work is reduced: a valid incremental index rescans a small fraction, or measurements expose repeated/depth-amplified processing. Event handling, renames, hard-link propagation and sealing still cost time; 1% change does not automatically yield 100 times speedup.

An initial complete scan must obtain the facts required by its contract. The existing permanent-deletion path processes selected directory entries. Renaming out of view and deleting later changes visible waiting, not physical completion or reclaimed space.

## Options and decisions

| Option | Decision | Evidence/entry condition |
| --- | --- | --- |
| Remove duplicate inline details for small catalogs | Validate first | Explicit duplicate path; audit readers and compatibility |
| Share immutable manifests between plans/history | Design first | Avoid encoding/writes only with sound reference retention and recovery |
| Bounded batches + one writer | Implement if lock waits justify it | Backpressure reference from dua; avoid unnecessary orchestration |
| Completion counters and separate projections | Alongside pipeline | References from dust/MangoDisk; retain complete facts and coverage |
| Consolidate adjacent ordinary-file checks | Isolated experiment | Preserve final checks, hard-link and race behavior |
| Parallel independent deletion targets/subtrees | Later experiment | Compare concurrency 1/2/4 after proving identity, journal and stop behavior |
| FSEvents/USN incremental indexing | Main candidate for large repeated-scan gains | Requires baseline, continuity and full-scan fallback; not an initial-scan promise |
| Windows NTFS USN discovery | Separate prototype | Measure complete metadata supplementation, not FRN enumeration alone |
| Raw MFT parser | Defer | Privilege, parser and consistency complexity; validate official APIs first |
| Top-files-only replacement, `rm`/`RemoveAll`, unlimited concurrency, nondurable intents | Excluded from current contract | Lose completeness, scope, resource or recovery guarantees |
| Rewrite everything in Rust | Unsupported by evidence | Different contracts do not prove a language bottleneck |

File ownership, lifecycle, faults, benchmark matrix and stop conditions are in the [architecture proposal](storage-performance-architecture.md).
