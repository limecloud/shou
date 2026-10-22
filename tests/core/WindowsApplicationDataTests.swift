import Foundation
import ShouCore
import ShouPlatform

private struct WindowsDataFixtureFS: PlatformFileSystem {
    let native=NativeFileSystem()
    var platform: String { "windows" }
    var supportsTrash: Bool { false }
    func normalizedPath(_ path: String) throws -> String { path }
    func entry(_ raw: FileEntry) -> FileEntry {
        var value=raw
        value.windowsIdentity = .init(volume: raw.device,fileId: String(format: "%032llx",raw.inode),ownerSid: "S-1-5-21-\(raw.owner)")
        return value
    }
    func rootIdentity(_ path: String) throws -> FileEntry { entry(try native.rootIdentity(path)) }
    func inspect(_ path: String,budget: ScanBudget,cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        let tree=try native.inspect(path,budget: budget,cancelled: cancelled)
        return .init(entries: tree.entries.map(entry),complete: tree.complete,issues: tree.issues,caseSensitive: false)
    }
    func inspectTarget(_ path: String,budget: ScanBudget,cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        let tree=try native.inspectTarget(path,budget: budget,cancelled: cancelled)
        return .init(entries: tree.entries.map(entry),complete: tree.complete,issues: tree.issues,caseSensitive: false)
    }
    func targetAvailability(_ path: String) -> LocationAvailability { native.locationAvailability(path) }
    func locationAvailability(_ path: String) -> LocationAvailability { native.locationAvailability(path) }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String,expected: [FileEntry]) throws -> TrashResult { throw ShouError("unsupported_platform","Fixture only supports permanent removal.") }
    func restore(_ path: String,to destination: String,expected: [FileEntry]) throws { throw ShouError("unsupported_platform","Fixture cannot restore.") }
    func purge(_ path: String,expected: [FileEntry]) throws {
        try native.purge(path,expected: expected.map { var copy=$0;copy.windowsIdentity=nil;return copy })
    }
}
private final class DataPresence: WindowsApplicationDataChecking,@unchecked Sendable {
    private let lock=NSLock()
    private var registered=false,running=false,partial=false
    func change(registered: Bool = false,running: Bool = false,partial: Bool = false) { lock.lock();defer { lock.unlock() };self.registered=registered;self.running=running;self.partial=partial }
    func read() throws -> WindowsApplicationDataPresence {
        lock.lock();defer { lock.unlock() }
        let ids=["windows.user_uninstall64","windows.user_uninstall32","windows.machine_uninstall64","windows.machine_uninstall32","windows.user_packages"]
        var items=[RegisteredApplication]()
        if registered {
            let value: [String: Any]=["id": Digest.sha256(Data((ids[0]+"\0fixture").utf8)),"source_id": ids[0],"registration": "fixture","name": "Discord","kind": "desktop","system_component": false,"evidence_digest": String(repeating: "a",count: 64)]
            items=[try Codec.decode(RegisteredApplication.self,from: JSONSerialization.data(withJSONObject: value))]
        }
        let sources=ids.enumerated().map { index,id in ApplicationSourceCoverage(source: .init(id: id,path: id),status: partial && index==0 ? "partial" : "complete",entryCount: index==0 ? items.count : 0,applicationCount: index==0 ? items.count : 0) }
        return .init(catalog: .init(checkedAt: Date(),sources: sources,items: items,issues: []),runningOwnerIds: running ? ["com.hnc.Discord"] : [])
    }
}
private struct DataFixture {
    let fixture: Fixture
    let home: URL
    let data: URL
    let sibling: URL
    let engine: ShouEngine
    let presence=DataPresence()
    init(now: @escaping @Sendable () -> Date = { Date() }) throws {
        let f=try Fixture();fixture=f;home=f.base.appendingPathComponent("generated-home")
        data=home.appendingPathComponent("AppData/Roaming/discord")
        sibling=home.appendingPathComponent("AppData/Roaming/unrelated")
        try FileManager.default.createDirectory(at: data,withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling,withIntermediateDirectories: true)
        try Data("generated personal data".utf8).write(to: data.appendingPathComponent("local.db"))
        try Data("keep sibling".utf8).write(to: sibling.appendingPathComponent("keep.txt"))
        engine=ShouEngine(store: f.store,filesystem: WindowsDataFixtureFS(),homeDirectory: home,now: now)
    }
    func plan() async throws -> WindowsApplicationDataPlan {
        let review=try await engine.reviewWindowsApplicationData(presence: presence)
        return try await engine.createWindowsApplicationDataPlan(reviewId: review.id,componentIds: review.components.map(\.id),includeUserData: true)
    }
}

func windowsApplicationDataReviewsInstalledAndAbsentOwnersWithSeparateConsent() async throws {
    let f=try DataFixture()
    let review=try await f.engine.reviewWindowsApplicationData(presence: f.presence)
    try expect(review.components.count==1 && review.components[0].eligible && !review.components[0].registered)
    try expect(review.components[0].path==f.data.path && review.limitations.contains("all_components_contain_personal_data"))
    for ids in [[],review.components.map(\.id)+review.components.map(\.id),["unknown"]] {
        try await expectThrows { try await f.engine.createWindowsApplicationDataPlan(reviewId: review.id,componentIds: ids,includeUserData: true) }
    }
    try await expectThrows { try await f.engine.createWindowsApplicationDataPlan(reviewId: review.id,componentIds: review.components.map(\.id),includeUserData: false) }
    f.presence.change(registered: true)
    try expect(try await f.engine.reviewWindowsApplicationData(presence: f.presence).components.isEmpty)
    let installed=try await f.engine.reviewWindowsApplicationData(presence: f.presence,leftoversOnly: false)
    try expect(installed.components.count==1 && installed.components[0].registered && installed.components[0].eligible)
    f.presence.change(running: true)
    let running=try await f.engine.reviewWindowsApplicationData(presence: f.presence)
    try expect(running.components[0].reasons.contains("application_running") && !running.components[0].eligible)
    f.presence.change(partial: true)
    try await expectThrows { try await f.engine.reviewWindowsApplicationData(presence: f.presence) }
    try expect(try f.fixture.store.ids("history").isEmpty && FileManager.default.fileExists(atPath: f.data.path))
}

func windowsApplicationDataExecutesExactReviewedManifestAndPreservesReceipts() async throws {
    let f=try DataFixture(),plan=try await f.plan()
    _=try await f.engine.collectRecords(policy: .init(maxAgeSeconds: 0,maxBytes: 0,graceSeconds: 0))
    try expect(try f.fixture.store.read("windows-app-data-plans",id: plan.id) != nil)
    try expect(try f.fixture.store.ids("windows-app-data-reviews").isEmpty)
    try await expectThrows { try await f.engine.executeWindowsApplicationData(planId: plan.id,confirmedDigest: "wrong",presence: f.presence,entryPoint: "test") }
    let receipt=try await f.engine.executeWindowsApplicationData(planId: plan.id,confirmedDigest: plan.digest,presence: f.presence,entryPoint: "test")
    try expect(receipt.state=="completed" && receipt.operation=="windows_application_data_cleanup" && receipt.items.count==1 && receipt.items[0].state=="purged")
    try expect(receipt.items[0].windowsApplicationDataOrigin?.ownerId=="com.hnc.Discord" && receipt.items[0].uninstallOrigin==nil)
    try expect(!FileManager.default.fileExists(atPath: f.data.path) && FileManager.default.fileExists(atPath: f.sibling.appendingPathComponent("keep.txt").path))
    try expect(try await f.engine.inspectHistory(executionId: receipt.id).items.count==1)
    try await expectThrows { try await f.engine.executeWindowsApplicationData(planId: plan.id,confirmedDigest: plan.digest,presence: f.presence,entryPoint: "test") }
    _=try await f.engine.collectRecords(policy: .init(maxAgeSeconds: 0,maxBytes: 0,graceSeconds: 0))
    try expect(try f.fixture.store.read("windows-app-data-plans",id: plan.id) == nil)
    try expect(try await f.engine.inspectHistory(executionId: receipt.id).items.count==1)
}

func windowsApplicationDataRechecksRegistrationActivityContentAndExclusions() async throws {
    for change in ["registered","running","partial","content","excluded","linked","parent"] {
        let f=try DataFixture(),plan=try await f.plan()
        switch change {
        case "registered": f.presence.change(registered: true)
        case "running": f.presence.change(running: true)
        case "partial": f.presence.change(partial: true)
        case "content": try Data("changed since review".utf8).write(to: f.data.appendingPathComponent("local.db"))
        case "excluded": _=try await f.engine.setGlobalExclusion(pattern: "AppData/Roaming/discord/**",remove: false)
        case "linked": try FileManager.default.linkItem(at: f.data.appendingPathComponent("local.db"),to: f.sibling.appendingPathComponent("linked.db"))
        default:
            try FileManager.default.moveItem(at: f.data.deletingLastPathComponent(),to: f.home.appendingPathComponent("AppData/retained-parent"))
            try FileManager.default.createDirectory(at: f.data,withIntermediateDirectories: true)
            try Data("generated personal data".utf8).write(to: f.data.appendingPathComponent("local.db"))
        }
        try await expectThrows { try await f.engine.executeWindowsApplicationData(planId: plan.id,confirmedDigest: plan.digest,presence: f.presence,entryPoint: "test") }
        try expect(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("local.db").path) && (try f.fixture.store.ids("history")).isEmpty)
    }
}

func windowsApplicationDataScopeRejectsInstallationsSharedParentsAndForgedPlans() async throws {
    let home=URL(fileURLWithPath: "/C:/Users/fixture")
    let access=try WindowsApplicationDataAccess(homeDirectory: home)
    for owner in WindowsApplicationDataOwner.all {
        for path in owner.paths(homeDirectory: home) {
            try expect(access.permitsTarget(path) && access.permitsTarget(path.replacingOccurrences(of: "/",with: "\\").uppercased()))
            try expect(!access.permitsTarget(path+"/child") && !access.permitsTarget(path+"-other"))
        }
    }
    for path in ["C:/Users/fixture/AppData/Roaming","C:/Users/fixture/AppData/Local/Discord","C:/Users/fixture/AppData/Local/Programs","C:/Users/fixture/AppData/Local/Google","C:/Users/fixture/AppData/Roaming/discord/../other","C:/Users/fixture/AppData/Roaming/discord:stream"] { try expect(!access.permitsTarget(path)) }
    let f=try DataFixture(),plan=try await f.plan()
    var value=try JSONSerialization.jsonObject(with: Codec.encode(plan)) as! [String: Any]
    var components=value["components"] as! [[String: Any]];components[0]["path"]=f.sibling.path;value["components"]=components
    var forged=try Codec.decode(WindowsApplicationDataPlan.self,from: JSONSerialization.data(withJSONObject: value));forged.digest=try forged.calculatedDigest()
    try f.fixture.store.write("windows-app-data-plans",id: forged.id,data: Codec.encode(forged))
    try await expectThrows { try await f.engine.executeWindowsApplicationData(planId: forged.id,confirmedDigest: forged.digest,presence: f.presence,entryPoint: "test") }
    try expect(FileManager.default.fileExists(atPath: f.sibling.path) && FileManager.default.fileExists(atPath: f.data.path))
    let clock=DataClock(),expired=try DataFixture(now: { clock.date })
    let expiredPlan=try await expired.plan();clock.advance()
    try await expectThrows { try await expired.engine.executeWindowsApplicationData(planId: expiredPlan.id,confirmedDigest: expiredPlan.digest,presence: expired.presence,entryPoint: "test") }
    try expect(FileManager.default.fileExists(atPath: expired.data.path) && (try expired.fixture.store.ids("history")).isEmpty)
}

private final class DataClock: @unchecked Sendable {
    private let lock=NSLock()
    private var value=Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.lock();defer { lock.unlock() };return value }
    func advance() { lock.lock();defer { lock.unlock() };value=value.addingTimeInterval(121) }
}
