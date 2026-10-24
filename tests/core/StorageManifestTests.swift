import Foundation
import ShouCore
import ShouPlatform

private func generatedPagedTarget(_ fixture: Fixture) throws {
    let directory=fixture.workspace.appendingPathComponent("generated-cache")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<5000 { try Data("generated".utf8).write(to: directory.appendingPathComponent("file-\(index).bin")) }
}

func storageManifestPagesVerifyCorruptionAndRetention() async throws {
    let fixture=try Fixture()
    try generatedPagedTarget(fixture)
    let store=JournalWriteStore(fixture.store, maximumRecordBytes: 2_097_152)
    let engine=ShouEngine(store: store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["generated-cache"], action: "permanent")
    try expect(plan.manifestFormatVersion == 1 && plan.items[0].manifest.count == 5001)
    try expect(try plan.calculatedDigest() == plan.digest)
    let bytes=try require(fixture.store.read("storage-plans", id: plan.id))
    try expect(bytes.count < 4096)
    let pages=try fixture.store.ids("storage-plan-manifests")
    try expect(pages.count == 2)
    let zero=RecordRetentionPolicy(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0)
    let preview=try await engine.recordRetentionPreview(policy: zero)
    try expect(preview.issues.isEmpty && !preview.records.contains { $0.collection == "storage-plan-manifests" || ($0.collection == "storage-plans" && $0.id == plan.id) })
    let page=try require(pages.first), original=try require(fixture.store.read("storage-plan-manifests", id: page))
    try fixture.store.write("storage-plan-manifests", id: page, data: Data("damaged generated page".utf8))
    try await expectThrows { try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "corrupt-page") }
    try expect(try fixture.store.ids("history").isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("generated-cache/file-0.bin").path))
    try fixture.store.write("storage-plan-manifests", id: page, data: original)
    let loaded=try await engine.storageRemovalPlan(plan.id)
    try expect(loaded.items[0].manifest == plan.items[0].manifest)
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "paged-fixture")
    try expect(receipt.state == "completed")
    try expect(try await engine.history(receipt.id).items[0].manifest == plan.items[0].manifest)
    try expect(store.sizes("history-manifests").count == 2 && store.sizes("storage-plan-manifests").count == 2)
    try expect(store.sizes("storage-plans").count == 3 && store.sizes("storage-plans").allSatisfy { $0 < 4096 })
    try await expectThrows { try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "replay") }
    let finished=try await engine.recordRetentionPreview(policy: zero)
    try expect(finished.issues.isEmpty && finished.records.filter { $0.collection == "storage-plan-manifests" }.count == 2)
    try expect(!finished.records.contains { $0.collection == "history-manifests" })
    let historyPages=try fixture.store.ids("history-manifests")
    _ = try await engine.collectRecords(policy: zero)
    try expect(try fixture.store.ids("storage-plan-manifests").isEmpty && fixture.store.ids("history-manifests") == historyPages)
    let broken=try require(historyPages.first), saved=try require(fixture.store.read("history-manifests", id: broken))
    try fixture.store.write("history-manifests", id: broken, data: Data("damaged generated history page".utf8))
    try await expectThrows { try await engine.history(receipt.id) }
    try fixture.store.write("history-manifests", id: broken, data: saved)
    _ = try await engine.clearHistory(executionIds: [receipt.id])
    try expect(try fixture.store.ids("history-manifests").isEmpty)
}

func storageManifestInterruptedPublicationAndLegacyPlans() async throws {
    let fixture=try Fixture()
    try generatedPagedTarget(fixture)
    let store=JournalWriteStore(fixture.store, failingCollection: "storage-plan-manifests", failingWrite: 2)
    let engine=ShouEngine(store: store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    try await expectThrows { try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["generated-cache"], action: "permanent") }
    try expect(try fixture.store.ids("storage-plans").isEmpty && fixture.store.ids("history").isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("generated-cache/file-0.bin").path))
    let working=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    var plan=try await working.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target"], action: "permanent")
    plan.manifestFormatVersion=nil
    plan.digest=try plan.calculatedDigest()
    try fixture.store.write("storage-plans", id: plan.id, data: Codec.encode(plan))
    try expect(try await working.storageRemovalPlan(plan.id).items[0].manifest == plan.items[0].manifest)
    let receipt=try await working.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "legacy-plan-fixture")
    try expect(receipt.state == "completed")
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("generated-cache/file-0.bin").path))
}

func permanentVerificationCancellationDoesNotRemoveFiles() async throws {
    let fixture=try Fixture(), target=fixture.workspace.appendingPathComponent("project/target").path
    let entries=try fixture.fs.inspectTarget(target, budget: ScanBudget(), cancelled: { false }).entries
    let task=Task {
        var context=PermanentRemovalContext()
        try fixture.fs.purge(target, expected: entries, context: &context, progress: { _, _, _ in
            // Reaching a mutation callback would violate the read-only stop boundary.
        }, checking: { _ in withUnsafeCurrentTask { $0?.cancel() } })
    }
    do { try await task.value; throw CheckFailure(description: "Cancelled verification must stop before mutation.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin")) == Data(repeating: 120, count: 8192))
}
