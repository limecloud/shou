import Foundation
import ShouCore
import ShouPlatform
import CSQLite

private let largeFileMiB: Int64=1024 * 1024

/// Query engines deliberately have no live filesystem, proving filter changes
/// and subsequent pages use saved evidence rather than another scan.
private struct LargeFileEvidenceFileSystem: PlatformFileSystem {
    var tree: TreeSnapshot? = nil
    var platform: String { "macos" }
    var supportsTrash: Bool { false }
    func rootIdentity(_ path: String) throws -> FileEntry {
        guard let root=tree?.entries.first(where: { $0.path == "." }) else { throw CheckFailure(description: "Large-file queries must not read live metadata.") }
        return root
    }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        guard let tree else { throw CheckFailure(description: "Large-file queries must not rescan.") }
        return tree
    }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw CheckFailure(description: "Read-only fixture.") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Read-only fixture.") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Read-only fixture.") }
}

private func largeFileEntry(_ root: FileEntry, path: String, allocated: Int64, inode: UInt64,
                            logical: Int64? = nil, kind: String = "file") -> FileEntry {
    var entry=root
    entry.path=path; entry.kind=kind; entry.inode=inode; entry.links=1
    entry.logicalBytes=logical ?? allocated; entry.allocatedBytes=allocated
    return entry
}

private func largeFileManifest(_ fixture: Fixture) throws -> [FileEntry] {
    let root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var entries=[root]
    for path in ["a", "z", "folder.mp4"] {
        entries.append(largeFileEntry(root, path: path, allocated: 4096, inode: root.inode + UInt64(entries.count), kind: "directory"))
    }
    let files: [(String, Int64)] = [("a/high.MP4", 300), ("z/tie.mp4", 200), ("a/tie.MP4", 200),
        ("music.mp3", 120), ("model.GGUF", 150), ("archive.zip", 110), ("photo.NEF", 90), ("guide.pdf", 80),
        ("installer.pkg", 70), ("disk.dmg", 60), ("blob.raw", 50), ("generic.bin", 40), (".dotfile", 30), ("extensionless", 20)]
    for (path, amount) in files {
        entries.append(largeFileEntry(root, path: path, allocated: amount * largeFileMiB, inode: root.inode + UInt64(entries.count)))
    }
    entries.append(largeFileEntry(root, path: "sparse.mov", allocated: 5 * largeFileMiB, inode: root.inode + 100, logical: 10_000 * largeFileMiB))
    entries.append(largeFileEntry(root, path: "link.mp4", allocated: 1000 * largeFileMiB, inode: root.inode + 101, kind: "symlink"))
    entries.append(largeFileEntry(root, path: "special.mp4", allocated: 1100 * largeFileMiB, inode: root.inode + 102, kind: "special"))
    return [root] + entries.dropFirst().reversed()
}

private func savedLargeFileEvidence(_ fixture: Fixture, entries: [FileEntry], catalog: Bool,
                                    complete: Bool = true) async throws -> (ShouEngine, StorageScan) {
    let tree=TreeSnapshot(entries: entries, complete: complete, issues: complete ? [] : ["resource_limit"], caseSensitive: true)
    let scanner=ShouEngine(store: fixture.store, filesystem: LargeFileEvidenceFileSystem(tree: tree))
    var scan=try await scanner.scanStorage(path: fixture.workspace.path)
    if catalog {
        let url=try require(fixture.store.storageCatalogURL(id: scan.id))
        let index=try StorageCatalog(url: url, create: true)
        for entry in entries.sorted(by: { $0.path < $1.path }) { _ = try index.append(entry, complete: complete) }
        try index.seal()
        scan.catalogId=scan.id; scan.measuredEntryCount=entries.count
        scan.tree.entries=[scan.identity]
        try fixture.store.write("storage-scans", id: scan.id, data: Codec.encode(scan))
    }
    return (ShouEngine(store: fixture.store, filesystem: LargeFileEvidenceFileSystem()), scan)
}

func storageLargeFilesFilterSavedEvidenceWithoutRescanning() async throws {
    for catalog in [false, true] {
        let fixture=try Fixture(), entries=try largeFileManifest(fixture)
        let (engine, scan)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog, complete: false)
        let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 100 * largeFileMiB, limit: 2)
        try expect(page.items.map(\.entry.path) == ["a/high.MP4", "a/tie.MP4"])
        try expect(page.totalCount == 6 && page.totalAllocatedBytes == 1080 * largeFileMiB && page.nextCursor != nil)
        let video=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 100 * largeFileMiB, type: .video)
        try expect(video.items.map(\.entry.path) == ["a/high.MP4", "a/tie.MP4", "z/tie.mp4"])
        try expect(video.totalCount == 3 && video.totalAllocatedBytes == 700 * largeFileMiB)
        let sparse=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0, type: .video)
        try expect(sparse.items.last?.entry.path == "sparse.mov" && sparse.items.last?.node.allocatedBytes == 5 * largeFileMiB)
        let defaults=try await engine.storageLargeFiles(scanId: scan.id)
        try expect(defaults.items.allSatisfy { $0.node.allocatedBytes >= 50 * largeFileMiB })
        try expect(defaults.totalCount == 11)
        let other=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0, type: .other)
        try expect(other.items.map(\.entry.path) == ["installer.pkg", "disk.dmg", "blob.raw", "generic.bin", ".dotfile", "extensionless"])
        for (type, path) in [(StorageFileType.audio, "music.mp3"), (.image, "photo.NEF"), (.archive, "archive.zip"), (.document, "guide.pdf"), (.aiModel, "model.GGUF")] {
            let filtered=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0, type: type)
            try expect(filtered.items.map(\.entry.path) == [path])
        }
        let empty=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: Int64.max)
        try expect(empty.items.isEmpty && empty.totalCount == 0 && empty.totalAllocatedBytes == 0 && empty.nextCursor == nil)
    }
}

func storageLargeFileIndexPreservesThresholdBoundariesAndLegacyCatalogs() async throws {
    let floor: Int64=1_048_576
    for catalog in [false, true] {
        let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
        let files: [(String, Int64)]=[("empty.bin", 0), ("tiny.mp4", floor - 1),
            ("boundary.MP4", floor), ("over.bin", floor + 1), ("large.mp4", 50 * largeFileMiB)]
        let entries=[root] + files.enumerated().map { index, file in
            largeFileEntry(root, path: file.0, allocated: file.1, inode: root.inode + UInt64(index + 1))
        }
        let (engine, scan)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog)
        let below=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: floor - 1)
        try expect(below.items.map(\.entry.path) == ["large.mp4", "over.bin", "boundary.MP4", "tiny.mp4"])
        let boundary=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: floor, limit: 2)
        try expect(boundary.items.map(\.entry.path) == ["large.mp4", "over.bin"] && boundary.totalCount == 3)
        let next=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: floor, cursor: boundary.nextCursor)
        try expect(next.items.map(\.entry.path) == ["boundary.MP4"] && next.nextCursor == nil)
        let video=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: floor, type: .video)
        try expect(video.items.map(\.entry.path) == ["large.mp4", "boundary.MP4"])
        let all=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0)
        try expect(all.totalCount == 5 && all.items.last?.node.allocatedBytes == 0)
        if catalog {
            // A pre-optimization immutable catalog has the same schema version
            // and no optional large-file index. Reading it must still work.
            let url=try require(fixture.store.storageCatalogURL(id: scan.id))
            var database: OpaquePointer?
            try expect(sqlite3_open(url.path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            try expect(sqlite3_exec(database, "DROP INDEX large_files", nil, nil, nil) == SQLITE_OK)
            let legacy=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: floor, type: .video)
            try expect(legacy.items.map(\.entry) == video.items.map(\.entry))
            try expect(legacy.totalCount == video.totalCount && legacy.totalAllocatedBytes == video.totalAllocatedBytes)
        }
    }
}

func storageLargeFilesPageGloballyWithBinaryPathTies() async throws {
    for catalog in [false, true] {
        let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
        let names=["z.mp4", "é.mp4", "e\u{301}.mp4", "A.mp4", "a.mp4", "中.mp4"]
        var entries=[root]
        for (index, path) in names.enumerated() {
            entries.append(largeFileEntry(root, path: path, allocated: 80 * largeFileMiB, inode: root.inode + UInt64(index + 1)))
        }
        let expected=names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let (engine, scan)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog)
        var paths=[String](), cursor: String?
        repeat {
            let page=try await engine.storageLargeFiles(scanId: scan.id, limit: paths.isEmpty ? 1 : 2, cursor: cursor)
            try expect(page.totalCount == names.count && page.totalAllocatedBytes == Int64(names.count) * 80 * largeFileMiB)
            paths.append(contentsOf: page.items.map(\.entry.path)); cursor=page.nextCursor
        } while cursor != nil
        try expect(paths.count == names.count)
        for (actual, wanted) in zip(paths, expected) { try expect(actual.utf8.elementsEqual(wanted.utf8)) }
    }
}

func storageLargeFilesPreserveLegacyHardLinkAccounting() async throws {
    let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var entries=[root, largeFileEntry(root, path: "z-alias.mp4", allocated: 100 * largeFileMiB, inode: root.inode + 1),
        largeFileEntry(root, path: "a-first.mp4", allocated: 100 * largeFileMiB, inode: root.inode + 1),
        largeFileEntry(root, path: "independent.mp4", allocated: 90 * largeFileMiB, inode: root.inode + 2)]
    entries[1].links=2; entries[2].links=2
    let expected=StorageIndex(entries: entries)
    var results=[[StorageCatalogItem]]()
    for catalog in [false, true] {
        let (engine, scan)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog)
        let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0)
        try expect(page.items.map(\.entry.path) == ["a-first.mp4", "independent.mp4", "z-alias.mp4"])
        try expect(page.totalCount == 3 && page.totalAllocatedBytes == 190 * largeFileMiB)
        for item in page.items {
            try expect(item.node.allocatedBytes == expected.nodes[item.entry.path]?.allocatedBytes)
            try expect(item.node.logicalBytes == expected.nodes[item.entry.path]?.logicalBytes)
        }
        let charged=try await engine.storageLargeFiles(scanId: scan.id)
        try expect(charged.totalCount == 2 && charged.items.last?.entry.path == "independent.mp4")
        results.append(page.items)
    }
    try expect(results[0].map(\.entry) == results[1].map(\.entry))
}

func storageLargeFilesRejectInvalidFiltersCursorsAndCatalogs() async throws {
    for catalog in [false, true] {
        let fixture=try Fixture(), entries=try largeFileManifest(fixture)
        let (engine, scan)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog)
        let cursor=try require(try await engine.storageLargeFiles(scanId: scan.id, limit: 1).nextCursor)
        try await expectThrows { try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: -1) }
        for limit in [0, 501] { try await expectThrows { try await engine.storageLargeFiles(scanId: scan.id, limit: limit) } }
        for invalid in ["not-base64!", Data("{}".utf8).base64EncodedString(), String(repeating: "A", count: 32_769)] {
            try await expectThrows { try await engine.storageLargeFiles(scanId: scan.id, cursor: invalid) }
        }
        try await expectThrows { try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0, cursor: cursor) }
        try await expectThrows { try await engine.storageLargeFiles(scanId: scan.id, type: .video, cursor: cursor) }
        let (_, other)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog)
        try await expectThrows { try await engine.storageLargeFiles(scanId: other.id, cursor: cursor) }
        let continued=try await engine.storageLargeFiles(scanId: scan.id, limit: 3, cursor: cursor)
        try expect(continued.items.count == 3 && continued.items.first?.entry.path == "a/tie.MP4")
        if catalog {
            var corrupt=scan; corrupt.catalogId=other.id
            try fixture.store.write("storage-scans", id: scan.id, data: Codec.encode(corrupt))
            try await expectThrows { try await engine.storageLargeFiles(scanId: scan.id) }
        }
    }
}

func storageLargeFilesBoundResultsAndHonorCancellation() async throws {
    for catalog in [false, true] {
        let fixture=try Fixture(), root=try fixture.fs.analysisRootIdentity(fixture.workspace.path), count=5_003
        var entries=[root]
        for index in 0..<count {
            entries.append(largeFileEntry(root, path: String(format: "file-%05d.bin", index), allocated: Int64(index + 1), inode: root.inode + UInt64(index + 1)))
        }
        entries=[root] + entries.dropFirst().reversed()
        let (engine, scan)=try await savedLargeFileEvidence(fixture, entries: entries, catalog: catalog)
        var cursor: String?, received=0
        repeat {
            let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0, limit: 73, cursor: cursor)
            try expect(page.items.count <= 73 && page.totalCount == count)
            for item in page.items { try expect(item.node.allocatedBytes == Int64(count - received)); received += 1 }
            cursor=page.nextCursor
        } while cursor != nil
        try expect(received == count)
        let task=Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0)
        }
        do { _ = try await task.value; throw CheckFailure(description: "Large-file loading must honor cancellation.") }
        catch let error as ShouError { try expect(error.code == "cancelled") }
        let recovered=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 0, limit: 1)
        try expect(recovered.items.first?.node.allocatedBytes == Int64(count))
    }
}

func storageLargeFilesReuseReviewedRemovalAndRejectChangedEvidence() async throws {
    let fixture=try Fixture()
    try fixture.put("review/movie.mp4", String(repeating: "m", count: 16_384))
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: 1, type: .video)
    try expect(page.items.map(\.entry.path) == ["review/movie.mp4"])
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: page.items.map(\.entry.path), action: "permanent")
    try expect(plan.items.count == 1 && plan.items[0].path == "review/movie.mp4" && !plan.digest.isEmpty)
    try fixture.put("review/movie.mp4", "changed after saved evidence")
    do {
        _ = try await engine.createStorageRemovalPlan(scanId: scan.id, paths: page.items.map(\.entry.path), action: "permanent")
        throw CheckFailure(description: "A large-file result must not bypass stale-evidence checks.")
    } catch let error as ShouError { try expect(error.code == "plan_stale") }
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("review/movie.mp4").path))
    try expect(try await engine.history().isEmpty)
}
