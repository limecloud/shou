import Foundation
import ShouCore

func commonReviewGroupsEvidenceWithoutGrantingAuthority() async throws {
    let fixture=try Fixture()
    try fixture.put("web/package.json", "{}")
    try fixture.put("web/node_modules/package/index.js")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    let view=try CleanupReview(snapshots: [scan, scan])
    try expect(view.categories.map(\.id) == ["build"])
    try expect(view.sources.count == 2)
    try expect(view.sources.allSatisfy(\.selectable))
    try expect(view.sources.contains { $0.candidate.risk == "high" })
    try expect(view.recommendedSources.allSatisfy { $0.candidate.risk != "high" })
    try expect(view.bytes == CleanupOverview.candidates(scan.candidates).reduce(0) { $0 + $1.allocatedBytesEstimate })
    var partial=scan
    partial.status="partial"
    partial.treeComplete=false
    partial.completedPaths=nil
    let partialReview=try CleanupReview(snapshots: [partial])
    try expect(partialReview.sources.count == 2 && partialReview.sources.allSatisfy { $0.selectable && $0.requiresManualReview })
    try expect(partialReview.recommendedSources.isEmpty)
    partial.completedPaths=["project/target"]
    let coveredReview=try CleanupReview(snapshots: [partial])
    try expect(coveredReview.sources.filter { !$0.requiresManualReview }.map(\.candidate.relativePath) == ["project/target"])
    var draft=scan
    draft.previewOnly=true
    try expect(try CleanupReview(snapshots: [draft]).sources.allSatisfy { !$0.selectable })
    try expect(try await engine.history().isEmpty)
}

func commonReviewSeparatesUserCachesAndCrossProjectArtifacts() async throws {
    let fixture=try Fixture()
    try fixture.put("Library/Caches/go-build/cache.bin")
    for path in ["Homebrew", "node-gyp", "org.swift.swiftpm", "pnpm", "ms-playwright"] {
        try fixture.put("Library/Caches/" + path + "/cache.bin")
    }
    try fixture.put("Library/pnpm/store/v10/files/ab/cached-package")
    try fixture.put("Library/pnpm/global/node_modules/tool/package.json", "{}")
    try fixture.put("Library/pnpm/config.json", "{\"preserve\":true}")
    try fixture.put("Library/Application Support/Codex/Cache/cache.bin")
    try fixture.put("Library/Application Support/Google/Chrome/Default/Cache/cache.bin")
    try fixture.put(".npm/_cacache/cache.bin")
    try fixture.put("dev/first/Cargo.toml", "[package]\nname = 'first'\n")
    try fixture.put("dev/first/target/artifact.bin")
    try fixture.put("dev/second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("dev/second/target/artifact.bin")
    try fixture.put("dev/python/pyproject.toml", "[project]\nname = 'fixture'\n")
    try fixture.put("dev/python/__pycache__/module.cpython-313.pyc")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace)
    let scan=try await engine.scanKnownLocations(includeProjects: true)
    let review=try CleanupReview(snapshots: scan.snapshots + scan.snapshots, locations: scan.locations)
    try expect(review.categories.map(\.id) == ["userCache", "application", "browser", "developer", "build"])
    let projects=try require(review.categories.first { $0.id == "build" })
    let rust=try require(projects.groups.first { $0.id == "shou.builtin.rust-target" })
    try expect(rust.sources.count == 2)
    try expect(Set(rust.sources.map(\.candidate.relativePath)) == ["first/target", "second/target"])
    try expect(projects.sources.contains { $0.candidate.relativePath == "python/__pycache__" })
    let projectObjects=review.projects(snapshots: scan.snapshots, locations: scan.locations)
    try expect(Set(projectObjects.map(\.path)) == Set(["first", "second", "python"].map { fixture.workspace.path + "/dev/" + $0 }))
    try expect(projectObjects.allSatisfy(\.identifiedProject))
    try expect(Set(projectObjects.flatMap(\.sources).map(\.id)) == Set(projects.sources.map(\.id)))
    try expect(projectObjects.reduce(Int64(0)) { $0 + $1.bytes } == projects.bytes)
    let userCaches=try require(review.categories.first { $0.id == "userCache" })
    try expect(["Homebrew download caches", "Node.js toolchain caches", "Swift Package Manager caches"].allSatisfy { title in userCaches.groups.contains { $0.title == title } })
    try expect(userCaches.sources.contains { $0.candidate.ruleIds.contains("shou.builtin.pnpm-user-caches") })
    try expect(userCaches.sources.contains { $0.candidate.ruleIds.contains("shou.builtin.browser-automation-caches") })
    try expect(review.sources.filter { $0.workspace.path.hasSuffix("/Library/pnpm") }.map(\.candidate.relativePath) == ["store"])
    try expect(review.recommendedSources.allSatisfy { $0.candidate.risk != "high" })
    try expect(review.sources.count == Set(review.sources.map(\.path)).count)
    try expect(review.bytes == review.sources.reduce(Int64(0)) { $0 + $1.candidate.allocatedBytesEstimate })
    try expect(try await engine.history().isEmpty)
}

func commonReviewRefinesOnlyOneTargetAndRetainsOriginalEvidence() async throws {
    let fixture=try Fixture()
    try fixture.put("second/Cargo.toml", "[package]\nname = 'second'\n")
    try fixture.put("second/target/artifact.bin")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    var base=try await engine.scan(workspaceId: root.id, scope: .cleanup)
    let path="project/target"
    let index=try require(base.candidates.firstIndex { $0.relativePath == path })
    base.id="aaa-base"; base.status="partial"; base.treeComplete=false
    base.completedPaths=base.candidates.filter { $0.relativePath != path }.map(\.relativePath)
    base.candidates[index].eligible=false
    base.candidates[index].reasons.append("incomplete_scan")
    base.candidates[index].allocatedBytesEstimate=1
    let before=try CleanupReview(snapshots: [base])
    let original=try require(before.sources.first { $0.candidate.relativePath == path })
    let sibling=try require(before.sources.first { $0.candidate.relativePath == "second/target" })
    var updated=base
    updated.id="zzz-refinement"; updated.status="complete"; updated.treeComplete=true
    updated.candidates[index].id="refined-candidate"
    updated.candidates[index].eligible=true
    updated.candidates[index].reasons.removeAll { $0 == "incomplete_scan" }
    updated.candidates[index].allocatedBytesEstimate=12345
    // Unrelated evidence in a refinement must never replace a sibling's original evidence.
    for i in updated.candidates.indices where i != index { updated.candidates[i].allocatedBytesEstimate=999999 }
    let refinement=CleanupTargetRefinement(originalSnapshotId: base.id, candidateId: original.candidate.id, snapshotId: updated.id)
    let after=try CleanupReview(snapshots: [updated, base], refinements: [refinement])
    let target=try require(after.sources.first { $0.candidate.relativePath == path })
    try expect(target.snapshotId == updated.id && target.selectable)
    try expect(after.sources.first { $0.candidate.relativePath == "second/target" }?.id == sibling.id)
    try expect(after.sources.count == before.sources.count)
    try expect(after.bytes == before.bytes - 1 + 12345)
    let selected=Set([original.id, sibling.id]).intersection(Set(after.sources.filter(\.selectable).map(\.id)))
    try expect(selected == [sibling.id] && !selected.contains(target.id))
    try expect(SystemScanResult(locations: [], snapshots: [base, updated], issues: [], skippedLocationIds: []).status == "partial")
    try expect(base.treeComplete == false && base.candidates[index].reasons.contains("incomplete_scan"))
    try expect(try await engine.history().isEmpty)
}

func commonReviewRefinementRejectsStaleEvidenceAndSupportsRepeatedPartialScans() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    var base=try await engine.scan(workspaceId: root.id, scope: .cleanup)
    let index=try require(base.candidates.firstIndex { $0.relativePath == "project/target" })
    base.candidates[index].reasons.append("incomplete_scan"); base.candidates[index].eligible=false
    var first=base; first.id="first-refinement"
    var final=first; final.id="final-refinement"
    final.candidates[index].eligible=true; final.candidates[index].reasons.removeAll { $0 == "incomplete_scan" }
    let a=CleanupTargetRefinement(originalSnapshotId: base.id, candidateId: base.candidates[index].id, snapshotId: first.id)
    let b=CleanupTargetRefinement(originalSnapshotId: first.id, candidateId: first.candidates[index].id, snapshotId: final.id)
    let view=try CleanupReview(snapshots: [base, final, first], refinements: [a, b])
    try expect(view.sources.first { $0.candidate.relativePath == "project/target" }?.snapshotId == final.id)
    var stale=first; stale.configurationDigest="changed"
    try expectThrows { try CleanupReview(snapshots: [base, stale], refinements: [a]) }
    stale=first; stale.previewOnly=true
    try expectThrows { try CleanupReview(snapshots: [base, stale], refinements: [a]) }
    stale=first; stale.workspace.identity.inode += 1
    try expectThrows { try CleanupReview(snapshots: [base, stale], refinements: [a]) }
    stale=first; stale.scope = .full
    try expectThrows { try CleanupReview(snapshots: [base, stale], refinements: [a]) }
    try expectThrows { try CleanupReview(snapshots: [base], refinements: [a]) }
}
