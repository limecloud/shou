import Foundation
import ShouCore
import ShouPlatform

private final class StorageProgressProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var updates=[ScanProgress]()
    func record(_ value: ScanProgress) { lock.lock(); defer { lock.unlock() }; updates.append(value) }
    var values: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return updates }
}

func storageWorkerReportsPostScanStagesAndExactLimit() async throws {
    let fixture=try Fixture(), progress=StorageProgressProbe()
    let native=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let engine=ShouEngine(store: fixture.store, filesystem: native)
    let scan=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget(maxEntries: 2), progress: { progress.record($0) })
    try expect(scan.tree.entries.count == 2 && !scan.tree.complete)
    let values=progress.values
    try expect(values.contains { $0.stage == "transferring" && $0.entryCount == 2 && $0.limitReached })
    try expect(values.contains { $0.stage == "loading" && $0.entryCount == 2 && $0.limitReached })
    try expect(values.last?.stage == "saving" && values.last?.entryCount == 2 && values.last?.limitReached == true)
    try expect(values.allSatisfy { $0.entryCount <= 2 })
    let loaded=try await engine.storageScan(scan.id)
    try expect(loaded.tree.entries == scan.tree.entries)
}

func storageWorkerPagesLargeResultsWithoutChangingEvidence() throws {
    let fixture=try Fixture()
    let folder=fixture.workspace.appendingPathComponent("generated-entries")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    for index in 0..<10_010 {
        try Data().write(to: folder.appendingPathComponent(String(index)))
    }
    let budget=ScanBudget(maxEntries: 20_000)
    let direct=try fixture.fs.inspect(fixture.workspace.path, budget: budget, cancelled: { false })
    let native=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let isolated=try native.inspect(fixture.workspace.path, budget: budget, cancelled: { false })
    try expect(isolated.entries == direct.entries && isolated.complete == direct.complete && isolated.issues == direct.issues)
    let progress=StorageProgressProbe()
    do {
        _ = try native.inspect(fixture.workspace.path, budget: budget,
            cancelled: { progress.values.contains { $0.stage == "loading" } }, progress: { progress.record($0) })
        throw CheckFailure(description: "Loading a paged worker result must remain cancellable.")
    } catch let error as ShouError { try expect(error.code == "cancelled") }
}

private struct GeneratedStorageFileSystem: PlatformFileSystem {
    let tree: TreeSnapshot
    var platform: String { "macos" }
    var supportsTrash: Bool { false }
    func rootIdentity(_ path: String) throws -> FileEntry { tree.entries[0] }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { tree }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw CheckFailure(description: "Read-only progress fixtures must never delete.") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Read-only fixture.") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Read-only fixture.") }
}

private func generatedStorageTree(_ fixture: Fixture, count: Int) throws -> TreeSnapshot {
    let root=try fixture.fs.rootIdentity(fixture.workspace.path)
    var entries=[root]
    for index in 1..<count {
        var entry=root
        entry.path=String(format: "file-%08d", index); entry.kind="file"; entry.inode += UInt64(index)
        entry.logicalBytes=4096; entry.allocatedBytes=4096
        entries.append(entry)
    }
    return TreeSnapshot(entries: entries, complete: false, issues: ["resource_limit"], caseSensitive: true)
}

func storagePagedResultsRoundTripAndRejectCorruption(count: Int = 20_005) async throws {
    let fixture=try Fixture(), tree=try generatedStorageTree(fixture, count: count)
    let engine=ShouEngine(store: fixture.store, filesystem: GeneratedStorageFileSystem(tree: tree))
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let loaded=try await engine.storageScan(scan.id)
    try expect(loaded.tree.entries == tree.entries && loaded.tree.issues == tree.issues && loaded.identity == scan.identity)
    let index=try StorageIndex(entries: loaded.tree.entries, checkpoint: { try Task.checkCancellation() })
    try expect(index.nodes["."]?.fileCount == count - 1)
    let pages=try fixture.store.ids("storage-scan-entries")
    try expect(pages.count == (count + 9999) / 10000)
    for page in pages {
        let data=try require(fixture.store.read("storage-scan-entries", id: page))
        try expect(data.count < 268_435_456)
    }
    let first=try require(pages.first)
    try fixture.store.write("storage-scan-entries", id: first, data: Data("[]".utf8))
    do { _ = try await engine.storageScan(scan.id); throw CheckFailure(description: "Corrupt entry pages must be refused.") }
    catch let error as ShouError { try expect(error.code == "store_corrupt") }
}

private struct CancellingStoragePageStore: RecordStore {
    let store: LocalRecordStore
    func read(_ collection: String, id: String) throws -> Data? { try store.read(collection, id: id) }
    func ids(_ collection: String) throws -> [String] { try store.ids(collection) }
    func lock() throws -> any StoreLease { try store.lock() }
    func write(_ collection: String, id: String, data: Data) throws {
        try store.write(collection, id: id, data: data)
        if collection == "storage-scan-entries" { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

func storageCancellationDoesNotPublishIncompletePages() async throws {
    let fixture=try Fixture(), tree=try generatedStorageTree(fixture, count: 20_005)
    let engine=ShouEngine(store: CancellingStoragePageStore(store: fixture.store), filesystem: GeneratedStorageFileSystem(tree: tree))
    let task=Task.detached { try await engine.scanStorage(path: fixture.workspace.path) }
    do { _ = try await task.value; throw CheckFailure(description: "Cancelled persistence must not publish an analysis.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(try fixture.store.ids("storage-scans").isEmpty)
    try expect(try fixture.store.ids("storage-scan-entries").count == 1)
}

func storageIndexCanCancelAndKeepsAccounting() throws {
    let fixture=try Fixture(), tree=try generatedStorageTree(fixture, count: 20_005)
    var checkpoints=0
    do {
        _ = try StorageIndex(entries: tree.entries) {
            checkpoints += 1
            if checkpoints == 8 { throw CancellationError() }
        }
        throw CheckFailure(description: "Index construction must stop on cancellation.")
    } catch is CancellationError {}
    let forward=StorageIndex(entries: tree.entries), reverse=StorageIndex(entries: Array(tree.entries.reversed()))
    try expect(forward.nodes.count == reverse.nodes.count)
    try expect(forward.children().map(\.path) == reverse.children().map(\.path))
    try expect(forward.nodes["."]?.allocatedBytes == reverse.nodes["."]?.allocatedBytes)
    try expect(forward.nodes["."]?.fileCount == tree.entries.count - 1)
}
