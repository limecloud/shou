import Foundation
import ShouCore
import ShouPlatform

private final class ServiceFixture: DeveloperServiceOperating, @unchecked Sendable {
    var running=false
    var definition="generated-definition"
    var registered=false
    var noChange=false
    var failStop=false
    var failStart=false
    var external=false
    var transitions=[Bool]()
    var dispatches=0
    var progress=[String]()
    var requestedTools=[[String]]()
    var ignoresScope=false
    var row: DeveloperService {
        .init(id: "generated-service", toolID: "nginx", source: "Homebrew", name: "nginx", version: "1.0", installationPath: "/generated/nginx/1.0", configurationPath: "/generated/nginx/1.0/service.plist", state: external ? "external" : running ? "running" : "stopped", registeredAtLogin: registered, identity: "\(definition):\(running)", definitionIdentity: definition, issue: external ? "developer_service_external_process" : nil)
    }
    func scan(catalog: DeveloperToolCatalog, inventory: DeveloperToolInventory) throws -> DeveloperServiceSnapshot {
        requestedTools.append(catalog.tools.map(\.id))
        return .init(services: ignoresScope || catalog.tools.contains { $0.id == row.toolID } ? [row] : [], issues: [])
    }
    func inspect(_ expected: DeveloperService) throws -> DeveloperService { row }
    func setRunning(_ running: Bool, expected: DeveloperService, expiresAt: Date) throws {
        dispatches += 1; transitions.append(running)
        if running && failStart || !running && failStop { throw ShouError("fixture_failure", "Generated transition failure.") }
        if !noChange { self.running=running }
    }
}
func developerServicesLoadOnlySelectedToolsWithoutDiscardingOtherObservations() async throws {
    let fixture=try Fixture(), platform=ServiceFixture()
    let controller=DeveloperServiceController(catalog: try .bundled(), platform: platform, makeStore: { fixture.store })
    let inventory=DeveloperToolInventory(installations: [], issues: [])
    let nginx=try await controller.scan(inventory, toolID: "nginx").services[0]
    try expect(try await controller.scan(inventory, toolID: "mysql").services.isEmpty)
    try expect(platform.requestedTools == [["nginx"],["mysql"]])
    try expect(try await controller.setRunning(true, expected: nginx).state == "succeeded")
    let refreshed=try await controller.scan(inventory, toolID: "nginx").services[0]
    try expect(try await controller.scan(inventory, toolIDs:["mysql","redis"]).services.isEmpty)
    try expect(Set(try require(platform.requestedTools.last)) == ["mysql","redis"])
    try await expectThrows { try await controller.scan(inventory, toolID:"nginx",toolIDs:["mysql"]) }
    platform.ignoresScope=true
    try await expectThrows { try await controller.scan(inventory, toolID: "mysql") }
    try await expectThrows { try await controller.scan(inventory, toolID: "unknown-tool") }
    try expect(try await controller.setRunning(false, expected: refreshed).state == "succeeded")
    try expect(platform.dispatches == 2)
}
func developerServiceSwitchesBindSourcesAndVerifyJournaledOutcomes() async throws {
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled(), platform=ServiceFixture()
    let controller=DeveloperServiceController(catalog: catalog, platform: platform, makeStore: { fixture.store })
    let inventory=DeveloperToolInventory(installations: [], observedAt: Date(), issues: [])
    for target in [true, false] {
        let expected=try await controller.scan(inventory).services[0]
        let result=try await controller.setRunning(target, expected: expected)
        try expect(result.state == "succeeded" && result.observed?.registeredAtLogin == false)
        try expect(try fixture.store.read("developer-service-intents", id: result.id) != nil)
        try expect(try fixture.store.read("developer-service-results", id: result.id) != nil)
        try await expectThrows { try await controller.setRunning(target, expected: expected) }
    }
    let stale=try await controller.scan(inventory).services[0]
    platform.definition="replaced-source"
    try await expectThrows { try await controller.setRunning(true, expected: stale) }
    try expect(platform.dispatches == 2)
    platform.noChange=true
    let current=try await controller.scan(inventory).services[0]
    try expect(try await controller.setRunning(true, expected: current).state == "unknown")
    try await expectThrows { try await controller.setRunning(true, expected: current) }
    let denied=DeveloperServiceController(catalog: catalog, platform: platform, makeStore: { throw ShouError("io_error", "Generated journal failure.") })
    let deniedRow=try await denied.scan(inventory).services[0]
    try await expectThrows { try await denied.setRunning(true, expected: deniedRow) }
    try expect(platform.dispatches == 3)
    platform.external=true
    for action in [DeveloperServiceAction.start, .stop, .restart] {
        let external=try await controller.scan(inventory).services[0]
        try expect(!external.controllable)
        try await expectThrows { try await controller.perform(action, expected: external) }
    }
    try expect(platform.dispatches == 3)
}
func developerServiceRestartRequiresVerifiedStopBeforeStart() async throws {
    for failure in ["none", "stop", "unchanged", "start"] {
        let fixture=try Fixture(), platform=ServiceFixture()
        platform.running=true; platform.failStop=failure == "stop"; platform.failStart=failure == "start"; platform.noChange=failure == "unchanged"
        let controller=DeveloperServiceController(catalog: try .bundled(), platform: platform, makeStore: { fixture.store })
        let row=try await controller.scan(.init(installations: [], observedAt: Date(), issues: [])).services[0]
        let outcome=try await controller.perform(.restart, expected: row) { event in platform.progress.append(event.stage) }
        try expect(outcome.action == .restart)
        try expect(platform.transitions == (["none","start"].contains(failure) ? [false,true] : [false]))
        try expect(outcome.state == (failure == "none" ? "succeeded" : failure == "start" ? "partial" : "unknown"))
        try expect(platform.progress == (failure == "none" ? ["stopping","stopped","starting","verifying"] : failure == "start" ? ["stopping","stopped","starting"] : ["stopping"]))
        try expect(outcome.failureCode == (failure == "none" ? nil : failure == "unchanged" ? "developer_service_changed" : "fixture_failure"))
        if ["none","start"].contains(failure) { try expect(try fixture.store.read("developer-service-stages", id: outcome.id) != nil) }
        if failure != "none" { try await expectThrows { try await controller.perform(.restart, expected: row) } }
    }
}
func nativeDeveloperServicesPreserveLoginRegistrationUsingGeneratedManager() async throws {
    #if os(macOS)
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled()
    let plist: [String:Any] = ["Label":"homebrew.mxcl.nginx", "KeepAlive":true, "ProgramArguments":[fixture.workspace.appendingPathComponent("Cellar/nginx/1.0/bin/nginx").path]]
    let bytes=try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try fixture.put("Cellar/nginx/1.0/homebrew.mxcl.nginx.plist", String(decoding: bytes, as: UTF8.self))
    try fixture.put("Library/LaunchAgents/homebrew.mxcl.nginx.plist", String(decoding: bytes, as: UTF8.self))
    try fixture.put("Cellar/nginx/1.0/bin/nginx", "generated executable; never launched")
    let user=String(data: try JSONSerialization.data(withJSONObject: NSUserName(), options: .fragmentsAllowed), encoding: .utf8)!
    let script="""
    #!/bin/sh
    printf '%s\\n' "$@" >> "$HOME/arguments"
    if [ "$1" = info ]; then
      printf '{"formulae":[{"full_name":"nginx","tap":"homebrew/core","installed":[{"version":"1.0"}],"versions":{"stable":"1.0"},"dependencies":[],"revision":0}],"casks":[]}'
    elif [ "$1" = services ] && [ "$2" = list ]; then
      printf '[{"name":"nginx"}]'
    elif [ "$1" = services ] && [ "$2" = info ]; then
      running=false; status=none; registered=false; user=null; file="$HOME/Cellar/nginx/1.0/homebrew.mxcl.nginx.plist"
      if [ -f "$HOME/login" ]; then registered=true; user='\(user)'; file="$HOME/Library/LaunchAgents/homebrew.mxcl.nginx.plist"; fi
      if [ -f "$HOME/running" ]; then running=true; status=started; user='\(user)'; fi
      printf '[{"name":"nginx","running":%s,"registered":%s,"status":"%s","user":%s,"file":"%s"}]' "$running" "$registered" "$status" "$user" "$file"
    elif [ "$1" = bootstrap ]; then
      printf 'generated' > "$HOME/running"
    elif [ "$1" = bootout ]; then
      /bin/rm "$HOME/running"
    else exit 11; fi
    """
    try fixture.put("bin/brew", script)
    let executable=fixture.workspace.appendingPathComponent("bin/brew")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let controller=DeveloperServiceController(catalog: catalog, platform: NativeDeveloperServices(homeDirectory: fixture.workspace, generatedExecutable: executable, generatedServiceExecutable: executable), makeStore: { fixture.store })
    let inventory=DeveloperToolInventory(installations: [.init(toolID: "nginx", source: "Homebrew", version: "1.0", path: fixture.workspace.appendingPathComponent("Cellar/nginx/1.0").path, evidence: "generated", status: "registered")], observedAt: Date(), issues: [])
    for registered in [false,true] {
        if registered { try fixture.put("login", "generated registration") }
        for target in [true,false] {
            let row=try require(try await controller.scan(inventory).services.first)
            try expect(row.registeredAtLogin == registered)
            let result=try await controller.setRunning(target, expected: row)
            try expect(result.state == "succeeded")
            if target, let running=result.observed {
                try expect(try await controller.perform(.restart, expected: running).state == "succeeded")
            }
        }
    }
    let log=try String(contentsOf: fixture.workspace.appendingPathComponent("arguments"), encoding: .utf8)
    try expect(log.contains("bootstrap\n") && log.contains("bootout\n") && !log.contains("services\nkill\n"))
    try expect(!log.contains("services\nstop\n") && !log.contains("restart") && !log.contains("sudo"))
    #endif
}
