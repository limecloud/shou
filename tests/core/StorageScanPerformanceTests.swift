import Foundation
import Dispatch
import ShouCore
import ShouPlatform

func storageBulkMetadataPreservesExactStatEvidence() throws {
    let fixture=try Fixture()
    let deep=(0..<20).map { "level-" + String($0) }.joined(separator: "/")
    for index in 0..<64 {
        try fixture.put(deep + "/数据-" + String(index) + "-é.bin", String(repeating: "x", count: index * 128))
    }
    try fixture.put("first/original", String(repeating: "h", count: 16_384))
    try fixture.put("second/keep", "keep")
    try FileManager.default.linkItem(at: fixture.workspace.appendingPathComponent("first/original"),
        to: fixture.workspace.appendingPathComponent("second/alias"))
    try FileManager.default.createSymbolicLink(atPath: fixture.workspace.appendingPathComponent("outside-link").path,
        withDestinationPath: "/Users")
    let sparse=fixture.workspace.appendingPathComponent("sparse.bin")
    try Data().write(to: sparse)
    let handle=try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 16 * 1024 * 1024)
    try handle.close()
    let reference=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
    let url=fixture.base.appendingPathComponent("metadata-catalog.sqlite")
    let measurement=try fixture.fs.measureStorage(fixture.workspace.path, catalog: url, cancelled: { false }, progress: { _ in })
    let catalog=try StorageCatalog(url: url)
    var actual=[FileEntry]()
    try catalog.forEachEntry { actual.append($0) }
    guard reference.complete && measurement.tree.complete else {
        throw CheckFailure(description: "Reference issues: \(reference.issues); catalog issues: \(measurement.tree.issues)")
    }
    try expect(measurement.entryCount == reference.entries.count)
    let actualSorted=actual.sorted { $0.path < $1.path }, referenceSorted=reference.entries.sorted { $0.path < $1.path }
    try expect(actualSorted == referenceSorted)
    let expected=try require(StorageIndex(entries: reference.entries).nodes["."])
    let root=try require(catalog.entry(at: "."))
    try expect(root.node.logicalBytes == expected.logicalBytes && root.node.allocatedBytes == expected.allocatedBytes)
    try expect(root.node.fileCount == expected.fileCount)
    let sparseEntry=try require(catalog.entry(at: "sparse.bin"))
    try expect(sparseEntry.entry.logicalBytes == 16 * 1024 * 1024 && sparseEntry.entry.allocatedBytes < sparseEntry.entry.logicalBytes)
}

func storageCatalogParentIDsPreserveNestedNamesAndTotals() throws {
    let fixture=try Fixture(), url=fixture.base.appendingPathComponent("parent-catalog.sqlite")
    let catalog=try StorageCatalog(url: url, create: true)
    let identity=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var root=try catalog.append(identity, name: ".", parentID: 0)
    var directory=identity; directory.path="nested"; directory.inode += 1
    var parent=try catalog.append(directory, name: "nested", parentID: root.id)
    var file=identity; file.path="nested/name.bin"; file.kind="file"; file.inode += 2
    file.links=1; file.logicalBytes=8192; file.allocatedBytes=8192
    let child=try catalog.append(file, name: "name.bin", parentID: parent.id)
    parent.node.logicalBytes += child.node.logicalBytes; parent.node.allocatedBytes += child.node.allocatedBytes
    parent.node.fileCount += child.node.fileCount; parent.node.isComplete=true
    try catalog.setTotals(parent.node, id: parent.id)
    root.node.logicalBytes += parent.node.logicalBytes; root.node.allocatedBytes += parent.node.allocatedBytes
    root.node.fileCount += parent.node.fileCount; root.node.isComplete=true
    try catalog.setTotals(root.node, id: root.id)
    try catalog.seal()
    let loaded=try StorageCatalog(url: url)
    try expect(try loaded.children(of: "nested").map(\.entry) == [file])
    try expect(try loaded.entry(at: "nested")?.node.allocatedBytes == parent.node.allocatedBytes)
    try expect(try loaded.entry(at: ".")?.node.fileCount == 1)
}

func storageCatalogDirectoryCursorPreservesIDsDuringInserts() throws {
    let fixture=try Fixture(), url=fixture.base.appendingPathComponent("directory-cursor.sqlite")
    let catalog=try StorageCatalog(url: url, create: true)
    let identity=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    let root=try catalog.append(identity, name: ".", parentID: 0)
    var expected=[String: Int64]()
    for index in 0..<600 {
        var entry=identity
        entry.path=String(format: "generated-%04d", index) + "-文件-😀"; entry.inode += UInt64(index + 1)
        expected[entry.path]=try catalog.append(entry, name: entry.path, parentID: root.id).id
    }
    var observed=[String: Int64]()
    try catalog.forEachChildDirectory(parentID: root.id) { id, item in
        try expect(id > 0 && expected[item.entry.path] == id && observed[item.entry.path] == nil)
        observed[item.entry.path]=id
        var child=identity
        child.path=item.entry.path + "/generated.bin"; child.kind="file"; child.links=1
        child.inode += UInt64(1000 + observed.count)
        _ = try catalog.append(child, name: "generated.bin", parentID: id)
    }
    try expect(observed == expected)
    var leafDirectories=0
    try catalog.forEachChildDirectory(parentID: require(expected.values.first)) { _, _ in leafDirectories += 1 }
    try expect(leafDirectories == 0)
    try catalog.seal()
    try expect(try StorageCatalog(url: url).children(of: ".").count == 600)
}

/// A repeatable generated fixture for the directory-worker path. The test reports elapsed time
/// for local APFS runs without making a machine-specific latency assertion.
func storageParallelDirectoryBenchmark() throws {
    let fixture=try Fixture()
    let filesPerDirectory=1_000
    for directory in 0..<8 {
        for file in 0..<filesPerDirectory {
            try fixture.put("bench/dir-\(directory)/file-\(file).bin", String(repeating: "x", count: 128))
        }
    }
    let started=Date(), catalogURL=fixture.base.appendingPathComponent("benchmark.sqlite")
    let measurement=try fixture.fs.measureStorage(fixture.workspace.path, catalog: catalogURL, cancelled: { false }, progress: { _ in })
    let elapsed=Date().timeIntervalSince(started)
    let workers=max(1, min(8, ProcessInfo.processInfo.environment["SHOU_STORAGE_SCAN_WORKERS"].flatMap(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount))
    print("storage benchmark: entries=\(measurement.entryCount) elapsed=\(String(format: "%.3f", elapsed))s workers=\(workers)")
    try expect(measurement.entryCount == filesPerDirectory * 8 + 14)
    try expect(measurement.tree.complete)
}

#if os(macOS)
private final class StorageWorkerCancellationProbe: @unchecked Sendable {
    private var originatingThread: Thread?
    private let lock=NSLock()
    private var blocked=false
    let started=DispatchSemaphore(value: 0)
    let resume=DispatchSemaphore(value: 0)
    func begin() { lock.lock(); originatingThread=Thread.current; lock.unlock() }
    func checkpoint() -> Bool {
        lock.lock()
        let shouldBlock = !blocked && Thread.current !== originatingThread
        if shouldBlock { blocked=true }
        lock.unlock()
        if shouldBlock {
            started.signal()
            _ = resume.wait(timeout: .now() + 10)
        }
        return false
    }
}

func storageDirectoryWorkersObserveParentTaskCancellation() async throws {
    // Repeat the final-worker handoff: group completion must also release all
    // callbacks before their nonescaping and unsafe-task scopes can end.
    for _ in 0..<16 { try await storageDirectoryWorkerCancellationOnce() }
}

private func storageDirectoryWorkerCancellationOnce() async throws {
    let fixture=try Fixture(), probe=StorageWorkerCancellationProbe()
    let task=Task.detached {
        probe.begin()
        return try fixture.fs.measureStorage(fixture.workspace.path,
            catalog: fixture.base.appendingPathComponent("cancel-worker.sqlite"),
            cancelled: { probe.checkpoint() }, progress: { _ in })
    }
    let started=await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: probe.started.wait(timeout: .now() + 10) == .success)
        }
    }
    task.cancel()
    probe.resume.signal()
    do {
        _ = try await task.value
        throw CheckFailure(description: "Directory workers must observe the parent task's cancellation.")
    } catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(started)
}
#else
func storageDirectoryWorkersObserveParentTaskCancellation() async throws {}
#endif
