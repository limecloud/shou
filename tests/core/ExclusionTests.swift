import Foundation
import ShouCore

func globalExclusionsProtectAllRootsAndRejectForgedPlans() async throws {
    let fixture=try Fixture(), other=try Fixture(), future=try Fixture()
    let (engine, root, _, originalCandidate)=try await fixture.ready()
    let otherRoot=try await engine.addWorkspace(path: other.workspace.path, rootRef: "other-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    let candidate=try require(scan.candidates.first { $0.relativePath == originalCandidate.relativePath && $0.eligible })
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let pattern="project/target/artifact.bin"
    _ = try await engine.setGlobalExclusion(pattern: pattern, remove: false)
    let config=try await engine.configuration()
    try expect(config.version == 2)
    let settings=try await engine.exclusionSettings(workspaceId: root.id)
    try expect(settings.globalPatterns == [pattern] && settings.workspacePatterns.isEmpty && settings.effectivePatterns == [pattern])
    let futureRoot=try await engine.addWorkspace(path: future.workspace.path, rootRef: "future-workspace")
    for workspace in [root, otherRoot, futureRoot] {
        for scope in [ScanScope.full, .cleanup] {
            let blocked=try await engine.scan(workspaceId: workspace.id, scope: scope)
            let target=try require(blocked.candidates.first { $0.relativePath == candidate.relativePath })
            try expect(!target.eligible && target.reasons.contains("excluded_descendant"))
            try expect(blocked.workspace.exclusions.contains(pattern))
        }
    }
    let draft=try await engine.scan(workspaceId: root.id, previewRule: CleanupRule.parse(fixtureRule()))
    try expect(draft.previewOnly && draft.candidates.first { $0.relativePath == candidate.relativePath }?.eligible == false)
    try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id]) }
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    // Even a rewritten stored digest and workspace policy cannot authorize the
    // parent target when current global exclusions protect a descendant.
    var forged=plan
    forged.configurationDigest=try Digest.of(await engine.configuration())
    forged.workspace.exclusions=settings.effectivePatterns
    forged.digest=try forged.calculatedDigest()
    try fixture.store.write("plans", id: forged.id, data: Codec.encode(forged))
    try await expectThrows { try await engine.execute(planId: forged.id, confirmedDigest: forged.digest, entryPoint: "test") }
    try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    _ = try await engine.setGlobalExclusion(pattern: pattern, remove: true)
    _ = try await engine.setGlobalExclusion(pattern: "**/keep/**", remove: false)
    let fresh=try await engine.scan(workspaceId: root.id)
    let freshCandidate=try require(fresh.candidates.first { $0.relativePath == candidate.relativePath && $0.eligible })
    let current=try await engine.createPlan(scanId: fresh.id, candidateIds: [freshCandidate.id])
    let receipt=try await engine.execute(planId: current.id, confirmedDigest: current.digest, entryPoint: "test")
    try expect(receipt.state == "completed")
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" })
    for value in [fixture, other, future] {
        try expect(try String(contentsOf: value.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == String(repeating: "x", count: 8192))
    }
}

func projectExclusionsStayLiteralAndScopedToTheirWorkspace() async throws {
    let fixture=try Fixture()
    let (engine, root, _, candidate)=try await fixture.ready()
    try fixture.put("sibling/Cargo.toml", "[package]\nname = 'sibling'\n")
    try fixture.put("sibling/target/artifact.bin", "preserve this sibling")
    let updated=try await engine.setExclusion(workspaceId: root.id, pattern: "**", remove: false, project: "project")
    try expect(updated.exclusions == ["project/**"])
    let scan=try await engine.scan(workspaceId: root.id)
    try expect(scan.candidates.first { $0.relativePath == candidate.relativePath }?.eligible == false)
    try expect(scan.candidates.first { $0.relativePath == "sibling/target" }?.eligible == true)
    try expect(try await engine.configuration().globalExclusions == nil)
    for project in ["../project", "/project", "**/project", "project?", ".", ""] {
        try await expectThrows { try await engine.setExclusion(workspaceId: root.id, pattern: "**", remove: false, project: project) }
    }
    _ = try await engine.setExclusion(workspaceId: root.id, pattern: "**", remove: true, project: "project")
    try expect(try await engine.exclusionSettings(workspaceId: root.id).effectivePatterns.isEmpty)
    let fresh=try await engine.scan(workspaceId: root.id)
    try expect(fresh.candidates.first { $0.relativePath == candidate.relativePath }?.eligible == true)
}

func globalExclusionStorageRetainsLegacyAndDowngradeBoundaries() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let legacy=Configuration()
    let bytes=try Codec.encode(legacy)
    try expect(try JSONDecoder().decode(JSONValue.self, from: bytes)["global_exclusions"] == nil)
    try fixture.store.write("configuration", id: "current", data: bytes)
    try expect(try await engine.configuration().version == 1)
    for pattern in ["../cache", "/cache", "~/cache", "${HOME}/cache"] {
        try await expectThrows { try await engine.setGlobalExclusion(pattern: pattern, remove: false) }
    }
    try expect(try Digest.of(await engine.configuration()) == Digest.of(legacy))
    _ = try await engine.setGlobalExclusion(pattern: "**/keep/**", remove: false)
    let protected=try await engine.configuration()
    try expect(protected.version == 2)
    _ = try await engine.setGlobalExclusion(pattern: "**/keep/**", remove: false)
    try expect(try Digest.of(await engine.configuration()) == Digest.of(protected))
    _ = try await engine.setGlobalExclusion(pattern: "**/missing/**", remove: true)
    try expect(try Digest.of(await engine.configuration()) == Digest.of(protected))
    _ = try await engine.setGlobalExclusion(pattern: "**/keep/**", remove: true)
    let cleared=try await engine.configuration()
    try expect(cleared.version == 2 && cleared.globalExclusions == nil)
    var invalid=protected
    invalid.version=1
    try fixture.store.write("configuration", id: "current", data: Codec.encode(invalid))
    try await expectThrows { try await engine.configuration() }
    invalid.version=2; invalid.globalExclusions=["../cache"]
    try fixture.store.write("configuration", id: "current", data: Codec.encode(invalid))
    try await expectThrows { try await engine.configuration() }
}
