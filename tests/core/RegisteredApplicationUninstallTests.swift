import Foundation
import ShouCore
import ShouPlatform

private func installerFixtureApp(_ index: Int) throws -> RegisteredApplication {
    let kind=["desktop", "msi", "msix"][index]
    let source=["windows.user_uninstall64", "windows.machine_uninstall64", "windows.user_packages"][index]
    let registration=index == 2 ? "Fixture.App_1.0.0.0_x64__fixture1234" : (index == 0 ? "HKEY_CURRENT_USER" : "HKEY_LOCAL_MACHINE") + "\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Fixture"
    let json: [String: Any]=["id": Digest.sha256(Data((source + "\0" + registration).utf8)), "source_id": source, "registration": registration,
        "name": "Generated application \(index)", "kind": kind, "system_component": false,
        "uninstall_available": index == 2 ? NSNull() : true, "package_family_name": index == 2 ? "Fixture.App_fixture1234" : NSNull(),
        "evidence_digest": String(repeating: "a", count: 64)]
    return try Codec.decode(RegisteredApplication.self, from: JSONSerialization.data(withJSONObject: json))
}
private final class RegisteredInstallerFixture: RegisteredApplicationUninstallRunning, @unchecked Sendable {
    let apps: [RegisteredApplication]
    private var removed=Set<String>()
    var changedId: String?
    var unknownResult=false, partialSource=false, refuseAtLaunch=false
    var onReview: (@Sendable () -> Void)?
    var onUninstall: (@Sendable () -> Void)?
    private(set) var starts=[String]()
    init() throws { apps=try (0...2).map(installerFixtureApp) }
    func inventory(options: ApplicationCatalogOptions) throws -> RegisteredApplicationCatalog {
        let sources=apps.map { app in ApplicationSourceCoverage(source: .init(id: app.sourceId, path: "generated", systemOwned: app.sourceId.contains("machine")),
            status: partialSource ? "partial" : "complete", entryCount: removed.contains(app.id) ? 0 : 1, applicationCount: removed.contains(app.id) ? 0 : 1) }
        return .init(checkedAt: Date(), sources: sources, items: apps.filter { !removed.contains($0.id) }, issues: [])
    }
    func review(_ application: RegisteredApplication) throws -> RegisteredUninstallAction {
        onReview?()
        return .init(application: application, route: application.kind, executablePath: application.kind == "msix" ? nil : "C:/generated/uninstall.exe",
            actionDigest: String(repeating: application.id == changedId ? "b" : "a", count: 64))
    }
    func uninstall(_ action: RegisteredUninstallAction, timeoutSeconds: Double) throws -> RegisteredUninstallInvocation {
        if refuseAtLaunch { return .init(started: false, issue: "installer_changed") }
        starts.append(action.application.id);onUninstall?()
        if unknownResult { throw ShouError("installer_failed", "private generated diagnostic must not enter receipts") }
        removed.insert(action.application.id)
        return .init(started: true, exitCode: 0, restartRequired: action.route == "msi")
    }
}
private final class InstallerClock: @unchecked Sendable {
    private let lock=NSLock()
    // This value rounds forward at the Unix epoch precision used by Codec.
    private var date=Date(timeIntervalSinceReferenceDate: 800_000_000.000_000_4)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func expire() { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(901) }
}
private final class InstallerJournalStore: RecordStore, @unchecked Sendable {
    let wrapped: any RecordStore
    var failingWrite=0
    private var writes=0
    init(_ store: any RecordStore) { wrapped=store }
    func read(_ collection: String, id: String) throws -> Data? { try wrapped.read(collection, id: id) }
    func write(_ collection: String, id: String, data: Data) throws {
        if collection == "registered-uninstall-history" { writes += 1; if writes == failingWrite { throw ShouError("generated_write_failure", "Generated journal failure") } }
        try wrapped.write(collection, id: id, data: data)
    }
    func ids(_ collection: String) throws -> [String] { try wrapped.ids(collection) }
    func lock() throws -> any StoreLease { try wrapped.lock() }
}

func registeredUninstallVerifiesAllInstallerRoutesAndConsumesConsent() async throws {
    let fixture=try Fixture(), runner=try RegisteredInstallerFixture()
    let service=RegisteredApplicationUninstallService(runner: runner, store: fixture.store)
    let scan=try await service.scan(), plan=try await service.createPlan(scanId: scan.id, applicationIds: runner.apps.map(\.id))
    try expect(plan.actions.map(\.route) == ["desktop", "msi", "msix"])
    try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: "wrong") }
    try expect(runner.starts.isEmpty)
    let receipt=try await service.execute(planId: plan.id, confirmedDigest: plan.digest)
    try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "completed" })
    try expect(receipt.items[1].restartRequired && runner.starts.count == 3)
    try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    try expect(try await service.history().count == 1)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.path))
}

func registeredUninstallRefusesStaleBatchesAndExpiredReviews() async throws {
    let fixture=try Fixture(), runner=try RegisteredInstallerFixture(), clock=InstallerClock()
    let service=RegisteredApplicationUninstallService(runner: runner, store: fixture.store, now: { clock.read() })
    let scan=try await service.scan(), ids=runner.apps.map(\.id)
    for invalid in [[], [ids[0], ids[0]], Array(repeating: ids[0], count: 21), ["unknown"]] {
        try await expectThrows { try await service.createPlan(scanId: scan.id, applicationIds: invalid) }
    }
    let plan=try await service.createPlan(scanId: scan.id, applicationIds: ids)
    runner.changedId=ids[1]
    try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    try expect(runner.starts.isEmpty && (try fixture.store.ids("registered-uninstall-history")).isEmpty)
    runner.changedId=nil;runner.onReview={ clock.expire() }
    try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    try expect(runner.starts.isEmpty && (try fixture.store.ids("registered-uninstall-history")).isEmpty)
}

func registeredUninstallKeepsUnknownAndUnstartedOutcomesSeparate() async throws {
    for mode in ["unknown", "partial", "launch-refused", "expiry"] {
        let fixture=try Fixture(), runner=try RegisteredInstallerFixture(), clock=InstallerClock()
        let service=RegisteredApplicationUninstallService(runner: runner, store: fixture.store, now: { clock.read() })
        let scan=try await service.scan(), plan=try await service.createPlan(scanId: scan.id, applicationIds: runner.apps.map(\.id))
        runner.unknownResult=mode == "unknown"; runner.partialSource=mode == "partial"; runner.refuseAtLaunch=mode == "launch-refused"
        if mode == "expiry" { runner.onUninstall={ clock.expire() } }
        let receipt=try await service.execute(planId: plan.id, confirmedDigest: plan.digest)
        try expect(receipt.state != "completed" && receipt.items.dropFirst().allSatisfy { $0.state == "not_started" })
        try expect(runner.starts.count == (mode == "launch-refused" ? 0 : 1))
        try expect(!String(decoding: Codec.encode(receipt), as: UTF8.self).contains("private generated diagnostic"))
        try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    }
    let fixture=try Fixture(), runner=try RegisteredInstallerFixture(), service=RegisteredApplicationUninstallService(runner: runner, store: fixture.store)
    let scan=try await service.scan(), plan=try await service.createPlan(scanId: scan.id, applicationIds: runner.apps.map(\.id))
    let task=Task { while !Task.isCancelled { await Task.yield() }; return try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
    task.cancel();try await expectThrows { try await task.value }
    try expect(runner.starts.isEmpty && (try fixture.store.ids("registered-uninstall-history")).isEmpty)
}

func registeredUninstallRequiresDurableIntentBeforeEveryInstaller() async throws {
    for failure in [1, 3] {
        let fixture=try Fixture(), runner=try RegisteredInstallerFixture(), store=InstallerJournalStore(fixture.store)
        let service=RegisteredApplicationUninstallService(runner: runner, store: store)
        let scan=try await service.scan(), plan=try await service.createPlan(scanId: scan.id, applicationIds: runner.apps.map(\.id))
        store.failingWrite=failure
        try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
        try expect(runner.starts.count == (failure == 1 ? 0 : 1))
        if failure == 3 {
            let history=try await service.history()
            try expect(history.count == 1 && history[0].items[0].state == "executing" && history[0].items[1].state == "not_started")
            try await expectThrows { try await service.execute(planId: plan.id, confirmedDigest: plan.digest) }
        }
    }
}

func registeredUninstallMaintenancePreservesActivePlansAndReceipts() async throws {
    let fixture=try Fixture(), runner=try RegisteredInstallerFixture()
    let service=RegisteredApplicationUninstallService(runner: runner, store: fixture.store)
    let scan=try await service.scan(), plan=try await service.createPlan(scanId: scan.id, applicationIds: [runner.apps[0].id])
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    _ = try await engine.collectRecords(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    try expect(try fixture.store.read("registered-uninstall-plans", id: plan.id) != nil)
    let receipt=try await service.execute(planId: plan.id, confirmedDigest: plan.digest)
    _ = try await engine.collectRecords(policy: .init(maxAgeSeconds: 0, maxBytes: 0, graceSeconds: 0))
    try expect(try fixture.store.read("registered-uninstall-history", id: receipt.id) != nil)
    try expect(try fixture.store.read("registered-app-scans", id: scan.id) != nil)
}
