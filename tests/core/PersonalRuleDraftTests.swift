import Foundation
import ShouCore

private func personalDraft(patterns: [String] = ["**/.personal-cache"]) -> PersonalRuleDraft {
    PersonalRuleDraft(name: "  Personal cache  ", relativePatterns: patterns, projectMarkers: ["Cargo.toml"],
                      exclusions: ["project/.personal-cache/keep/**"], minimumAgeDays: 0,
                      rebuildNote: " Regenerate using the local build. ", limitations: [" Keep work in progress. "])
}

func personalDraftUsesClosedContractAndPortableFields() throws {
    let rule=try personalDraft(patterns: ["**/.personal-cache", "**/.other-cache"]).rule(id: "personal.fixture", rootRef: "test-workspace", platform: "macos")
    try expect(rule.name == "Personal cache" && rule.risk.rebuildNote == "Regenerate using the local build.")
    try expect(rule.match.relativePatterns == ["**/.personal-cache", "**/.other-cache"])
    try expect(rule.exclude.relativePatterns == ["project/.personal-cache/keep/**"])
    try expect(!rule.scope.followSymlinks && !rule.scope.crossFilesystems && rule.action.type == "trash")
    try expect(try CleanupRule.parse(Codec.encode(rule)) == rule)
    var draft=personalDraft(); draft.minimumAgeDays=nil
    let noAge=try draft.rule(id: "personal.fixture", rootRef: "test-workspace", platform: "macos")
    try expect(noAge.conditions.newestDescendantModifiedDaysAtLeast == nil)
    draft.highRisk=true
    try expect(try draft.rule(id: "personal.fixture", rootRef: "test-workspace", platform: "macos").risk.declaredLevel == "high")
    let invalidEdits: [(inout PersonalRuleDraft) -> Void] = [
        { $0.relativePatterns=["../outside"] }, { $0.relativePatterns=["**"] },
        { $0.relativePatterns=["cache", "cache"] }, { $0.projectMarkers=["../Cargo.toml"] },
        { $0.exclusions=["/absolute"] }, { $0.minimumAllocatedBytes = -1 },
        { $0.minimumAgeDays=3651 }, { $0.maxDepth=33 }, { $0.name="   " }, { $0.limitations=[] }
    ]
    for mutate in invalidEdits {
        var invalid=personalDraft(); mutate(&invalid)
        try expectThrows { try invalid.rule(id: "personal.fixture", rootRef: "test-workspace", platform: "macos") }
    }
}

func exactPersonalRuleSelectionCannotExpandItsScope() throws {
    try expect(try PersonalRuleDraft.exactRelativePath(selection: "/work/projects/项目/cache", workspacePath: "/work/projects") == "项目/cache")
    try expect(try PersonalRuleDraft.exactRelativePath(selection: "/work/projects/cache", workspacePath: "/work/projects/") == "cache")
    for path in ["/work/projects", "/work/projects-other/cache", "/other/cache", "/work/projects/../outside", "/work/projects/a/../../outside",
                 "/work/projects/cache/*", "/work/projects/cache?", "/work/projects/cache\n", "/work/projects//cache"] {
        try expectThrows { try PersonalRuleDraft.exactRelativePath(selection: path, workspacePath: "/work/projects") }
    }
}

func personalRuleRevisionsPreserveBindingsAndRejectStaleSaves() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let original=try personalDraft().rule(id: "personal.versioned", rootRef: workspace.rootRef, platform: "macos")
    _ = try await engine.importRule(Codec.encode(original))
    let binding=try await engine.setRule(ruleId: original.id, workspaceId: workspace.id, enabled: true, version: original.version)
    let reviewed=try await engine.configuration()
    let revision=try PersonalRuleRevision.suggestedRule(original, existingVersions: ["0.1.0", "0.1.1", "0.1.2"])
    try expect(revision.version == "0.1.3" && revision.id == original.id && revision.match == original.match)
    let stale="foreign-configuration"
    do {
        _ = try await engine.importRule(Codec.encode(revision), requireNewVersion: true, expectedConfigurationRevision: stale)
        throw CheckFailure(description: "A stale rule save must be refused.")
    } catch let error as ShouError { try expect(error.code == "plan_stale") }
    try expect(try Codec.encode(await engine.configuration()) == Codec.encode(reviewed))
    _ = try await engine.importRule(Codec.encode(revision), requireNewVersion: true, expectedConfigurationRevision: reviewed.revision)
    let saved=try await engine.configuration()
    try expect(try Codec.encode(saved.bindings) == Codec.encode([binding]) && saved.rules.count == 2 && saved.rules.contains { $0.rule == revision })
    try await expectThrows { try await engine.importRule(Codec.encode(revision), requireNewVersion: true) }
    try expect(try Codec.encode(await engine.configuration()) == Codec.encode(saved))
    var exhausted=original;exhausted.version="0.1."+String(Int.max)
    try expectThrows { try PersonalRuleRevision.suggestedRule(exhausted, existingVersions: []) }
}

func personalDraftPreviewExplainsConditionsAndPreservesDisabledState() async throws {
    let fixture=try Fixture()
    try fixture.put("project/.personal-cache/generated.bin", String(repeating: "x", count: 8192))
    try fixture.put("project/.personal-cache/keep/sentinel.txt", "preserve")
    try fixture.put("missing-marker/.personal-cache/generated.bin", "generated")
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash))
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let before=try await engine.configuration()
    var input=personalDraft(); input.minimumAllocatedBytes=1_000_000; input.minimumAgeDays=14
    let failedRule=try input.rule(id: "personal.fixture", rootRef: root.rootRef, platform: "macos")
    let conditions=try await engine.scan(workspaceId: root.id, previewRule: failedRule, scope: .cleanup)
    let failedRows=try PersonalRulePreview.rows(snapshot: conditions, rule: failedRule)
    let missing=try require(failedRows.first { $0.path == "missing-marker/.personal-cache" })
    try expect(missing.status == "not_matched")
    try expect(Set(missing.reasons) == ["rule_minimum_size", "rule_missing_markers", "rule_recent_modification"])
    input.minimumAllocatedBytes=0; input.minimumAgeDays=nil
    let protectedRule=try input.rule(id: "personal.fixture", rootRef: root.rootRef, platform: "macos")
    let protected=try await engine.scan(workspaceId: root.id, previewRule: protectedRule, scope: .cleanup)
    let protectedRow=try require(PersonalRulePreview.rows(snapshot: protected, rule: protectedRule).first { $0.path == "project/.personal-cache" })
    try expect(protectedRow.status == "blocked" && protectedRow.reasons.contains("excluded_descendant"))
    input.exclusions=[]
    let rule=try input.rule(id: "personal.fixture", rootRef: root.rootRef, platform: "macos")
    let preview=try await engine.scan(workspaceId: root.id, previewRule: rule, scope: .cleanup)
    let matched=try require(PersonalRulePreview.rows(snapshot: preview, rule: rule).first { $0.path == "project/.personal-cache" })
    try expect(matched.status == "matched" && matched.reasons.isEmpty)
    let candidate=try require(preview.candidates.first { $0.relativePath == matched.path })
    try await expectThrows { try await engine.createPlan(scanId: preview.id, candidateIds: [candidate.id]) }
    try expect(try Codec.encode(await engine.configuration()) == Codec.encode(before))
    _ = try await engine.importRule(Codec.encode(rule))
    let saved=try await engine.configuration()
    try expect(saved.rules.count == 1 && saved.bindings.isEmpty)
    try expect(saved.rules[0].rule == rule)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/.personal-cache/keep/sentinel.txt").path))
    try expect(try await engine.history().isEmpty)
}

func personalDraftAgeExplanationUsesCandidateDecisionBoundary() async throws {
    let fixture=try Fixture()
    try fixture.put("project/.personal-cache/generated.bin", "generated")
    let tree=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
    let measured=try require(StorageIndex(entries: tree.entries).nodes["project/.personal-cache"])
    let threshold=Date(timeIntervalSince1970: Double(measured.newestModifiedNanoseconds) / 1_000_000_000 + 86_400)
    let filesystem=FixtureFileSystem(native: fixture.fs, trash: fixture.trash)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, now: { threshold })
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    var input=personalDraft(); input.minimumAgeDays=1; input.exclusions=[]
    let rule=try input.rule(id: "personal.fixture", rootRef: root.rootRef, platform: "macos")
    let boundary=try await engine.scan(workspaceId: root.id, previewRule: rule, scope: .cleanup)
    let row=try require(PersonalRulePreview.rows(snapshot: boundary, rule: rule).first { $0.path == "project/.personal-cache" })
    try expect(row.status == "matched")
    let early=ShouEngine(store: fixture.store, filesystem: filesystem, now: { threshold.addingTimeInterval(-0.001) })
    let recent=try await early.scan(workspaceId: root.id, previewRule: rule, scope: .cleanup)
    let rejected=try require(PersonalRulePreview.rows(snapshot: recent, rule: rule).first { $0.path == "project/.personal-cache" })
    try expect(rejected.status == "not_matched" && rejected.reasons == ["rule_recent_modification"])
}

func independentPersonalRulesCompleteCleanupWithoutEnablingOtherDrafts() async throws {
    let fixture=try Fixture()
    let home=fixture.base.appendingPathComponent("empty-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try fixture.put("project/disposable-cache/output.bin", String(repeating: "x", count: 8192))
    try fixture.put("project/offline-dependencies/keep.bin", "must remain available offline")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: home)
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "independent-fixture")
    let cleanup=try PersonalRuleDraft(name: "Rebuildable output", relativePatterns: ["project/disposable-cache"], rebuildNote: "Generated fixture can be rebuilt.", limitations: ["Generated test data only."])
        .rule(id: "personal.fixture-build", rootRef: root.rootRef, platform: "macos")
    let keep=try PersonalRuleDraft(name: "Offline dependencies", relativePatterns: ["project/offline-dependencies"], rebuildNote: "Would require a download.", limitations: ["Keep while offline."])
        .rule(id: "personal.fixture-offline", rootRef: root.rootRef, platform: "macos")
    _ = try await engine.importRule(Codec.encode(cleanup))
    _ = try await engine.importRule(Codec.encode(keep))
    for rule in [cleanup, keep] {
        let preview=try await engine.scan(workspaceId: root.id, previewRule: rule, scope: .cleanup)
        let rows=try PersonalRulePreview.rows(snapshot: preview, rule: rule)
        try expect(rows.filter { $0.status == "matched" }.map(\.path) == rule.match.relativePatterns)
        let benefits=try await engine.rulePreviewBenefits(scanId: preview.id)
        try expect(benefits.eligibleMatchCount == 1 && benefits.additionalAllocatedBytesEstimate > 0)
        try await expectThrows { try await engine.createPlan(scanId: preview.id, candidateIds: preview.candidates.filter(\.eligible).map(\.id), action: "permanent") }
    }
    try expect(try await engine.configuration().bindings.isEmpty)
    _ = try await engine.setRule(ruleId: cleanup.id, workspaceId: root.id, enabled: true, version: cleanup.version)
    let reopened=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: home)
    let daily=try await reopened.scanKnownLocations(includeProjects: true)
    let dailyScan=try require(daily.snapshots.first { $0.workspace.id == root.id })
    try expect(dailyScan.candidates.contains { $0.relativePath == "project/disposable-cache" && $0.eligible && $0.ruleIds == [cleanup.id] })
    try expect(!dailyScan.candidates.contains { $0.eligible && $0.ruleIds.contains(keep.id) })
    let fresh=try await reopened.scan(workspaceId: root.id, ruleIds: [cleanup.id], scope: .cleanup)
    let selected=fresh.candidates.filter(\.eligible)
    try expect(selected.map(\.relativePath) == ["project/disposable-cache"])
    let plan=try await reopened.createPlan(scanId: fresh.id, candidateIds: selected.map(\.id), action: "permanent")
    let receipt=try await reopened.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "independent-rule-fixture")
    try expect(receipt.state == "completed" && receipt.items.count == 1 && receipt.items[0].state == "purged")
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/disposable-cache").path))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/offline-dependencies/keep.bin"), encoding: .utf8) == "must remain available offline")
    let config=try await reopened.configuration()
    try expect(config.bindings.count == 1 && config.bindings[0].ruleId == cleanup.id && config.bindings[0].enabled)
    try expect(config.rules.contains { $0.rule.id == keep.id })
    try expect(try await reopened.history(receipt.id).items[0].originalPath == receipt.items[0].originalPath)
    let after=try await reopened.scan(workspaceId: root.id, scope: .cleanup)
    try expect(!after.candidates.contains { $0.eligible && $0.ruleIds.contains(cleanup.id) })
}
