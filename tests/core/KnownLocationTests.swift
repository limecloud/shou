import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#endif

private final class KnownLocationProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var recorded: [String]=[]
    let cancelOnIdentity: Bool
    init(cancelOnIdentity: Bool = false) { self.cancelOnIdentity=cancelOnIdentity }
    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event)
    }
    func events() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

func nativeAvailabilityDistinguishesDirectoriesWithoutFollowingLinks() throws {
    let fixture=try Fixture()
    let root=fixture.workspace
    let filesystem=NativeFileSystem()
    let file=root.appendingPathComponent("project/Cargo.toml")
    let directoryLink=root.appendingPathComponent("directory-link")
    let danglingLink=root.appendingPathComponent("dangling-link")
    let loop=root.appendingPathComponent("loop")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root.appendingPathComponent("project"))
    try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: root.appendingPathComponent("missing"))
    try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")

    guard case .available=filesystem.locationAvailability(root.path) else {
        throw CheckFailure(description: "An existing fixture directory must be available.")
    }
    for path in [root.appendingPathComponent("missing").path, file.appendingPathComponent("child").path] {
        guard case .missing=filesystem.locationAvailability(path) else {
            throw CheckFailure(description: "ENOENT and ENOTDIR must report a missing location.")
        }
    }
    for path in [file.path, directoryLink.path, danglingLink.path, loop.appendingPathComponent("child").path] {
        guard case .unavailable(let reason)=filesystem.locationAvailability(path) else {
            throw CheckFailure(description: "Files, symbolic links and uninspectable locations must not be available.")
        }
        try expect(!reason.isEmpty)
    }
}

/// Simulates known roots without reading or changing the user's application data.
private struct KnownLocationFileSystem: PlatformFileSystem {
    var incompletePath: String? = nil
    var probe: KnownLocationProbe? = nil
    var platform: String { "macos" }
    var supportsTrash: Bool { false }
    func locationAvailability(_ path: String) -> LocationAvailability {
        probe?.record("availability:" + path)
        return .available
    }
    func rootIdentity(_ path: String) throws -> FileEntry {
        probe?.record("identity:" + path)
        if probe?.cancelOnIdentity == true { withUnsafeCurrentTask { $0?.cancel() } }
        let inode=path.utf8.reduce(UInt64(1)) { ($0 &* 31) &+ UInt64($1) }
        return FileEntry(path: ".", kind: "directory", device: 1, inode: inode, logicalBytes: 0, allocatedBytes: 0,
            modifiedNanoseconds: 0, changedNanoseconds: 0, mode: 0, owner: 1, links: 1)
    }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        if cancelled() { throw ShouError("cancelled", "Scan cancelled.") }
        return TreeSnapshot(entries: [try rootIdentity(path)], complete: path != incompletePath,
            issues: path == incompletePath ? ["Simulated unreadable subtree."] : [], caseSensitive: true)
    }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw ShouError("capability_unavailable", "Not supported by read-only fixture.") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Not supported by read-only fixture.") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Not supported by read-only fixture.") }
}

func nativeRootIdentityNeedsOnlySearchAccess() throws {
    #if os(macOS)
    let fixture=try Fixture()
    let root=fixture.workspace.appendingPathComponent("metadata-only")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    let identity=try fixture.fs.rootIdentity(root.path)
    try expect(identity.kind == "directory" && identity.mode & 0o777 == 0o111)
    if getuid() != 0 {
        try expectThrows { try fixture.fs.inspect(root.path, budget: ScanBudget(), cancelled: { false }) }
    }
    #endif
}

func knownLocationRegistrationUsesOnlyRequestedRoot() async throws {
    let fixture=try Fixture()
    let probe=KnownLocationProbe()
    let engine=ShouEngine(store: fixture.store, filesystem: KnownLocationFileSystem(probe: probe), homeDirectory: fixture.workspace)
    let workspace=try await engine.workspaceForKnownLocation("caches")
    let reused=try await engine.workspaceForKnownLocation("caches")
    try expect(workspace.id == reused.id)
    try expect(probe.events() == ["identity:" + workspace.path])
    try await expectThrows { try await engine.workspaceForKnownLocation("unknown-root") }
    try expect(probe.events() == ["identity:" + workspace.path])
}

func systemScanPreparationIsLinearAndReportsRootBeforeIdentity() async throws {
    let fixture=try Fixture()
    let probe=KnownLocationProbe()
    let engine=ShouEngine(store: fixture.store, filesystem: KnownLocationFileSystem(probe: probe), homeDirectory: fixture.workspace)
    let result=try await engine.scanKnownLocations(progress: { location, progress in
        if progress.stage == "preparing" {
            probe.record("preparing:" + location.path + ":" + progress.currentPath)
        }
    })
    let events=probe.events()
    try expect(events.filter { $0.hasPrefix("availability:") }.count == result.locations.count)
    for location in result.locations {
        let preparing="preparing:" + location.path + ":" + location.path
        let preparationIndex=try require(events.firstIndex(of: preparing))
        let identityIndex=try require(events.firstIndex(of: "identity:" + location.path))
        try expect(preparationIndex < identityIndex)
        try expect(events.filter { $0 == preparing }.count == 1)
    }
    let digest=try Digest.of(await engine.configuration())
    try expect(result.snapshots.allSatisfy { $0.configurationDigest == digest })
}

func systemScanPreparationCancellationPreventsRegistration() async throws {
    let fixture=try Fixture()
    let probe=KnownLocationProbe()
    let engine=ShouEngine(store: fixture.store, filesystem: KnownLocationFileSystem(probe: probe), homeDirectory: fixture.workspace)
    let operation=Task {
        do {
            _ = try await engine.scanKnownLocations(progress: { _, progress in
                if progress.stage == "preparing" { withUnsafeCurrentTask { $0?.cancel() } }
            })
            return false
        } catch let failure as ShouError { return failure.code == "cancelled" }
    }
    try expect(try await operation.value)
    try expect(try await engine.configuration().workspaces.isEmpty)
    try expect(!probe.events().contains { $0.hasPrefix("identity:") })

    // Cancellation arriving during identity lookup must not persist the root.
    let duringProbe=KnownLocationProbe(cancelOnIdentity: true)
    let duringEngine=ShouEngine(store: fixture.store, filesystem: KnownLocationFileSystem(probe: duringProbe), homeDirectory: fixture.workspace)
    let duringIdentity=Task {
        do { _ = try await duringEngine.workspaceForKnownLocation("caches"); return false }
        catch let failure as ShouError { return failure.code == "cancelled" }
    }
    try expect(try await duringIdentity.value)
    try expect(try await duringEngine.configuration().workspaces.isEmpty)

    // A cancelled native call stops before even opening a nonexistent path.
    let nativeOperation=Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try fixture.fs.rootIdentity(fixture.workspace.appendingPathComponent("missing").path); return false }
        catch let failure as ShouError { return failure.code == "cancelled" }
    }
    try expect(try await nativeOperation.value)
}

func knownLocationsAreExplicitAndPlatformScoped() throws {
    let fixture=try Fixture()
    let locations=try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "macos")
    try expect(Set(locations.map(\.id)).count == locations.count)
    try expect(locations.allSatisfy { $0.path.hasPrefix(fixture.workspace.path + "/") && !$0.ruleIds.isEmpty })
    try expect(locations.first { $0.id == "caches" }?.path == fixture.workspace.path + "/Library/Caches")
    try expect(locations.first { $0.id == "chrome" }?.ruleIds == ["shou.builtin.chrome-caches"])
    try expect(Set(locations.map(\.category)) == Set(["application", "browser", "developer", "system"]))
    try expect(locations.first { $0.id == "chrome" }?.applicationBundleIdentifiers.contains("com.google.Chrome") == true)
    try expect(!locations.contains { $0.path == fixture.workspace.path || $0.path == fixture.workspace.path + "/Library/Application Support" })
    try expect(try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "windows").isEmpty)
}

func expandedCatalogKeepsCacheAndUserDataBoundaries() async throws {
    struct ScopeCase {
        let location: String
        let caches: [String]
        let retained: [String]
    }
    let cases: [ScopeCase] = [
        .init(location: "edge", caches: ["Default/Cache", "Profile 2/GPUCache"], retained: ["Default/Local Storage/leveldb", "Default/Sessions", "Default/Extensions/addon"]),
        .init(location: "brave", caches: ["Guest Profile/Code Cache"], retained: ["Guest Profile/IndexedDB", "Guest Profile/Network"]),
        .init(location: "arc", caches: ["Default/Cache"], retained: ["Default/Sessions", "Spaces", "Default/Extensions"]),
        .init(location: "firefox", caches: ["profile.default/cache2", "profile.default/startupCache"], retained: ["profile.default/bookmarkbackups", "profile.default/sessionstore-backups"]),
        .init(location: "slack", caches: ["Cache", "Service Worker/CacheStorage"], retained: ["IndexedDB", "Local Storage", "Service Worker/Database"]),
        .init(location: "postman", caches: ["Code Cache", "Partitions/account/GPUCache"], retained: ["Partitions/account/IndexedDB", "Partitions/account/Storage", "workspaces"]),
        .init(location: "workbuddy", caches: ["GPUCache", "Partitions/preview/Code Cache"], retained: ["IndexedDB", "Local Storage", "Partitions/preview/Session Storage", "tasks", "projects"]),
        .init(location: "wechat-profiles", caches: ["account/Cache", "account/Code Cache"], retained: ["account/IndexedDB", "account/Local Storage", "account/messages", "account/downloads"]),
        .init(location: "lark", caches: ["aha/users/account/profile_main/Cache", "iron/users/account/profile_explorer/Service Worker/CacheStorage"], retained: ["aha/users/account/profile_main/IndexedDB", "iron/users/account/profile_explorer/Service Worker/Database", "accounts", "downloads"]),
        .init(location: "vscode", caches: ["CachedData", "CachedExtensionVSIXs"], retained: ["User/globalStorage", "User/workspaceStorage", "Backups", "extensions"]),
        .init(location: "cursor", caches: ["Cache", "CachedData"], retained: ["User/globalStorage", "User/workspaceStorage", "Backups"]),
        .init(location: "jetbrains", caches: ["IntelliJIdea2026.2/caches", "WebStorm2026.2/index"], retained: ["IntelliJIdea2026.2/LocalHistory", "IntelliJIdea2026.2/plugins", "WebStorm2026.2/LocalHistory"]),
        .init(location: "caches", caches: ["pip", "pypoetry/artifacts", "pypoetry/cache", "go-build", "CocoaPods", "com.tencent.meeting/WebKit/NetworkCache"], retained: ["pypoetry/virtualenvs", "com.tencent.meeting/meeting-recordings", "com.tencent.meeting/accounts"]),
        .init(location: "developer-cache", caches: ["uv", "ruff", "mypy", "node/corepack"], retained: ["huggingface/hub", "models", "credentials"]),
        .init(location: "yarn-berry", caches: ["cache"], retained: ["plugins", "releases"]),
        .init(location: "go-module-downloads", caches: ["download"], retained: ["private-source", "configuration"])
    ]
    let fixture=try Fixture()
    let locations=try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "macos")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    for sample in cases {
        let location=try require(locations.first { $0.id == sample.location })
        let relativeRoot=String(location.path.dropFirst(fixture.workspace.path.count + 1))
        for directory in sample.caches + sample.retained { try fixture.put(relativeRoot + "/" + directory + "/payload.bin") }
        let workspace=try await engine.addWorkspace(path: location.path, rootRef: "boundary-" + location.id)
        let rules=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos")
        try expect(rules.allSatisfy { location.ruleIds.contains($0.id) })
        let tree=try fixture.fs.inspect(location.path, budget: ScanBudget(), cancelled: { false })
        let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: Date())
        for path in sample.caches { try expect(candidates.first { $0.relativePath == path }?.eligible == true) }
        for path in sample.retained {
            try expect(!candidates.contains { candidate in candidate.eligible && (candidate.relativePath == path || path.hasPrefix(candidate.relativePath + "/")) })
        }
    }
}

func expandedApplicationCacheSecretsRemainProtected() async throws {
    let fixture=try Fixture()
    let roots=try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "macos")
    let figma=try require(roots.first { $0.id == "figma" })
    let prefix=String(figma.path.dropFirst(fixture.workspace.path.count + 1))
    try fixture.put(prefix + "/GPUCache/token.pem", "retain")
    try fixture.put(prefix + "/Cache/source.rs", "retain")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace)
    let workspace=try await engine.workspaceForKnownLocation("figma")
    let rules=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos")
    let tree=try fixture.fs.inspect(workspace.path, budget: ScanBudget(), cancelled: { false })
    let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: Date())
    for path in ["Cache", "GPUCache"] {
        let candidate=try require(candidates.first { $0.relativePath == path })
        try expect(!candidate.eligible && candidate.reasons.contains("protected_content"))
    }
    let incomplete=TreeSnapshot(entries: tree.entries, complete: false, issues: ["Interrupted fixture scan."], caseSensitive: tree.caseSensitive)
    try expect(try Analysis.candidates(tree: incomplete, workspace: workspace, rules: rules, now: Date()).allSatisfy { !$0.eligible })
}

func fixedApplicationRulesPreserveUserDataAndSecrets() async throws {
    let fixture=try Fixture()
    let prefix="Library/Application Support/Google/Chrome/"
    for path in ["Default/Cache/data.bin", "Default/Code Cache/js/data.bin", "Profile 2/Cache/data.bin", "Default/Local Storage/leveldb/user.bin", "Default/Extensions/addon/data.bin", "Default/GPUCache/token.pem"] {
        try fixture.put(prefix + path)
    }
    try fixture.put(prefix + "Default/History", "retain")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path + "/Library/Application Support/Google/Chrome", rootRef: "chrome-fixture")
    let rules=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace)
    let tree=try fixture.fs.inspect(workspace.path, budget: ScanBudget(), cancelled: { false })
    let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: Date())
    for path in ["Default/Cache", "Default/Code Cache", "Profile 2/Cache"] {
        let candidate=try require(candidates.first { $0.relativePath == path })
        try expect(candidate.eligible && candidate.ruleIds == ["shou.builtin.chrome-caches"])
    }
    try expect(candidates.first { $0.relativePath == "Default/GPUCache" }?.reasons.contains("protected_content") == true)
    try expect(candidates.filter(\.eligible).allSatisfy { ["Default/Cache", "Default/Code Cache", "Profile 2/Cache"].contains($0.relativePath) })
    // A logical root name alone cannot activate fixed application rules elsewhere.
    let unrelated=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "chrome")
    try expect(!(try BuiltinCatalog.rules(for: unrelated, homeDirectory: fixture.workspace)).contains { $0.id == "shou.builtin.chrome-caches" })
}

func knownLocationRegistrationReusesConfiguration() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: KnownLocationFileSystem())
    let workspace=try await engine.workspaceForKnownLocation("caches")
    _ = try await engine.setExclusion(workspaceId: workspace.id, pattern: "keep", remove: false)
    _ = try await engine.setRule(ruleId: "shou.builtin.wechat-caches", workspaceId: workspace.id, enabled: false)
    let before=try await engine.configuration()
    let reused=try await engine.workspaceForKnownLocation("caches")
    try expect(reused.id == workspace.id && reused.exclusions == ["keep"])
    try expect(try Digest.of(await engine.configuration()) == Digest.of(before))
    try await expectThrows { try await engine.scan(locationId: "npm", budget: ScanBudget(maxEntries: 0)) }
    try await expectThrows { try await engine.workspaceForKnownLocation("not-a-location") }
    try expect(try Digest.of(await engine.configuration()) == Digest.of(before))
}

func systemScanRegistersBeforeEvidenceAndReportsPartial() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: KnownLocationFileSystem())
    let result=try await engine.scanKnownLocations()
    let config=try await engine.configuration()
    let existing=result.locations.filter(\.exists)
    let unavailable=result.locations.filter { $0.availabilityIssue != nil }
    let cacheDiscoveryUnavailable=existing.contains { $0.id == "caches" }
    try expect(result.status == (unavailable.isEmpty && !cacheDiscoveryUnavailable ? "complete" : "partial"))
    try expect(result.issues.filter { $0.code == "access_unavailable" }.count == unavailable.count)
    try expect(result.issues.filter { $0.code == "application_discovery_unavailable" }.count == (cacheDiscoveryUnavailable ? 1 : 0))
    try expect(result.issues.allSatisfy { $0.code == "access_unavailable" || ($0.locationId == "caches" && $0.code == "application_discovery_unavailable") })
    if let caches=result.snapshots.first(where: { $0.workspace.path.hasSuffix("/Library/Caches") }) {
        try expect(caches.status == "complete" && caches.installedApplicationCaches == nil)
        try expect(try await engine.builtinRules(workspaceId: caches.workspace.id).contains { $0.id == "shou.builtin.wechat-caches" })
    }
    try expect(config.workspaces.count == existing.count && result.snapshots.count == existing.count)
    let digest=try Digest.of(config)
    try expect(result.snapshots.allSatisfy { $0.configurationDigest == digest })
    try expect(Set(result.skippedLocationIds) == Set(result.locations.filter { !$0.exists && $0.availabilityIssue == nil }.map(\.id)))
    if let first=existing.first {
        let other=try Fixture()
        let partialEngine=ShouEngine(store: other.store, filesystem: KnownLocationFileSystem(incompletePath: first.path))
        let partial=try await partialEngine.scanKnownLocations()
        try expect(partial.status == "partial")
        try expect(partial.issues.contains { $0.locationId == first.id && $0.code == "partial_result" })
        let snapshot=try require(partial.snapshots.first { $0.workspace.path == first.path })
        try expect(snapshot.status == "partial")
        try await expectThrows { try await partialEngine.createPlan(scanId: snapshot.id, candidateIds: ["not-authorized"]) }
    }
}
