import Foundation
import ShouCore
import ShouPlatform

private struct CancellableFollowUpFileSystem: PlatformFileSystem {
    enum Boundary: Sendable { case before, verification, journal, restored }
    let wrapped: FixtureFileSystem
    let boundary: Boundary
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { wrapped.supportsTrash }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        if boundary == .verification && wrapped.isTrashLocation(path) { withUnsafeCurrentTask { $0?.cancel() } }
        return try wrapped.inspect(path, budget: budget, cancelled: cancelled)
    }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { try wrapped.moveToTrash(path, expected: expected) }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws {
        try wrapped.restore(path, to: destination, expected: expected)
        if boundary == .restored { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func purge(_ path: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Cancellation fixtures must not purge.") }
}

private final class CancelAfterIntentStore: RecordStore, @unchecked Sendable {
    let wrapped: LocalRecordStore
    let collection: String
    private let mutex=NSLock()
    private var triggered=false
    init(_ wrapped: LocalRecordStore, collection: String) { self.wrapped=wrapped; self.collection=collection }
    var protectedPaths: [String] { wrapped.protectedPaths }
    func read(_ collection: String, id: String) throws -> Data? { try wrapped.read(collection, id: id) }
    func ids(_ collection: String) throws -> [String] { try wrapped.ids(collection) }
    func lock() throws -> any StoreLease { try wrapped.lock() }
    func write(_ collection: String, id: String, data: Data) throws {
        try wrapped.write(collection, id: id, data: data)
        mutex.lock(); defer { mutex.unlock() }
        guard collection == self.collection, !triggered else { return }
        let record=try Codec.decode(JSONValue.self, from: data)
        let intent=collection == "followups" ? record["state"] == .string("pending") :
            record["items"]?.array?.contains { $0["state"] == .string("moving") } == true
        if intent { triggered=true; withUnsafeCurrentTask { $0?.cancel() } }
    }
}

func followUpCancellationPreservesUnstartedItemsAndCompletedReceipts() async throws {
    for boundary in [CancellableFollowUpFileSystem.Boundary.before, .verification, .journal, .restored] {
        let fixture=try Fixture()
        try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
        try fixture.put("second/target/artifact.bin", "second artifact")
        let (initial, _, scan, _)=try await fixture.ready()
        let plan=try await initial.createPlan(scanId: scan.id, candidateIds: scan.candidates.filter(\.eligible).map(\.id))
        try expect(plan.items.count == 2)
        let receipt=try await initial.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
        let saved=try fixture.store.read("history", id: receipt.id)
        let ids=receipt.items.map(\.id)
        let digest=try await initial.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
        let filesystem=CancellableFollowUpFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), boundary: boundary)
        let store: any RecordStore=boundary == .journal ? CancelAfterIntentStore(fixture.store, collection: "followups") : fixture.store
        let engine=ShouEngine(store: store, filesystem: filesystem)
        let task=Task.detached {
            if boundary == .before { withUnsafeCurrentTask { $0?.cancel() } }
            return try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
        }
        let results=try await task.value
        let completed=[.journal, .restored].contains(boundary) ? 1 : 0
        try expect(results.count == completed && results.allSatisfy { $0.state == "completed" })
        try expect(try await engine.followUps().count == completed)
        try expect(try fixture.store.read("history", id: receipt.id) == saved)
        for item in receipt.items {
            let restored=results.contains { $0.itemId == item.id }
            try expect(FileManager.default.fileExists(atPath: item.originalPath) == restored)
            try expect(FileManager.default.fileExists(atPath: try require(item.trashPath)) != restored)
        }
        let remaining=ids.filter { id in !results.contains { $0.itemId == id } }
        let retryDigest=try await initial.followUpDigest(executionId: receipt.id, itemIds: remaining, action: "restore")
        let retry=try await initial.followUp(executionId: receipt.id, itemIds: remaining, action: "restore", confirmedDigest: retryDigest)
        try expect(retry.count == 2 - completed && retry.allSatisfy { $0.state == "completed" })
        try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
        try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("second/target/artifact.bin"), encoding: .utf8) == "second artifact")
        try expect(try fixture.store.read("history", id: receipt.id) == saved)
    }
}

func nativeTrashCancellationAfterIntentFinishesOneItemAndRestores() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/artifact.bin", "preserve second artifact")
    let (initial, _, scan, _)=try await fixture.ready()
    let plan=try await initial.createPlan(scanId: scan.id, candidateIds: scan.candidates.filter(\.eligible).map(\.id))
    let native=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let engine=ShouEngine(store: CancelAfterIntentStore(fixture.store, collection: "history"), filesystem: native, artifactEvidence: ArtifactFixtureEvidence())
    let task=Task.detached { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "native-cancellation-test") }
    let receipt=try await task.value
    let moved=receipt.items.filter { $0.state == "trashed" }
    try expect(receipt.state == "cancelled" && moved.count == 1 && receipt.items.filter { $0.state == "pending" }.count == 1)
    let restore=ShouEngine(store: fixture.store, filesystem: native)
    let ids=moved.map(\.id)
    let digest=try await restore.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let results=try await restore.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(results.count == 1 && results[0].state == "completed")
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("second/target/artifact.bin"), encoding: .utf8) == "preserve second artifact")
    try expect(moved.allSatisfy { !FileManager.default.fileExists(atPath: $0.trashPath ?? "") })
}

func followUpEligibilityIsIsolatedByExecution() async throws {
    for state in ["pending", "completed"] {
        let fixture=try Fixture()
        let (engine, _, scan, candidate)=try await fixture.ready()
        let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
        let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
        let item=receipt.items[0]
        let otherId=Codec.id("followup")
        let saved=try Codec.encode(JSONValue.object([
            "id": .string(otherId), "execution_id": .string("execution_other"), "item_id": .string(item.id),
            "action": .string("restore"), "created_at": .string("2026-10-19T00:00:00Z"), "state": .string(state),
            "resulting_path": .null, "error": .null
        ]))
        try fixture.store.write("followups", id: otherId, data: saved)
        let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
        let restored=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
        try expect(restored.count == 1 && restored[0].state == "completed")
        try expect(try fixture.store.read("followups", id: otherId) == saved)
        try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
    }
}

private final class FollowUpProgressRecorder: @unchecked Sendable {
    private let mutex=NSLock()
    private var updates: [ExecutionProgress]=[]
    private var proofs: [Bool]=[]
    func record(_ update: ExecutionProgress, durableIntent: Bool? = nil) {
        mutex.lock(); defer { mutex.unlock() }
        updates.append(update)
        if let durableIntent { proofs.append(durableIntent) }
    }
    var events: [ExecutionProgress] { mutex.lock(); defer { mutex.unlock() }; return updates }
    var verifiedDurableIntent: Bool { mutex.lock(); defer { mutex.unlock() }; return proofs == [true] }
}

func followUpProgressPreservesDurableCancellationBoundary() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/artifact.bin", "second retained output")
    let (engine, _, scan, _)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: scan.candidates.filter(\.eligible).map(\.id))
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let original=try fixture.store.read("history", id: receipt.id)
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let recorder=FollowUpProgressRecorder()
    let task=Task.detached {
        try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest) { update in
            if update.stage == "restoring" && update.processedCount == 0 {
                let stored=(try? fixture.store.ids("followups")) ?? []
                let intent=stored.first.flatMap { try? fixture.store.read("followups", id: $0) }
                    .flatMap { try? Codec.decode(FollowUpReceipt.self, from: $0) }
                recorder.record(update, durableIntent: stored.count == 1 && intent?.state == "pending" && intent?.action == "restore")
                withUnsafeCurrentTask { $0?.cancel() }
            } else { recorder.record(update) }
        }
    }
    let restored=try await task.value
    try expect(recorder.verifiedDurableIntent)
    try expect(restored.count == 1 && restored[0].state == "completed")
    try expect(try await engine.followUps().count == 1)
    let events=recorder.events
    try expect(events.allSatisfy { $0.itemCount == 2 && (0...1).contains($0.processedCount) })
    try expect(events.last?.stage == "restoring" && events.last?.processedCount == 1)
    try expect(zip(events, events.dropFirst()).allSatisfy { $0.processedCount <= $1.processedCount })
    for item in receipt.items {
        let completed=restored.contains { $0.itemId == item.id }
        try expect(FileManager.default.fileExists(atPath: item.originalPath) == completed)
        try expect(FileManager.default.fileExists(atPath: try require(item.trashPath)) != completed)
    }
    let remaining=ids.filter { id in !restored.contains { $0.itemId == id } }
    let retryDigest=try await engine.followUpDigest(executionId: receipt.id, itemIds: remaining, action: "restore")
    let retry=try await engine.followUp(executionId: receipt.id, itemIds: remaining, action: "restore", confirmedDigest: retryDigest)
    try expect(retry.count == 1 && retry[0].state == "completed")
    try expect(try fixture.store.read("history", id: receipt.id) == original)
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("second/target/artifact.bin"), encoding: .utf8) == "second retained output")
}

func followUpProgressCountsFailedOutcomeWithoutOverwriting() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let original=try fixture.store.read("history", id: receipt.id)
    let item=receipt.items[0]
    try fixture.put(item.relativePath + "/keep.txt", "Do not overwrite this destination.")
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
    let recorder=FollowUpProgressRecorder()
    let result=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest, progress: { recorder.record($0) })
    try expect(result.count == 1 && result[0].state == "failed")
    try expect(recorder.events.allSatisfy { $0.itemCount == 1 })
    try expect(recorder.events.last?.processedCount == 1 && recorder.events.last?.stage == "restoring")
    try expect(try await engine.followUps()[0].state == "failed")
    try expect(try String(contentsOfFile: item.originalPath + "/keep.txt", encoding: .utf8) == "Do not overwrite this destination.")
    try expect(FileManager.default.fileExists(atPath: try require(item.trashPath)))
    try expect(try fixture.store.read("history", id: receipt.id) == original)
}
