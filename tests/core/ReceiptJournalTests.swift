import Foundation
import ShouCore
import ShouPlatform

final class JournalWriteStore: RecordStore, @unchecked Sendable {
    let wrapped: LocalRecordStore
    let failingCollection: String?
    let failingWrite: Int
    let maximumRecordBytes: Int?
    let corruptingManifestRead: Int?
    private let lockState=NSLock()
    private var writes: [String: [Int]]=[:]
    private var manifestReads=0
    init(_ wrapped: LocalRecordStore, failingCollection: String? = nil, failingWrite: Int = 0, maximumRecordBytes: Int? = nil, corruptingManifestRead: Int? = nil) {
        self.wrapped=wrapped; self.failingCollection=failingCollection; self.failingWrite=failingWrite
        self.maximumRecordBytes=maximumRecordBytes
        self.corruptingManifestRead=corruptingManifestRead
    }
    var protectedPaths: [String] { wrapped.protectedPaths }
    func read(_ collection: String, id: String) throws -> Data? {
        if collection == "storage-plan-manifests" {
            lockState.lock()
            manifestReads += 1
            let corrupt=manifestReads == corruptingManifestRead
            lockState.unlock()
            if corrupt { try wrapped.write(collection, id: id, data: Data("Changed after plan loading".utf8)) }
        }
        return try wrapped.read(collection, id: id)
    }
    func ids(_ collection: String) throws -> [String] { try wrapped.ids(collection) }
    func records(_ collection: String) throws -> [StoredRecord] { try wrapped.records(collection) }
    func recordMetadata(_ collection: String, id: String) throws -> StoredRecord? { try wrapped.recordMetadata(collection, id: id) }
    func removeDerivedRecord(_ record: StoredRecord) throws { try wrapped.removeDerivedRecord(record) }
    func removeHistoryRecord(_ collection: String, id: String) throws { try wrapped.removeHistoryRecord(collection, id: id) }
    func lock() throws -> any StoreLease { try wrapped.lock() }
    func write(_ collection: String, id: String, data: Data) throws {
        lockState.lock(); defer { lockState.unlock() }
        writes[collection, default: []].append(data.count)
        if let maximumRecordBytes, data.count > maximumRecordBytes { throw ShouError("resource_limit", "Generated record-size budget exceeded.") }
        if collection == failingCollection, writes[collection]?.count == failingWrite { throw ShouError("journal_unavailable", "Injected journal boundary failure.") }
        try wrapped.write(collection, id: id, data: data)
    }
    func sizes(_ collection: String) -> [Int] { lockState.lock(); defer { lockState.unlock() }; return writes[collection] ?? [] }
}

func largeReceiptJournalRetainsRecoveryWithoutRewritingManifests() async throws {
    let fixture=try Fixture()
    for index in 0..<1100 { try fixture.put("project/target/nested/file-\(index).bin", "generated-\(index)") }
    let (setup, root, _, _)=try await fixture.ready()
    _ = setup
    let store=JournalWriteStore(fixture.store)
    let engine=ShouEngine(store: store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), artifactEvidence: ArtifactFixtureEvidence())
    let scan=try await engine.scan(workspaceId: root.id)
    let candidate=try require(scan.candidates.first(where: \.eligible))
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "large-journal-fixture")
    try expect(receipt.state == "completed")
    let loaded=try await engine.history(receipt.id)
    try expect(loaded.items[0].manifest == receipt.items[0].manifest && loaded.items[0].manifest.count > 1024)
    try expect(store.sizes("history").count == 4 && store.sizes("history").allSatisfy { $0 < 4096 })
    // Trash changes the root metadata once; only that changed manifest is rewritten.
    try expect(store.sizes("history-manifests").count == 2)
    let manifests=try fixture.store.ids("history-manifests")
    _ = try await engine.collectRecords(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    try expect(try fixture.store.ids("history-manifests") == manifests)
    let latest=try require(manifests.first { id in
        guard let data=try? fixture.store.read("history-manifests", id: id) else { return false }
        return (try? Codec.decode([FileEntry].self, from: data)) == receipt.items[0].manifest
    })
    let bytes=try require(fixture.store.read("history-manifests", id: latest))
    try fixture.store.write("history-manifests", id: latest, data: Data("damaged fixture".utf8))
    try await expectThrows { try await engine.history(receipt.id) }
    try await expectThrows { try await engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore") }
    try fixture.store.write("history-manifests", id: latest, data: bytes)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" })
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("project/target/nested/file-1099.bin")) == Data("generated-1099".utf8))
    let preview=try await engine.historyCleanupPreview()
    try expect(preview.recordBytes > bytes.count)
    _ = try await engine.clearHistory(executionIds: [receipt.id])
    try expect(try fixture.store.ids("history-manifests").isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target").path))
}

func largeReceiptJournalFailuresPreserveDurableMutationIntent() async throws {
    for boundary in ["history-manifests", "history"] {
        let fixture=try Fixture()
        for index in 0..<1030 { try fixture.put("project/target/file-\(index).bin") }
        let (_, root, _, _)=try await fixture.ready()
        let store=JournalWriteStore(fixture.store, failingCollection: boundary, failingWrite: boundary == "history" ? 3 : 1)
        let engine=ShouEngine(store: store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
        let scan=try await engine.scan(workspaceId: root.id)
        let plan=try await engine.createPlan(scanId: scan.id, candidateIds: scan.candidates.filter(\.eligible).map(\.id), action: "permanent")
        try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "large-journal-fault") }
        let target=fixture.workspace.appendingPathComponent("project/target").path
        if boundary == "history-manifests" {
            try expect(FileManager.default.fileExists(atPath: target))
            try expect(try fixture.store.ids("history").isEmpty)
        } else {
            try expect(!FileManager.default.fileExists(atPath: target))
            let receipt=try require(try await engine.history().first)
            try expect(receipt.state == "executing" && receipt.items[0].state == "purging" && receipt.items[0].manifest.count > 1024)
            try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "replay") }
            _ = try await engine.collectRecords(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
            try expect(try await engine.history(receipt.id).items[0].manifest == receipt.items[0].manifest)
        }
    }
}
