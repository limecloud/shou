import Foundation
import ShouCore
import ShouPlatform

private struct FullStorageCatalogFileSystem: PlatformFileSystem {
    let native: NativeFileSystem
    let failWhileSealing: Bool
    var platform: String { native.platform }
    var supportsTrash: Bool { false }
    var supportsStorageCatalog: Bool { true }
    func rootIdentity(_ path: String) throws -> FileEntry { try native.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try native.inspect(path, budget: budget, cancelled: cancelled)
    }
    func availableBytes(_ path: String) -> Int64? { native.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw CheckFailure(description: "Read-only index fixture.") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Read-only index fixture.") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Read-only index fixture.") }
    func measureStorage(_ path: String, catalog url: URL, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement {
        let catalog=try StorageCatalog(url: url, create: true, maximumBytes: 65_536)
        let root=try native.analysisRootIdentity(path)
        _ = try catalog.append(root)
        do {
            for index in 0..<(failWhileSealing ? 100 : 1000) {
                var entry=root
                entry.path=String(repeating: "generated-", count: 16) + String(index)
                entry.kind="file"; entry.links=1; entry.inode += UInt64(index + 1)
                _ = try catalog.append(entry)
            }
        } catch {
            if failWhileSealing { throw CheckFailure(description: "The sealing fixture must finish appending before it exhausts storage.") }
            throw error
        }
        guard failWhileSealing else { throw CheckFailure(description: "The generated index must exhaust its row storage.") }
        progress(ScanProgress(stage: "analysis", entryCount: 101, currentPath: path))
        try catalog.seal()
        throw CheckFailure(description: "The generated index must exhaust storage while sealing.")
    }
}

func storageCatalogFullFailureNeverReplacesPreviousAnalysis() async throws {
    for failWhileSealing in [false, true] {
        let fixture=try Fixture(), native=NativeFileSystem()
        let initial=ShouEngine(store: fixture.store, filesystem: native)
        let previous=try await initial.scanStorage(path: fixture.workspace.path)
        let original=try Data(contentsOf: require(fixture.store.storageCatalogURL(id: previous.id)))
        let engine=ShouEngine(store: fixture.store, filesystem: FullStorageCatalogFileSystem(native: native, failWhileSealing: failWhileSealing))
        do {
            _ = try await engine.scanStorage(path: fixture.workspace.path)
            throw CheckFailure(description: "A full index must not publish a new analysis.")
        } catch let error as ShouError {
            print("Generated catalog exhaustion during \(failWhileSealing ? "sealing" : "append"): \(error.code), \(error.details)")
            try expect(error.code == "storage_full")
            try expect(error.details["sqlite_code"] == "13" && error.retryable)
        }
        try expect(try fixture.store.ids("storage-scans") == [previous.id])
        let catalogDirectory=try require(fixture.store.storageCatalogURL(id: previous.id)).deletingLastPathComponent()
        try expect(try FileManager.default.contentsOfDirectory(atPath: catalogDirectory.path) == [previous.id + ".sqlite"])
        try expect(try Data(contentsOf: require(fixture.store.storageCatalogURL(id: previous.id))) == original)
        try expect(try await initial.storageDirectory(scanId: previous.id).item.node.path == ".")
    }
}

func storageCatalogPreparesPrivateFilesAfterExistingFileRefusal() throws {
    let fixture=try Fixture(), url=try require(fixture.store.storageCatalogURL(id: "prepared-private-file"))
    let root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var preparations=0
    do {
        let catalog=try StorageCatalog(url: url, create: true, prepareNewFile: {
            preparations += 1
            try Data().write(to: url, options: .withoutOverwriting)
        })
        _ = try catalog.append(root); try catalog.seal()
    }
    try expect(preparations == 1)
    try expect(try StorageCatalog(url: url).entry(at: ".")?.entry == root)
    let original=try Data(contentsOf: url)
    try expectThrows {
        _ = try StorageCatalog(url: url, create: true, prepareNewFile: { preparations += 1 })
    }
    try expect(preparations == 1 && Data(contentsOf: url) == original)
    let cancelled=try require(fixture.store.storageCatalogURL(id: "cancelled-private-file"))
    do {
        _ = try StorageCatalog(url: cancelled, create: true, prepareNewFile: { throw ShouError("cancelled", "Stopped before file creation.") })
        throw CheckFailure(description: "File preparation failure must stop SQLite creation.")
    } catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(!FileManager.default.fileExists(atPath: cancelled.path))
    let corrupt=try require(fixture.store.storageCatalogURL(id: "corrupt-index"))
    let corruptBytes=Data("generated invalid SQLite index".utf8)
    try corruptBytes.write(to: corrupt)
    do {
        _ = try StorageCatalog(url: corrupt)
        throw CheckFailure(description: "A corrupt index must remain unavailable.")
    } catch let error as ShouError { try expect(error.code == "store_corrupt" && error.details["sqlite_code"] != "13") }
    try expect(try Data(contentsOf: corrupt) == corruptBytes)
}

func storageCatalogScansLaterSiblingsAndLoadsExactDirectories() async throws {
    let fixture=try Fixture()
    let early=fixture.workspace.appendingPathComponent(".npm")
    try FileManager.default.createDirectory(at: early, withIntermediateDirectories: false)
    for index in 0..<10_010 { try Data().write(to: early.appendingPathComponent(String(index))) }
    try fixture.put("Documents/project/build/large.bin", String(repeating: "d", count: 65_536))
    try fixture.put("Library/Caches/app/large.bin", String(repeating: "l", count: 131_072))
    let native=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let engine=ShouEngine(store: fixture.store, filesystem: native)
    let bounded=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget(maxEntries: 1000))
    try expect(!bounded.tree.complete && !bounded.tree.entries.contains { $0.path == "Library" })
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    try expect(scan.tree.complete && scan.catalogId == scan.id && scan.entryCount > 10_010)
    try expect(scan.tree.entries.count == 1)
    let root=try await engine.storageDirectory(scanId: scan.id)
    try expect(root.children.contains { $0.node.path == "Documents" && $0.node.allocatedBytes >= 65_536 && $0.node.isComplete == true })
    try expect(root.children.contains { $0.node.path == "Library" && $0.node.allocatedBytes >= 131_072 && $0.node.isComplete == true })
    try expect(root.item.node.allocatedBytes == root.item.entry.allocatedBytes + root.children.reduce(0) { $0 + $1.node.allocatedBytes })
    let later=try await engine.storageDirectory(scanId: scan.id, path: "Library/Caches/app")
    try expect(later.children.map(\.entry.path) == ["Library/Caches/app/large.bin"])
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["Library/Caches/app/large.bin"], action: "permanent")
    try expect(plan.items.count == 1 && plan.items[0].allocatedBytesEstimate >= 131_072)
    try fixture.put("Library/Caches/app/large.bin", "changed after catalog measurement")
    try await expectThrows { try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["Library/Caches/app/large.bin"]) }
}

func storageCatalogAccountsHardLinksAndOpaqueLinks() async throws {
    let fixture=try Fixture()
    try fixture.put("a/data", String(repeating: "x", count: 8192))
    try fixture.put("b/keep", "retain")
    try FileManager.default.linkItem(at: fixture.workspace.appendingPathComponent("a/data"), to: fixture.workspace.appendingPathComponent("b/alias"))
    try FileManager.default.createSymbolicLink(atPath: fixture.workspace.appendingPathComponent("outside-link").path, withDestinationPath: "/Users")
    let engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let reference=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
    let expected=try require(StorageIndex(entries: reference.entries).nodes["."])
    let root=try await engine.storageDirectory(scanId: scan.id)
    try expect(root.item.node.allocatedBytes == expected.allocatedBytes && root.item.node.logicalBytes == expected.logicalBytes)
    try expect(root.item.node.fileCount == expected.fileCount)
    let link=try require(root.children.first { $0.node.path == "outside-link" })
    try expect(link.node.kind == "symlink" && link.node.allocatedBytes == 0)
    try await expectThrows { try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["outside-link"]) }
}

func storageCatalogMarksUnreadableDirectoriesWithoutHidingSiblings() async throws {
    let fixture=try Fixture(), denied=fixture.workspace.appendingPathComponent("a-denied")
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
    try fixture.put("a-denied/secret.bin", "unreadable generated fixture")
    try fixture.put("z-readable/data.bin", String(repeating: "z", count: 4096))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
    let engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let directory=try await engine.storageDirectory(scanId: scan.id)
    try expect(!scan.tree.complete && directory.item.node.isComplete == false)
    try expect(directory.children.first { $0.node.path == "a-denied" }?.node.isComplete == false)
    try expect(directory.children.first { $0.node.path == "z-readable" }?.node.isComplete == true)
    var entries=[FileEntry]()
    try StorageCatalog(url: require(fixture.store.storageCatalogURL(id: scan.id))).forEachEntry { entries.append($0) }
    let legacy=StorageIndex(tree: TreeSnapshot(entries: entries, complete: false, issues: ["resource_limit"], caseSensitive: true, completedPaths: ["z-readable"]))
    try expect(legacy.nodes["."]?.isComplete == false)
    try expect(legacy.nodes["z-readable"]?.isComplete == true)
}

func storageCatalogCancellationNeverPublishesAScan() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let task=Task.detached {
        try await engine.scanStorage(path: fixture.workspace.path, progress: { update in
            if update.stage == "analysis" { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do { _ = try await task.value; throw CheckFailure(description: "Cancelled catalog must not be published.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(try fixture.store.ids("storage-scans").isEmpty)
    let native=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let isolated=ShouEngine(store: fixture.store, filesystem: native)
    let workerTask=Task.detached {
        try await isolated.scanStorage(path: fixture.workspace.path, progress: { update in
            if ["scanning", "analysis"].contains(update.stage) { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    do { _ = try await workerTask.value; throw CheckFailure(description: "Cancelled worker catalog must not be published.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(try fixture.store.ids("storage-scans").isEmpty)
    let url=try require(fixture.store.storageCatalogURL(id: "cancel-during-index"))
    let catalog=try StorageCatalog(url: url, create: true)
    let root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    _ = try catalog.append(root)
    for number in 0..<1000 {
        var entry=root; entry.path="file-" + String(number); entry.kind="file"; entry.inode += UInt64(number+1)
        _ = try catalog.append(entry)
    }
    var checks=0
    do {
        try catalog.seal { checks += 1; if checks >= 2 { throw ShouError("cancelled", "Index preparation stopped.") } }
        throw CheckFailure(description: "Index preparation must remain cancellable.")
    } catch let error as ShouError { try expect(error.code == "cancelled") }
}

func storageCatalogSupportsMoreThanAMillionEntries() throws {
    let fixture=try Fixture(), count=1_000_005
    let url=try require(fixture.store.storageCatalogURL(id: "generated-million"))
    let catalog=try StorageCatalog(url: url, create: true)
    let root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var total=try catalog.append(root)
    for index in 1...count {
        var entry=root
        entry.path=String(format: "file-%08d", index); entry.kind="file"; entry.inode += UInt64(index)
        entry.links=1; entry.logicalBytes=4096; entry.allocatedBytes=4096
        let node=try catalog.append(entry)
        total.logicalBytes += node.logicalBytes; total.allocatedBytes += node.allocatedBytes; total.fileCount += 1
    }
    total.isComplete=true
    try catalog.setTotals(total); try catalog.seal()
    let loaded=try StorageCatalog(url: url)
    try expect(try loaded.entry(at: ".")?.node.fileCount == count)
    try expect(try loaded.entry(at: "file-01000005")?.node.allocatedBytes == 4096)
    try expect(try loaded.entry(at: ".")?.node.allocatedBytes == root.allocatedBytes + Int64(count) * 4096)
}
