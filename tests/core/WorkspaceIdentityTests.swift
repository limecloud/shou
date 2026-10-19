import Foundation
import ShouCore

private final class IdentityFlipState: @unchecked Sendable {
    private let lock=NSLock()
    private var calls=0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { calls += 1 }
        return calls
    }
}

/// Simulates an APFS remount: the root inode remains stable while the process
/// observes a different device number. Target entries are left untouched so
/// this test covers only registration rebinding, not cleanup authorization.
private struct RemountingFileSystem: PlatformFileSystem {
    let wrapped: FixtureFileSystem
    let state: IdentityFlipState
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { wrapped.supportsTrash }
    var trashUnavailableReason: String? { wrapped.trashUnavailableReason }
    func locationAvailability(_ path: String) -> LocationAvailability { wrapped.locationAvailability(path) }
    func targetAvailability(_ path: String) -> LocationAvailability { wrapped.targetAvailability(path) }
    func rootIdentity(_ path: String) throws -> FileEntry {
        var identity=try wrapped.rootIdentity(path)
        if state.next() > 0 { identity.device += 1 }
        return identity
    }
    func applicationParentIdentity(_ path: String) throws -> FileEntry { try wrapped.applicationParentIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try wrapped.inspect(path, budget: budget, cancelled: cancelled) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot { try wrapped.inspect(path, budget: budget, cancelled: cancelled, progress: progress) }
    func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try wrapped.inspectTarget(path, budget: budget, cancelled: cancelled) }
    func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot { try wrapped.inspectCleanup(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress) }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { try wrapped.moveToTrash(path, expected: expected) }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try wrapped.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { try wrapped.purge(path, expected: expected) }
}

func workspaceRootRemountRefreshesBinding() async throws {
    let fixture=try Fixture()
    let state=IdentityFlipState()
    let wrapped=FixtureFileSystem(native: fixture.fs, trash: fixture.trash)
    let engine=ShouEngine(store: fixture.store, filesystem: RemountingFileSystem(wrapped: wrapped, state: state), artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    _ = try await engine.importRule(fixtureRule())
    _ = try await engine.setRule(ruleId: "test.artifacts", workspaceId: root.id, enabled: true)
    let scan=try await engine.scan(workspaceId: root.id)
    try expect(scan.status == "complete")
    let candidate=try require(scan.candidates.first(where: { $0.eligible }))
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let configuration=try await engine.configuration()
    let configurationDigest=try Digest.of(configuration)
    try expect(plan.configurationDigest == configurationDigest)
    let current=try await engine.configuration().workspaces.first(where: { $0.id == root.id })
    try expect(current?.identity == root.identity)
}
