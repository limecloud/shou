import Foundation
import ShouCore

private final class TargetCoverageState: @unchecked Sendable {
    private let lock=NSLock()
    private var paths: [String]?
    init(_ paths: [String]?) { self.paths=paths }
    func get() -> [String]? { lock.lock(); defer { lock.unlock() }; return paths }
    func set(_ value: [String]?) { lock.lock(); defer { lock.unlock() }; paths=value }
}

/// Keeps native target inspection and isolated Trash behavior while making a
/// different part of the workspace unavailable to the workspace-wide scan.
private struct TargetCoverageFileSystem: PlatformFileSystem {
    let wrapped: FixtureFileSystem
    let workspacePath: String
    let coverage: TargetCoverageState
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { wrapped.supportsTrash }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        var tree=try wrapped.inspect(path, budget: budget, cancelled: cancelled)
        if path == workspacePath {
            tree.complete=false; tree.issues=["Simulated unavailable sibling subtree."]
            tree.completedPaths=coverage.get()
        }
        return tree
    }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { try wrapped.moveToTrash(path, expected: expected) }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try wrapped.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { try wrapped.purge(path, expected: expected) }
}

private func coverageEngine(_ fixture: Fixture, coverage: TargetCoverageState) async throws -> (ShouEngine, Workspace) {
    let filesystem=TargetCoverageFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), workspacePath: fixture.workspace.path, coverage: coverage)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    _ = try await engine.importRule(fixtureRule())
    _ = try await engine.setRule(ruleId: "test.artifacts", workspaceId: root.id, enabled: true)
    return (engine, root)
}

func completeTargetInPartialRootCanExecuteAndRestore() async throws {
    let fixture=try Fixture(), coverage=TargetCoverageState(["project/target"])
    try fixture.put("other/Cargo.toml", "[package]\nname = 'other'\n")
    try fixture.put("other/target/keep.bin", "unreviewed sibling")
    let (engine, root)=try await coverageEngine(fixture, coverage: coverage)
    let scan=try await engine.scan(workspaceId: root.id)
    try expect(scan.status == "partial" && scan.completedPaths == ["project/target"])
    try expect(try await engine.scanSnapshot(scan.id).completedPaths == ["project/target"])
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" })
    let sibling=try require(scan.candidates.first { $0.relativePath == "other/target" })
    try expect(target.eligible && !target.manifestDigest.isEmpty)
    try expect(!sibling.eligible && sibling.reasons.contains("incomplete_scan"))
    try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [sibling.id]) }
    try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [target.id, sibling.id]) }
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [target.id])
    try expect(plan.items.count == 1 && plan.items[0].candidate.relativePath == "project/target")
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "coverage-test")
    try expect(receipt.state == "completed" && receipt.items.count == 1 && receipt.items[0].state == "trashed")
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target").path))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("other/target/keep.bin"), encoding: .utf8) == "unreviewed sibling")
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.count == 1 && restored[0].state == "completed")
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
}

func absentOrUnrelatedCoverageCannotAuthorizeTarget() async throws {
    let fixture=try Fixture(), coverage=TargetCoverageState(nil)
    let (engine, root)=try await coverageEngine(fixture, coverage: coverage)
    let unrelated: [[String]?]=[nil, [], ["project/target-other"], ["project/tar"], ["project/target/subtree"], ["project/target/artifact.bin"]]
    for paths in unrelated {
        coverage.set(paths)
        let scan=try await engine.scan(workspaceId: root.id)
        let target=try require(scan.candidates.first { $0.relativePath == "project/target" })
        try expect(scan.status == "partial" && !target.eligible && target.reasons.contains("incomplete_scan"))
        try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [target.id]) }
    }
    // A fully covered ancestor does cover the target; similarly named siblings do not.
    coverage.set(["project"])
    let scan=try await engine.scan(workspaceId: root.id)
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" })
    try expect(target.eligible)
    _ = try await engine.createPlan(scanId: scan.id, candidateIds: [target.id])
    try expect(try await engine.history().isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func lostExecutionCoverageRefusesPreviouslyValidPlan() async throws {
    let fixture=try Fixture(), coverage=TargetCoverageState(["project/target"])
    let (engine, root)=try await coverageEngine(fixture, coverage: coverage)
    let scan=try await engine.scan(workspaceId: root.id)
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" && $0.eligible })
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [target.id])
    for paths: [String]? in [nil, [], ["project/target-sibling"]] {
        coverage.set(paths)
        do {
            _ = try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "coverage-test")
            throw CheckFailure(description: "Execution must reproduce complete target coverage.")
        } catch let failure as ShouError { try expect(failure.code == "plan_stale") }
    }
    try expect(try await engine.history().isEmpty)
    try expect(try await engine.plan(plan.id).executionId == nil)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
    try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

func changedTargetWithCoverageStillRefusesExecution() async throws {
    let fixture=try Fixture(), coverage=TargetCoverageState(["project/target"])
    let (engine, root)=try await coverageEngine(fixture, coverage: coverage)
    let scan=try await engine.scan(workspaceId: root.id)
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" && $0.eligible })
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [target.id])
    try fixture.put("project/target/artifact.bin", "changed after planning")
    do {
        _ = try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "coverage-test")
        throw CheckFailure(description: "Coverage does not authorize a changed target manifest.")
    } catch let failure as ShouError { try expect(failure.code == "plan_stale") }
    try expect(try await engine.history().isEmpty)
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == "changed after planning")
    try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}
