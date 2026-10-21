import Foundation
import ShouCore
import ShouPlatform

func historyRetentionPreservesRecoveryAndNeverRemovesTargetFiles() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    let trash=try require(receipt.items.first?.trashPath)
    try expect(try await engine.historyCleanupPreview().executionIds.isEmpty)
    try await expectThrows { try await engine.clearHistory(executionIds: [receipt.id]) }
    let preview=try await engine.historyCleanupPreview(includeRecoverable: true)
    try expect(preview.executionIds == [receipt.id] && preview.recordBytes > 0)
    _ = try await engine.clearHistory(executionIds: [receipt.id], includeRecoverable: true)
    try expect(try await engine.history().isEmpty)
    try expect(FileManager.default.fileExists(atPath: trash))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/Cargo.toml").path))
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
}

func historyRetentionPreservesActiveRecordsAndRejectsStoreEscapes() async throws {
    let fixture=try Fixture()
    let (engine, _, scan, candidate)=try await fixture.ready()
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    var receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    receipt.state="executing"
    try fixture.store.write("history", id: receipt.id, data: Codec.encode(receipt))
    try expect(try await engine.historyCleanupPreview(includeRecoverable: true).executionIds.isEmpty)
    try await expectThrows { try await engine.clearHistory(executionIds: [receipt.id], includeRecoverable: true) }
    try expectThrows { try fixture.store.removeHistoryRecord("configuration", id: "current") }
    try expectThrows { try fixture.store.removeHistoryRecord("history", id: "../configuration/current") }
    let link=fixture.store.directory.appendingPathComponent("history/linked.json")
    let target=fixture.workspace.appendingPathComponent("project/Cargo.toml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try expectThrows { try fixture.store.removeHistoryRecord("history", id: "linked") }
    try expect(FileManager.default.fileExists(atPath: target.path))
}

func storageCoverageSeparatesSystemLocationsFromUserAccess() throws {
    let root="/System/Volumes/Data"
    for path in [".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100", "private/var/agentx"] {
        let note=StorageCoverageNote(issue: "unreadable_directory: " + path, root: root)
        try expect(note.systemManaged && note.concerns("."))
        try expect(!note.concerns("Users/person/project"))
    }
    let user=StorageCoverageNote(issue: "authorization_required: Users/person/Library/Mail", root: root)
    try expect(!user.systemManaged && user.concerns("Users/person"))
    try expect(!user.concerns("Users/person/project"))
    let budget=StorageCoverageNote(issue: "resource_limit", root: root)
    try expect(!budget.systemManaged && budget.concerns("Users/person/project"))
    let systemBudget=StorageCoverageNote(issue: "resource_limit", root: "/System")
    try expect(!systemBudget.systemManaged)
}
