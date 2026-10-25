import Foundation
import ShouCore
import ShouPlatform

private struct ComparisonScanFixture: Encodable {
    let id: String
    let rootPath: String
    let identity: FileEntry
    let createdAt: Date
    let tree: TreeSnapshot
    let catalogId: String
    let measuredEntryCount: Int
}

@discardableResult private func saveComparisonScan(_ fixture: Fixture, id: String, entries: [FileEntry],
                                                  complete: Bool = true, timestamp: Double) throws -> StorageScan {
    let root=try require(entries.first { $0.path == "." })
    let url=try require(fixture.store.storageCatalogURL(id: id))
    let catalog=try StorageCatalog(url: url, create: true)
    let ordered=[root] + entries.filter { $0.path != "." }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    for entry in ordered { _ = try catalog.append(entry) }
    let tree=TreeSnapshot(entries: ordered, complete: complete, issues: complete ? [] : ["permission_denied"], caseSensitive: true)
    let index=StorageIndex(tree: tree)
    for entry in ordered where entry.kind == "directory" {
        var node=try require(index.nodes[entry.path]); node.isComplete=complete
        try catalog.setTotals(node)
    }
    try catalog.seal()
    let record=ComparisonScanFixture(id: id, rootPath: fixture.workspace.path, identity: root,
        createdAt: Date(timeIntervalSince1970: timestamp), tree: TreeSnapshot(entries: [root], complete: complete,
            issues: tree.issues, caseSensitive: true), catalogId: id, measuredEntryCount: entries.count)
    let data=try Codec.encode(record)
    try fixture.store.write("storage-scans", id: id, data: data)
    return try Codec.decode(StorageScan.self, from: data)
}

private func comparisonEntry(_ root: FileEntry, path: String, inode: UInt64, bytes: Int64, kind: String = "file") -> FileEntry {
    var entry=root
    entry.path=path; entry.kind=kind; entry.inode=inode; entry.links=1
    entry.logicalBytes=bytes; entry.allocatedBytes=bytes
    return entry
}

func storageComparisonMergesWideDirectoriesAndBoundsRanking() async throws {
    let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var before=[root], after=[root]
    for index in 0..<520 {
        let entry=comparisonEntry(root, path: String(format: "entry_%04d", index), inode: UInt64(index + 100), bytes: 4096)
        before.append(entry)
        var current=entry
        if index == 519 { current.allocatedBytes=32_768; current.logicalBytes=32_768 }
        after.append(current)
    }
    before += [comparisonEntry(root, path: "only_earlier", inode: 1000, bytes: 100), comparisonEntry(root, path: "replaced", inode: 1001, bytes: 100)]
    after += [comparisonEntry(root, path: "only_current", inode: 1002, bytes: 200), comparisonEntry(root, path: "replaced", inode: 1003, bytes: 300)]
    for (index, name) in ["'quoted name'", "Mixed CASE", "一组文件", "🧪 fixture"].enumerated() {
        let entry=comparisonEntry(root, path: name, inode: UInt64(index + 1100), bytes: 100)
        before.append(entry); var current=entry; current.allocatedBytes=500; after.append(current)
    }
    try saveComparisonScan(fixture, id: "before", entries: before, timestamp: 1)
    try saveComparisonScan(fixture, id: "after", entries: after, timestamp: 2)
    let engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let metadata=try fixture.store.records("storage-scans") + fixture.store.records("storage-catalogs")
    let result=try await engine.compareStorage(baselineId: "before", scanId: "after")
    try expect(result.status == "complete" && result.examinedEntryCount == 527 && result.changedEntryCount == 8)
    try expect(result.changes.first?.path == "entry_0519" && result.changes.first?.deltaBytes == 28_672)
    for (path, state) in [("only_earlier", "only_baseline"), ("only_current", "only_current"), ("replaced", "replaced")] {
        let row=try require(result.changes.first { $0.path == path })
        try expect(row.state == state && row.deltaBytes == nil)
    }
    try expect(result.deltaBytes == 30_572)
    let top=try await engine.compareStorage(baselineId: "before", scanId: "after", limit: 1)
    try expect(top.changes.count == 1 && top.changedEntryCount == 8 && top.examinedEntryCount == result.examinedEntryCount)
    let bounded=try await engine.compareStorage(baselineId: "before", scanId: "after", maxEntries: 1)
    try expect(bounded.status == "partial" && bounded.examinedEntryCount == 1 && bounded.issues == ["comparison_budget_reached"])
    try expect(try fixture.store.records("storage-scans") + fixture.store.records("storage-catalogs") == metadata)
    let history=try await engine.storageComparisonHistory(scanId: "after")
    try expect(history.candidates.map(\.id) == ["before"] && history.status == "complete")
    try await expectThrows { try await engine.compareStorage(baselineId: "after", scanId: "before") }
    try await expectThrows { try await engine.compareStorage(baselineId: "after", scanId: "after") }
    try await expectThrows { try await engine.compareStorage(baselineId: "before", scanId: "after", path: "../escape") }
    try await expectThrows { try await engine.compareStorage(baselineId: "before", scanId: "after", maxSeconds: .nan) }
}

func storageComparisonRetainsUnknownCoverageAndRejectsReplacedRoots() async throws {
    let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    let file=comparisonEntry(root, path: "cache.bin", inode: 100, bytes: 4096)
    let folder=comparisonEntry(root, path: "folder", inode: 101, bytes: 0, kind: "directory")
    try saveComparisonScan(fixture, id: "complete", entries: [root, file, folder], timestamp: 1)
    var changed=file; changed.allocatedBytes=8192
    try saveComparisonScan(fixture, id: "partial", entries: [root, changed, folder], complete: false, timestamp: 2)
    let engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let partial=try await engine.compareStorage(baselineId: "complete", scanId: "partial")
    try expect(partial.status == "partial" && partial.deltaBytes == nil && partial.changes.allSatisfy { $0.deltaBytes == nil })
    try expect(partial.changes.first { $0.path == "cache.bin" }?.state == "not_comparable")
    var replacedRoot=root; replacedRoot.inode += 1000
    try saveComparisonScan(fixture, id: "replaced_root", entries: [replacedRoot, changed], timestamp: 3)
    try await expectThrows { try await engine.compareStorage(baselineId: "complete", scanId: "replaced_root") }
    var replacedFolder=folder; replacedFolder.inode += 1000
    try saveComparisonScan(fixture, id: "replaced_folder", entries: [root, replacedFolder], timestamp: 3)
    try await expectThrows { try await engine.compareStorage(baselineId: "complete", scanId: "replaced_folder", path: "folder") }
    try FileManager.default.removeItem(at: require(fixture.store.storageCatalogURL(id: "complete")))
    do {
        _ = try await engine.compareStorage(baselineId: "complete", scanId: "partial")
        throw CheckFailure(description: "Cleared comparison indexes must require new scans.")
    } catch let error as ShouError { try expect(error.code == "analysis_unavailable") }
    let history=try await engine.storageComparisonHistory(scanId: "partial")
    try expect(history.candidates.isEmpty && history.status == "partial" && history.issues.contains("history_index_cleared"))
}

func storageComparisonBoundsHistoryAndHonorsCancellation() async throws {
    let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    try saveComparisonScan(fixture, id: "current", entries: [root], timestamp: 10)
    for index in 0..<140 { try fixture.store.write("storage-scans", id: "invalid_" + String(index), data: Data("{}".utf8)) }
    let engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let history=try await engine.storageComparisonHistory(scanId: "current")
    try expect(history.status == "partial" && history.examinedRecordCount <= 128 && history.candidates.isEmpty)
    try expect(history.issues.contains("history_record_limit") && history.issues.contains("history_record_unavailable"))
    let task=Task { withUnsafeCurrentTask { $0?.cancel() }; return try await engine.storageComparisonHistory(scanId: "current") }
    do { _ = try await task.value; throw CheckFailure(description: "Cancelled history must not publish a result.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
}

func storageComparisonUsesNativeAllocatedAccounting() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let before=try await engine.scanStorage(path: fixture.workspace.path)
    let file=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    let handle=try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 42, count: 65_536)); try handle.close()
    try FileManager.default.linkItem(at: file, to: fixture.workspace.appendingPathComponent("project/target/linked.bin"))
    let sparse=try FileHandle(forWritingTo: file)
    try sparse.truncate(atOffset: 1_048_576); try sparse.close()
    let after=try await engine.scanStorage(path: fixture.workspace.path)
    let root=try await engine.compareStorage(baselineId: before.id, scanId: after.id)
    let old=try await engine.storageDirectory(scanId: before.id)
    let new=try await engine.storageDirectory(scanId: after.id)
    try expect(root.status == "complete" && root.deltaBytes == new.item.node.allocatedBytes - old.item.node.allocatedBytes)
    let detail=try await engine.compareStorage(baselineId: before.id, scanId: after.id, path: "project/target")
    try expect(detail.changes.first { $0.path.hasSuffix("linked.bin") }?.state == "only_current")
    try expect(try Data(contentsOf: file).count == 1_048_576)
}
