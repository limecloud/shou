import Foundation
import ShouCore
import ShouPlatform

private final class FailingReceiptStore: RecordStore, @unchecked Sendable {
    let wrapped: LocalRecordStore
    let collection: String
    let failingWrite: Int
    private let mutex=NSLock()
    private var writes=0
    init(_ wrapped: LocalRecordStore, collection: String, failingWrite: Int) {
        self.wrapped=wrapped; self.collection=collection; self.failingWrite=failingWrite
    }
    var protectedPaths: [String] { wrapped.protectedPaths }
    func read(_ collection: String, id: String) throws -> Data? { try wrapped.read(collection, id: id) }
    func ids(_ collection: String) throws -> [String] { try wrapped.ids(collection) }
    func lock() throws -> any StoreLease { try wrapped.lock() }
    func write(_ collection: String, id: String, data: Data) throws {
        mutex.lock(); defer { mutex.unlock() }
        if collection == self.collection {
            writes += 1
            if writes == failingWrite { throw ShouError("journal_unavailable", "Injected receipt write failure.") }
        }
        try wrapped.write(collection, id: id, data: data)
    }
}

func historyInspectionPreservesRecordsAndDetectsConflictChangesAndRestore() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let item=receipt.items[0], trash=try require(receipt.items[0].trashPath)
    let saved=try fixture.store.read("history", id: receipt.id)
    var report=try await engine.inspectHistory(executionId: receipt.id)
    try expect(report.status == "complete" && !report.unfinished && report.items[0].state == "verified_trash")
    try expect(report.items[0].original.state == "missing" && report.items[0].trash.state == "matches")
    try expect(try fixture.store.read("history", id: receipt.id) == saved)
    try fixture.put("project/target/preserve.txt", "restore destination must survive")
    report=try await engine.inspectHistory(executionId: receipt.id)
    try expect(report.status == "partial" && report.items[0].state == "restore_conflict")
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: [item.id], action: "restore")
    let failure=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
    try expect(failure[0].state == "failed")
    try expect(try String(contentsOfFile: item.originalPath + "/preserve.txt", encoding: .utf8) == "restore destination must survive")
    try FileManager.default.moveItem(atPath: item.originalPath, toPath: fixture.base.appendingPathComponent("preserved-conflict").path)
    let retry=try await engine.followUp(executionId: receipt.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
    try expect(retry[0].state == "completed")
    report=try await engine.inspectHistory(executionId: receipt.id)
    try expect(report.items[0].state == "restored" && report.items[0].original.state == "matches" && report.items[0].trash.state == "missing")
    try expect(!FileManager.default.fileExists(atPath: trash))
    try expect(try fixture.store.read("history", id: receipt.id) == saved)
    let lease=try fixture.store.lock()
    try await expectThrows { try await engine.inspectHistory(executionId: receipt.id) }
    lease.release()
}

func historyInspectionBlocksChangedAndBudgetLimitedEvidence() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let trash=try require(receipt.items[0].trashPath)
    var report=try await engine.inspectHistory(executionId: receipt.id, budget: ScanBudget(maxEntries: 1))
    try expect(report.status == "partial" && report.items[0].trash.state == "unavailable")
    try Data("changed fixture".utf8).write(to: URL(fileURLWithPath: trash).appendingPathComponent("artifact.bin"))
    report=try await engine.inspectHistory(executionId: receipt.id)
    try expect(report.items[0].state == "needs_verification" && report.items[0].trash.state == "changed")
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore", confirmedDigest: digest)
    try expect(restored.count == 1 && restored[0].state == "failed")
    try expect(try await engine.followUps().allSatisfy { $0.state == "failed" })
    try expect(try String(contentsOfFile: trash + "/artifact.bin", encoding: .utf8) == "changed fixture")
}

func perItemJournalFailuresNeverLookLikeSkippedWork() async throws {
    for failingWrite in [2, 3] {
        let fixture=try Fixture()
        let (initial, _, scan, candidate)=try await fixture.ready()
        let plan=try await initial.createPlan(scanId: scan.id, candidateIds: [candidate.id])
        let failing=FailingReceiptStore(fixture.store, collection: "history", failingWrite: failingWrite)
        let engine=ShouEngine(store: failing, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), artifactEvidence: ArtifactFixtureEvidence())
        try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
        let receipt=try require(try await engine.history().first)
        try expect(receipt.state == "executing")
        let report=try await engine.inspectHistory(executionId: receipt.id)
        try expect(report.unfinished)
        if failingWrite == 2 {
            try expect(receipt.items[0].state == "pending" && report.items[0].state == "verified_original")
            try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
        } else {
            try expect(receipt.items[0].state == "moving" && report.items[0].state == "missing")
            let target=try require(FileManager.default.contentsOfDirectory(at: fixture.trash, includingPropertiesForKeys: nil).first)
            try expect(try Data(contentsOf: target.appendingPathComponent("artifact.bin")) == Data(String(repeating: "x", count: 8192).utf8))
        }
        try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    }
}

func unfinishedRestoreIsObservedWithoutRetryingOrRewriting() async throws {
    let fixture=try Fixture()
    let (initial, _, scan, candidate)=try await fixture.ready()
    let plan=try await initial.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await initial.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let engine=ShouEngine(store: FailingReceiptStore(fixture.store, collection: "followups", failingWrite: 2), filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
    let ids=receipt.items.map(\.id), digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    try await expectThrows { try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest) }
    let before=try await engine.followUps()
    try expect(before.count == 1 && before[0].state == "pending")
    let report=try await engine.inspectHistory(executionId: receipt.id)
    try expect(report.unfinished && report.items[0].state == "needs_verification")
    try expect(report.items[0].original.state == "matches" && report.items[0].trash.state == "missing")
    try expect(try Codec.encode(await engine.followUps()) == Codec.encode(before))
    try await expectThrows { try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore") }
    try await expectThrows { try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest) }
    try expect(FileManager.default.fileExists(atPath: receipt.items[0].originalPath + "/artifact.bin"))
}

private struct TerminatingTrashFileSystem: PlatformFileSystem {
    let wrapped: FixtureFileSystem
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { true }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try wrapped.inspect(path, budget: budget, cancelled: cancelled) }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        _ = try wrapped.moveToTrash(path, expected: expected)
        Foundation.exit(86)
    }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try wrapped.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { try wrapped.purge(path, expected: expected) }
}

func historyInterruptionChild(_ output: String) async throws {
    let fixture=try Fixture()
    let (initial, _, scan, candidate)=try await fixture.ready()
    let plan=try await initial.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    try JSONSerialization.data(withJSONObject: ["base": fixture.base.path, "plan_id": plan.id]).write(to: URL(fileURLWithPath: output))
    let engine=ShouEngine(store: fixture.store, filesystem: TerminatingTrashFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash)), artifactEvidence: ArtifactFixtureEvidence())
    _ = try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
}

func processExitAfterMovingRetainsIntentAndCannotReplay() async throws {
    let parent=try Fixture(), output=parent.base.appendingPathComponent("interrupted-child.json")
    let process=Process()
    process.executableURL=URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments=["--history-interruption-child", output.path]
    process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationReason == .exit && process.terminationStatus == 86)
    let record=try require(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: String])
    let base=URL(fileURLWithPath: try require(record["base"]))
    defer { try? FileManager.default.removeItem(at: base) }
    let store=try LocalRecordStore(directory: base.appendingPathComponent("store")), fs=FixtureFileSystem(native: NativeFileSystem(), trash: base.appendingPathComponent("isolated-trash"))
    let engine=ShouEngine(store: store, filesystem: fs)
    let receipt=try require(try await engine.history().first)
    let saved=try store.read("history", id: receipt.id)
    try expect(receipt.state == "executing" && receipt.items[0].state == "moving" && receipt.items[0].trashPath == nil)
    let report=try await engine.inspectHistory(executionId: receipt.id)
    try expect(report.unfinished && report.status == "partial" && report.items[0].state == "missing")
    try expect(report.items[0].trash.state == "not_recorded")
    let plan=try await engine.plan(try require(record["plan_id"]))
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    try expect(try store.read("history", id: receipt.id) == saved)
    let target=try require(FileManager.default.contentsOfDirectory(at: fs.trash, includingPropertiesForKeys: nil).first)
    try expect(try Data(contentsOf: target.appendingPathComponent("artifact.bin")) == Data(String(repeating: "x", count: 8192).utf8))
}
