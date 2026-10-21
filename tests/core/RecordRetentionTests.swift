import Foundation
import ShouCore
import ShouPlatform

func recordRetentionProtectsActivePlansAndRecoveryWithZeroQuota() async throws {
    let fixture=try Fixture()
    let (engine, root, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    // A second scan makes the referenced first scan no longer the latest.
    var old=scan; old.id="scan_expired"
    try fixture.store.write("scans", id: old.id, data: Codec.encode(old))
    _ = try await engine.scan(workspaceId: root.id)
    let preview=try await engine.collectRecords(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    try expect(preview.records.contains { $0.id == old.id })
    try expect(try fixture.store.read("scans", id: scan.id) != nil)
    try expect(try fixture.store.read("plans", id: plan.id) != nil)
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let trash=try require(receipt.items.first?.trashPath)
    _ = try await engine.collectRecords(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    let results=try await engine.followUp(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore", confirmedDigest: digest)
    try expect(results.allSatisfy { $0.state == "completed" })
    try expect(!FileManager.default.fileExists(atPath: trash))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func recordRetentionPreservesDependenciesAndRejectsChangedRecords() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    // Paged storage evidence must be collected as one publication group.
    try fixture.store.write("storage-scans", id: "storage_old", data: Data("{\"scan\":{\"catalog_id\":\"storage_old\"},\"pages\":[{\"id\":\"storage_old_p0\"}]}".utf8))
    try fixture.store.write("storage-scan-entries", id: "storage_old_p0", data: Data("[]".utf8))
    try fixture.store.write("storage-scans", id: "storage_new", data: Data("{\"catalog_id\":\"storage_new\"}".utf8))
    let preview=try await engine.recordRetentionPreview(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    let old=preview.records.filter { $0.id.hasPrefix("storage_old") }
    try expect(old.count == 2 && old[0].collection == "storage-scans")
    let record=try require(old.first)
    try fixture.store.write(record.collection, id: record.id, data: Data("{}".utf8))
    try expectThrows { try fixture.store.removeDerivedRecord(record) }
    try fixture.store.write("plans", id: "plan_corrupt", data: Data("invalid".utf8))
    let blocked=try await engine.recordRetentionPreview(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    try expect(blocked.records.isEmpty && !blocked.issues.isEmpty)
    let forbidden=StoredRecord(collection: "configuration", id: "current", byteCount: 0, modifiedAt: Date(), revision: "")
    try expectThrows { try fixture.store.removeDerivedRecord(forbidden) }
}

func historySummariesPageAndInvalidateWithoutChangingRecoveryEvidence() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    var receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let before=try fixture.store.read("history", id: receipt.id)
    let first=try await engine.historySummaries(limit: 1)
    try expect(first.totalCount == 1 && first.nextOffset == nil)
    try expect(first.receipts[0].items.allSatisfy { $0.manifest.isEmpty })
    try expect(try fixture.store.read("history", id: receipt.id) == before)
    receipt.state="partial"
    try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
    try expect(try await engine.historySummaries().receipts[0].state == "partial")
    // Corrupt disposable cache falls back to the authoritative journal.
    try fixture.store.write("history-summaries", id: receipt.id, data: Data("invalid".utf8))
    try expect(try await engine.historySummaries().receipts[0].state == "partial")
    receipt.id="execution_second"
    try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
    let page=try await engine.historySummaries(limit: 1)
    try expect(page.totalCount == 2 && page.nextOffset == 1)
    let next=try await engine.historySummaries(offset: 1, limit: 1)
    try expect(next.receipts[0].id != page.receipts[0].id && next.nextOffset == nil)
    try await expectThrows { try await engine.historySummaries(limit: 0) }
}
