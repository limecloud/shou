import Foundation
import ShouCore
import ShouPlatform

func scanBudgetsSurvivePlanningAndRejectTamperedEvidence() async throws {
    let fixture=try Fixture()
    let (engine, workspace, _, _)=try await fixture.ready()
    let budget=ScanBudget(maxEntries: 250_000, maxSeconds: 600)
    let snapshot=try await engine.scan(workspaceId: workspace.id, budget: budget)
    let candidate=try require(snapshot.candidates.first { $0.relativePath == "project/target" && $0.eligible })
    let plan=try await engine.createPlan(scanId: snapshot.id, candidateIds: [candidate.id])
    try expect(plan.scanBudget?.maxSeconds == 600 && plan.scanBudget?.maxEntries == 250_000)

    for invalid in [ScanBudget(maxEntries: 0), ScanBudget(maxSeconds: 0), ScanBudget(maxSeconds: 601), ScanBudget(maxDepth: 129)] {
        var alteredScan=snapshot
        alteredScan.budget=invalid
        try fixture.store.write("scans", id: snapshot.id, data: Codec.encode(alteredScan))
        try await expectThrows { try await engine.createPlan(scanId: snapshot.id, candidateIds: [candidate.id]) }
        try fixture.store.write("scans", id: snapshot.id, data: Codec.encode(snapshot))

        var alteredPlan=plan
        alteredPlan.scanBudget=invalid
        alteredPlan.digest=try alteredPlan.calculatedDigest()
        try fixture.store.write("plans", id: plan.id, data: Codec.encode(alteredPlan))
        try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: alteredPlan.digest, entryPoint: "test") }
    }
    let tree=try fixture.fs.inspect(workspace.path, budget: ScanBudget(), cancelled: { false })
    for invalid in [TimeInterval.infinity, TimeInterval.nan] {
        try expectThrows {
            try Analysis.candidates(tree: tree, workspace: workspace, rules: [], now: Date(), maxSeconds: invalid)
        }
    }
    try expect(try await engine.history().isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}
