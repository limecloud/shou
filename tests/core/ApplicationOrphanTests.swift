import Foundation
import ShouCore

private final class OrphanPresenceFixture: ApplicationAbsenceChecking, @unchecked Sendable {
    var absent=true
    func absentIdentifiers(in identifiers: Set<String>) throws -> Set<String> { absent ? identifiers.intersection(["com.google.Chrome"]) : [] }
}

func applicationOrphansRequireAbsenceConsentAndReuseDeletionJournals() async throws {
    let fixture=try Fixture(), presence=OrphanPresenceFixture()
    try fixture.put("Library/Caches/com.google.Chrome/cache.bin", String(repeating: "x", count: 8192))
    try fixture.put("Library/Preferences/com.google.Chrome.plist", "fixture personal settings")
    try fixture.put("Library/Group Containers/com.google.Chrome/keep.bin", "shared")
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), homeDirectory: fixture.workspace)
    let review=try await engine.reviewApplicationOrphans(presence: presence)
    let cache=try require(review.components.first { $0.kind == .caches && $0.eligible })
    let preferences=try require(review.components.first { $0.kind == .preferences && $0.eligible })
    try expect(!review.components.contains { $0.kind == .groupContainer || $0.kind == .application })
    try await expectThrows { try await engine.createApplicationOrphanPlan(reviewId: review.id, componentIds: [preferences.id]) }
    let plan=try await engine.createApplicationOrphanPlan(reviewId: review.id, componentIds: [cache.id])
    presence.absent=false
    let blocked=try await engine.executeApplicationOrphans(planId: plan.id, confirmedDigest: plan.digest, presence: presence, entryPoint: "test")
    try expect(blocked.state == "partial" && blocked.items.first?.state == "failed")
    try expect(FileManager.default.fileExists(atPath: cache.path))
    presence.absent=true
    let retry=try await engine.createApplicationOrphanPlan(reviewId: review.id, componentIds: [cache.id])
    let receipt=try await engine.executeApplicationOrphans(planId: retry.id, confirmedDigest: retry.digest, presence: presence, entryPoint: "test")
    try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "purged" })
    try expect(!FileManager.default.fileExists(atPath: cache.path))
    try expect(try await engine.history(receipt.id).operation == "application_orphan_cleanup")
    try await expectThrows { try await engine.executeApplicationOrphans(planId: plan.id, confirmedDigest: plan.digest, presence: presence, entryPoint: "test") }
    let personalPlan=try await engine.createApplicationOrphanPlan(reviewId: review.id, componentIds: [preferences.id], includeUserData: true, action: "trash")
    let trashed=try await engine.executeApplicationOrphans(planId: personalPlan.id, confirmedDigest: personalPlan.digest, presence: presence, entryPoint: "test")
    let item=try require(trashed.items.first)
    try expect(item.state == "trashed")
    let digest=try await engine.followUpDigest(executionId: trashed.id, itemIds: [item.id], action: "restore")
    let restored=try await engine.followUp(executionId: trashed.id, itemIds: [item.id], action: "restore", confirmedDigest: digest)
    try expect(restored.first?.state == "completed" && FileManager.default.fileExists(atPath: preferences.path))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("Library/Group Containers/com.google.Chrome/keep.bin").path))
}

func applicationOrphansRespectUnknownOwnersExclusionsAndChangedContents() async throws {
    let fixture=try Fixture(), presence=OrphanPresenceFixture()
    try fixture.put("Library/Caches/com.google.Chrome/cache.bin", "generated")
    try fixture.put("Library/Caches/dev.unknown.Custom/keep.bin", "unknown")
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), homeDirectory: fixture.workspace)
    let review=try await engine.reviewApplicationOrphans(presence: presence)
    try expect(!review.components.contains { $0.path.contains("dev.unknown.Custom") })
    let component=try require(review.components.first { $0.kind == .caches && $0.eligible })
    let plan=try await engine.createApplicationOrphanPlan(reviewId: review.id, componentIds: [component.id])
    try fixture.put("Library/Caches/com.google.Chrome/new.bin", "changed after review")
    let failed=try await engine.executeApplicationOrphans(planId: plan.id, confirmedDigest: plan.digest, presence: presence, entryPoint: "test")
    try expect(failed.state == "partial" && failed.items.first?.state == "failed")
    _ = try await engine.setGlobalExclusion(pattern: "**/com.google.Chrome", remove: false)
    let excluded=try await engine.reviewApplicationOrphans(presence: presence)
    try expect(excluded.components.first { $0.kind == .caches }?.reasons.contains("excluded") == true)
    try expect(FileManager.default.fileExists(atPath: component.path))
}
