import Foundation
import ShouCore
import ShouPlatform

/// All mutations and Trash operations stay inside the generated fixture.
private struct TargetScanFileSystem: PlatformFileSystem {
    let fixture: FixtureFileSystem
    let reader: NativeFileSystem
    var platform: String { "macos" }
    var supportsTrash: Bool { true }
    func rootIdentity(_ path: String) throws -> FileEntry { try reader.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try reader.inspect(path, budget: budget, cancelled: cancelled) }
    func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try reader.inspectCleanup(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress)
    }
    func availableBytes(_ path: String) -> Int64? { fixture.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { fixture.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { try fixture.moveToTrash(path, expected: expected) }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try fixture.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { try fixture.purge(path, expected: expected) }
}

private struct TargetScanFixture {
    let fixture: Fixture
    let engine: ShouEngine
    let workspace: Workspace
    let scan: ScanSnapshot
    let target: Candidate
}

private func incompleteTargetFixture(evidence: any ArtifactEvidenceChecking = ArtifactFixtureEvidence(), exclusion: String? = nil) async throws -> TargetScanFixture {
    let fixture=try Fixture()
    for index in 0..<48 { try fixture.put("project/target/data-\(index).bin") }
    let filesystem=TargetScanFileSystem(fixture: .init(native: fixture.fs, trash: fixture.trash), reader: fixture.fs)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: evidence, homeDirectory: fixture.workspace)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    if let exclusion { _ = try await engine.setExclusion(workspaceId: workspace.id, pattern: exclusion, remove: false) }
    let scan=try await engine.scan(workspaceId: workspace.id, scope: .cleanup, budget: .init(maxEntries: 12))
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" })
    try expect(!target.eligible && target.reasons.contains("incomplete_scan"))
    return TargetScanFixture(fixture: fixture, engine: engine, workspace: workspace, scan: scan, target: target)
}

private func expectTargetScanError(_ code: String, _ operation: () async throws -> ScanSnapshot) async throws {
    do { _ = try await operation(); throw CheckFailure(description: "Expected target scan failure: \(code)") }
    catch let error as ShouError { try expect(error.code == code) }
}

func cleanupTargetRescanCompletesOnlyOriginalTargetAndExecutes() async throws {
    let fixture=try Fixture()
    let siblings=try addFairCleanupFixture(fixture)
    let filesystem=TargetScanFileSystem(fixture: .init(native: fixture.fs, trash: fixture.trash), reader: fixture.fs)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let otherRoot=fixture.base.appendingPathComponent("other-root")
    try FileManager.default.createDirectory(at: otherRoot.appendingPathComponent("target"), withIntermediateDirectories: true)
    try Data("[package]".utf8).write(to: otherRoot.appendingPathComponent("Cargo.toml"))
    try Data("other artifact".utf8).write(to: otherRoot.appendingPathComponent("target/output.bin"))
    let otherWorkspace=try await engine.addWorkspace(path: otherRoot.path, rootRef: "other-root")
    let original=try await engine.scan(workspaceId: workspace.id, scope: .cleanup, budget: .init(maxEntries: 256))
    let other=try await engine.scan(workspaceId: otherWorkspace.id, scope: .cleanup)
    let target=try require(original.candidates.first { $0.relativePath == "ai/aiclientproxy/node_modules" })
    try expect(!target.eligible && target.reasons.contains("incomplete_scan"))
    let config=try await engine.configuration()
    // Content may change before the fresh read; the bound directory object may not.
    try fixture.put(target.relativePath + "/new-package/index.js", "dependency source")
    // The new root siblings exceed this plan's entire entry budget. Cleanup
    // preflight must retain the same selected-target read boundary.
    for index in 0..<1_200 { try fixture.put("noise-\(index).txt") }
    let refined=try await engine.scanCleanupTarget(scanId: original.id, candidateId: target.id, budget: .init(maxEntries: 1_000))
    let complete=try require(refined.candidates.first { $0.relativePath == target.relativePath })
    try expect(complete.eligible && complete.ruleIds == target.ruleIds && complete.ruleVersions == target.ruleVersions)
    try expect(refined.workspace.id == workspace.id && refined.workspace.rootRef == workspace.rootRef)
    try expect(refined.configurationDigest == original.configurationDigest && refined.scope == .cleanup && refined.treeComplete == false)
    try expect(refined.completedPaths == [target.relativePath] && refined.status == "complete")
    try expect(siblings.allSatisfy { path in !refined.entries.contains { $0.path == path || $0.path.hasPrefix(path + "/") } })
    try expect(refined.candidates.allSatisfy { $0.relativePath == target.relativePath || $0.relativePath.hasPrefix(target.relativePath + "/") })
    try expect(try Digest.of(await engine.configuration()) == Digest.of(config))
    try expect(try Codec.encode(await engine.scanSnapshot(original.id)) == Codec.encode(original))
    try expect(try Codec.encode(await engine.scanSnapshot(other.id)) == Codec.encode(other))
    try await expectThrows { try await engine.createPlan(scanId: original.id, candidateIds: [target.id]) }
    let plan=try await engine.createPlan(scanId: refined.id, candidateIds: [complete.id])
    let full=try fixture.fs.inspect(fixture.workspace.appendingPathComponent(target.relativePath).path, budget: .init(), cancelled: { false })
    try expect(plan.items[0].manifest == full.entries && plan.scanScope == .cleanup)
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "target-rescan-fixture")
    try expect(receipt.state == "completed" && receipt.items[0].state == "trashed")
    for path in siblings { try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(path).path)) }
    try expect(FileManager.default.fileExists(atPath: otherRoot.appendingPathComponent("target/output.bin").path))
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" })
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent(target.relativePath + "/new-package/index.js"), encoding: .utf8) == "dependency source")
}

func cleanupTargetRescanRejectsPreviewCompleteAndChangedConfiguration() async throws {
    let context=try await incompleteTargetFixture()
    let engine=context.engine, original=context.scan, target=context.target
    let previewRule=try CleanupRule.parse(fixtureRule())
    let preview=try await engine.scan(workspaceId: context.workspace.id, previewRule: previewRule, scope: .cleanup, budget: .init(maxEntries: 12))
    let previewTarget=try require(preview.candidates.first { $0.relativePath == target.relativePath })
    try await expectTargetScanError("partial_result") { try await engine.scanCleanupTarget(scanId: preview.id, candidateId: previewTarget.id) }
    let full=try await engine.scan(workspaceId: context.workspace.id, scope: .cleanup)
    let fullTarget=try require(full.candidates.first { $0.relativePath == target.relativePath })
    try await expectTargetScanError("invalid_argument") { try await engine.scanCleanupTarget(scanId: full.id, candidateId: fullTarget.id) }
    try await expectTargetScanError("invalid_argument") { try await engine.scanCleanupTarget(scanId: original.id, candidateId: "missing") }
    let parent=try require(original.candidates.first { $0.relativePath == "project" })
    try await expectTargetScanError("invalid_argument") { try await engine.scanCleanupTarget(scanId: original.id, candidateId: parent.id) }
    var forged=original
    forged.id=Codec.id("scan")
    let targetIndex=try require(forged.candidates.firstIndex { $0.id == target.id })
    forged.candidates[targetIndex].relativePath="project"
    try context.fixture.store.write("scans", id: forged.id, data: Codec.encode(forged))
    try await expectTargetScanError("store_corrupt") { try await engine.scanCleanupTarget(scanId: forged.id, candidateId: target.id) }
    let nonCleanup=try await engine.scan(workspaceId: context.workspace.id, budget: .init(maxEntries: 12))
    let nonCleanupTarget=try require(nonCleanup.candidates.first { $0.relativePath == target.relativePath })
    try await expectTargetScanError("invalid_argument") { try await engine.scanCleanupTarget(scanId: nonCleanup.id, candidateId: nonCleanupTarget.id) }
    _ = try await engine.setRule(ruleId: "shou.builtin.rust-target", workspaceId: context.workspace.id, enabled: false)
    try await expectTargetScanError("plan_stale") { try await engine.scanCleanupTarget(scanId: original.id, candidateId: target.id) }
    let excluded=try await incompleteTargetFixture()
    _ = try await excluded.engine.setExclusion(workspaceId: excluded.workspace.id, pattern: "project/target/**", remove: false)
    try await expectTargetScanError("plan_stale") { try await excluded.engine.scanCleanupTarget(scanId: excluded.scan.id, candidateId: excluded.target.id) }
    let global=try await incompleteTargetFixture()
    _ = try await global.engine.setGlobalExclusion(pattern: "project/**", remove: false)
    try await expectTargetScanError("plan_stale") { try await global.engine.scanCleanupTarget(scanId: global.scan.id, candidateId: global.target.id) }
    let ruleChanged=try await incompleteTargetFixture()
    _ = try await ruleChanged.engine.importRule(fixtureRule())
    try await expectTargetScanError("plan_stale") { try await ruleChanged.engine.scanCleanupTarget(scanId: ruleChanged.scan.id, candidateId: ruleChanged.target.id) }
    let alreadyExcluded=try await incompleteTargetFixture(exclusion: "project/target/**")
    let excludedScan=try await alreadyExcluded.engine.scanCleanupTarget(scanId: alreadyExcluded.scan.id, candidateId: alreadyExcluded.target.id)
    let protected=try require(excludedScan.candidates.first { $0.relativePath == alreadyExcluded.target.relativePath })
    try expect(!protected.eligible && protected.reasons.contains("excluded_descendant"))
    try await expectThrows { try await alreadyExcluded.engine.createPlan(scanId: excludedScan.id, candidateIds: [protected.id]) }
    try expect(try await engine.history().isEmpty)
}

func cleanupTargetRescanRejectsReplacedBindingsAndMissingMarkers() async throws {
    for change in ["target", "root", "marker", "linked-marker"] {
        let context=try await incompleteTargetFixture()
        let fixture=context.fixture
        switch change {
        case "target":
            try FileManager.default.moveItem(at: fixture.workspace.appendingPathComponent("project/target"), to: fixture.base.appendingPathComponent("previous-target"))
            try fixture.put("project/target/replacement.bin")
        case "root":
            try FileManager.default.moveItem(at: fixture.workspace, to: fixture.base.appendingPathComponent("previous-root"))
            try fixture.put("project/Cargo.toml")
            try fixture.put("project/target/replacement.bin")
        default:
            let marker=fixture.workspace.appendingPathComponent("project/Cargo.toml")
            let moved=fixture.base.appendingPathComponent("previous-marker")
            try FileManager.default.moveItem(at: marker, to: moved)
            if change == "linked-marker" { try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: moved) }
        }
        try await expectTargetScanError("plan_stale") { try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id) }
        try expect(try await context.engine.history().isEmpty)
    }
}

private final class TargetArtifactFacts: ArtifactEvidenceChecking, @unchecked Sendable {
    private let lock=NSLock()
    private var value=ArtifactFixtureEvidence()
    func set(_ evidence: ArtifactFixtureEvidence) { lock.lock(); defer { lock.unlock() }; value=evidence }
    private var current: ArtifactFixtureEvidence { lock.lock(); defer { lock.unlock() }; return value }
    func hasGitTrackedFiles(at path: String) throws -> Bool { try current.hasGitTrackedFiles(at: path) }
    func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity { try current.cargoSourceIntegrity(at: path, expected: expected) }
    func runningBuildProcesses(in names: Set<String>) throws -> Set<String> { try current.runningBuildProcesses(in: names) }
}

func cleanupTargetRescanRechecksSourceGitAndBuildActivity() async throws {
    for reason in ["protected_content", "tracked_artifact_content", "build_process_running", "artifact_evidence_unavailable"] {
        let facts=TargetArtifactFacts(), context=try await incompleteTargetFixture(evidence: facts)
        switch reason {
        case "protected_content": try context.fixture.put("project/target/authored.rs", "pub fn keep() {}")
        case "tracked_artifact_content": facts.set(.init(tracked: true))
        case "build_process_running": facts.set(.init(active: ["cargo"]))
        default: facts.set(.init(unavailable: true))
        }
        let scan=try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id)
        let candidate=try require(scan.candidates.first { $0.relativePath == context.target.relativePath })
        try expect(scan.status == "complete" && !candidate.eligible && candidate.reasons.contains(reason))
        try await expectThrows { try await context.engine.createPlan(scanId: scan.id, candidateIds: [candidate.id]) }
        try expect(try await context.engine.history().isEmpty)
    }
}

private final class TargetScanMutation: @unchecked Sendable {
    private let lock=NSLock()
    private var changed=false
    private var failure: Error?
    let stage: String
    let path: String?
    let operation: @Sendable () throws -> Void
    init(stage: String, path: String? = nil, operation: @escaping @Sendable () throws -> Void) { self.stage=stage; self.path=path; self.operation=operation }
    func record(_ update: ScanProgress) {
        guard update.stage == stage, path == nil || update.currentPath == path else { return }
        lock.lock(); defer { lock.unlock() }
        guard !changed else { return }
        changed=true
        do { try operation() } catch { failure=error }
    }
    func verify() throws { lock.lock(); defer { lock.unlock() }; try expect(changed); if let failure { throw failure } }
}

func cleanupTargetRescanProtectsLimitsCancellationAndMidScanChanges() async throws {
    let context=try await incompleteTargetFixture()
    let limited=try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, budget: .init(maxEntries: 12))
    let partial=try require(limited.candidates.first { $0.relativePath == context.target.relativePath })
    try expect(limited.status == "partial" && limited.issues.contains("resource_limit") && !partial.eligible)
    try expect(limited.entries.count <= 12 && partial.reasons.contains("incomplete_scan"))
    try await expectThrows { try await context.engine.createPlan(scanId: limited.id, candidateIds: [partial.id]) }
    try await expectTargetScanError("invalid_argument") { try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, budget: .init(maxEntries: 1_000_001)) }
    for stage in ["scanning", "saving"] {
        let before=try context.fixture.store.ids("scans")
        let task=Task {
            try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, progress: { update in
                if update.stage == stage { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        try await expectTargetScanError("cancelled") { try await task.value }
        try expect(try context.fixture.store.ids("scans") == before)
    }
    let fixture=context.fixture
    let mutation=TargetScanMutation(stage: "analysis") {
        let data=try require(fixture.store.read("configuration", id: "current"))
        var config=try Codec.decode(Configuration.self, from: data)
        config.revision="fixture-policy-change"
        try fixture.store.write("configuration", id: "current", data: Codec.encode(config))
    }
    try await expectTargetScanError("plan_stale") { try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, progress: { mutation.record($0) }) }
    try mutation.verify()
    try expect(try await context.engine.history().isEmpty)
}

func cleanupTargetRescanRejectsChangesDuringMeasurement() async throws {
    for replaceMarker in [false, true] {
        let context=try await incompleteTargetFixture()
        let fixture=context.fixture, target=fixture.workspace.appendingPathComponent(context.target.relativePath)
        let mutation=TargetScanMutation(stage: "scanning", path: target.path) {
            let source=replaceMarker ? fixture.workspace.appendingPathComponent("project/Cargo.toml") : target
            try FileManager.default.moveItem(at: source, to: fixture.base.appendingPathComponent("old-binding"))
            try fixture.put(replaceMarker ? "project/Cargo.toml" : "project/target/replacement.bin")
        }
        if replaceMarker {
            let partial=try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, progress: { mutation.record($0) })
            let candidate=try require(partial.candidates.first { $0.relativePath == context.target.relativePath })
            try expect(!candidate.eligible && candidate.reasons.contains("incomplete_scan") && partial.completedPaths?.isEmpty == true)
            try expect(partial.issues.contains { $0.hasPrefix("changed_directory:") })
            try await expectThrows { try await context.engine.createPlan(scanId: partial.id, candidateIds: [candidate.id]) }
        } else {
            try await expectTargetScanError("plan_stale") { try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, progress: { mutation.record($0) }) }
        }
        try mutation.verify()
        try expect(try await context.engine.history().isEmpty)
    }
}

func cleanupTargetRescanRetainsCanonicalGeneratedSourceRules() async throws {
    let fixture=try Fixture(), product="swift/.build/arm64-apple-macosx/debug"
    try fixture.put("swift/Package.swift", "// swift-tools-version: 6.0")
    try fixture.put("swift/.build/workspace-state.json", "{}")
    try fixture.put(product + "/description.json", "{}")
    try fixture.put(product + "/Demo.build/DerivedSources/resource_bundle_accessor.swift", "// generated")
    for index in 0..<64 { try fixture.put(product + "/Demo.build/output-\(index).bin") }
    try fixture.put("swift/.build/checkouts/dependency/Sources/Keep.swift", "// authored")
    let filesystem=TargetScanFileSystem(fixture: .init(native: fixture.fs, trash: fixture.trash), reader: fixture.fs)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: workspace.id, ruleIds: ["shou.builtin.swift-build"], scope: .cleanup, budget: .init(maxEntries: 40))
    let partial=try require(scan.candidates.first { $0.relativePath == product })
    try expect(!partial.eligible && partial.reasons.contains("incomplete_scan"))
    let refined=try await engine.scanCleanupTarget(scanId: scan.id, candidateId: partial.id)
    let target=try require(refined.candidates.first { $0.relativePath == product })
    try expect(target.eligible && target.ruleVersions["shou.builtin.swift-build"] == "1.1.0")
    try expect(refined.entries.contains { $0.path == "swift/Package.swift" })
    try expect(refined.entries.contains { $0.path == "swift/.build/workspace-state.json" })
    try expect(!refined.entries.contains { $0.path.hasPrefix("swift/.build/checkouts") })
    let plan=try await engine.createPlan(scanId: refined.id, candidateIds: [target.id])
    try expect(plan.items[0].manifest.contains { $0.path.hasSuffix("resource_bundle_accessor.swift") })
}

func isolatedCleanupTargetRescanMatchesNativeNarrowEvidence() async throws {
    let context=try await incompleteTargetFixture()
    for index in 0..<300 {
        try context.fixture.put("noise-\(index).txt")
        try context.fixture.put("project/noise-\(index).txt")
    }
    let reader=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let filesystem=TargetScanFileSystem(fixture: .init(native: context.fixture.fs, trash: context.fixture.trash), reader: reader)
    let worker=ShouEngine(store: context.fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: context.fixture.workspace)
    let native=try await context.engine.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, budget: .init(maxEntries: 128))
    let isolated=try await worker.scanCleanupTarget(scanId: context.scan.id, candidateId: context.target.id, budget: .init(maxEntries: 128))
    try expect(native.entries == isolated.entries && native.completedPaths == isolated.completedPaths)
    try expect(isolated.status == "complete" && isolated.entries.count < 128)
    let target=try require(isolated.candidates.first { $0.relativePath == context.target.relativePath })
    try expect(target.eligible && target.ruleVersions == context.target.ruleVersions)
    try expect(!isolated.entries.contains { $0.path.contains("noise-") })
    let plan=try await worker.createPlan(scanId: isolated.id, candidateIds: [target.id])
    try expect(plan.items.count == 1 && plan.workspace.id == context.workspace.id)
}
