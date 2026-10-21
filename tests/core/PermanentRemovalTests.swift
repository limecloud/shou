import Foundation
import ShouCore
import ShouPlatform

func nativePermanentRemovalHandlesNestedAndRetainedHardLinks() throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    let retained=fixture.workspace.appendingPathComponent("retained.bin")
    try FileManager.default.linkItem(at: source, to: retained)
    try fixture.put("project/target/nested/other.bin", "independent file")
    try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent("project/target/nested/shared.bin"))
    try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent("project/target/shared.bin"))
    let bytes=try Data(contentsOf: retained)
    let path=source.deletingLastPathComponent().path
    let manifest=try fixture.fs.inspectTarget(path, budget: ScanBudget(), cancelled: { false })
    try expect(manifest.complete)
    try fixture.fs.purge(path, expected: manifest.entries)
    try expect(!FileManager.default.fileExists(atPath: path))
    try expect(try Data(contentsOf: retained) == bytes)
    let remaining=try fixture.fs.inspectTarget(retained.path, budget: ScanBudget(), cancelled: { false })
    try expect(remaining.entries.first?.links == 1)
}

func permanentRuleBatchHandlesHardLinksAcrossTargets() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/nested/independent.bin", "keep batch progressing")
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    for relative in ["second/target/a.bin", "second/target/nested/z.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let (engine, _, scan, _)=try await fixture.ready()
    let candidates=scan.candidates.filter { ["project/target", "second/target"].contains($0.relativePath) && $0.eligible }
    try expect(candidates.count == 2)
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: candidates.map(\.id), action: "permanent")
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "hardlink-fixture")
    try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "purged" })
    for item in receipt.items { try expect(!FileManager.default.fileExists(atPath: item.originalPath)) }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("retained.bin")) == Data(repeating: 120, count: 8192))
    let fresh=try await engine.scan(workspaceId: scan.workspace.id)
    try expect(!fresh.candidates.contains { candidates.map(\.relativePath).contains($0.relativePath) })
}

func permanentStorageBatchHandlesSharedFilesAndDirectories() async throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    try fixture.put("second-cache/independent.bin", "second target")
    for relative in ["loose.bin", "second-cache/a.bin", "second-cache/z.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget())
    let selected=["project/target/artifact.bin", "second-cache", "loose.bin"]
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: selected, action: "permanent")
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "hardlink-fixture")
    try expect(receipt.state == "completed" && receipt.items.count == 3 && receipt.items.allSatisfy { $0.state == "purged" })
    for relative in selected { try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(relative).path)) }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("retained.bin")) == Data(repeating: 120, count: 8192))
}

func permanentRemovalStillRejectsExternallyChangedHardLinks() throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    let retained=fixture.workspace.appendingPathComponent("retained.bin")
    try FileManager.default.linkItem(at: source, to: retained)
    let target=source.deletingLastPathComponent().path
    let manifest=try fixture.fs.inspectTarget(target, budget: ScanBudget(), cancelled: { false })
    try Data("externally changed content".utf8).write(to: retained)
    try expectThrows { try fixture.fs.purge(target, expected: manifest.entries) }
    try expect(FileManager.default.fileExists(atPath: source.path))
    try expect(try Data(contentsOf: retained) == Data("externally changed content".utf8))
}

func permanentRemovalContextRejectsUnrelatedMetadataChanges() throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent("retained.bin"))
    let before=try require(fixture.fs.inspectTarget(source.path, budget: ScanBudget(), cancelled: { false }).entries.first)
    var context=PermanentRemovalContext(), after=before
    after.links -= 1; after.changedNanoseconds += 1
    try context.recordUnlink(before: before, after: after)
    try expect(context.reconciled([before]) == [after])
    var modified=before; modified.logicalBytes += 1
    try expect(context.reconciled([modified]) == [modified])
    var invalid=after; invalid.mode ^= 1
    var rejected=PermanentRemovalContext()
    try expectThrows { try rejected.recordUnlink(before: before, after: invalid) }
    invalid=after; invalid.links=before.links
    try expectThrows { try rejected.recordUnlink(before: before, after: invalid) }
    try expect(PermanentRemovalContext().reconciled([before]) == [before])
}

private final class MutateAfterFirstPurge: @unchecked Sendable {
    private let lock=NSLock()
    private var changed=false
    private var failure: Error?
    let retained: URL
    init(retained: URL) { self.retained=retained }
    func observe(_ update: ExecutionProgress) {
        lock.lock(); defer { lock.unlock() }
        guard !changed, update.stage == "purging", update.processedCount == 1 else { return }
        changed=true
        do { try Data("changed after the first target was removed".utf8).write(to: retained) }
        catch { failure=error }
    }
    func verify() throws {
        lock.lock(); defer { lock.unlock() }
        try expect(changed)
        if let failure { throw failure }
    }
}

func permanentBatchRefusesExternalChangeAfterItsOwnUnlink() async throws {
    let fixture=try Fixture()
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    try fixture.put("second-cache/independent.bin", "remaining target")
    for relative in ["second-cache/shared.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget())
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target/artifact.bin", "second-cache"], action: "permanent")
    let mutation=MutateAfterFirstPurge(retained: fixture.workspace.appendingPathComponent("retained.bin"))
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "external-change-fixture", progress: { mutation.observe($0) })
    try mutation.verify()
    try expect(receipt.state == "partial" && receipt.items[0].state == "purged" && receipt.items[1].state == "failed")
    try expect(!FileManager.default.fileExists(atPath: receipt.items[0].originalPath))
    try expect(FileManager.default.fileExists(atPath: receipt.items[1].originalPath))
    try expect(try Data(contentsOf: mutation.retained) == Data("changed after the first target was removed".utf8))
}

func trashFollowUpPurgesHardLinksAcrossRecordedTargets() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/independent.bin", "second target")
    let source=fixture.workspace.appendingPathComponent("project/target/artifact.bin")
    for relative in ["second/target/a.bin", "second/target/z.bin", "retained.bin"] {
        try FileManager.default.linkItem(at: source, to: fixture.workspace.appendingPathComponent(relative))
    }
    let (engine, _, scan, _)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: scan.candidates.filter(\.eligible).map(\.id))
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "hardlink-fixture")
    try expect(receipt.state == "completed" && receipt.items.count == 2)
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "purge")
    let results=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "purge", confirmedDigest: digest)
    try expect(results.count == 2 && results.allSatisfy { $0.state == "completed" })
    for item in receipt.items { try expect(!FileManager.default.fileExists(atPath: try require(item.trashPath))) }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("retained.bin")) == Data(repeating: 120, count: 8192))
}
