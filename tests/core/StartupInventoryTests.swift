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

func startupDefinitionsDecodeLegacyDataAndResolveConfiguredDefaults() throws {
    let old="""
    {"id":"legacy","source_id":"fixture","path":"/fixture.plist","label":"com.example.fixture","program_path":"/usr/bin/true","disabled_by_definition":false,"triggers":[]}
    """
    let decoded=try Codec.decode(StartupDefinition.self, from: Data(old.utf8))
    try expect(decoded.displayName == nil && decoded.applicationPath == nil && decoded.publisher == nil)
    try expect(decoded.targetState == "unknown" && !decoded.removable && decoded.configuredState == "unknown")
    try expect(try Codec.decode(StartupDefinition.self, from: Codec.encode(decoded)) == decoded)
    let overrides=LaunchctlStateParser.configuredStates("\"com.a\" => true;\n\"com.b\" => false,\n\"com.c\" => disabled,")
    try expect(overrides == ["com.a":"disabled","com.b":"enabled","com.c":"disabled"])
    try expect(LaunchctlStateParser.configuredState(label: "unlisted", disabledByDefinition: true, overrides: [:]) == "disabled")
    try expect(LaunchctlStateParser.configuredState(label: "unlisted", disabledByDefinition: false, overrides: [:]) == "enabled")
    try expect(LaunchctlStateParser.configuredState(label: "unlisted", disabledByDefinition: true, overrides: nil) == "unknown")
    try expect(LaunchctlStateParser.configuredState(label: "com.a", disabledByDefinition: false, overrides: overrides) == "disabled")
    try expect(LaunchctlStateParser.disabledOverrides("disabled services = {\n\"example\" => invalid\n}") == nil)
}

func nativeStartupInventoryFindsAppIdentityWithoutFalseResiduals() throws {
    #if os(macOS)
    let fixture=try StartupFixture(); defer { fixture.remove() }
    let application=fixture.root.appendingPathComponent("Example.app")
    try FileManager.default.createDirectory(at: application.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName":"Fixture Application"], format: .binary, options: 0).write(to: application.appendingPathComponent("Contents/Info.plist"))
    let executable=application.appendingPathComponent("Contents/MacOS/Example")
    try Data("fixture".utf8).write(to: executable)
    _ = try fixture.put(["Label":"fixture.present", "Program":executable.path], "present.plist")
    _ = try fixture.put(["Label":"fixture.missing", "Program":fixture.root.appendingPathComponent("Removed.app/Contents/MacOS/Removed").path], "missing.plist")
    _ = try fixture.put(["Label":"fixture.offline", "Program":"/Volumes/ShouUnavailableFixtureVolume/Missing.app/Contents/MacOS/Missing"], "offline.plist")
    _ = try fixture.put(["Label":"fixture.relative", "ProgramArguments":["sh", "-c", "never-run"]], "relative.plist")
    let report=try NativeStartupInventory(locations: fixture.locations).read(options: StartupInventoryOptions())
    let present=report.items.first { $0.label == "fixture.present" }
    try expect(present?.displayName == "Fixture Application" && present?.applicationPath == application.path && present?.targetState == "exists")
    try expect(report.items.first { $0.label == "fixture.missing" }?.targetState == "missing")
    try expect(report.items.first { $0.label == "fixture.offline" }?.targetState == "unknown")
    try expect(report.items.first { $0.label == "fixture.relative" }?.targetState == "unknown")
    #endif
}

#if os(macOS)
private final class StartupCommandRecorder: @unchecked Sendable {
    private let lock=NSLock()
    private var stored: [[String]]=[]
    func append(_ arguments: [String]) { lock.lock(); defer { lock.unlock() }; stored.append(arguments) }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
}
#endif

func nativeStartupControlReadbackAndRemovalUseOnlyPreflightedFixtures() throws {
    #if os(macOS)
    let fixture=try StartupFixture(); defer { fixture.remove() }
    let agents=fixture.root.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let path=agents.appendingPathComponent("com.example.safe.plist")
    let bytes=try PropertyListSerialization.data(fromPropertyList: ["Label":"com.example.safe", "Program":"/usr/bin/true"], format: .xml, options: 0)
    try bytes.write(to: path)
    let definition=StartupDefinition(sourceId: "macos.user_agents", path: path.path, label: "com.example.safe", programPath: "/usr/bin/true", disabledByDefinition: false, triggers: [], controlCapability: "launchctl_user_agent", removable: true)
    let commands=StartupCommandRecorder()
    let controller=NativeStartupControl(homeDirectory: fixture.root, command: { arguments, _ in
        commands.append(arguments)
        return StartupCommandOutput(status: 0, output: arguments.first == "print-disabled" ? "disabled services = {\n\"com.example.safe\" => disabled\n}" : "")
    })
    let disabled=try controller.apply(definition: definition, action: .disable)
    try expect(disabled.configuredState == "disabled" && commands.calls.count == 2)
    try expect(commands.calls[0] == ["disable", "gui/\(getuid())/com.example.safe"])
    let unverified=NativeStartupControl(homeDirectory: fixture.root, command: { _,_ in StartupCommandOutput(status: 0, output:"disabled services = {}") })
    do { _ = try unverified.apply(definition: definition, action:.disable); throw CheckFailure(description:"Unverified state must fail") }
    catch let error as ShouError { try expect(error.code == "startup_verification_failed") }
    let trashPath=fixture.root.appendingPathComponent("fixture-trash.plist")
    let remover=NativeStartupControl(homeDirectory: fixture.root, command: { _,_ in throw CheckFailure(description:"Removal must not run launchctl") }, trash: { source, manifest in
        try expect(source == path.path && manifest.count == 1 && manifest[0].contentDigest == Digest.sha256(bytes))
        try FileManager.default.moveItem(atPath: source, toPath: trashPath.path)
        return TrashResult(path: trashPath.path, manifest: manifest, verified: true)
    })
    let removed=try remover.apply(definition: definition,action:.remove)
    try expect(removed.configuredState == "not_applicable" && !FileManager.default.fileExists(atPath:path.path))
    try expect(try Data(contentsOf:trashPath) == bytes)
    try bytes.write(to:path)
    let forged=StartupDefinition(sourceId:"macos.user_agents",path:agents.appendingPathComponent("../LaunchAgents/com.example.safe.plist").path,label:"com.example.safe",programPath:"/usr/bin/true",disabledByDefinition:false,triggers:[],controlCapability:"launchctl_user_agent",removable:true)
    try expectThrows { try controller.apply(definition:forged,action:.remove) }
    let apple=StartupDefinition(sourceId:"macos.user_agents",path:path.path,label:"com.apple.forged",programPath:"/usr/bin/true",disabledByDefinition:false,triggers:[],controlCapability:"launchctl_user_agent",removable:true)
    try expectThrows { try controller.apply(definition:apple,action:.remove) }
    let link=agents.appendingPathComponent("linked.plist")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:path)
    let linked=StartupDefinition(sourceId:"macos.user_agents",path:link.path,label:"com.example.safe",programPath:"/usr/bin/true",disabledByDefinition:false,triggers:[],controlCapability:"launchctl_user_agent",removable:true)
    try expectThrows { try controller.apply(definition:linked,action:.remove) }
    let hardlink=agents.appendingPathComponent("hardlink.plist")
    try FileManager.default.linkItem(at:path,to:hardlink)
    try expectThrows { try controller.apply(definition:definition,action:.remove) }
    try expect(try Data(contentsOf:path) == bytes && Data(contentsOf:trashPath) == bytes)
    #endif
}

private indirect enum StartupPlistFixture {
    case string(String), integer(Int), uid(Int), array([Self]), dictionary([String: Self])
}
private func startupBackgroundFixture(enabled: Bool, version: Int = 13) -> Data {
    func intBytes(_ value: Int, _ width: Int) -> Data { Data((0..<width).reversed().map { UInt8((UInt64(value) >> ($0*8)) & 255) }) }
    var encoded: [Data]=[]
    func append(_ value: StartupPlistFixture) -> Int {
        let index=encoded.count; encoded.append(Data())
        func header(_ type: UInt8, _ count: Int) -> Data {
            count < 15 ? Data([type | UInt8(count)]) : Data([type | 15,0x12]) + intBytes(count,4)
        }
        switch value {
        case .string(let string): encoded[index]=header(0x50,string.utf8.count) + Data(string.utf8)
        case .integer(let number): encoded[index]=Data([0x12]) + intBytes(number,4)
        case .uid(let number): encoded[index]=Data([0x81]) + intBytes(number,2)
        case .array(let array):
            let refs=array.map(append); encoded[index]=header(0xa0,refs.count) + refs.reduce(into:Data()) { $0 += intBytes($1,2) }
        case .dictionary(let dictionary):
            let keys=dictionary.keys.sorted(), keyRefs=keys.map { append(.string($0)) }, valueRefs=keys.map { append(dictionary[$0]!) }
            encoded[index]=header(0xd0,keys.count) + (keyRefs+valueRefs).reduce(into:Data()) { $0 += intBytes($1,2) }
        }
        return index
    }
    let objects: [StartupPlistFixture] = [
        .string("$null"), .dictionary(["$classname":.string("ItemRecord")]),
        .dictionary(["$class":.uid(1),"type":.integer(2),"identifier":.uid(3),"bundleIdentifier":.uid(4),"name":.uid(5),"developerName":.uid(6),"url":.uid(7),"disposition":.integer(enabled ? 11 : 10)]),
        .string("2.com.example.App"),.string("com.example.App"),.string("Fixture App"),.string("Fixture Developer"),.dictionary(["NS.relative":.uid(8)]),.string("file:///Applications/Fixture%20App.app/")
    ]
    let root=append(.dictionary(["$archiver":.string("NSKeyedArchiver"),"$top":.dictionary(["version":.integer(version)]),"$objects":.array(objects)]))
    var data=Data("bplist00".utf8), offsets: [Int]=[]
    for value in encoded { offsets.append(data.count); data += value }
    let table=data.count
    for offset in offsets { data += intBytes(offset,4) }
    data += Data(repeating:0,count:6) + Data([4,2]) + intBytes(encoded.count,8) + intBytes(root,8) + intBytes(table,8)
    return data
}

func startupBackgroundArchiveIsBoundedVersionedAndNeverUnarchivesClasses() throws {
    let disabled=try StartupBackgroundArchiveParser.parse(startupBackgroundFixture(enabled:false))
    try expect(disabled.count == 1 && disabled[0].name == "Fixture App" && disabled[0].publisher == "Fixture Developer")
    try expect(disabled[0].path == "/Applications/Fixture App.app" && !disabled[0].enabled)
    try expect(try StartupBackgroundArchiveParser.parse(startupBackgroundFixture(enabled:true))[0].enabled)
    try expectThrows { try StartupBackgroundArchiveParser.parse(startupBackgroundFixture(enabled:false,version:12)) }
    try expectThrows { try StartupBackgroundArchiveParser.parse(startupBackgroundFixture(enabled:false),limit:0) }
    try expectThrows { try StartupBackgroundArchiveParser.parse(startupBackgroundFixture(enabled:false),deadline:.now.advanced(by:.seconds(-1))) }
    try expectThrows { try StartupBackgroundArchiveParser.parse(Data(repeating:0,count:StartupBackgroundArchiveParser.maximumBytes+1)) }
    var foreignClass=startupBackgroundFixture(enabled:false)
    if let range=foreignClass.range(of:Data("ItemRecord".utf8)) { foreignClass.replaceSubrange(range,with:Data("UnsafeCode".utf8)) }
    try expectThrows { try StartupBackgroundArchiveParser.parse(foreignClass) }
    var malformed=startupBackgroundFixture(enabled:false)
    malformed[malformed.count-8]=255
    try expectThrows { try StartupBackgroundArchiveParser.parse(malformed) }
}

func nativeStartupDaemonControlUsesFixedAuthorizationAndReadback() throws {
    let label="homebrew.mxcl.mysql@8.0"
    let script=try StartupSystemDaemonAuthorization.script(action:.disable,label:label)
    try expect(script == "do shell script \"/bin/launchctl disable system/homebrew.mxcl.mysql@8.0\" with administrator privileges")
    for malicious in ["com.apple.unsafe", "a;touch /tmp/unsafe", "a\"", "a/b", "a b", "a\n", "$(id)"] {
        try expectThrows { try StartupSystemDaemonAuthorization.script(action:.enable,label:malicious) }
    }
    try expectThrows { try StartupSystemDaemonAuthorization.script(action:.remove,label:label) }
    #if os(macOS)
    let calls=StartupCommandRecorder()
    let state=try StartupSystemDaemonAuthorization.apply(label:label,action:.disable,command:{ arguments,_ in
        calls.append(arguments)
        return StartupCommandOutput(status:0,output:"disabled services = {\n\"homebrew.mxcl.mysql@8.0\" => true;\n}")
    },administrator:{ arguments,_ in calls.append(arguments); return StartupCommandOutput(status:0,output:"") })
    try expect(state == "disabled" && calls.calls == [["disable","system/" + label],["print-disabled","system"]])
    do {
        _ = try StartupSystemDaemonAuthorization.apply(label:label,action:.enable,command:{ _,_ in StartupCommandOutput(status:0,output:"disabled services = {}") },administrator:{ _,_ in StartupCommandOutput(status:0,output:"") })
        throw CheckFailure(description:"System mutation requires readback")
    } catch let error as ShouError { try expect(error.code == "startup_verification_failed") }
    let fixture=try StartupFixture(); defer { fixture.remove() }
    let file=try fixture.put(["Label":label,"Program":"/usr/bin/true"],"daemon.plist")
    let forged=StartupDefinition(sourceId:"macos.local_daemons",path:file.path,label:label,programPath:"/usr/bin/true",disabledByDefinition:false,triggers:[],controlCapability:"launchctl_system_daemon")
    let controller=NativeStartupControl(command:{ _,_ in throw CheckFailure(description:"Out-of-scope daemon must not execute") },administrator:{ _,_ in throw CheckFailure(description:"Out-of-scope daemon must not authorize") })
    try expectThrows { try controller.apply(definition:forged,action:.disable) }
    try expectThrows { try controller.apply(definition:forged,action:.remove) }
    #endif
}

#if os(macOS)
private final class StartupFixtureLoginManager: StartupLoginItemManaging, @unchecked Sendable {
    private let lock=NSLock()
    private var entries: [StartupLoginRegistration]
    private var changes: [String]=[]
    private var snapshots=0
    let complete: Bool
    let mutationWorks: Bool
    let changeIdentityOnRecheck: Bool
    init(entries: [StartupLoginRegistration] = [], complete: Bool = true, mutationWorks: Bool = true, changeIdentityOnRecheck: Bool = false) {
        self.entries=entries; self.complete=complete; self.mutationWorks=mutationWorks; self.changeIdentityOnRecheck=changeIdentityOnRecheck
    }
    func snapshot(limit: Int, deadline: ContinuousClock.Instant) throws -> StartupLoginSnapshot {
        lock.lock(); defer { lock.unlock() }; snapshots += 1
        if snapshots == 2 && changeIdentityOnRecheck { entries=entries.map { StartupLoginRegistration(id:$0.id+1,path:$0.path,name:$0.name) } }
        return StartupLoginSnapshot(items:entries,complete:complete)
    }
    func insert(path: String) throws {
        lock.lock(); defer { lock.unlock() }; changes.append("insert:" + path)
        if mutationWorks { entries.append(StartupLoginRegistration(id:77,path:path,name:"Fixture Login")) }
    }
    func remove(id: UInt32, path: String) throws {
        lock.lock(); defer { lock.unlock() }; changes.append("remove:\(id)")
        if mutationWorks { entries.removeAll { $0.id == id && $0.path == path } }
    }
    var actions: [String] { lock.lock(); defer { lock.unlock() }; return changes }
}
#endif

func nativeStartupLoginControlRevalidatesIdentityAndNativeState() throws {
    #if os(macOS)
    let fixture=try StartupFixture(); defer { fixture.remove() }
    let application=fixture.root.appendingPathComponent("Login.app")
    let info=application.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(at:info.deletingLastPathComponent(),withIntermediateDirectories:true)
    func writeBundle(_ bundle: String) throws {
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":bundle],format:.xml,options:0).write(to:info)
    }
    try writeBundle("com.example.LoginFixture")
    let record=StartupBackgroundRecord(identifier:"2.com.example.LoginFixture",bundleIdentifier:"com.example.LoginFixture",name:"Fixture Login",path:application.path,enabled:true)
    func definition(state: String, path: String? = nil) -> StartupDefinition {
        StartupDefinition(sourceId:"macos.background_tasks",path:path ?? "btm:" + record.identifier,label:record.bundleIdentifier,programPath:application.path,
            disabledByDefinition:state == "disabled",triggers:["login_item"],configuredState:state,controlCapability:"login_item",applicationPath:application.path,targetState:"exists")
    }
    let manager=StartupFixtureLoginManager()
    let controller=NativeStartupControl(loginItems:manager,backgroundRecords:{ [record] })
    let enabled=try controller.apply(definition:definition(state:"disabled"),action:.enable)
    try expect(enabled.configuredState == "enabled" && manager.actions == ["insert:" + application.path])
    let disabled=try controller.apply(definition:definition(state:"enabled"),action:.disable)
    try expect(disabled.configuredState == "disabled" && manager.actions == ["insert:" + application.path,"remove:77"])
    try expectThrows { try controller.apply(definition:definition(state:"disabled",path:"btm:forged"),action:.enable) }
    try expect(manager.actions.count == 2)
    let incomplete=StartupFixtureLoginManager(complete:false)
    try expectThrows { try NativeStartupControl(loginItems:incomplete,backgroundRecords:{ [record] }).apply(definition:definition(state:"disabled"),action:.enable) }
    try expect(incomplete.actions.isEmpty)
    let unverifiable=StartupFixtureLoginManager(mutationWorks:false)
    do {
        _ = try NativeStartupControl(loginItems:unverifiable,backgroundRecords:{ [record] }).apply(definition:definition(state:"disabled"),action:.enable)
        throw CheckFailure(description:"Login mutation must verify a complete native snapshot")
    } catch let error as ShouError { try expect(error.code == "startup_verification_failed") }
    try writeBundle("com.apple.Forged")
    try expectThrows { try controller.apply(definition:definition(state:"disabled"),action:.enable) }
    try expect(manager.actions.count == 2)
    try writeBundle("com.example.LoginFixture")
    let native=StartupLoginRegistration(id:77,path:application.path,name:"Fixture Login")
    let nativeDefinition=StartupDefinition(sourceId:"macos.login_items",path:"login-item:77",label:native.name,programPath:application.path,disabledByDefinition:false,triggers:["login_item"],configuredState:"enabled",controlCapability:"login_item",applicationPath:application.path,targetState:"exists")
    let stale=StartupFixtureLoginManager(entries:[native],changeIdentityOnRecheck:true)
    try expectThrows { try NativeStartupControl(loginItems:stale).apply(definition:nativeDefinition,action:.disable) }
    try expect(stale.actions.isEmpty)
    let direct=StartupFixtureLoginManager(entries:[native])
    let nativeResult=try NativeStartupControl(loginItems:direct,backgroundRecords:{ throw CheckFailure(description:"Native login identity must not use an unrelated BTM record") }).apply(definition:nativeDefinition,action:.disable)
    try expect(nativeResult.configuredState == "disabled" && direct.actions == ["remove:77"])
    try expectThrows { try controller.apply(definition:definition(state:"disabled"),action:.remove) }
    #endif
}
