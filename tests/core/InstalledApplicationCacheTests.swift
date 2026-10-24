import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class InstalledCacheActivity: ApplicationUninstallChecking, ApplicationActivityChecking, @unchecked Sendable {
    private let lock=NSLock()
    private var running=Set<String>()
    private var current=Set<String>()
    private var unavailable=false
    func set(running: Set<String> = [], current: Set<String> = [], unavailable: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.running=running; self.current=current; self.unavailable=unavailable
    }
    func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw ShouError("application_activity_unavailable", "Generated activity is unavailable.") }
        return running.intersection(identifiers)
    }
    func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw ShouError("application_activity_unavailable", "Generated activity is unavailable.") }
        let identifier=application.bundleIdentifier ?? ""
        return ApplicationUninstallFacts(currentUser: getuid(), running: running.contains(identifier), currentApplication: current.contains(identifier))
    }
    func containerIdentifier(at path: String) throws -> String { throw ShouError("ownership_unverified", "No container fixture.") }
}

private final class InstalledCacheCatalog: ApplicationCatalogReading, @unchecked Sendable {
    let native: NativeApplicationCatalog
    private let lock=NSLock()
    private var partial=false
    private var additions: [ApplicationDefinition]=[]
    private var applicationOwner: UInt32?
    private var issues: [ApplicationCatalogIssue]=[]
    private var sourceStatus: String?
    init(source: ApplicationSource) { native=NativeApplicationCatalog(sources: [source]) }
    func set(partial: Bool = false, additions: [ApplicationDefinition] = [], applicationOwner: UInt32? = nil,
             issues: [ApplicationCatalogIssue] = [], sourceStatus: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.partial=partial; self.additions=additions; self.applicationOwner=applicationOwner; self.issues=issues; self.sourceStatus=sourceStatus
    }
    func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog {
        let result=try native.read(options: options)
        lock.lock()
        let partial=self.partial, additions=self.additions, owner=applicationOwner, issues=self.issues, sourceStatus=self.sourceStatus
        lock.unlock()
        let allIssues=result.issues + issues + (partial ? [ApplicationCatalogIssue(path: result.sources.first?.source.path ?? "", code: "resource_limit")] : [])
        let sources=result.sources.map { coverage in
            let affected=allIssues.contains { $0.path == coverage.source.path || $0.path.hasPrefix(coverage.source.path + "/") }
            return ApplicationSourceCoverage(source: coverage.source, status: sourceStatus ?? (affected ? "partial" : coverage.status),
                entryCount: coverage.entryCount, applicationCount: coverage.applicationCount)
        }
        return ApplicationCatalog(checkedAt: result.checkedAt, sources: sources, items: result.items.map { replacingOwner($0, owner: owner) } + additions, issues: allIssues)
    }
    func application(at path: String) throws -> ApplicationDefinition {
        let application=try native.application(at: path)
        lock.lock(); let owner=applicationOwner; lock.unlock()
        return replacingOwner(application, owner: owner)
    }
    private func replacingOwner(_ application: ApplicationDefinition, owner: UInt32?) -> ApplicationDefinition {
        guard let owner else { return application }
        var identity=application.identity; identity.owner=owner
        return ApplicationDefinition(path: application.path, source: application.source, identity: identity, name: application.name,
            bundleIdentifier: application.bundleIdentifier, version: application.version, executableName: application.executableName, infoDigest: application.infoDigest)
    }
}

private struct InstalledCacheFixture {
    let files: Fixture
    let app: URL
    let identifier: String
    let catalog: InstalledCacheCatalog
    let activity: InstalledCacheActivity
    let engine: ShouEngine
    init(identifier: String = "dev.shou.generated.unlisted", createCache: Bool = true) throws {
        files=try Fixture(); self.identifier=identifier
        app=files.workspace.appendingPathComponent("Applications/Unlisted Generated.app")
        try Self.writeApplication(app, identifier: identifier)
        if createCache { try files.put("Library/Caches/" + identifier + "/cache.bin", String(repeating: "c", count: 8192)) }
        try files.put("Library/Application Support/" + identifier + "/personal.bin", "retain application data")
        try files.put("Library/Preferences/" + identifier + ".plist", "retain preferences")
        catalog=InstalledCacheCatalog(source: ApplicationSource(id: "generated.apps", path: app.deletingLastPathComponent().path))
        activity=InstalledCacheActivity()
        engine=ShouEngine(store: files.store, filesystem: FixtureFileSystem(native: files.fs, trash: files.trash),
            applicationActivity: activity, applicationCatalog: catalog, uninstallEvidence: activity, homeDirectory: files.workspace)
    }
    static func writeApplication(_ path: URL, identifier: String, version: String = "1") throws {
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": "Unlisted Generated App",
            "CFBundleExecutable": "Generated", "CFBundlePackageType": "APPL", "CFBundleVersion": version], format: .binary, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
        try Data("inert generated executable".utf8).write(to: path.appendingPathComponent("Contents/MacOS/Generated"))
    }
    func scan() async throws -> (Workspace, ScanSnapshot) {
        let workspace=try await engine.workspaceForKnownLocation("caches")
        return (workspace, try await engine.scan(workspaceId: workspace.id, scope: .cleanup))
    }
    func candidate(_ scan: ScanSnapshot) throws -> Candidate { try require(scan.candidates.first { $0.relativePath == identifier }) }
    var unrelatedIssue: ApplicationCatalogIssue {
        ApplicationCatalogIssue(path: app.deletingLastPathComponent().appendingPathComponent("Unrelated Broken.app").path, code: "io_error")
    }
    func duplicateOwner() throws -> ApplicationDefinition {
        let original=try catalog.native.application(at: app.path)
        return ApplicationDefinition(path: app.deletingLastPathComponent().appendingPathComponent("Late Duplicate.app").path,
            source: original.source, identity: original.identity, name: "Generated Duplicate", bundleIdentifier: identifier.uppercased(),
            version: original.version, executableName: original.executableName, infoDigest: original.infoDigest)
    }
    func retainedHashes() throws -> [String: String] {
        let paths=["Applications/Unlisted Generated.app/Contents/Info.plist", "Applications/Unlisted Generated.app/Contents/MacOS/Generated",
            "Library/Application Support/" + identifier + "/personal.bin", "Library/Preferences/" + identifier + ".plist"]
        return try Dictionary(uniqueKeysWithValues: paths.map { ($0, Digest.sha256(try Data(contentsOf: files.workspace.appendingPathComponent($0)))) })
    }
}

func installedApplicationCachesUseNormalCleanupWithoutUninstalling() async throws {
    #if os(macOS)
    let fixture=try InstalledCacheFixture(), retained=try fixture.retainedHashes()
    try fixture.files.put("Library/Caches/dev.shou.not-installed/retain.bin", "uninstalled cache is not authorized")
    let outside=fixture.files.workspace.appendingPathComponent("retained-outside.bin")
    try Data("retain linked destination".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.files.workspace.appendingPathComponent("Library/Caches/" + fixture.identifier + "/opaque-link"), withDestinationURL: outside)
    let (workspace, snapshot)=try await fixture.scan(), candidate=try fixture.candidate(snapshot)
    try expect(candidate.eligible && candidate.ruleIds.count == 1 && candidate.ruleIds[0].hasPrefix("shou.builtin.installed-cache."))
    try expect(snapshot.installedApplicationCaches?.count == 1)
    try expect(!snapshot.entries.contains { $0.path.contains("opaque-link/") })
    try expect(snapshot.candidates.first { $0.relativePath == "dev.shou.not-installed" }?.eligible != true)
    let review=try CleanupReview(snapshots: [snapshot], locations: await fixture.engine.knownLocations())
    let group=try require(review.categories.flatMap(\.groups).first { $0.id == candidate.ruleIds[0] })
    try expect(group.title == "Unlisted Generated App" && group.category == "application")
    try expect(group.applicationBundleIdentifiers == [fixture.identifier] && group.sources[0].isBuiltIn && group.sources[0].selectable)
    let plan=try await fixture.engine.createPlan(scanId: snapshot.id, candidateIds: [candidate.id])
    try expect(plan.installedApplicationCaches == snapshot.installedApplicationCaches && plan.workspace.id == workspace.id)
    let receipt=try await fixture.engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-installed-cache")
    try expect(receipt.state == "completed" && receipt.items.count == 1 && receipt.items[0].state == "trashed")
    try expect(receipt.operation == nil && receipt.items[0].uninstallOrigin == nil)
    try expect(try await fixture.engine.history().count == 1)
    try expect(try fixture.retainedHashes() == retained && Data(contentsOf: outside) == Data("retain linked destination".utf8))
    let ids=receipt.items.map(\.id)
    let digest=try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await fixture.engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" })
    try expect(FileManager.default.fileExists(atPath: workspace.path + "/" + fixture.identifier + "/cache.bin"))
    try expect(try fixture.retainedHashes() == retained)
    #endif
}

func installedApplicationCachesKeepActivityAndIdentityGates() async throws {
    #if os(macOS)
    let adminOwned=try InstalledCacheFixture()
    adminOwned.catalog.set(applicationOwner: getuid() &+ 1)
    let (_, adminCache)=try await adminOwned.scan(), adminCandidate=try adminOwned.candidate(adminCache)
    try expect(adminCandidate.eligible)
    let adminPlan=try await adminOwned.engine.createPlan(scanId: adminCache.id, candidateIds: [adminCandidate.id])
    try expect(adminPlan.items.count == 1)
    let fixture=try InstalledCacheFixture()
    fixture.activity.set(running: [fixture.identifier])
    let (_, running)=try await fixture.scan()
    try expect(try fixture.candidate(running).reasons.contains("application_running"))
    fixture.activity.set(unavailable: true)
    let (_, unknown)=try await fixture.scan()
    try expect(try fixture.candidate(unknown).reasons.contains("application_activity_unavailable"))
    fixture.activity.set(current: [fixture.identifier])
    let (_, current)=try await fixture.scan()
    try expect(try fixture.candidate(current).reasons.contains("protected_content"))
    fixture.activity.set()
    let (_, ready)=try await fixture.scan(), candidate=try fixture.candidate(ready)
    fixture.activity.set(running: [fixture.identifier])
    try await expectThrows { try await fixture.engine.createPlan(scanId: ready.id, candidateIds: [candidate.id]) }
    fixture.activity.set()
    let plan=try await fixture.engine.createPlan(scanId: ready.id, candidateIds: [candidate.id])
    fixture.activity.set(running: [fixture.identifier])
    let receipt=try await fixture.engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-cache-running")
    try expect(receipt.items[0].state == "skipped" && receipt.items[0].error == "application_running")
    try expect(FileManager.default.fileExists(atPath: fixture.app.path))

    let changed=try InstalledCacheFixture(), (_, scanned)=try await changed.scan(), selected=try changed.candidate(scanned)
    try InstalledCacheFixture.writeApplication(changed.app, identifier: changed.identifier, version: "changed")
    try await expectThrows { try await changed.engine.createPlan(scanId: scanned.id, candidateIds: [selected.id]) }
    let replaced=try InstalledCacheFixture(), (_, original)=try await replaced.scan(), old=try replaced.candidate(original)
    let originalPlan=try await replaced.engine.createPlan(scanId: original.id, candidateIds: [old.id])
    try FileManager.default.moveItem(at: replaced.app, to: replaced.app.deletingLastPathComponent().appendingPathComponent("Retained Original.bundle"))
    try InstalledCacheFixture.writeApplication(replaced.app, identifier: replaced.identifier)
    try await expectThrows { try await replaced.engine.execute(planId: originalPlan.id, confirmedDigest: originalPlan.digest, entryPoint: "generated-cache-replaced") }
    try expect(try await replaced.engine.history().isEmpty)
    #endif
}

func installedApplicationCachesRecheckAtEachMutationBoundary() async throws {
    #if os(macOS)
    let fixture=try InstalledCacheFixture(), (_, scanned)=try await fixture.scan(), candidate=try fixture.candidate(scanned)
    let plan=try await fixture.engine.createPlan(scanId: scanned.id, candidateIds: [candidate.id])
    let receipt=try await fixture.engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-cache-boundary", progress: { update in
        if update.stage == "moving" && update.processedCount == 0 { fixture.activity.set(running: [fixture.identifier]) }
    })
    try expect(receipt.items[0].state == "skipped" && receipt.items[0].error == "application_running")
    try expect(FileManager.default.fileExists(atPath: fixture.files.workspace.path + "/Library/Caches/" + fixture.identifier + "/cache.bin"))
    let changed=try InstalledCacheFixture(), (_, prior)=try await changed.scan(), selected=try changed.candidate(prior)
    let changedPlan=try await changed.engine.createPlan(scanId: prior.id, candidateIds: [selected.id])
    let failed=try await changed.engine.execute(planId: changedPlan.id, confirmedDigest: changedPlan.digest, entryPoint: "generated-cache-owner-boundary", progress: { update in
        if update.stage == "moving" && update.processedCount == 0 {
            try? InstalledCacheFixture.writeApplication(changed.app, identifier: changed.identifier, version: "boundary-change")
        }
    })
    try expect(failed.items[0].state == "failed" && failed.items[0].trashPath == nil)
    let permanent=try InstalledCacheFixture(), (_, permanentScan)=try await permanent.scan(), permanentCandidate=try permanent.candidate(permanentScan)
    let permanentPlan=try await permanent.engine.createPlan(scanId: permanentScan.id, candidateIds: [permanentCandidate.id], action: "permanent")
    let skipped=try await permanent.engine.execute(planId: permanentPlan.id, confirmedDigest: permanentPlan.digest, entryPoint: "generated-cache-permanent-boundary", progress: { update in
        if update.stage == "checking" && update.processedCount == 0 { permanent.activity.set(unavailable: true) }
    })
    try expect(skipped.operation == "permanent_cleanup" && skipped.items[0].state == "skipped" && skipped.items[0].error == "application_activity_unavailable")

    for action in ["trash", "permanent"] {
        let coverage=try InstalledCacheFixture(), (_, complete)=try await coverage.scan(), completeCandidate=try coverage.candidate(complete)
        let coveragePlan=try await coverage.engine.createPlan(scanId: complete.id, candidateIds: [completeCandidate.id], action: action)
        let interrupted=try await coverage.engine.execute(planId: coveragePlan.id, confirmedDigest: coveragePlan.digest, entryPoint: "generated-cache-coverage-boundary", progress: { update in
            if update.stage == (action == "trash" ? "moving" : "checking") && update.processedCount == 0 {
                coverage.catalog.set(issues: [coverage.unrelatedIssue])
            }
        })
        try expect(interrupted.items[0].state == "failed" && interrupted.items[0].trashPath == nil)
        try expect(FileManager.default.fileExists(atPath: coverage.files.workspace.path + "/Library/Caches/" + coverage.identifier + "/cache.bin"))

        let duplicate=try InstalledCacheFixture()
        duplicate.catalog.set(issues: [duplicate.unrelatedIssue])
        let (_, partial)=try await duplicate.scan(), selected=try duplicate.candidate(partial), lateOwner=try duplicate.duplicateOwner()
        let duplicatePlan=try await duplicate.engine.createPlan(scanId: partial.id, candidateIds: [selected.id], action: action)
        let refused=try await duplicate.engine.execute(planId: duplicatePlan.id, confirmedDigest: duplicatePlan.digest, entryPoint: "generated-cache-duplicate-boundary", progress: { update in
            if update.stage == (action == "trash" ? "moving" : "checking") && update.processedCount == 0 {
                duplicate.catalog.set(additions: [lateOwner], issues: [duplicate.unrelatedIssue])
            }
        })
        try expect(refused.items[0].state == "failed" && refused.items[0].trashPath == nil)
        try expect(FileManager.default.fileExists(atPath: duplicate.files.workspace.path + "/Library/Caches/" + duplicate.identifier + "/cache.bin"))
    }
    #endif
}

func installedApplicationCachesRespectStaticScopeAndDisabledRules() async throws {
    #if os(macOS)
    let narrow=try InstalledCacheFixture(identifier: "com.tencent.meeting")
    try narrow.files.put("Library/Caches/com.tencent.meeting/WebKit/NetworkCache/payload.bin")
    try narrow.files.put("Library/Caches/com.tencent.meeting/meeting-recordings/retain.bin")
    let (workspace, snapshot)=try await narrow.scan()
    try expect(snapshot.installedApplicationCaches == nil)
    try expect(snapshot.candidates.first { $0.relativePath == "com.tencent.meeting" }?.eligible != true)
    try expect(snapshot.candidates.first { $0.relativePath == "com.tencent.meeting/WebKit/NetworkCache" }?.eligible == true)
    _ = try await narrow.engine.setRule(ruleId: "shou.builtin.tencent-meeting-caches", workspaceId: workspace.id, enabled: false)
    let disabled=try await narrow.engine.scan(workspaceId: workspace.id)
    try expect(disabled.installedApplicationCaches == nil && !disabled.candidates.contains(where: \.eligible))

    let generic=try InstalledCacheFixture(), (genericRoot, active)=try await generic.scan(), candidate=try generic.candidate(active)
    _ = try await generic.engine.setRule(ruleId: candidate.ruleIds[0], workspaceId: genericRoot.id, enabled: false)
    let off=try await generic.engine.scan(workspaceId: genericRoot.id)
    try expect(off.installedApplicationCaches == nil && !off.candidates.contains(where: \.eligible))
    _ = try await generic.engine.setRule(ruleId: candidate.ruleIds[0], workspaceId: genericRoot.id, enabled: true)
    let enabled=try await generic.engine.scan(workspaceId: genericRoot.id)
    try expect(try generic.candidate(enabled).ruleIds == candidate.ruleIds)
    let review=try CleanupReview(snapshots: [enabled, enabled])
    try expect(review.recommendedSources.count == 1)
    #endif
}

func installedApplicationCachesRetainSharedProtectionAndNoFollowBoundaries() async throws {
    #if os(macOS)
    for name in ["secret.pem", "database.db", "metadata.sqlite", ".env"] {
        let fixture=try InstalledCacheFixture()
        try fixture.files.put("Library/Caches/" + fixture.identifier + "/" + name, "retain protected content")
        let (_, snapshot)=try await fixture.scan(), candidate=try fixture.candidate(snapshot)
        try expect(!candidate.eligible && candidate.reasons.contains("protected_content"))
    }
    let fixture=try InstalledCacheFixture(), (workspace, snapshot)=try await fixture.scan()
    let rules=try await fixture.engine.builtinRules(workspaceId: workspace.id).filter { $0.id.hasPrefix("shou.builtin.installed-cache.") }
    try expect(rules.count == 1 && !rules[0].scope.followSymlinks && !rules[0].scope.crossFilesystems)
    var foreign=snapshot.entries
    let index=try require(foreign.firstIndex { $0.path.hasSuffix("/cache.bin") })
    foreign[index].owner = foreign[index].owner &+ 1
    let foreignCandidates=try Analysis.candidates(tree: TreeSnapshot(entries: foreign, complete: true, issues: [], caseSensitive: true), workspace: workspace, rules: rules, now: Date())
    try expect(foreignCandidates.first { $0.relativePath == fixture.identifier }?.reasons.contains("protected_content") == true)
    let incomplete=try Analysis.candidates(tree: TreeSnapshot(entries: snapshot.entries, complete: false, issues: ["resource_limit"], caseSensitive: true, completedPaths: []), workspace: workspace, rules: rules, now: Date())
    try expect(incomplete.first { $0.relativePath == fixture.identifier }?.reasons.contains("incomplete_scan") == true)
    _ = try await fixture.engine.setExclusion(workspaceId: workspace.id, pattern: fixture.identifier + "/cache.bin", remove: false)
    let excluded=try await fixture.engine.scan(workspaceId: workspace.id)
    try expect(try fixture.candidate(excluded).reasons.contains("excluded_descendant"))
    let linked=try InstalledCacheFixture(createCache: false)
    try FileManager.default.createDirectory(at: linked.files.workspace.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked.files.workspace.appendingPathComponent("Library/Caches/" + linked.identifier), withDestinationURL: linked.app)
    let (_, links)=try await linked.scan()
    try expect(!links.candidates.contains { $0.relativePath == linked.identifier && $0.eligible })
    try expect(!links.entries.contains { $0.path.hasPrefix(linked.identifier + "/") })
    #endif
}

func installedApplicationCachesReportInventoryGapsAndAmbiguousOwners() async throws {
    #if os(macOS)
    let local=try InstalledCacheFixture(), retained=try local.retainedHashes()
    // A real malformed neighbor makes native source coverage partial without changing this owner.
    let malformed=local.app.deletingLastPathComponent().appendingPathComponent("Malformed Neighbor.app")
    try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    let native=try local.catalog.native.read(options: ApplicationCatalogOptions())
    try expect(native.status == "partial" && native.sources.first?.status == "partial")
    let (_, usable)=try await local.scan(), usableCandidate=try local.candidate(usable)
    try expect(usableCandidate.eligible && usable.installedApplicationCaches?.first?.ownershipCoverageIncomplete == true)
    try expect(usable.issues.contains("installed_application_cache:application_discovery_incomplete"))
    let review=try CleanupReview(snapshots: [usable])
    let source=try require(review.sources.first { $0.candidate.id == usableCandidate.id })
    try expect(source.selectable && !source.recommendationEligible && review.recommendedSources.isEmpty)
    let manual=try await local.engine.createPlan(scanId: usable.id, candidateIds: [usableCandidate.id])
    try expect(manual.installedApplicationCaches == usable.installedApplicationCaches)
    let receipt=try await local.engine.execute(planId: manual.id, confirmedDigest: manual.digest, entryPoint: "generated-partial-cache")
    try expect(receipt.state == "completed" && receipt.items[0].state == "trashed" && receipt.operation == nil)
    let ids=receipt.items.map(\.id)
    let restoreDigest=try await local.engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await local.engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: restoreDigest)
    try expect(restored.allSatisfy { $0.state == "completed" } && local.retainedHashes() == retained)

    let fixture=try InstalledCacheFixture()
    try fixture.files.put("Library/Caches/com.google.Chrome/cache.bin")
    fixture.catalog.set(partial: true)
    let (_, partial)=try await fixture.scan()
    try expect(partial.installedApplicationCaches == nil && partial.issues.contains("installed_application_cache:application_discovery_incomplete"))
    try expect(partial.candidates.first { $0.relativePath == "com.google.Chrome" }?.eligible == true)
    let system=try await fixture.engine.scanKnownLocations()
    try expect(system.issues.contains { $0.locationId == "caches" && $0.code == "application_discovery_incomplete" })
    for issue in [ApplicationCatalogIssue(path: fixture.app.path, code: "source_changed"),
                  ApplicationCatalogIssue(path: fixture.app.appendingPathComponent("Contents/Info.plist").path, code: "io_error"),
                  ApplicationCatalogIssue(path: fixture.app.deletingLastPathComponent().path, code: "source_changed"),
                  ApplicationCatalogIssue(path: fixture.files.workspace.path, code: "resource_limit")] {
        fixture.catalog.set(issues: [issue])
        let (_, blocked)=try await fixture.scan()
        try expect(blocked.installedApplicationCaches == nil && blocked.issues.contains("installed_application_cache:application_discovery_incomplete"))
    }
    for status in ["unavailable", "not_scanned", "unknown"] {
        fixture.catalog.set(sourceStatus: status)
        let (_, blocked)=try await fixture.scan()
        try expect(blocked.installedApplicationCaches == nil)
    }
    // A gap in another source remains visible without claiming a problem in this source.
    fixture.catalog.set(issues: [ApplicationCatalogIssue(path: "/Applications/Unrelated Broken.app", code: "io_error")])
    let (_, otherSource)=try await fixture.scan()
    try expect(try fixture.candidate(otherSource).eligible && otherSource.installedApplicationCaches?.first?.ownershipCoverageIncomplete == true)
    fixture.catalog.set()
    try InstalledCacheFixture.writeApplication(fixture.app.deletingLastPathComponent().appendingPathComponent("Duplicate.app"), identifier: fixture.identifier)
    let (_, duplicate)=try await fixture.scan()
    try expect(duplicate.installedApplicationCaches == nil && duplicate.issues.contains("installed_application_cache:ambiguous_application_owner"))
    try expect(duplicate.candidates.first { $0.relativePath == fixture.identifier }?.eligible != true)

    let fresh=try InstalledCacheFixture(), (_, ready)=try await fresh.scan(), candidate=try fresh.candidate(ready)
    try InstalledCacheFixture.writeApplication(fresh.app.deletingLastPathComponent().appendingPathComponent("New Duplicate.app"), identifier: fresh.identifier)
    try await expectThrows { try await fresh.engine.createPlan(scanId: ready.id, candidateIds: [candidate.id]) }

    let changed=try InstalledCacheFixture(), (_, complete)=try await changed.scan(), completeCandidate=try changed.candidate(complete)
    let completePlan=try await changed.engine.createPlan(scanId: complete.id, candidateIds: [completeCandidate.id])
    changed.catalog.set(issues: [changed.unrelatedIssue])
    try await expectThrows { try await changed.engine.createPlan(scanId: complete.id, candidateIds: [completeCandidate.id]) }
    try await expectThrows { try await changed.engine.execute(planId: completePlan.id, confirmedDigest: completePlan.digest, entryPoint: "generated-complete-to-partial") }
    try expect(try await changed.engine.history().isEmpty)
    let (_, rescanned)=try await changed.scan(), rescannedCandidate=try changed.candidate(rescanned)
    let reviewed=try await changed.engine.createPlan(scanId: rescanned.id, candidateIds: [rescannedCandidate.id])
    try expect(reviewed.installedApplicationCaches?.first?.ownershipCoverageIncomplete == true)
    changed.catalog.set(additions: [try changed.duplicateOwner()], issues: [changed.unrelatedIssue])
    try await expectThrows { try await changed.engine.execute(planId: reviewed.id, confirmedDigest: reviewed.digest, entryPoint: "generated-new-duplicate") }
    changed.catalog.set(issues: [ApplicationCatalogIssue(path: changed.app.path, code: "source_changed")])
    try await expectThrows { try await changed.engine.createPlan(scanId: rescanned.id, candidateIds: [rescannedCandidate.id]) }
    changed.catalog.set()
    let recovered=try await changed.engine.createPlan(scanId: rescanned.id, candidateIds: [rescannedCandidate.id])
    try expect(recovered.installedApplicationCaches?.first?.ownershipCoverageIncomplete == true)

    let invalid=try InstalledCacheFixture(identifier: "invalid_identifier")
    let (_, invalidScan)=try await invalid.scan()
    try expect(invalidScan.installedApplicationCaches == nil && !invalidScan.candidates.contains(where: \.eligible))
    let noMetadata=try InstalledCacheFixture()
    let originalOwner=try noMetadata.catalog.native.application(at: noMetadata.app.path), missingIdentifier="dev.shou.generated.missing-info"
    let missingInfo=ApplicationDefinition(path: noMetadata.app.deletingLastPathComponent().appendingPathComponent("Missing Info.app").path,
        source: originalOwner.source, identity: originalOwner.identity, name: "Missing Info", bundleIdentifier: missingIdentifier,
        version: nil, executableName: nil, infoDigest: nil)
    try noMetadata.files.put("Library/Caches/" + missingIdentifier + "/retain.bin")
    noMetadata.catalog.set(additions: [missingInfo], issues: [noMetadata.unrelatedIssue])
    let (_, missingScan)=try await noMetadata.scan()
    try expect(!((missingScan.installedApplicationCaches ?? []).contains { $0.application.bundleIdentifier == missingIdentifier }))
    try expect(missingScan.candidates.first { $0.relativePath == missingIdentifier }?.eligible != true)
    let apple=try InstalledCacheFixture(identifier: "com.apple.generated-fixture")
    let (_, appleScan)=try await apple.scan()
    try expect(appleScan.installedApplicationCaches == nil && !appleScan.candidates.contains(where: \.eligible))
    let unsupported=ShouEngine(store: fresh.files.store, filesystem: FixtureFileSystem(native: fresh.files.fs, trash: fresh.files.trash),
        applicationActivity: fresh.activity, homeDirectory: fresh.files.workspace)
    let unknown=try await unsupported.scan(locationId: "caches")
    try expect(unknown.issues.contains("installed_application_cache:application_discovery_unavailable"))
    #endif
}

func installedApplicationCachesKeepLegacyRecordsAndBindEvidenceDigests() async throws {
    #if os(macOS)
    let fixture=try InstalledCacheFixture(), (_, snapshot)=try await fixture.scan(), candidate=try fixture.candidate(snapshot)
    let plan=try await fixture.engine.createPlan(scanId: snapshot.id, candidateIds: [candidate.id])
    let evidence=try require(plan.installedApplicationCaches?.first)
    let evidenceBytes=try Codec.encode(evidence)
    try expect(!String(decoding: evidenceBytes, as: UTF8.self).contains("ownership_coverage_incomplete"))
    let decodedEvidence=try Codec.decode(InstalledApplicationCacheEvidence.self, from: evidenceBytes)
    try expect(decodedEvidence.ownershipCoverageIncomplete == nil && Codec.encode(decodedEvidence) == evidenceBytes)
    let oldDynamicBytes=try Codec.encode(plan), oldDynamicPlan=try Codec.decode(CleanupPlan.self, from: oldDynamicBytes)
    try expect(try Codec.encode(oldDynamicPlan) == oldDynamicBytes && oldDynamicPlan.calculatedDigest() == plan.digest)
    var changedCoverage=plan
    changedCoverage.installedApplicationCaches=[InstalledApplicationCacheEvidence(ruleId: evidence.ruleId, application: evidence.application, ownershipCoverageIncomplete: true)]
    try expect(try changedCoverage.calculatedDigest() != plan.calculatedDigest())
    var legacyScan=snapshot; legacyScan.installedApplicationCaches=nil
    let scanBytes=try Codec.encode(legacyScan)
    try expect(!String(decoding: scanBytes, as: UTF8.self).contains("installed_application_caches"))
    let decodedScan=try Codec.decode(ScanSnapshot.self, from: scanBytes)
    try expect(decodedScan.installedApplicationCaches == nil && Codec.encode(decodedScan) == scanBytes)
    var legacyPlan=plan; legacyPlan.installedApplicationCaches=nil
    legacyPlan.digest=""; legacyPlan.state="ready"; legacyPlan.executionId=nil
    let oldBytes=try Codec.encode(legacyPlan), oldDigest=Digest.sha256(oldBytes)
    try expect(!String(decoding: oldBytes, as: UTF8.self).contains("installed_application_caches"))
    let decodedPlan=try Codec.decode(CleanupPlan.self, from: oldBytes)
    try expect(decodedPlan.installedApplicationCaches == nil && decodedPlan.calculatedDigest() == oldDigest)
    try expect(try plan.calculatedDigest() != oldDigest)
    try fixture.files.store.write("scans", id: snapshot.id, data: scanBytes)
    try await expectThrows { try await fixture.engine.createPlan(scanId: snapshot.id, candidateIds: [candidate.id]) }
    #endif
}
