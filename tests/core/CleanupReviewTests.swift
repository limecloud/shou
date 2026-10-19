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
    try expect(view.bytes == CleanupOverview.candidates(scan.candidates).reduce(0) { $0 + $1.allocatedBytesEstimate })
    var partial=scan
    partial.status="partial"
    partial.treeComplete=false
    partial.completedPaths=nil
    let partialReview=try CleanupReview(snapshots: [partial])
    try expect(partialReview.sources.count == 2 && partialReview.sources.allSatisfy { !$0.selectable })
    partial.completedPaths=["project/target"]
    let coveredReview=try CleanupReview(snapshots: [partial])
    try expect(coveredReview.sources.filter(\.selectable).map(\.candidate.relativePath) == ["project/target"])
    var draft=scan
    draft.previewOnly=true
    try expect(try CleanupReview(snapshots: [draft]).sources.allSatisfy { !$0.selectable })
    try expect(try await engine.history().isEmpty)
}
