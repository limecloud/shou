import Foundation
import ShouCore
import ShouPlatform

private final class CloseFixtureController: ApplicationClosing, ApplicationUninstallChecking, @unchecked Sendable {
    private let lock=NSLock()
    private var active=true
    private var requests=0
    private var requestedIDs=[String]()
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return requestedIDs }
    var permitsClose=true
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func requestClose(_ application: ApplicationDefinition) async throws { close(application.id) }
    private func close(_ id: String) { lock.lock(); defer { lock.unlock() }; requests += 1; requestedIDs.append(id); if permitsClose { active=false } }
    func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts {
        lock.lock(); defer { lock.unlock() }
        return .init(currentUser: application.identity.owner, running: active, currentApplication: false)
    }
    func containerIdentifier(at path: String) throws -> String { throw ShouError("capability_unavailable", "No generated containers.") }
}

func applicationClosingVerifiesIdentityAndReportsRemainingOwners() async throws {
    let fixture=try Fixture(), controller=CloseFixtureController()
    let app=fixture.workspace.appendingPathComponent("Applications/Fixture.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let info=try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"dev.shou.close-fixture", "CFBundleName":"Close Fixture", "CFBundleExecutable":"Fixture"], format: .xml, options: 0)
    try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data("fixture".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Fixture"))
    let catalog=NativeApplicationCatalog(homeDirectory: fixture.workspace)
    let definition=try catalog.application(at: app.path)
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, applicationCatalog: catalog, uninstallEvidence: controller, homeDirectory: fixture.workspace)
    let plan=try await engine.applicationClosePlan(applications: [definition])
    try await expectThrows { try await engine.closeApplications(planId: plan.id, confirmedDigest: "wrong", controller: controller) }
    try expect(controller.count == 0)
    let result=try await engine.closeApplications(planId: plan.id, confirmedDigest: plan.digest, controller: controller, timeoutSeconds: 0)
    try expect(result.map(\.state) == ["closed"] && controller.count == 1)
    try expect(try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) == info)
    let refusing=CloseFixtureController(); refusing.permitsClose=false
    let other=ShouEngine(store: fixture.store, filesystem: fixture.fs, applicationCatalog: catalog, uninstallEvidence: refusing, homeDirectory: fixture.workspace)
    let retry=try await other.applicationClosePlan(applications: [definition])
    let remaining=try await other.closeApplications(planId: retry.id, confirmedDigest: retry.digest, controller: refusing, timeoutSeconds: 0)
    try expect(remaining.map(\.state) == ["still_running"] && refusing.count == 1)
    try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let changed=try await other.closeApplications(planId: retry.id, confirmedDigest: retry.digest, controller: refusing, timeoutSeconds: 0)
    try expect(changed.map(\.state) == ["failed"] && refusing.count == 1)
}

func applicationClosingOnlyRequestsExplicitlySelectedApplications() async throws {
    let fixture=try Fixture(), controller=CloseFixtureController()
    let catalog=NativeApplicationCatalog(homeDirectory: fixture.workspace)
    var apps=[ApplicationDefinition]()
    for name in ["First", "Second"] {
        let app=fixture.workspace.appendingPathComponent("Applications/" + name + ".app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let data=try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"dev.shou.close-" + name.lowercased(), "CFBundleName":name, "CFBundleExecutable":name], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("generated fixture".utf8).write(to: app.appendingPathComponent("Contents/MacOS/" + name))
        apps.append(try catalog.application(at: app.path))
    }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, applicationCatalog: catalog, uninstallEvidence: controller, homeDirectory: fixture.workspace)
    let plan=try await engine.applicationClosePlan(applications: [apps[1]])
    let results=try await engine.closeApplications(planId: plan.id, confirmedDigest: plan.digest, controller: controller, timeoutSeconds: 0)
    try expect(controller.ids == [apps[1].id] && results.map(\.applicationId) == [apps[1].id])
    for app in apps { try expect(try catalog.application(at: app.path) == app) }
}
