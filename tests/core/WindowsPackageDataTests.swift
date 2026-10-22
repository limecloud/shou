import Foundation
import ShouCore
import ShouPlatform

private func packageDataFixtureApp(_ index: Int, family: String? = nil, system: Bool = false, kind: String = "msix") throws -> RegisteredApplication {
    let source=kind=="msix" ? "windows.user_packages" : "windows.user_uninstall64",registration="Generated.App\(index)_1.0.0.0_x64__fixture1234"
    let value: [String: Any]=["id": Digest.sha256(Data((source+"\0"+registration).utf8)),"source_id": source,"registration": registration,
        "name": "Generated MSIX \(index)","kind": kind,"system_component": system,"package_family_name": family ?? "Generated.App\(index)_fixture1234",
        "evidence_digest": String(repeating: "a",count: 64)]
    return try Codec.decode(RegisteredApplication.self,from: JSONSerialization.data(withJSONObject: value))
}
private final class PackageDataFixture: WindowsPackageDataRunning,@unchecked Sendable {
    let files: Fixture
    var apps: [RegisteredApplication]
    var partial=false, changed=false, running=false, wrongOwner=false, invalidPath=false
    var mode="completed"
    var onReview: (@Sendable () -> Void)?
    var onClear: (@Sendable () -> Void)?
    private(set) var starts=[String]()
    init(apps: [RegisteredApplication]? = nil) throws {
        files=try Fixture(); self.apps=try apps ?? [packageDataFixtureApp(0),packageDataFixtureApp(1)]
        for app in self.apps { try Data("generated personal data".utf8).write(to: files.workspace.appendingPathComponent(app.id)) }
        try Data("keep adjacent user file".utf8).write(to: files.workspace.appendingPathComponent("retained.txt"))
    }
    func inventory() throws -> RegisteredApplicationCatalog {
        .init(checkedAt: Date(),sources: [.init(source: .init(id: "windows.user_packages",path: "current_user:PackageManager"),
            status: partial ? "partial" : "complete",entryCount: apps.count,applicationCount: apps.count)],items: apps,issues: [])
    }
    func review(_ application: RegisteredApplication) throws -> WindowsPackageDataAction {
        onReview?()
        if running { throw ShouError("application_running","Generated running owner") }
        var identity=try files.fs.rootIdentity(files.workspace.path)
        identity.windowsIdentity = .init(volume: identity.device,fileId: String(format: "%032llx",identity.inode),ownerSid: "S-1-5-21-\(identity.owner)")
        return .init(application: wrongOwner ? apps[1] : application,
            dataPath: "C:/generated/AppData/Local/Packages/"+(invalidPath ? "../other" : application.packageFamilyName!),dataIdentity: identity,
            actionDigest: String(repeating: changed ? "b" : "a",count: 64))
    }
    func clear(_ action: WindowsPackageDataAction,timeoutSeconds: Double) throws -> WindowsPackageDataInvocation {
        try expect(timeoutSeconds>=1 && timeoutSeconds<=120)
        if mode=="refused" { return .init(started: false,issue: "package_data_changed") }
        starts.append(action.application.id); onClear?()
        if mode=="throw" { throw ShouError("package_data_result_unavailable","private generated failure must not enter receipts") }
        if mode=="timeout" { return .init(started: true,issue: "package_data_timeout") }
        if mode=="incomplete" { return .init(started: true) }
        // The generated owner clears only its own fixture file. The real
        // implementation delegates to Windows; no MSIX is touched by this test.
        try Data().write(to: files.workspace.appendingPathComponent(action.application.id))
        return .init(started: true,completed: true)
    }
}
private final class PackageDataClock: @unchecked Sendable {
    private let lock=NSLock();private var date=Date(timeIntervalSince1970: 1_800_000_000)
    func read() -> Date { lock.lock();defer { lock.unlock() };return date }
    func expire() { lock.lock();defer { lock.unlock() };date.addTimeInterval(121) }
}
private final class PackageDataJournal: RecordStore,@unchecked Sendable {
    let wrapped: any RecordStore
    var failAt=0
    private var writes=0
    init(_ store: any RecordStore) { wrapped=store }
    func read(_ collection: String,id: String) throws -> Data? { try wrapped.read(collection,id: id) }
    func ids(_ collection: String) throws -> [String] { try wrapped.ids(collection) }
    func lock() throws -> any StoreLease { try wrapped.lock() }
    func write(_ collection: String,id: String,data: Data) throws {
        if collection=="windows-package-data-history" { writes+=1;if writes==failAt { throw ShouError("generated_write_failure","Generated durable-intent failure") } }
        try wrapped.write(collection,id: id,data: data)
    }
}
func windowsPackageDataRequiresCurrentMSIXScopeAndSeparateConsent() async throws {
    let runner=try PackageDataFixture(),service=WindowsPackageDataService(runner: runner,store: runner.files.store)
    let scan=try await service.scan(),ids=runner.apps.map(\.id)
    try await expectThrows { try await service.createPlan(scanId: scan.id,applicationIds: ids,includeUserData: false) }
    for invalid in [[],["unknown"],[ids[0],ids[0]],Array(repeating: ids[0],count: 21)] {
        try await expectThrows { try await service.createPlan(scanId: scan.id,applicationIds: invalid,includeUserData: true) }
    }
    for mode in ["partial","running","owner","path"] {
        runner.partial=mode=="partial";runner.running=mode=="running";runner.wrongOwner=mode=="owner";runner.invalidPath=mode=="path"
        let current=try await service.scan()
        try await expectThrows { try await service.createPlan(scanId: current.id,applicationIds: [ids[0]],includeUserData: true) }
    }
    for app in [try packageDataFixtureApp(0,system: true),try packageDataFixtureApp(0,kind: "desktop")] {
        let invalid=try PackageDataFixture(apps: [app]),service=WindowsPackageDataService(runner: invalid,store: invalid.files.store),scan=try await service.scan()
        try await expectThrows { try await service.createPlan(scanId: scan.id,applicationIds: [app.id],includeUserData: true) }
    }
    let duplicates=try PackageDataFixture(apps: [packageDataFixtureApp(0),packageDataFixtureApp(1,family: "Generated.App0_fixture1234")])
    let duplicateService=WindowsPackageDataService(runner: duplicates,store: duplicates.files.store),duplicateScan=try await duplicateService.scan()
    try await expectThrows { try await duplicateService.createPlan(scanId: duplicateScan.id,applicationIds: duplicates.apps.map(\.id),includeUserData: true) }
    try expect(runner.starts.isEmpty && (try runner.files.store.ids("windows-package-data-history")).isEmpty)
}
func windowsPackageDataConsumesConsentAndRetainsOwnerResults() async throws {
    let runner=try PackageDataFixture(),service=WindowsPackageDataService(runner: runner,store: runner.files.store)
    let scan=try await service.scan(),plan=try await service.createPlan(scanId: scan.id,applicationIds: runner.apps.map(\.id),includeUserData: true)
    try await expectThrows { try await service.execute(planId: plan.id,confirmedDigest: "wrong") }
    let engine=ShouEngine(store: runner.files.store,filesystem: runner.files.fs)
    _=try await engine.collectRecords(policy: .init(maxAgeSeconds: 0,maxBytes: 0,graceSeconds: 0))
    try expect(try runner.files.store.read("windows-package-data-plans",id: plan.id) != nil)
    let receipt=try await service.execute(planId: plan.id,confirmedDigest: plan.digest)
    try expect(receipt.state=="completed" && receipt.items.allSatisfy { $0.state=="completed" } && runner.starts.count==2)
    for app in runner.apps { try expect(try Data(contentsOf: runner.files.workspace.appendingPathComponent(app.id)).isEmpty) }
    try expect(try String(contentsOf: runner.files.workspace.appendingPathComponent("retained.txt"),encoding: .utf8)=="keep adjacent user file")
    try await expectThrows { try await service.execute(planId: plan.id,confirmedDigest: plan.digest) }
    _=try await engine.collectRecords(policy: .init(maxAgeSeconds: 0,maxBytes: 0,graceSeconds: 0))
    let history=try await service.history()
    try expect(try runner.files.store.read("windows-package-data-plans",id: plan.id)==nil && history.count==1)
}
func windowsPackageDataRechecksWholeBatchActivityAndExpiry() async throws {
    for mode in ["changed","running","expired"] {
        let runner=try PackageDataFixture(),clock=PackageDataClock(),service=WindowsPackageDataService(runner: runner,store: runner.files.store,now: { clock.read() })
        let scan=try await service.scan(),plan=try await service.createPlan(scanId: scan.id,applicationIds: runner.apps.map(\.id),includeUserData: true)
        runner.changed=mode=="changed";runner.running=mode=="running"
        if mode=="expired" { runner.onReview={ clock.expire() } }
        try await expectThrows { try await service.execute(planId: plan.id,confirmedDigest: plan.digest) }
        try expect(runner.starts.isEmpty && (try runner.files.store.ids("windows-package-data-history")).isEmpty)
    }
    let runner=try PackageDataFixture(),clock=PackageDataClock(),service=WindowsPackageDataService(runner: runner,store: runner.files.store,now: { clock.read() })
    let scan=try await service.scan(),plan=try await service.createPlan(scanId: scan.id,applicationIds: runner.apps.map(\.id),includeUserData: true)
    runner.onClear={ clock.expire() }
    let receipt=try await service.execute(planId: plan.id,confirmedDigest: plan.digest)
    try expect(runner.starts.count==1 && receipt.state=="partial" && receipt.items[1].state=="not_started" && receipt.items[1].error=="confirmation_expired")
}
func windowsPackageDataPreservesUncertainOutcomesAndDurableIntent() async throws {
    for mode in ["refused","throw","timeout","incomplete"] {
        let runner=try PackageDataFixture(),service=WindowsPackageDataService(runner: runner,store: runner.files.store)
        let scan=try await service.scan(),plan=try await service.createPlan(scanId: scan.id,applicationIds: runner.apps.map(\.id),includeUserData: true)
        runner.mode=mode
        let receipt=try await service.execute(planId: plan.id,confirmedDigest: plan.digest)
        try expect(receipt.state != "completed" && runner.starts.count==(mode=="refused" ? 0 : 1) && receipt.items[1].state=="not_started")
        try expect(receipt.items[0].state==(mode=="refused" ? "not_started" : "needs_verification"))
        try expect(!String(decoding: Codec.encode(receipt),as: UTF8.self).contains("private generated failure"))
        try await expectThrows { try await service.execute(planId: plan.id,confirmedDigest: plan.digest) }
    }
    for failure in [1,2,3] {
        let runner=try PackageDataFixture(),store=PackageDataJournal(runner.files.store),service=WindowsPackageDataService(runner: runner,store: store)
        let scan=try await service.scan(),plan=try await service.createPlan(scanId: scan.id,applicationIds: runner.apps.map(\.id),includeUserData: true)
        store.failAt=failure
        try await expectThrows { try await service.execute(planId: plan.id,confirmedDigest: plan.digest) }
        try expect(runner.starts.count==(failure==3 ? 1 : 0))
        if failure>=2 {
            try await expectThrows { try await service.execute(planId: plan.id,confirmedDigest: plan.digest) }
            try expect(try await service.history().count==1)
        }
    }
}
