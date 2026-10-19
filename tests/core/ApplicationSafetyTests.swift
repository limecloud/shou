import Foundation
import ShouCore

private final class TestApplicationActivity: ApplicationActivityChecking, @unchecked Sendable {
    private let lock=NSLock()
    private var running=Set<String>()
    func setRunning(_ value: Set<String>) { lock.lock(); defer { lock.unlock() }; running=value }
    func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }; return running.intersection(identifiers)
    }
}

func applicationActivityFollowsDeclarativeCatalogMetadata() throws {
    let templates=try BuiltinCatalog.templates()
    let guarded=templates.filter { !($0.applicationBundleIdentifiers ?? []).isEmpty }
    let activity=TestApplicationActivity()
    try expect(guarded.count > 20)
    for template in guarded {
        for identifier in template.applicationBundleIdentifiers ?? [] {
            activity.setRunning([identifier])
            let blocked=ApplicationSafety.blockedRules([template.id, "personal.cache"], activity: activity)
            try expect(blocked[template.id] == "application_running" && blocked["personal.cache"] == nil)
        }
        activity.setRunning(["org.example.unrelated"])
        try expect(ApplicationSafety.blockedRules([template.id], activity: activity).isEmpty)
        try expect(ApplicationSafety.blockedRules([template.id], activity: UnavailableApplicationActivity())[template.id] == "application_activity_unavailable")
    }
    let unguarded=templates.filter { ($0.applicationBundleIdentifiers ?? []).isEmpty }.map(\.id)
    try expect(ApplicationSafety.blockedRules(unguarded + ["personal.cache"], activity: UnavailableApplicationActivity()).isEmpty)
}

func applicationActivityBlocksAndRechecksExecution() async throws {
    let fixture=try Fixture()
    try fixture.put("Library/Caches/com.google.Chrome/resource.bin")
    try fixture.put("Library/Caches/com.tencent.xinWeChat/resource.bin")
    let activity=TestApplicationActivity()
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), applicationActivity: activity, homeDirectory: fixture.workspace)
    let workspace=try await engine.workspaceForKnownLocation("caches")
    activity.setRunning(["com.google.Chrome"])
    let blocked=try await engine.scan(workspaceId: workspace.id)
    let chrome=try require(blocked.candidates.first { $0.relativePath == "com.google.Chrome" })
    try expect(!chrome.eligible && chrome.reasons.contains("application_running"))
    try expect(blocked.candidates.first { $0.relativePath == "com.tencent.xinWeChat" }?.eligible == true)
    activity.setRunning([])
    let ready=try await engine.scan(workspaceId: workspace.id)
    let ids=ready.candidates.filter(\.eligible).map(\.id)
    try expect(ids.count == 2)
    activity.setRunning(["com.google.Chrome"])
    try await expectThrows { try await engine.createPlan(scanId: ready.id, candidateIds: ids) }
    activity.setRunning([])
    let plan=try await engine.createPlan(scanId: ready.id, candidateIds: ids)
    // Starting the application after confirmation evidence was prepared must
    // skip only its caches; the other application's action still completes.
    activity.setRunning(["com.google.Chrome"])
    let receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "partial")
    try expect(receipt.items.first { $0.relativePath == "com.google.Chrome" }?.state == "skipped")
    try expect(receipt.items.first { $0.relativePath == "com.tencent.xinWeChat" }?.state == "trashed")
    try expect(FileManager.default.fileExists(atPath: workspace.path + "/com.google.Chrome/resource.bin"))
    let unavailableEngine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace)
    let unknown=try await unavailableEngine.scan(workspaceId: workspace.id)
    let unknownChrome=try require(unknown.candidates.first { $0.relativePath == "com.google.Chrome" })
    try expect(!unknownChrome.eligible && unknownChrome.reasons.contains("application_activity_unavailable"))
}
