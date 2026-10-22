import Foundation
import ShouCore
import ShouPlatform

private final class SummaryProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var counts=[String: Int](), emitted=[ApplicationSummary]()
    func record(_ key: String) { lock.lock(); defer { lock.unlock() }; counts[key, default: 0] += 1 }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
    func emit(_ summary: ApplicationSummary) { lock.lock(); defer { lock.unlock() }; emitted.append(summary) }
    var values: [ApplicationSummary] { lock.lock(); defer { lock.unlock() }; return emitted }
}
private struct SummaryCatalogFixture: ApplicationCatalogReading {
    let items: [ApplicationDefinition]
    let probe: SummaryProbe
    func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog {
        probe.record("inventory")
        return ApplicationCatalog(checkedAt: Date(), sources: [], items: items, issues: [])
    }
    func application(at path: String) throws -> ApplicationDefinition { throw CheckFailure(description: "Summary must reuse one inventory.") }
    func measureSummary(for application: ApplicationDefinition, budget: ScanBudget, progress: @Sendable (ScanProgress) -> Void) throws -> ApplicationSummaryMeasurement {
        probe.record("measurement")
        if application.name == "unavailable" { throw ShouError("permission_denied", "Generated unavailable application.") }
        progress(ScanProgress(stage: "measuring", entryCount: 1, currentPath: application.path))
        return ApplicationSummaryMeasurement(allocatedBytesEstimate: 8192, owner: application.identity.owner,
            containsForeignOwnedContent: application.name == "foreign", lastUsed: application.name == "ready" ? Date(timeIntervalSince1970: 123456) : nil)
    }
}
private struct SummaryEvidenceFixture: ApplicationUninstallChecking {
    let currentUser: UInt32
    let probe: SummaryProbe
    func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts { throw CheckFailure(description: "Summary must use one activity snapshot.") }
    func facts(for applications: [ApplicationDefinition]) throws -> [String: ApplicationUninstallFacts] {
        probe.record("activity")
        return Dictionary(uniqueKeysWithValues: applications.map {
            ($0.id, ApplicationUninstallFacts(currentUser: currentUser, running: $0.name == "running", currentApplication: $0.name == "self"))
        })
    }
    func containerIdentifier(at path: String) throws -> String { throw CheckFailure(description: "Summary must not inspect associated components.") }
}

func applicationSummariesStreamOneInventoryAndKeepOwnershipConservative() async throws {
    let fixture=try Fixture(), root=try fixture.fs.rootIdentity(fixture.workspace.path), probe=SummaryProbe()
    let source=ApplicationSource(id: "fixture.summary", path: fixture.workspace.path)
    var apps=[ApplicationDefinition]()
    for (index, name) in ["ready", "running", "admin", "protected", "self", "foreign", "admin-without-metadata", "unavailable"].enumerated() {
        var identity=root; identity.inode += UInt64(index + 1)
        if name.hasPrefix("admin") { identity.owner=root.owner == 0 ? 501 : 0 }
        apps.append(ApplicationDefinition(path: fixture.workspace.appendingPathComponent(name + ".app").path,
            source: name == "protected" ? ApplicationSource(id: "system", path: fixture.workspace.path, systemOwned: true) : source,
            identity: identity, name: name, bundleIdentifier: "dev.summary." + name, version: "1.2.3", executableName: "Fixture", infoDigest: name == "admin-without-metadata" ? nil : "fixture"))
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, applicationCatalog: SummaryCatalogFixture(items: apps, probe: probe),
        uninstallEvidence: SummaryEvidenceFixture(currentUser: root.owner, probe: probe))
    let result=try await engine.applicationSummaries(onSummary: { probe.emit($0) })
    try expect(probe.count("inventory") == 1 && probe.count("activity") == 1 && probe.count("measurement") == apps.count)
    try expect(result.catalog.items == apps && result.items.count == apps.count && probe.values.map(\.id) == apps.map(\.id))
    try expect(result.items.map(\.status) == ["ready", "running", "admin-required", "protected", "protected", "admin-required", "unavailable", "unavailable"])
    try expect(result.items[0].lastUsed == Date(timeIntervalSince1970: 123456) && result.items[1].lastUsed == nil)
    try expect(result.items.last?.allocatedBytesEstimate == nil && result.items.last?.issues == ["permission_denied"])
    try expect(try fixture.store.ids("application-reviews").isEmpty && fixture.store.ids("uninstall-plans").isEmpty)
    let task=Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await engine.applicationSummaries()
    }
    do { _ = try await task.value; throw CheckFailure(description: "Summary cancellation must stop before inventory.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(probe.count("inventory") == 1)
}

func nativeApplicationSummaryMeasuresWithoutManifestsOrLinkTraversal() throws {
    #if os(macOS)
    let fixture=try Fixture(), applications=fixture.workspace.appendingPathComponent("Applications"), app=applications.appendingPathComponent("Summary.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.shou.summary", "CFBundleName": "Summary"], format: .binary, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let payload=app.appendingPathComponent("Contents/payload.bin")
    try Data(repeating: 31, count: 8192).write(to: payload)
    try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("outside").path, withDestinationPath: fixture.workspace.path)
    let catalog=NativeApplicationCatalog(sources: [ApplicationSource(id: "fixture.apps", path: applications.path)])
    let definition=try catalog.application(at: app.path)
    let measured=try catalog.measureSummary(for: definition, budget: ScanBudget(), progress: { _ in })
    let tree=try fixture.fs.inspectTarget(app.path, budget: ScanBudget(), cancelled: { false })
    let expected=StorageIndex(entries: tree.entries).nodes["."]?.allocatedBytes
    try expect(measured.allocatedBytesEstimate == expected && measured.issues.isEmpty && !measured.containsForeignOwnedContent)
    try FileManager.default.linkItem(at: payload, to: app.appendingPathComponent("Contents/alias.bin"))
    let linked=try catalog.measureSummary(for: catalog.application(at: app.path), budget: ScanBudget(), progress: { _ in })
    let linkedTree=try fixture.fs.inspectTarget(app.path, budget: ScanBudget(), cancelled: { false })
    try expect(linked.allocatedBytesEstimate == StorageIndex(entries: linkedTree.entries).nodes["."]?.allocatedBytes)
    try expect(linked.issues == ["multiply_linked_content"])
    let bounded=try catalog.measureSummary(for: catalog.application(at: app.path), budget: ScanBudget(maxEntries: 2), progress: { _ in })
    try expect(bounded.issues.contains("resource_limit"))
    #endif
}
