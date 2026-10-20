import Foundation
import ShouCore
import ShouPlatform

func projectDiscoveryFindsCollectionsWithoutRegistrationAndReusesPolicy() async throws {
    let fixture=try Fixture()
    try fixture.put("Documents/dev/rust/Cargo.toml", "[package]\nname = 'generated'\n")
    try fixture.put("Documents/dev/rust/target/artifact.bin")
    try fixture.put("Projects/web/package.json", "{}")
    try fixture.put("Projects/web/node_modules/package/index.js")
    try fixture.put("outside/sentinel.txt", "preserve outside linked directory")
    try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent("Code"), withDestinationURL: fixture.workspace.appendingPathComponent("outside"))
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    try expect(try await engine.scanKnownLocations().snapshots.isEmpty)
    try expect(try await engine.configuration().workspaces.isEmpty)
    let suggested=try await engine.projectLocations()
    try expect(Set(suggested.filter(\.exists).map(\.path)) == Set([fixture.workspace.path + "/Documents/dev", fixture.workspace.path + "/Projects"]))
    try expect(suggested.contains { $0.path.hasSuffix("/Code") && !$0.exists && $0.availabilityIssue != nil })
    try expect(try await engine.configuration().workspaces.isEmpty)
    let scan=try await engine.scanKnownLocations(includeProjects: true)
    try expect(scan.snapshots.count == 2 && scan.status == "partial")
    try expect(scan.snapshots.flatMap(\.candidates).contains { $0.relativePath == "rust/target" && $0.eligible })
    try expect(scan.snapshots.flatMap(\.candidates).contains { $0.relativePath == "web/node_modules" && $0.eligible })
    let config=try await engine.configuration()
    let digest=try Digest.of(config)
    try expect(config.workspaces.count == 2 && scan.snapshots.allSatisfy { $0.configurationDigest == digest })
    let root=try require(config.workspaces.first { $0.path.hasSuffix("/Documents/dev") })
    _ = try await engine.setExclusion(workspaceId: root.id, pattern: "rust/target/**", remove: false)
    let policyDigest=try Digest.of(await engine.configuration())
    let repeated=try await engine.scanKnownLocations(includeProjects: true)
    try expect(try Digest.of(await engine.configuration()) == policyDigest)
    try expect(Set(repeated.snapshots.map { $0.workspace.id }) == Set(scan.snapshots.map { $0.workspace.id }))
    try expect(repeated.snapshots.flatMap(\.candidates).allSatisfy { $0.relativePath != "rust/target" || !$0.eligible })
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("outside/sentinel.txt"), encoding: .utf8) == "preserve outside linked directory")
    try expect(try await engine.history().isEmpty)
}

func projectDiscoveryRespectsExplicitNestedScopeAndDisabledRules() async throws {
    let fixture=try Fixture()
    try fixture.put("Documents/dev/one/Cargo.toml", "[package]\nname = 'generated'\n")
    try fixture.put("Documents/dev/one/target/artifact.bin")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let root=try await engine.addWorkspace(path: fixture.workspace.path + "/Documents/dev/one", rootRef: "specific-project")
    let rules=try await engine.builtinRules(workspaceId: root.id)
    let rust=try require(rules.first { $0.id.contains("rust") && $0.match.relativePatterns.contains("**/target") })
    _ = try await engine.setRule(ruleId: rust.id, workspaceId: root.id, enabled: false)
    let before=try Digest.of(await engine.configuration())
    let locations=try await engine.projectLocations()
    try expect(locations.map(\.path) == [root.path])
    let scan=try await engine.scanKnownLocations(includeProjects: true)
    try expect(scan.snapshots.count == 1 && scan.snapshots[0].workspace.id == root.id)
    try expect(scan.snapshots.flatMap(\.candidates).allSatisfy { !$0.ruleIds.contains(rust.id) })
    try expect(try Digest.of(await engine.configuration()) == before)
}

func projectDiscoveryCancellationStopsBeforeRegistration() async throws {
    let fixture=try Fixture()
    try fixture.put("dev/project/package.json", "{}")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace)
    let operation=Task {
        do {
            _ = try await engine.scanKnownLocations(includeProjects: true, progress: { _, update in
                if update.stage == "preparing" { withUnsafeCurrentTask { $0?.cancel() } }
            })
            return false
        } catch let error as ShouError { return error.code == "cancelled" }
    }
    try expect(try await operation.value)
    try expect(try await engine.configuration().workspaces.isEmpty)
}

func enabledPersonalRulesJoinRepeatedCleanupWithoutReselecting() async throws {
    let fixture=try Fixture()
    try fixture.put("project/scratch/generated.bin", "generated personal cache")
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let record=try await engine.importRule(fixtureRule(pattern: "**/scratch"))
    let disabled=try await engine.scanKnownLocations(includeProjects: true)
    try expect(try CleanupReview(snapshots: disabled.snapshots).recommendedSources.allSatisfy { !$0.candidate.ruleIds.contains(record.rule.id) })
    _ = try await engine.setRule(ruleId: record.rule.id, workspaceId: root.id, enabled: true)
    let enabled=try await engine.scanKnownLocations(includeProjects: true)
    let review=try CleanupReview(snapshots: enabled.snapshots)
    let personal=try require(review.recommendedSources.first { $0.candidate.ruleIds.contains(record.rule.id) })
    try expect(!personal.isBuiltIn && personal.path == fixture.workspace.path + "/project/scratch")
    let plan=try await engine.createPlan(scanId: personal.snapshotId, candidateIds: [personal.candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "completed")
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    _ = try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    let again=try await engine.scanKnownLocations(includeProjects: true)
    try expect(try CleanupReview(snapshots: again.snapshots).recommendedSources.contains { $0.candidate.ruleIds.contains(record.rule.id) })
    _ = try await engine.setRule(ruleId: record.rule.id, workspaceId: root.id, enabled: false)
    let off=try await engine.scanKnownLocations(includeProjects: true)
    try expect(try CleanupReview(snapshots: off.snapshots).recommendedSources.allSatisfy { !$0.candidate.ruleIds.contains(record.rule.id) })
    let draft=try await engine.scan(workspaceId: root.id, previewRule: record.rule)
    try expect(try CleanupReview(snapshots: [draft]).recommendedSources.isEmpty)
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/scratch/generated.bin"), encoding: .utf8) == "generated personal cache")
}
