import Foundation
import ShouCore
import ShouPlatform

private struct SelectiveFixtureFileSystem: PlatformFileSystem {
    let wrapped: FixtureFileSystem
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { wrapped.supportsTrash }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try wrapped.inspect(path, budget: budget, cancelled: cancelled) }
    func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try wrapped.native.inspectCleanup(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress)
    }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { try wrapped.moveToTrash(path, expected: expected) }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try wrapped.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { try wrapped.purge(path, expected: expected) }
}

func selectiveDiscoveryPrunesProtectedTreesWithinBudget() throws {
    let fixture=try Fixture()
    for index in 0..<300 { try fixture.put(".git/objects/pack/object-\(index).bin") }
    try fixture.put(".ssh/private-material", "preserve")
    let rules=[try CleanupRule.parse(fixtureRule())]
    let tree=try fixture.fs.inspectCleanup(fixture.workspace.path, rules: rules, budget: ScanBudget(maxEntries: 20), cancelled: { false }, progress: { _ in })
    try expect(!tree.complete && tree.discoveryComplete == true && tree.issues.isEmpty)
    try expect(tree.completedPaths == ["project/target"])
    try expect(tree.entries.count < 20 && tree.entries.contains { $0.path == "project/target/artifact.bin" })
    try expect(!tree.entries.contains { $0.path == ".git" || $0.path.hasPrefix(".git/") || $0.path == ".ssh" || $0.path.hasPrefix(".ssh/") })
    let full=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(maxEntries: 20), cancelled: { false })
    try expect(!full.complete && full.issues.contains("resource_limit"))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent(".ssh/private-material"), encoding: .utf8) == "preserve")
}

func fixedSelectivePatternsAvoidUnreachableSubtrees() throws {
    let fixture=try Fixture()
    for index in 0..<300 { try fixture.put("archive/deep/unrelated/data-\(index).bin") }
    try fixture.put("project/notes.txt", "unrelated file")
    let rule=try CleanupRule.parse(fixtureRule(pattern: "project/target"))
    let tree=try fixture.fs.inspectCleanup(fixture.workspace.path, rules: [rule], budget: ScanBudget(maxEntries: 12), cancelled: { false }, progress: { _ in })
    try expect(tree.discoveryComplete == true && tree.issues.isEmpty && !tree.complete)
    try expect(tree.completedPaths == ["project/target"])
    try expect(!tree.entries.contains { $0.path == "archive" || $0.path.hasPrefix("archive/") || $0.path == "project/notes.txt" })
    try expect(tree.entries.contains { $0.path == "project/Cargo.toml" && $0.kind == "file" })
    try expect(tree.entries.contains { $0.path == "project/target/artifact.bin" })
}

func matchedSelectiveTargetsRetainFullManifestsAndMarkers() async throws {
    let fixture=try Fixture()
    let deep="project/target/" + Array(repeating: "nested", count: 10).joined(separator: "/") + "/data.bin"
    try fixture.put(deep)
    try fixture.put("project/target/.git/config", "protected nested metadata")
    try fixture.put("project/target/.env", "protected local material")
    let rule=try CleanupRule.parse(fixtureRule(pattern: "project/target"))
    let tree=try fixture.fs.inspectCleanup(fixture.workspace.path, rules: [rule], budget: ScanBudget(), cancelled: { false }, progress: { _ in })
    try expect(tree.discoveryComplete == true && tree.completedPaths == ["project/target"])
    try expect(tree.entries.contains { $0.path == "project/Cargo.toml" })
    try expect(tree.entries.contains { $0.path == deep })
    try expect(tree.entries.contains { $0.path == "project/target/.git/config" })
    try expect(tree.entries.contains { $0.path == "project/target/.env" })
    let measured=try fixture.fs.inspect(fixture.workspace.appendingPathComponent("project/target").path, budget: ScanBudget(), cancelled: { false })
    try expect(Analysis.subtree(tree.entries, path: "project/target") == measured.entries)
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: [rule], now: Date())
    let target=try require(candidates.first { $0.relativePath == "project/target" })
    try expect(!target.eligible && target.reasons.contains("protected_content"))
}

func selectiveEngineEvidencePlansOnlyMeasuredTargetsAndRestores() async throws {
    let fixture=try Fixture()
    try fixture.put("project/source.rs", "authored source remains")
    try fixture.put("project/target/deps/cache.bin", "generated data")
    let filesystem=SelectiveFixtureFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence())
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: workspace.id, scope: .cleanup)
    try expect(scan.status == "complete" && scan.scope == .cleanup && scan.treeComplete == false)
    try expect(scan.completedPaths == ["project/target"])
    try expect(!scan.entries.contains { $0.path == "project/source.rs" })
    let persisted=try await engine.scanSnapshot(scan.id)
    try expect(persisted.scope == .cleanup && persisted.treeComplete == false && persisted.completedPaths == scan.completedPaths)
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" && $0.eligible })
    let parent=try require(scan.candidates.first { $0.relativePath == "project" })
    try expect(!parent.eligible)
    try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [parent.id]) }

    // Even a matching rule cannot turn sparse discovery into a complete parent manifest.
    var parentRule=try CleanupRule.parse(fixtureRule(pattern: "project"))
    parentRule.match.projectMarkers=nil
    let sparse=TreeSnapshot(entries: scan.entries, complete: false, issues: [], caseSensitive: scan.caseSensitive,
                            completedPaths: scan.completedPaths, discoveryComplete: true)
    let parentCandidates=try Analysis.candidates(tree: sparse, workspace: workspace, rules: [parentRule], now: Date())
    let unmeasured=try require(parentCandidates.first { $0.relativePath == "project" })
    try expect(!unmeasured.eligible && unmeasured.reasons.contains("incomplete_scan"))

    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [target.id])
    try expect(plan.scanScope == .cleanup && plan.items.count == 1)
    let fullTarget=try fixture.fs.inspect(fixture.workspace.appendingPathComponent("project/target").path, budget: ScanBudget(), cancelled: { false })
    try expect(plan.items[0].manifest == fullTarget.entries)
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "selective-test")
    try expect(receipt.state == "completed" && receipt.items[0].state == "trashed")
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target").path))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/source.rs"), encoding: .utf8) == "authored source remains")
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.count == 1 && restored[0].state == "completed")
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/deps/cache.bin"), encoding: .utf8) == "generated data")
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
}
