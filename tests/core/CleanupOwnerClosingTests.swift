import Foundation
import ShouCore

private final class OwnerCloseFixture: CleanupOwnerClosing, @unchecked Sendable {
    private let lock=NSLock()
    private var generation: UInt64=100
    private var running=true
    private var requests=0
    var refuses=false
    var throwsOnRequest=false
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func changeIdentity() { lock.lock(); defer { lock.unlock() }; generation += 1 }
    func inspect(identifiers: Set<String>) throws -> [CleanupOwnerTarget] {
        lock.lock(); defer { lock.unlock() }
        let file=FileEntry(path: "executable", kind: "file", device: 1, inode: 0, logicalBytes: 10, allocatedBytes: 10, modifiedNanoseconds: 1, changedNanoseconds: 1, mode: 0, owner: 0, links: 1)
        var identity=file; identity.windowsIdentity = .init(volume: 1, fileId: String(repeating: "a", count: 32), ownerSid: "S-1-5-21-1")
        return identifiers.filter { $0 == "com.google.Chrome" }.sorted().map { .init(identifier: $0, name: "Generated owner", processes: [.init(pid: 123, created: generation, session: 1, ownerSid: "S-1-5-21-1", executablePath: "C:/generated/owner.exe", executableIdentity: identity)]) }
    }
    func requestClose(_ target: CleanupOwnerTarget) throws {
        lock.lock(); defer { lock.unlock() }; requests += 1
        if throwsOnRequest { throw ShouError("fixture_refused", "Private path and detail must not enter the receipt.") }
        if !refuses { running=false }
    }
    func isRunning(identifier: String) throws -> Bool { lock.lock(); defer { lock.unlock() }; return running }
}

private func ownerClosingFixture() async throws -> (Fixture, ShouEngine, ScanSnapshot, OwnerCloseFixture) {
    let fixture=try Fixture(), (engine, _, original, _)=try await fixture.ready()
    var scan=original
    let rule=try BuiltinCatalog.templates().first { $0.applicationBundleIdentifiers?.contains("com.google.Chrome") == true }!
    scan.candidates[0].ruleIds=[rule.id]; scan.candidates[0].reasons=["application_running"]; scan.candidates[0].eligible=false
    try fixture.store.write("scans", id: scan.id, data: Codec.encode(scan))
    return (fixture, engine, scan, OwnerCloseFixture())
}

func cleanupOwnerClosingBindsProcessesAndConsumesConsent() async throws {
    let (fixture,engine,scan,controller)=try await ownerClosingFixture()
    let before=try Data(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"))
    let review=try await engine.cleanupOwnerCloseReview(scanIds: [scan.id], controller: controller)
    try expect(review.targets.count == 1 && review.targets[0].identifier == "com.google.Chrome")
    try expect(review.affectedWorkspaceIds == [scan.workspace.id] && review.affectedPaths == [scan.workspace.path + "/" + scan.candidates[0].relativePath])
    try await expectThrows { try await engine.closeCleanupOwners(review: review, confirmedDigest: "wrong", controller: controller, timeoutSeconds: 0) }
    try expect(controller.count == 0 && (try fixture.store.ids("cleanup-close-history")).isEmpty)
    let result=try await engine.closeCleanupOwners(review: review, confirmedDigest: review.digest, controller: controller, timeoutSeconds: 0)
    try expect(result.state == "completed" && result.items.map(\.state) == ["closed"] && controller.count == 1)
    try await expectThrows { try await engine.closeCleanupOwners(review: review, confirmedDigest: review.digest, controller: controller, timeoutSeconds: 0) }
    try expect(controller.count == 1)
    let receipt=try fixture.store.read("cleanup-close-history", id: result.id)!
    try expect(!String(decoding: receipt, as: UTF8.self).contains("C:/generated"))
    try expect(try Data(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin")) == before)
}

func cleanupOwnerClosingRejectsChangedProcessesSettingsAndPreview() async throws {
    let (fixture,engine,scan,controller)=try await ownerClosingFixture()
    let review=try await engine.cleanupOwnerCloseReview(scanIds: [scan.id], controller: controller)
    let expired=ShouEngine(store: fixture.store, filesystem: fixture.fs, now: { Date.distantFuture })
    try await expectThrows { try await expired.closeCleanupOwners(review: review, confirmedDigest: review.digest, controller: controller, timeoutSeconds: 0) }
    let cancelled=Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await engine.closeCleanupOwners(review: review, confirmedDigest: review.digest, controller: controller, timeoutSeconds: 0)
    }
    try await expectThrows { try await cancelled.value }
    try expect(controller.count == 0)
    controller.changeIdentity()
    try await expectThrows { try await engine.closeCleanupOwners(review: review, confirmedDigest: review.digest, controller: controller, timeoutSeconds: 0) }
    try expect(controller.count == 0)
    let current=try await engine.cleanupOwnerCloseReview(scanIds: [scan.id], controller: controller)
    _ = try await engine.setGlobalExclusion(pattern: "retained/**", remove: false)
    try await expectThrows { try await engine.closeCleanupOwners(review: current, confirmedDigest: current.digest, controller: controller, timeoutSeconds: 0) }
    try expect(controller.count == 0)
    var preview=scan; preview.id="generated_preview"; preview.previewOnly=true
    try fixture.store.write("scans", id: preview.id, data: Codec.encode(preview))
    try await expectThrows { try await engine.cleanupOwnerCloseReview(scanIds: [preview.id], controller: controller) }
    try await expectThrows { try await engine.cleanupOwnerCloseReview(scanIds: [scan.id,scan.id], controller: controller) }
}

func cleanupOwnerClosingRetainsRefusalAndSanitizesFailures() async throws {
    let (fixture,engine,scan,controller)=try await ownerClosingFixture()
    controller.refuses=true
    let review=try await engine.cleanupOwnerCloseReview(scanIds: [scan.id], controller: controller)
    let remaining=try await engine.closeCleanupOwners(review: review, confirmedDigest: review.digest, controller: controller, timeoutSeconds: 0)
    try expect(remaining.state == "partial" && remaining.items.map(\.state) == ["still_running"])
    controller.changeIdentity(); controller.throwsOnRequest=true
    let other=try await engine.cleanupOwnerCloseReview(scanIds: [scan.id], controller: controller)
    let failed=try await engine.closeCleanupOwners(review: other, confirmedDigest: other.digest, controller: controller, timeoutSeconds: 0)
    try expect(failed.state == "partial" && failed.items[0].error == "fixture_refused")
    try expect(!String(decoding: try fixture.store.read("cleanup-close-history", id: failed.id)!, as: UTF8.self).contains("Private path"))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}
