import Foundation
import ShouCore

func agentRuleLoopMeasuresAdditionalCoverageAndPersistsReuse() async throws {
    let fixture=try Fixture()
    try fixture.put("project/.personal-cache/generated.bin", String(repeating: "x", count: 8192))
    let filesystem=FixtureFileSystem(native: fixture.fs, trash: fixture.trash)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem)
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    let opportunities=try await engine.ruleOpportunities(scanId: scan.id, minimumBytes: 0)
    try expect(opportunities.items.contains { $0.relativePath == "project/.personal-cache" && !$0.eligible && $0.complete })
    let first=try await engine.ruleOpportunities(scanId: scan.id, minimumBytes: 0, limit: 1)
    try expect(first.items.count == 1 && first.nextOffset == 1)
    let input=PersonalRuleDraft(name: "Generated cache", relativePatterns: ["**/.personal-cache"], rebuildNote: "Run the fixture build.", limitations: ["Generated fixture only."])
    let rule=try input.rule(id: "personal.agent-fixture", rootRef: root.rootRef, platform: "macos")
    _ = try await engine.importRule(Codec.encode(rule))
    let preview=try await engine.scan(workspaceId: root.id, previewRule: rule)
    let benefits=try await engine.rulePreviewBenefits(scanId: preview.id)
    try expect(benefits.eligibleMatchCount == 1 && benefits.additionalAllocatedBytesEstimate > 0 && benefits.alreadyCoveredAllocatedBytesEstimate == 0)
    try expect(try await engine.configuration().bindings.isEmpty)
    let candidate=try require(preview.candidates.first { $0.eligible })
    try await expectThrows { try await engine.createPlan(scanId: preview.id, candidateIds: [candidate.id]) }
    _ = try await engine.setRule(ruleId: rule.id, workspaceId: root.id, enabled: true)
    let reopened=ShouEngine(store: fixture.store, filesystem: filesystem)
    let active=try await reopened.scan(workspaceId: root.id)
    try expect(active.candidates.contains { $0.eligible && $0.ruleIds.contains(rule.id) })
    let second=try await reopened.scan(workspaceId: root.id, previewRule: rule)
    let duplicate=try await reopened.rulePreviewBenefits(scanId: second.id)
    try expect(duplicate.additionalAllocatedBytesEstimate == 0 && duplicate.alreadyCoveredAllocatedBytesEstimate == duplicate.matchedAllocatedBytesEstimate)
    let cleanup=try await reopened.scan(workspaceId: root.id, scope: .cleanup)
    try await expectThrows { try await reopened.ruleOpportunities(scanId: cleanup.id) }
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/.personal-cache/generated.bin").path))
}
