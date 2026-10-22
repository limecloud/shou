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

/// A large first project has both an artifact tree and unrelated deep files.
/// Later toolchains must receive discovery and measurement opportunities.
func addFairCleanupFixture(_ fixture: Fixture) throws -> [String] {
    try fixture.put("ai/aiclientproxy/package.json", "{}")
    for index in 0..<300 {
        try fixture.put("ai/aiclientproxy/node_modules/package/shard-\(index)/index.js")
        try fixture.put("ai/aiclientproxy/notes/deep/file-\(index).txt")
    }
    let projects: [(String, String, String)]=[
        ("rust/demo", "Cargo.toml", "target/output.bin"),
        ("Java/demo", "build.gradle", "build/classes/Demo.class"),
        ("flutter/demo", "pubspec.yaml", ".dart_tool/package_config.json"),
        ("python/demo", "pyproject.toml", ".mypy_cache/state.json")
    ]
    for (project, marker, output) in projects {
        try fixture.put(project + "/" + marker)
        try fixture.put(project + "/" + output)
    }
    return projects.map { project, _, output in project + "/" + output.split(separator: "/")[0] }
}

func selectiveDiscoverySharesFiniteBudgetAcrossLargeAndLaterProjects() async throws {
    let fixture=try Fixture()
    let expected=try addFairCleanupFixture(fixture)
    let filesystem=SelectiveFixtureFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let budget=ScanBudget(maxEntries: 256)
    let probe=FairCleanupProgressProbe()
    let scan=try await engine.scan(workspaceId: workspace.id, scope: .cleanup, budget: budget, progress: { probe.record($0) })
    try expect(scan.status == "partial" && scan.issues.contains("resource_limit"))
    try expect(scan.entries.count <= budget.maxEntries)
    try expect(probe.values.map(\.entryCount) == probe.values.map(\.entryCount).sorted())
    try expect(probe.values.allSatisfy { $0.entryCount <= budget.maxEntries })
    let large=try require(scan.candidates.first { $0.relativePath == "ai/aiclientproxy/node_modules" })
    try expect(!large.eligible && large.reasons.contains("incomplete_scan"))
    for path in expected {
        let candidate=try require(scan.candidates.first { $0.relativePath == path })
        try expect(candidate.eligible && scan.completedPaths?.contains(path) == true)
        let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
        try expect(plan.items.count == 1 && plan.workspace.id == workspace.id)
    }
    try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [large.id]) }
    try expect(try await engine.history().isEmpty)
}

private final class FairCleanupProgressProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var recorded=[ScanProgress]()
    func record(_ update: ScanProgress) { lock.lock(); defer { lock.unlock() }; recorded.append(update) }
    var values: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return recorded }
}

func selectiveFairDiscoveryPreservesRulesMarkersAndExclusions() async throws {
    let fixture=try Fixture()
    _ = try addFairCleanupFixture(fixture)
    try fixture.put("unmarked/target/inner/Cargo.toml")
    try fixture.put("unmarked/target/inner/target/output.bin")
    try fixture.put("linked/target/output.bin")
    try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("linked/Cargo.toml"), withDestinationURL: fixture.workspace.appendingPathComponent("project/Cargo.toml"))
    try fixture.put("custom/scratch/output.bin")
    let filesystem=SelectiveFixtureFileSystem(wrapped: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    _ = try await engine.setExclusion(workspaceId: workspace.id, pattern: "rust/demo/target/**", remove: false)
    _ = try await engine.setGlobalExclusion(pattern: "Java/demo/build/**", remove: false)
    _ = try await engine.setRule(ruleId: "shou.builtin.flutter-build", workspaceId: workspace.id, enabled: false)
    var personal=try CleanupRule.parse(fixtureRule(pattern: "custom/scratch"))
    personal.match.projectMarkers=nil
    let record=try await engine.importRule(Codec.encode(personal))
    _ = try await engine.setRule(ruleId: record.rule.id, workspaceId: workspace.id, enabled: true)
    let scan=try await engine.scan(workspaceId: workspace.id, scope: .cleanup, budget: .init(maxEntries: 400))
    for path in ["rust/demo/target", "Java/demo/build"] {
        let blocked=try require(scan.candidates.first { $0.relativePath == path })
        try expect(!blocked.eligible && blocked.reasons.contains("excluded_descendant"))
    }
    try expect(scan.candidates.allSatisfy { !$0.ruleIds.contains("shou.builtin.flutter-build") })
    try expect(scan.candidates.first { $0.relativePath == "custom/scratch" }?.eligible == true)
    try expect(scan.candidates.first { $0.relativePath == "unmarked/target/inner/target" }?.eligible == true)
    try expect(scan.candidates.first { $0.relativePath == "linked/target" }?.eligible != true)
    try expect(scan.candidates.first { $0.relativePath == "unmarked/target" }?.eligible != true)
    try expect(try await engine.configuration().workspaces.count == 1)
}

private final class CleanupReplacementProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var changed=false
    let trigger: String
    let operation: @Sendable () throws -> Void
    private var failure: Error?
    init(trigger: String, operation: @escaping @Sendable () throws -> Void) { self.trigger=trigger; self.operation=operation }
    func record(_ progress: ScanProgress) {
        guard progress.currentPath == trigger else { return }
        lock.lock(); defer { lock.unlock() }
        guard !changed else { return }
        changed=true
        do { try operation() } catch { failure=error }
    }
    func verify() throws { lock.lock(); defer { lock.unlock() }; try expect(changed); if let failure { throw failure } }
}

func selectiveDiscoveryRejectsReplacedTargetsAndMarkers() async throws {
    for replaceMarker in [false, true] {
        let fixture=try Fixture()
        let target=fixture.workspace.appendingPathComponent("project/target")
        let probe=CleanupReplacementProbe(trigger: target.path) {
            if replaceMarker {
                let marker=fixture.workspace.appendingPathComponent("project/Cargo.toml")
                try FileManager.default.moveItem(at: marker, to: fixture.base.appendingPathComponent("previous-marker"))
                try fixture.put("project/Cargo.toml", "replacement marker")
            } else {
                try FileManager.default.moveItem(at: target, to: fixture.base.appendingPathComponent("previous-target"))
                try fixture.put("project/target/replacement.bin")
            }
        }
        let rules=[try CleanupRule.parse(fixtureRule())]
        let tree=try fixture.fs.inspectCleanup(fixture.workspace.path, rules: rules, budget: .init(), cancelled: { false }, progress: { probe.record($0) })
        try probe.verify()
        try expect(tree.discoveryComplete == false && !tree.isComplete(at: "project/target"))
        try expect(tree.issues.contains { $0.hasPrefix("changed_directory:") })
    }
}

func selectiveDiscoveryCancellationKeepsPartialTargetsUnauthorized() throws {
    let fixture=try Fixture()
    _ = try addFairCleanupFixture(fixture)
    let rule=try CleanupRule.parse(fixtureRule())
    let cancellation=CleanupCancellationProbe()
    do {
        _ = try fixture.fs.inspectCleanup(fixture.workspace.path, rules: [rule], budget: .init(maxEntries: 256),
            cancelled: { cancellation.cancelled }, progress: { update in
                if update.entryCount > 0 { cancellation.stop() }
            })
        throw CheckFailure(description: "A cancelled discovery must not return authorized targets.")
    } catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

private final class CleanupCancellationProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var stopped=false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); defer { lock.unlock() }; stopped=true }
}
