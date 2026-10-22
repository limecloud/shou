import Foundation
import CSQLite
import ShouCore
import ShouPlatform

func windowsPrivacyPolicyKeepsPlatformsProfilesAndDataKindsClosed() throws {
    for (_, identifier, root) in PrivacySourcePolicy.windowsChromiumRoots {
        for profile in ["Default", "Profile 42"] {
            for (kind, suffix) in [(PrivacyDataKind.history, "History"), (.cookies, "Cookies"), (.cookies, "Network/Cookies")] {
                let source=PrivacySourceDefinition(browser: .chromium, browserName: "fixture", bundleIdentifier: identifier, profile: profile, kind: kind, relativePath: root + "/" + profile + "/" + suffix, platform: "windows")
                try expect(PrivacySourcePolicy.valid(source))
                let encoded=try Codec.encode(source)
                try expect(try Codec.decode(PrivacySourceDefinition.self, from: encoded) == source)
            }
        }
    }
    let ff="AppData/Roaming/Mozilla/Firefox/Profiles/generated.default/cookies.sqlite"
    try expect(PrivacySourcePolicy.valid(.init(browser: .firefox, browserName: "Firefox", bundleIdentifier: "org.mozilla.firefox", profile: "generated.default", kind: .cookies, relativePath: ff, platform: "windows")))
    for (platform, profile, suffix, kind) in [("macos", "Default", "History", PrivacyDataKind.history), ("windows", "../Default", "History", .history), ("windows", "Default", "Login Data", .passwords), ("windows", "Default", "History-wal", .history), ("linux", "Default", "History", .history)] {
        let root=PrivacySourcePolicy.windowsChromiumRoots[0].2
        try expect(!PrivacySourcePolicy.valid(.init(browser: .chromium, browserName: "Chrome", bundleIdentifier: "com.google.Chrome", profile: profile, kind: kind, relativePath: root + "/" + profile + "/" + suffix, platform: platform)))
    }
    try expect(!PrivacySourcePolicy.valid(.init(browser: .safari, browserName: "Safari", bundleIdentifier: "com.apple.Safari", profile: "Default", kind: .history, relativePath: "Library/Safari/History.db", platform: "windows")))
    let legacy=PrivacySourceDefinition(browser: .chromium, browserName: "Chrome", bundleIdentifier: "com.google.Chrome", profile: "Default", kind: .history, relativePath: "Library/Application Support/Google/Chrome/Default/History")
    try expect(PrivacySourcePolicy.valid(try Codec.decode(PrivacySourceDefinition.self, from: Codec.encode(legacy))))
    let identifiers=Set(PrivacySourcePolicy.windowsChromiumRoots.map { $0.1 } + ["org.mozilla.firefox"])
    let running=try WindowsApplicationActivity { $0 == "chrome.exe" }.runningBundleIdentifiers(in: identifiers)
    try expect(running == ["com.google.Chrome", "org.chromium.Chromium"])
}

private final class PrivacyLeaseProbe: @unchecked Sendable {
    let lock=NSLock()
    private var count=0
    var active: Int { lock.lock(); defer { lock.unlock() }; return count }
    func change(_ value: Int) { lock.lock(); defer { lock.unlock() }; count += value }
}
private final class PrivacyLeaseFixture: PrivacySourceAccess, @unchecked Sendable {
    let probe: PrivacyLeaseProbe
    private let lock=NSLock()
    private var released=false
    init(_ probe: PrivacyLeaseProbe) { self.probe=probe; probe.change(1) }
    func release() { lock.lock(); defer { lock.unlock() }; if !released { released=true; probe.change(-1) } }
    deinit { release() }
}
private struct WindowsPrivacySourceFixture: PrivacySourceDiscovering {
    let definition: PrivacySourceDefinition
    let probe: PrivacyLeaseProbe
    func discover(home: URL) throws -> [PrivacySourceDefinition] { [definition] }
    func acquire(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> any PrivacySourceAccess { PrivacyLeaseFixture(probe) }
    func evidence(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> [FileEntry] {
        try expect(probe.active > 0)
        var entry=try require(NativeFileSystem().inspectTarget(home.appendingPathComponent(source.relativePath).path, budget: ScanBudget(), cancelled: { false }).entries.first)
        entry.path="database"; return [entry]
    }
}
private struct PrivacyStoppedBrowser: ApplicationActivityChecking {
    func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> { [] }
}
private struct PrivacyCaseInsensitiveFileSystem: PlatformFileSystem {
    let native=NativeFileSystem()
    var platform: String { "windows" }
    var caseSensitivePaths: Bool { false }
    var supportsTrash: Bool { false }
    func rootIdentity(_ path: String) throws -> FileEntry { try native.rootIdentity(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot { try native.inspect(path, budget: budget, cancelled: cancelled) }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw ShouError("capability_unavailable", "Privacy fixture only") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Privacy fixture only") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Privacy fixture only") }
}

func windowsPrivacyTransactionsHoldAccessAndHonorCaseInsensitiveExclusions() async throws {
    let fixture=try Fixture(), probe=PrivacyLeaseProbe()
    let relative=PrivacySourcePolicy.windowsChromiumRoots[0].2 + "/Default/Network/Cookies"
    let definition=PrivacySourceDefinition(browser: .chromium, browserName: "Chrome", bundleIdentifier: "com.google.Chrome", profile: "Default", kind: .cookies, relativePath: relative, platform: "windows")
    let url=fixture.workspace.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    try expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    try expect(sqlite3_exec(database, "CREATE TABLE cookies(last_access_utc INTEGER,value TEXT); INSERT INTO cookies VALUES(0,'generated-retained-cookie');", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    let source=WindowsPrivacySourceFixture(definition: definition, probe: probe)
    let service=PrivacyService(store: fixture.store, filesystem: PrivacyCaseInsensitiveFileSystem(), activity: PrivacyStoppedBrowser(), sources: source, home: fixture.workspace)
    let scan=try await service.scan(range: .allTime), item=try require(scan.sources.first)
    try expect(item.eligible && item.recordCount == 1 && probe.active == 0)
    try await expectThrows { try await service.preparePlan(scanId: scan.id, sourceIDs: [item.id]) }
    let plan=try await service.preparePlan(scanId: scan.id, sourceIDs: [item.id], acknowledgeSignOut: true)
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: .init(irreversibleDeletion: true)) }
    let result=try await service.execute(planId: plan.id, digest: plan.digest, consent: .init(irreversibleDeletion: true, signOut: true))
    try expect(result.state == "completed" && result.items[0].removedRecords == 1 && probe.active == 0)
    let receipt=String(decoding: try Codec.encode(result), as: UTF8.self)
    try expect(!receipt.contains("AppData") && !receipt.contains("generated-retained-cookie") && !receipt.contains("Default"))
    try await expectThrows { try await service.execute(planId: plan.id, digest: plan.digest, consent: .init(irreversibleDeletion: true, signOut: true)) }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    _ = try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "privacy-protection")
    var config=try await engine.configuration()
    config.workspaces[0].path=fixture.workspace.path.uppercased(); config.workspaces[0].exclusions=["appdata/**"]
    try fixture.store.write("configuration", id: "current", data: Codec.encode(config))
    let protected=try await service.scan(range: .allTime)
    try expect(protected.sources[0].status == .permissionRequired && protected.sources[0].recordCount == nil && probe.active == 0)
    try expect(try fixture.store.ids("plans").isEmpty && fixture.store.ids("history").isEmpty)
}
