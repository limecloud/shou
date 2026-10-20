import Foundation
import ShouCore

private final class WindowsVolumeProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var reads=0
    func volume() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return reads == 1 ? 42 : 43
    }
}
private struct WindowsBindingFileSystem: PlatformFileSystem {
    let probe: WindowsVolumeProbe
    var platform: String { "windows" }
    var supportsTrash: Bool { false }
    func rootIdentity(_ path: String) throws -> FileEntry {
        var entry=FileEntry(path: ".", kind: "directory", device: 0, inode: 0, logicalBytes: 0, allocatedBytes: 0,
            modifiedNanoseconds: 0, changedNanoseconds: 0, mode: 0, owner: 0, links: 1)
        entry.windowsIdentity=WindowsFileIdentity(volume: probe.volume(), fileId: "00000000000000010000000000000001", ownerSid: "S-1-5-21-1001")
        return entry
    }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { throw ShouError("capability_unavailable", "Binding fixture only") }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw ShouError("capability_unavailable", "Binding fixture only") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Binding fixture only") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Binding fixture only") }
}

func windowsVolumeChangesCannotUsePOSIXRemountCompatibility() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: WindowsBindingFileSystem(probe: WindowsVolumeProbe()))
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "windows-binding")
    let accessible=try await engine.workspaceAccessible(workspace.id)
    try expect(!accessible)
}

private struct UncertainMutationFileSystem: PlatformFileSystem {
    let wrapped: FixtureFileSystem
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { true }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try wrapped.inspect(path, budget: budget, cancelled: cancelled) }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func targetAvailability(_ path: String) -> LocationAvailability { wrapped.targetAvailability(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        let result=try wrapped.moveToTrash(path, expected: expected)
        throw ShouError("trash_outcome_unknown", "Injected post-move verification failure", details: ["resulting_path": result.path])
    }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws {
        try wrapped.restore(path, to: destination, expected: expected)
        throw ShouError("restore_outcome_unknown", "Injected post-restore verification failure", details: ["resulting_path": destination])
    }
    func purge(_ path: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "No purge in uncertainty fixtures") }
}

func uncertainNativeMutationsPreserveObservedPathsAndBlockReplay() async throws {
    for restoring in [false, true] {
        let fixture=try Fixture()
        let (initial, _, scan, candidate)=try await fixture.ready()
        let plan=try await initial.createPlan(scanId: scan.id, candidateIds: [candidate.id])
        let fs=UncertainMutationFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
        let engine=ShouEngine(store: fixture.store, filesystem: fs, artifactEvidence: ArtifactFixtureEvidence())
        if restoring {
            let receipt=try await initial.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
            let ids=receipt.items.map(\.id)
            let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
            let results=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
            try expect(results.count == 1 && results[0].state == "pending")
            try expect(results[0].resultingPath == receipt.items[0].originalPath)
            try expect(FileManager.default.fileExists(atPath: receipt.items[0].originalPath))
            try await expectThrows { try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore") }
        } else {
            let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
            try expect(receipt.items.count == 1 && receipt.items[0].state == "unknown")
            let observed=try require(receipt.items[0].trashPath)
            try expect(FileManager.default.fileExists(atPath: observed))
            try expect(try await engine.history(receipt.id).items[0].trashPath == observed)
            try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
        }
    }
}

func windowsIdentityPreservesFileIDOwnerAndLegacyRecords() throws {
    let legacy=FileEntry(path: "fixture", kind: "file", device: 42, inode: 0,
        logicalBytes: 64, allocatedBytes: 4096, modifiedNanoseconds: 1, changedNanoseconds: 2,
        mode: 0, owner: 0, links: 1)
    let encoded=try Codec.encode(legacy)
    try expect(!String(decoding: encoded, as: UTF8.self).contains("windows_identity"))
    try expect(try Codec.decode(FileEntry.self, from: encoded) == legacy)
    var first=legacy, second=legacy, root=legacy
    first.path="a"; second.path="b"; root.path="."; root.kind="directory"; root.allocatedBytes=0
    first.windowsIdentity=WindowsFileIdentity(volume: 42, fileId: "00000000000000010000000000000001", ownerSid: "S-1-5-21-1001")
    second.windowsIdentity=WindowsFileIdentity(volume: 42, fileId: "00000000000000020000000000000001", ownerSid: "S-1-5-21-1001")
    try expect(!first.sameObject(as: second))
    try expect(!first.sameObject(as: legacy) && !legacy.sameObject(as: first))
    try expect(first.hasSameOwner(as: second))
    try expect(StorageIndex(entries: [root, first, second]).nodes["."]?.allocatedBytes == 8192)
    second.windowsIdentity=WindowsFileIdentity(volume: 42, fileId: first.windowsIdentity!.fileId, ownerSid: "S-1-5-21-2002")
    try expect(first.sameObject(as: second) && !first.hasSameOwner(as: second))
    try expect(first != second)
    try expect(try Codec.decode(FileEntry.self, from: Codec.encode(first)) == first)
}
