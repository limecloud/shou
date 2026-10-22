import Foundation
import ShouCore
import ShouPlatform

private let windowsUserStartupSources=["windows.user_run", "windows.user_run_once", "windows.user_startup", "windows.scheduled_tasks"]
private let windowsMachineStartupSources=["windows.machine_run64", "windows.machine_run_once64", "windows.machine_run32", "windows.machine_run_once32", "windows.machine_startup", "windows.services"]

private func taskDefinition(path: String = "\\Fixture\\Login", source: String = "windows.scheduled_tasks", digest: String? = String(repeating: "a", count: 64), state: String = "enabled", runtime: String = "running", capability: String = "windows_user_task", triggers: [String] = ["login"]) -> StartupDefinition {
    StartupDefinition(sourceId: source, path: path, label: "Generated Fixture", programPath: "C:/fixture/owned.exe", disabledByDefinition: state == "disabled", triggers: triggers,
        configuredState: state, runtimeState: runtime, controlCapability: capability, targetState: "exists", evidenceDigest: digest)
}
private func windowsStartupPayload(_ items: [StartupDefinition], system: Bool = false, missingSource: Bool = false, badCount: Bool = false, issues: [StartupInventoryIssue] = []) throws -> Data {
    let ids=windowsUserStartupSources + (system ? windowsMachineStartupSources : [])
    let sources=ids.filter { !missingSource || $0 != "windows.user_run" }.map { id in
        let count=items.filter { $0.sourceId == id }.count
        return StartupSourceCoverage(location: StartupLocation(id: id, path: "Generated:"+id, kind: "fixture", scope: windowsMachineStartupSources.contains(id) ? "machine":"user", systemOwned: windowsMachineStartupSources.contains(id)),
            status: issues.contains { $0.sourceId == id } ? "partial":"complete", entryCount: count, definitionCount: count + (badCount && id == "windows.user_run" ? 1:0))
    }
    return try Codec.encode(JSONValue.object(["sources": .from(sources), "items": .from(items), "issues": .from(issues), "unavailable_sources": .array([.string("shortcut_target_resolution"), .string("packaged_app_startup_tasks")])]))
}

func windowsStartupPreservesCoverageUnknownStatesAndDistinctRegistrations() throws {
    let registration=StartupDefinition(sourceId: "windows.user_run", path: "HKEY_CURRENT_USER\\Software\\Fixture\\Generated", label: "Generated Fixture", programPath: nil, disabledByDefinition: false, triggers: ["login"])
    let task=taskDefinition()
    let payload=try windowsStartupPayload([registration,task],system: true,issues: [.init(sourceId: "windows.services", path: "Generated:services", code: "resource_limit")])
    let inventory=try WindowsStartupInventory(reader: { options in try expect(options.includeSystem);return payload }).read(options: .init(includeSystem: true))
    try expect(inventory.scope == "windows_startup_items" && inventory.status == "partial")
    try expect(inventory.sources.count == 10 && inventory.items.count == 2 && inventory.issues.count == 1)
    try expect(inventory.items.contains { $0.programPath == nil && $0.targetState == "unknown" && $0.configuredState == "unknown" })
    let groups=StartupPresentation.groups(inventory.items)
    try expect(groups.count == 2 && groups.allSatisfy { $0.name == "Generated Fixture" })
    try expect(groups.flatMap(\.controllableItems) == [task])
    try expect(groups.filter(StartupFilter.leftover.matches).isEmpty)
    try expect(inventory.unavailableSources.contains("shortcut_target_resolution"))
    let empty=try windowsStartupPayload([])
    let complete=try WindowsStartupInventory(reader: { _ in empty }).read(options: .init())
    try expect(complete.status == "complete" && complete.sources.count == 4 && complete.items.isEmpty)
}

func windowsStartupRejectsIncompleteOrForgedNativeContracts() throws {
    let task=taskDefinition()
    let badItems=[
        [task,task],
        [taskDefinition(source: "windows.user_run")],
        [taskDefinition(path: "\\Microsoft\\Fixture")],
        [taskDefinition(path: "\\Fixture/unsafe")],
        [taskDefinition(digest: nil)],
        [taskDefinition(digest: "invalid")],
        [taskDefinition(capability: "arbitrary_command")],
        [taskDefinition(triggers: ["arbitrary"])],
        [taskDefinition(source: "windows.machine_run64",capability: "system_settings")]
    ]
    for items in badItems {
        let payload=try windowsStartupPayload(items)
        try expectThrows { try WindowsStartupInventory(reader: { _ in payload }).read(options: .init()) }
    }
    for payload in [try windowsStartupPayload([task],missingSource: true),try windowsStartupPayload([task],badCount: true),try windowsStartupPayload([task],issues: [.init(sourceId: "unknown.source",path: "generated",code: "read_failed")])] {
        try expectThrows { try WindowsStartupInventory(reader: { _ in payload }).read(options: .init()) }
    }
    let reader=WindowsStartupInventory(reader: { _ in throw CheckFailure(description: "Invalid budgets reached the native reader") })
    try expectThrows { try reader.read(options: .init(maxEntries: 0)) }
    try expectThrows { try reader.read(options: .init(maxSeconds: .infinity)) }
}

private final class StartupChangeFixture: @unchecked Sendable {
    private let lock=NSLock()
    private var changes=[String]()
    func change(_ path: String,_ digest: String,_ enabled: Bool) throws {
        try expect(path == "\\Fixture\\Login" && digest == String(repeating: "a",count: 64) && !enabled)
        lock.lock();defer { lock.unlock() };changes.append(path)
    }
    var count: Int { lock.lock();defer { lock.unlock() };return changes.count }
}

func windowsStartupControlBindsDefinitionsAndRetainsUnknownOutcomes() throws {
    let fixture=StartupChangeFixture()
    let controller=WindowsStartupControl(change: { try fixture.change($0,$1,$2) })
    let result=try controller.apply(definition: taskDefinition(),action: .disable)
    try expect(result.configuredState == "disabled" && result.runtimeState == "unknown" && fixture.count == 1)
    for definition in [taskDefinition(source: "windows.user_run"),taskDefinition(digest: nil),taskDefinition(path: "\\Microsoft\\Fixture"),taskDefinition(state: "unknown"),taskDefinition(capability: "system_settings"),taskDefinition(triggers: [])] {
        try expectThrows { try controller.apply(definition: definition,action: .disable) }
    }
    try expectThrows { try controller.apply(definition: taskDefinition(),action: .remove) }
    try expect(fixture.count == 1)
    for code in ["plan_stale", "startup_verification_failed"] {
        let failed=WindowsStartupControl(change: { _,_,_ in throw ShouError(code,"Generated fixture failure") })
        do { _=try failed.apply(definition: taskDefinition(),action: .disable);throw CheckFailure(description: "Unsafe startup outcome accepted") }
        catch let error as ShouError { try expect(error.code == code) }
    }
}

func startupSelectionBindsConfigurationAndKeepsLegacyRecordsReadable() throws {
    let current=taskDefinition()
    try expect(try StartupSelection.digest(current) == StartupSelection.digest(taskDefinition(runtime: "not_running")))
    try expect(try StartupSelection.digest(current) != StartupSelection.digest(taskDefinition(state: "disabled")))
    try expect(try StartupSelection.digest(current) != StartupSelection.digest(taskDefinition(digest: String(repeating:"b",count:64))))
    var legacy=try require(JSONValue.from(current).object);legacy.removeValue(forKey: "evidence_digest")
    let decoded=try Codec.decode(StartupDefinition.self,from: Codec.encode(JSONValue.object(legacy)))
    try expect(decoded.id == current.id && decoded.evidenceDigest == nil)
    try expectThrows { try WindowsStartupControl(change: { _,_,_ in throw CheckFailure(description:"Legacy evidence reached a mutation") }).apply(definition: decoded,action: .disable) }
}
