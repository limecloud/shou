import Foundation
import ShouCore
import ShouPlatform

func recordRetentionExplicitScanCleanupKeepsActivePlansAndUnpublishedCatalogs() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let pending=try require(fixture.store.storageCatalogURL(id: "storage_unpublished_fixture"))
    try Data("generated unpublished worker placeholder".utf8).write(to: pending)
    let policy=RecordRetentionPolicy(keepLatestScans: false)
    let reviewed=try await engine.recordRetentionPreview(policy: policy)
    try expect(reviewed.records.contains { $0.collection == "storage-scans" && $0.id == scan.id })
    try expect(reviewed.records.contains { $0.collection == "storage-catalogs" && $0.id == scan.id })
    try expect(!reviewed.records.contains { $0.id == "storage_unpublished_fixture" })
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target"], action: "permanent")
    let protected=try await engine.recordRetentionPreview(policy: policy)
    try expect(!protected.records.contains { $0.id == scan.id || $0.id == plan.id || $0.id == "storage_unpublished_fixture" })
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func recordRetentionExplicitHistoryCleanupReclaimsOnlyFinishedDependencies() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    for index in 0..<1100 { try fixture.put("generated-history-cache/file-\(index)", "generated") }
    try fixture.put("sentinel.txt", "keep this generated sibling")
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["generated-history-cache"], action: "permanent")
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-history-cleanup")
    try expect(receipt.state == "completed")
    let pages=try fixture.store.ids("history-manifests")
    try expect(!pages.isEmpty)
    _ = try await engine.historySummaries()
    let historyBytes=try require(fixture.store.read("history", id: receipt.id))
    let configBytes=try fixture.store.read("configuration", id: "current")
    let ordinary=try await engine.recordRetentionPreview()
    try expect(!ordinary.records.contains { $0.collection == "history" || $0.collection == "history-manifests" })
    let reviewed=try await engine.recordRetentionPreview(includeFinishedHistory: true)
    try expect(reviewed.records.contains { $0.collection == "history" && $0.id == receipt.id })
    try expect(reviewed.records.filter { $0.collection == "history-manifests" }.count == pages.count)
    try expect(reviewed.records.contains { $0.collection == "history-summaries" && $0.id == receipt.id })
    try expect(reviewed.collections.reduce(Int64(0)) { $0 + $1.totalBytes } == reviewed.totalBytes)
    try expect(reviewed.collections.reduce(Int64(0)) { $0 + $1.removableBytes } == reviewed.removableBytes)
    try expect(try fixture.store.read("history", id: receipt.id) == historyBytes)
    try await expectThrows { try await engine.collectRecords(includeFinishedHistory: true) }
    _ = try await engine.collectRecords(reviewedRecords: reviewed.records, includeFinishedHistory: true)
    try expect(try fixture.store.ids("history").isEmpty && fixture.store.ids("history-manifests").isEmpty && fixture.store.ids("history-summaries").isEmpty)
    try expect(try fixture.store.read("configuration", id: "current") == configBytes)
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("sentinel.txt"), encoding: .utf8) == "keep this generated sibling")
    try await expectThrows { try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "no-replay-after-history-cleanup") }
}

func recordRetentionHistoryReviewRejectsChangesAndKeepsRecoveryOrUncertainty() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    var receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-history-review")
    let trash=try require(receipt.items.first?.trashPath)
    try expect(try await engine.recordRetentionPreview(includeFinishedHistory: true).records.allSatisfy { $0.collection != "history" })
    // A terminal permanent-removal journal is eligible. The referenced Trash
    // fixture remains untouched while exercising changes to the review evidence.
    receipt.items[0].state="purged"
    try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
    let reviewed=try await engine.recordRetentionPreview(includeFinishedHistory: true)
    try expect(reviewed.records.contains { $0.collection == "history" })
    for state in ["executing", "future_unknown_state"] {
        receipt.state=state
        try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
        try await expectThrows { try await engine.collectRecords(reviewedRecords: reviewed.records, includeFinishedHistory: true) }
        try expect(try fixture.store.read("history", id: receipt.id) != nil)
    }
    receipt.state="completed"; receipt.items[0].state="unknown"
    try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
    try expect(try await engine.recordRetentionPreview(includeFinishedHistory: true).records.allSatisfy { $0.collection != "history" })
    receipt.items[0].state="purged"
    try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
    let fresh=try await engine.recordRetentionPreview(includeFinishedHistory: true)
    var second=receipt; second.id="execution_second_finished"
    try fixture.store.write("history", id: second.id, data: Codec.encode(second))
    try await expectThrows { try await engine.collectRecords(reviewedRecords: fresh.records, includeFinishedHistory: true) }
    try expect(try fixture.store.ids("history").count == 2)
    try expect(FileManager.default.fileExists(atPath: trash))
}

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
    try expect(preview.collections.reduce(Int64(0)) { $0 + $1.totalBytes } == preview.totalBytes)
    try expect(preview.collections.reduce(Int64(0)) { $0 + $1.removableBytes } == preview.removableBytes)
    try expect(preview.retentionReasons.contains { $0.reason == "active_plan" && $0.byteCount > 0 })
    try expect(preview.quotaExcessBytes > 0)
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

func recordRetentionReviewIsExactAndVolumeChangesRemainSigned() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let policy=RecordRetentionPolicy(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0, keepLatestScans: false)
    let preview=try await engine.recordRetentionPreview(policy: policy)
    let record=try require(preview.records.first)
    try await expectThrows { try await engine.collectRecords(policy: policy, reviewedRecords: [record,record]) }
    // A plan created after the review protects its scan and invalidates the reviewed collection.
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try await expectThrows { try await engine.collectRecords(policy: policy, reviewedRecords: preview.records) }
    try expect(try fixture.store.read("scans", id: scan.id) != nil)
    var first=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    first.volumeAvailableBefore=1000; first.volumeAvailableAfter=900
    var second=first; second.id="execution_second"; second.createdAt=first.createdAt
    second.volumeAvailableBefore=900; second.volumeAvailableAfter=700
    let observed=CleanupVolumeObservation.from([first,second,first])
    try expect(observed.count == 1 && observed[0].change == -300)
    second.workspace.identity.device += 1
    try expect(CleanupVolumeObservation.from([first,second]).count == 2)
    second.workspace.identity.device=first.workspace.identity.device
    second.volumeAvailableAfter=nil
    try expect(CleanupVolumeObservation.from([first,second])[0].change == nil)
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
