import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#endif

func trashRootComparisonAllowsOnlyDirectoryCTime() throws {
    let original=FileEntry(path: ".", kind: "directory", device: 1, inode: 2, logicalBytes: 64, allocatedBytes: 0,
        modifiedNanoseconds: 100, changedNanoseconds: 200, mode: 0o40755, owner: 501, links: 2)
    var changed=original
    changed.changedNanoseconds += 1
    try expect(original != changed)
    try expect(original.matchesTrashRoot(as: changed) && changed.matchesTrashRoot(as: original))
    let mutations: [(inout FileEntry) -> Void] = [
        { $0.path="child" }, { $0.kind="file" }, { $0.device += 1 }, { $0.inode += 1 },
        { $0.logicalBytes += 1 }, { $0.allocatedBytes += 1 }, { $0.modifiedNanoseconds += 1 },
        { $0.mode ^= 0o010 }, { $0.owner += 1 }, { $0.links += 1 }
    ]
    for mutate in mutations {
        var other=changed
        mutate(&other)
        try expect(!original.matchesTrashRoot(as: other) && !other.matchesTrashRoot(as: original))
    }
    var descendant=original
    descendant.path="child"
    var changedDescendant=descendant
    changedDescendant.changedNanoseconds += 1
    try expect(!descendant.matchesTrashRoot(as: changedDescendant))
    var file=original
    file.kind="file"
    try expect(!file.matchesTrashRoot(as: file))
}

private func updateReceiptXattr(_ path: String) throws {
    #if os(macOS)
    let marker=Data([1])
    let status=marker.withUnsafeBytes { bytes in
        setxattr(path, "com.shou.tests.receipt", bytes.baseAddress, bytes.count, 0, 0)
    }
    try expect(status == 0)
    #else
    throw ShouError("capability_unavailable", "This regression requires macOS extended attributes.")
    #endif
}

private func isolatedTrashReceipt() async throws -> (Fixture, ShouEngine, ExecutionReceipt) {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "completed" && receipt.items.count == 1 && receipt.items[0].state == "trashed")
    return (fixture, engine, receipt)
}

func trashRootCTimeChangeRestoresThroughBothVerificationLayers() async throws {
    let (fixture, engine, receipt)=try await isolatedTrashReceipt()
    let item=receipt.items[0]
    let trashPath=try require(item.trashPath)
    let originalData=try Data(contentsOf: URL(fileURLWithPath: trashPath).appendingPathComponent("artifact.bin"))
    try updateReceiptXattr(trashPath)
    let current=try fixture.fs.inspect(trashPath, budget: ScanBudget(), cancelled: { false })
    let savedRoot=try require(item.manifest.first { $0.path == "." })
    let currentRoot=try require(current.entries.first { $0.path == "." })
    try expect(current.complete && savedRoot.changedNanoseconds != currentRoot.changedNanoseconds)
    try expect(savedRoot.matchesTrashRoot(as: currentRoot))
    try expect(current.entries.filter { $0.path != "." } == item.manifest.filter { $0.path != "." })
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
    try expect(restored.count == 1 && restored[0].state == "completed")
    let restoredData=try Data(contentsOf: URL(fileURLWithPath: item.originalPath).appendingPathComponent("artifact.bin"))
    try expect(Digest.sha256(restoredData) == Digest.sha256(originalData))
    try expect(!FileManager.default.fileExists(atPath: trashPath))
}

func trashRootCTimeExceptionNeverAuthorizesPlanExecution() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try updateReceiptXattr(fixture.workspace.appendingPathComponent(candidate.relativePath).path)
    let rejected=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(rejected.state == "partial" && rejected.items.allSatisfy { $0.state == "failed" && $0.trashPath == nil })
    try expect(try await engine.history().count == 1)
    try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func changedTrashMetadataIdentityAndDescendantsStillRefuseRestore() async throws {
    for change in ["mtime", "mode", "identity", "descendant", "descendant_ctime"] {
        let (fixture, engine, receipt)=try await isolatedTrashReceipt()
        let item=receipt.items[0]
        let trashPath=try require(item.trashPath)
        let root=try require(item.manifest.first { $0.path == "." })
        let artifact=URL(fileURLWithPath: trashPath).appendingPathComponent("artifact.bin")
        switch change {
        case "mtime":
            let date=Date(timeIntervalSince1970: Double(root.modifiedNanoseconds) / 1_000_000_000 + 10)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: trashPath)
        case "mode":
            try FileManager.default.setAttributes([.posixPermissions: (root.mode & 0o777) ^ 0o010], ofItemAtPath: trashPath)
        case "identity":
            try FileManager.default.moveItem(atPath: trashPath, toPath: fixture.base.appendingPathComponent("preserved-original").path)
            try FileManager.default.createDirectory(atPath: trashPath, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: artifact)
        case "descendant":
            try Data("changed descendant".utf8).write(to: artifact)
        default:
            try updateReceiptXattr(artifact.path)
        }
        let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
        let result=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
        try expect(result.count == 1 && result[0].state == "failed")
        // Verify the platform boundary independently of the engine's early rejection.
        try expectThrows { try fixture.fs.restore(trashPath, to: item.originalPath, expected: item.manifest) }
        try expect(FileManager.default.fileExists(atPath: artifact.path))
        try expect(!FileManager.default.fileExists(atPath: item.originalPath))
        try expect(try await engine.followUps().allSatisfy { $0.state == "failed" })
    }
}
