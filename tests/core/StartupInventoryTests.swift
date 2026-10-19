import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin
#endif

private final class StartupReadCounter: @unchecked Sendable {
    private let mutex=NSLock()
    private var count=0
    func increment() { mutex.lock(); defer { mutex.unlock() }; count += 1 }
    var value: Int { mutex.lock(); defer { mutex.unlock() }; return count }
}
private struct StartupFixtureSource: StartupInventoryReading {
    let calls: StartupReadCounter
    func read(options: StartupInventoryOptions) throws -> StartupInventory {
        calls.increment()
        return StartupInventory(checkedAt: Date(timeIntervalSince1970: 0), includeSystem: options.includeSystem, sources: [], items: [], issues: [])
    }
}

func launchctlStateParsersKeepOnlyDocumentedStates() throws {
    let output="""
    disabled services = {
        "com.example.enabled" => enabled
        "com.example.disabled" => disabled
        "ignored" => running
        not-a-service => disabled
    }
    """
    let states=LaunchctlStateParser.configuredStates(output)
    try expect(states == ["com.example.enabled": "enabled", "com.example.disabled": "disabled"])
    try expect(LaunchctlStateParser.runtimeState(status: 0, output: "state = running") == "running")
    try expect(LaunchctlStateParser.runtimeState(status: 0, output: "state = exited") == "loaded")
    try expect(LaunchctlStateParser.runtimeState(status: 113, output: "Could not find service") == "not_loaded")
    try expect(LaunchctlStateParser.runtimeState(status: 1, output: "permission denied") == "unknown")
}

private final class StartupControlRecorder: @unchecked Sendable {
    private let mutex=NSLock()
    private(set) var actions: [(String, StartupControlAction)]=[]
    func record(_ definition: StartupDefinition, _ action: StartupControlAction) {
        mutex.lock(); defer { mutex.unlock() }
        actions.append((definition.id, action))
    }
}
private struct StartupFixtureController: StartupControlling {
    let recorder: StartupControlRecorder
    func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult {
        recorder.record(definition, action)
        return StartupControlResult(definitionId: definition.id, label: definition.label, action: action, configuredState: action == .enable ? "enabled" : "disabled", runtimeState: "unknown", controlCapability: definition.controlCapability, message: "fixture")
    }
}

func startupInventoryValidatesBeforeReadingAndHonorsCancellation() async throws {
    let calls=StartupReadCounter()
    let service=StartupInventoryService(source: StartupFixtureSource(calls: calls))
    for options in [StartupInventoryOptions(maxEntries: 0), StartupInventoryOptions(maxEntries: 10_001), StartupInventoryOptions(maxSeconds: .infinity), StartupInventoryOptions(maxSeconds: 31)] {
        try await expectThrows { try await service.scan(options: options) }
    }
    try expect(calls.value == 0)
    let cancelled=Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.scan()
    }
    do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled startup discovery must not read.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(calls.value == 0)
    let result=try await service.scan()
    try expect(calls.value == 1 && result.scope == "launchd_definitions")
    try expect(result.unavailableSources == ["login_items", "background_task_registrations", "embedded_helpers"])
}

func startupControlRequiresPlatformCapabilityAndForwardsExplicitAction() async throws {
    let recorder=StartupControlRecorder()
    let service=StartupControlService(controller: StartupFixtureController(recorder: recorder))
    let readOnly=StartupDefinition(sourceId: "fixture.user", path: "/tmp/LaunchAgents/example.plist", label: "dev.example", programPath: "/usr/bin/true", disabledByDefinition: false, triggers: [])
    try await expectThrows { try await service.apply(definition: readOnly, action: .disable) }
    try expect(recorder.actions.isEmpty)
    let controllable=StartupDefinition(sourceId: "macos.user_agents", path: "/Users/test/Library/LaunchAgents/example.plist", label: "dev.example", programPath: "/usr/bin/true", disabledByDefinition: false, triggers: [], controlCapability: "launchctl_user_agent")
    let result=try await service.apply(definition: controllable, action: .disable)
    try expect(result.action == .disable && result.configuredState == "disabled" && recorder.actions.count == 1 && recorder.actions[0].1 == .disable)
}

func nativeStartupControlRefusesSystemAndOutOfScopeDefinitions() throws {
    #if os(macOS)
    let controller=NativeStartupControl(homeDirectory: URL(fileURLWithPath: "/tmp/shou-startup-control-test"))
    let system=StartupDefinition(sourceId: "macos.local_agents", path: "/Library/LaunchAgents/example.plist", label: "com.example.test", programPath: "/usr/bin/true", disabledByDefinition: false, triggers: [])
    try expectThrows { try controller.apply(definition: system, action: .disable) }
    let wrongParent=StartupDefinition(sourceId: "macos.user_agents", path: "/tmp/example.plist", label: "com.example.test", programPath: "/usr/bin/true", disabledByDefinition: false, triggers: [], controlCapability: "launchctl_user_agent")
    try expectThrows { try controller.apply(definition: wrongParent, action: .disable) }
    #endif
}

#if os(macOS)
private struct StartupFixture {
    let root: URL
    let user: URL
    let system: URL
    init() throws {
        let temporary=FileManager.default.temporaryDirectory.path
        // Match the physical-path fixtures; Foundation can retain the /var alias.
        let physical=temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        root=URL(fileURLWithPath: physical).appendingPathComponent("shou-startup-" + UUID().uuidString)
        user=root.appendingPathComponent("user"); system=root.appendingPathComponent("system")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    }
    var locations: [StartupLocation] {
        [StartupLocation(id: "fixture.user", path: user.path, kind: "agent", scope: "user"),
         StartupLocation(id: "fixture.system", path: system.path, kind: "daemon", scope: "machine", systemOwned: true),
         StartupLocation(id: "fixture.missing", path: root.appendingPathComponent("missing").path, kind: "agent", scope: "machine")]
    }
    func put(_ values: [String: Any], _ name: String, system: Bool = false, binary: Bool = false) throws -> URL {
        let path=(system ? self.system : user).appendingPathComponent(name)
        try PropertyListSerialization.data(fromPropertyList: values, format: binary ? .binary : .xml, options: 0).write(to: path)
        return path
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
#endif

func nativeStartupInventoryKeepsStateUnknownAndOmitsSecrets() throws {
    #if os(macOS)
    let fixture=try StartupFixture(); defer { fixture.remove() }
    let secret="never-output-this-startup-credential"
    let first=try fixture.put(["Label":"dev.example.工具", "ProgramArguments":["/Applications/Example.app/Contents/MacOS/Example", "--token", secret], "EnvironmentVariables":["TOKEN":secret], "RunAtLoad":true, "KeepAlive":["SuccessfulExit":false]], "one.plist")
    let second=try fixture.put(["Label":"dev.example.工具", "Program":"/usr/bin/true", "Disabled":true, "StartInterval":30], "two.plist", binary:true)
    let apple=try fixture.put(["Label":"com.apple.fixture", "Program":"/usr/bin/true"], "apple.plist", system:true)
    let before=try [first,second,apple].map { try Data(contentsOf: $0) }
    let reader=NativeStartupInventory(locations: fixture.locations)
    let report=try reader.read(options: StartupInventoryOptions())
    try expect(report.status == "complete" && report.items.count == 2 && report.sources.count == 2)
    try expect(report.sources.first { $0.id == "fixture.missing" }?.status == "missing")
    try expect(Set(report.items.map(\.id)).count == 2)
    try expect(report.items.allSatisfy { $0.configuredState == "unknown" && $0.runtimeState == "unknown" && $0.controlCapability == "system_settings" })
    try expect(report.items.first { $0.path == first.path }?.triggers == ["run_at_load", "conditional_keep_alive"])
    try expect(report.items.first { $0.path == second.path }?.disabledByDefinition == true)
    let encoded=try Codec.encode(report)
    try expect(!String(decoding: encoded, as: UTF8.self).contains(secret))
    let json=try Codec.decode(JSONValue.self, from: encoded)
    try expect(json["scope"] == .string("launchd_definitions"))
    try expect(json["items"]?.array?.allSatisfy { $0["runtime_state"] == .string("unknown") && $0["program_arguments"] == nil && $0["environment_variables"] == nil } == true)
    let withSystem=try reader.read(options: StartupInventoryOptions(includeSystem:true))
    try expect(withSystem.items.count == 3 && withSystem.sources.count == 3 && withSystem.includeSystem)
    try expect(try [first,second,apple].map { try Data(contentsOf: $0) } == before)
    #else
    try expectThrows { try NativeStartupInventory().read(options: StartupInventoryOptions()) }
    #endif
}

func nativeStartupInventoryRejectsUnsafeAndInvalidDefinitions() throws {
    #if os(macOS)
    let fixture=try StartupFixture(); defer { fixture.remove() }
    let secret=try fixture.put(["Label":"must-not-follow", "Program":"/usr/bin/true"], "outside.plist", system:true)
    let before=try Data(contentsOf: secret)
    try FileManager.default.createSymbolicLink(at: fixture.user.appendingPathComponent("linked.plist"), withDestinationURL: secret)
    try Data("invalid property list".utf8).write(to: fixture.user.appendingPathComponent("invalid.plist"))
    _ = try fixture.put(["Label":"bad-boolean", "Disabled":"true"], "wrong-type.plist")
    _ = try fixture.put(["Label":"bad\nlabel"], "bad-label.plist")
    try Data(repeating: 32, count: NativeStartupInventory.maximumDefinitionBytes + 1).write(to: fixture.user.appendingPathComponent("large.plist"))
    let fifo=fixture.user.appendingPathComponent("fifo.plist")
    try expect(mkfifo(fifo.path, 0o600) == 0)
    let report=try NativeStartupInventory(locations: fixture.locations).read(options: StartupInventoryOptions())
    try expect(report.status == "partial" && report.items.isEmpty)
    try expect(Set(report.issues.map(\.code)) == ["linked_definition", "invalid_definition", "definition_too_large", "unsupported_definition"])
    try expect(report.issues.count == 6 && report.sources.first?.status == "partial")
    let alias=fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.system)
    let linkedAncestor=StartupLocation(id: "fixture.alias", path: alias.appendingPathComponent("subdirectory").path, kind: "agent", scope: "user")
    try FileManager.default.createDirectory(at: fixture.system.appendingPathComponent("subdirectory"), withIntermediateDirectories: false)
    try FileManager.default.copyItem(at: secret, to: fixture.system.appendingPathComponent("subdirectory/secret.plist"))
    let linked=try NativeStartupInventory(locations: [linkedAncestor]).read(options: StartupInventoryOptions())
    try expect(linked.items.isEmpty && linked.sources.first?.status == "unavailable" && linked.status == "partial")
    try expect(try Data(contentsOf: secret) == before)
    #endif
}

func nativeStartupInventoryReportsBudgetGapsWithoutLosingValidItems() throws {
    #if os(macOS)
    let fixture=try StartupFixture(); defer { fixture.remove() }
    for index in 0..<8 { _ = try fixture.put(["Label":"fixture.\(index)", "Program":"/usr/bin/true"], "\(index).plist") }
    let reader=NativeStartupInventory(locations: fixture.locations)
    let limited=try reader.read(options: StartupInventoryOptions(includeSystem: true, maxEntries: 2))
    try expect(limited.status == "partial" && limited.items.count == 2)
    try expect(limited.sources.reduce(0) { $0 + $1.entryCount } == 2)
    try expect(limited.issues.allSatisfy { $0.code == "resource_limit" })
    try expect(limited.sources.filter { $0.status == "not_scanned" }.count == 2)
    let full=try reader.read(options: StartupInventoryOptions())
    try expect(full.status == "complete" && full.items.count == 8)
    #endif
}
