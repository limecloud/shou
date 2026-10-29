import Foundation
import ShouCore
import ShouPlatform

private final class PackageFixtureClock: @unchecked Sendable {
    private let lock=NSLock()
    private var value=Date(timeIntervalSince1970: 10_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private final class PackageFixtureRunner: PackageUpdateRunning, @unchecked Sendable {
    var miseGlobalConfigurationPaths: Set<String> { ["/fixture/.config/mise/config.toml"] }
    private let lock=NSLock()
    var versions=["node":"20.1.0", "cursor":"1.0.0"]
    var identity="generated-manager"
    var pinned=false
    var malformedToken=false
    var duplicate=false
    var failUpgrade=false
    var failCheck=false
    var cancelUpgrade=false
    var doNotChangeVersion=false
    var upgradeDependency=false
    var miseRequest="latest"
    var misePath="/fixture/.config/mise/config.toml"
    var upgrades=[PackageUpdateCommand]()
    var onRun: (@Sendable (PackageUpdateCommand) -> Void)?
    func run(_ command: PackageUpdateCommand, timeoutSeconds: Double, expectedExecutableIdentity: String?) throws -> PackageUpdateOutput {
        lock.lock(); defer { lock.unlock() }
        onRun?(command)
        guard expectedExecutableIdentity == nil || expectedExecutableIdentity == identity else { throw ShouError("tool_changed", "Generated identity changed.") }
        guard command.valid else { throw ShouError("invalid_argument", "Generated invalid command.") }
        if case .outdated = command, failCheck { throw ShouError("tool_timeout", "Generated catalog timeout.") }
        if command.mutating {
            upgrades.append(command)
            if cancelUpgrade { withUnsafeCurrentTask { $0?.cancel() }; throw ShouError("cancelled", "Generated cancellation after dispatch.") }
            if failUpgrade { throw ShouError("tool_timeout", "Generated update interruption.") }
            if case .upgrade(_, _, let token)=command, !doNotChangeVersion { versions[token] = token == "node" ? "20.2.0" : "2.0.0" }
            if upgradeDependency { versions["node"]="20.2.0" }
        }
        let json: Any
        switch command {
        case .installed(.homebrew):
            let row: [String:Any] = ["name": malformedToken ? "--all" : "node", "full_name": malformedToken ? "--all" : "node", "desc":"Generated runtime", "pinned":pinned,
                                    "installed":[["version":versions["node"]!, "installed_on_request":true]]]
            json=["formulae":duplicate ? [row,row] : [row], "casks":[["token":"cursor", "name":["Cursor"], "installed":versions["cursor"]!,
                "artifacts":[["app":["Cursor.app"], "target":"/Applications/Cursor.app"],
                    ["binary":["cursor"], "target":"/Applications/NotAnApp.app"], ["app":["Unsafe.app"], "target":"/Applications/../Unsafe.app"]]]]]
        case .outdated(.homebrew):
            json=["formulae":versions["node"] == "20.1.0" ? [["name":"node", "current_version":"20.2.0"]] : [],
                  "casks":versions["cursor"] == "1.0.0" ? [["name":"cursor", "current_version":"2.0.0"]] : []]
        case .installed(.mise):
            json=["node":[["version":versions["node"]!, "active":true, "installed":true, "requested_version":miseRequest,
                            "source":["type":"mise.toml", "path":misePath]]]]
        case .outdated(.mise):
            json=versions["node"] == "20.1.0" ? ["node":["name":"node", "requested":miseRequest, "current":"20.1.0", "latest":"20.2.0", "source":["type":"mise.toml", "path":misePath]]] : [:]
        default: json=[:]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: json), executableIdentity: identity)
    }
}

func packageUpdatesRecognizeFrozenTargetsReachedByDependencies() async throws {
    let runner=PackageFixtureRunner(), service=PackageUpdateService(runner: runner)
    runner.upgradeDependency=true
    let inventory=try await service.inventory(.homebrew)
    let plan=try await service.prepare(inventory, selectedIDs: Set(inventory.items.map(\.id)))
    let results=try await service.execute(plan)
    try expect(results.count == 2 && results.allSatisfy { $0.state == "succeeded" })
    try expect(runner.upgrades.count == 1 && runner.upgrades.first?.arguments == ["upgrade","--cask","cursor"])
}

func packageUpdatesFreezeExactSelectionsAndVerifyInstalledVersions() async throws {
    let runner=PackageFixtureRunner(), service=PackageUpdateService(runner: runner)
    let inventory=try await service.inventory(.homebrew)
    try expect(inventory.items.count == 2 && inventory.items.allSatisfy(\.canUpgrade))
    try expect(inventory.items.first { $0.token == "cursor" }?.iconApplicationPaths == ["/Applications/Cursor.app"])
    let plan=try await service.prepare(inventory, selectedIDs: Set(inventory.items.map(\.id)))
    let results=try await service.execute(plan)
    try expect(results.count == 2 && results.allSatisfy { $0.state == "succeeded" })
    try expect(runner.upgrades.count == 2 && !runner.upgrades.contains { $0.arguments == ["upgrade"] })
    try expect(runner.upgrades.contains { $0.arguments == ["upgrade","--formula","node"] })
    try expect(runner.upgrades.contains { $0.arguments == ["upgrade","--cask","cursor"] })
    try await expectThrows { try await service.execute(plan) }
    try expect(try await service.inventory(.homebrew).items.allSatisfy { !$0.canUpgrade })
}

func packageUpdatesRejectStaleChangedPinnedAndUnknownSelections() async throws {
    let runner=PackageFixtureRunner(), service=PackageUpdateService(runner: runner)
    let inventory=try await service.inventory(.homebrew)
    try await expectThrows { try await service.prepare(inventory, selectedIDs: ["unknown"]) }
    try await expectThrows { try await service.prepare(inventory, selectedIDs: []) }
    let plan=try await service.prepare(inventory, selectedIDs: [inventory.items[0].id])
    runner.identity="replaced-manager"
    try await expectThrows { try await service.execute(plan) }
    try expect(runner.upgrades.isEmpty)
    runner.pinned=true
    let pinned=try await service.inventory(.homebrew)
    let node=try require(pinned.items.first { $0.token == "node" })
    try expect(!node.canUpgrade)
    try await expectThrows { try await service.prepare(pinned, selectedIDs: [node.id]) }
    runner.pinned=false
    let fresh=try await service.inventory(.homebrew)
    let stale=try await service.prepare(fresh, selectedIDs: [node.id])
    runner.versions["node"]="20.1.1"
    try await expectThrows { try await service.execute(stale) }
    try expect(runner.upgrades.isEmpty)
    runner.failCheck=true
    let partial=try await service.inventory(.homebrew)
    try expect(partial.items.count == 2 && partial.issue != nil && partial.items.allSatisfy { !$0.canUpgrade })
    try await expectThrows { try await service.prepare(partial, selectedIDs: [partial.items[0].id]) }

    // Rechecking the inventory must not extend the authorization to dispatch.
    let slowClock=PackageFixtureClock(), slowRunner=PackageFixtureRunner()
    let slowService=PackageUpdateService(runner: slowRunner, now: { slowClock.now() })
    let slowInventory=try await slowService.inventory(.homebrew)
    let slowPlan=try await slowService.prepare(slowInventory, selectedIDs: Set(slowInventory.items.map(\.id)))
    slowRunner.onRun={ if case .outdated = $0 { slowClock.advance(61) } }
    let expiredBeforeFirst=try await slowService.execute(slowPlan)
    try expect(expiredBeforeFirst.map(\.state) == ["failed","skipped"] && slowRunner.upgrades.isEmpty)
    try expect(expiredBeforeFirst.first?.issue == "plan_stale")

    // A completed upgrade remains verified, but cannot authorize a later item.
    let batchClock=PackageFixtureClock(), batchRunner=PackageFixtureRunner()
    let batchService=PackageUpdateService(runner: batchRunner, now: { batchClock.now() })
    let batchInventory=try await batchService.inventory(.homebrew)
    let batchPlan=try await batchService.prepare(batchInventory, selectedIDs: Set(batchInventory.items.map(\.id)))
    batchRunner.onRun={ if $0.mutating { batchClock.advance(120) } }
    let expiredAfterFirst=try await batchService.execute(batchPlan)
    try expect(expiredAfterFirst.map(\.state) == ["succeeded","failed"] && batchRunner.upgrades.count == 1)
    try expect(expiredAfterFirst.last?.issue == "plan_stale")
}

func packageUpdatesRejectMalformedIdentitiesAndPreserveGlobalMiseRanges() async throws {
    let runner=PackageFixtureRunner(), service=PackageUpdateService(runner: runner)
    runner.malformedToken=true
    try await expectThrows { try await service.inventory(.homebrew) }
    runner.malformedToken=false; runner.duplicate=true
    try await expectThrows { try await service.inventory(.homebrew) }
    runner.duplicate=false
    for token in ["--all", "../node", "node\n--all", "node\n", "node;touch /tmp/other", "https://example.test/tool"] {
        try expect(!PackageUpdateCommand.upgrade(.homebrew, kind: "formula", token: token).valid)
        try expect(!PackageUpdateCommand.upgrade(.mise, kind: "tool", token: token).valid)
    }
    runner.miseRequest="20"
    try expect(try await service.inventory(.mise).items.allSatisfy { !$0.canUpgrade })
    runner.miseRequest="latest"; runner.misePath="/fixture/project/mise.toml"
    try expect(try await service.inventory(.mise).items.allSatisfy { !$0.canUpgrade })
    runner.misePath="/fixture/.config/mise/config.toml"
    let global=try await service.inventory(.mise)
    let plan=try await service.prepare(global, selectedIDs: Set(global.items.map(\.id)))
    try expect(try await service.execute(plan).allSatisfy { $0.state == "succeeded" })
    try expect(runner.upgrades.last?.arguments == ["upgrade","--global","--no-prune","node"])
}

func packageUpdatesInterruptedOrUnverifiedInstallsRemainUnknown() async throws {
    for mode in ["timeout","unverified"] {
        let runner=PackageFixtureRunner(), service=PackageUpdateService(runner: runner)
        runner.failUpgrade = mode == "timeout"; runner.doNotChangeVersion = mode == "unverified"
        let inventory=try await service.inventory(.homebrew)
        let plan=try await service.prepare(inventory, selectedIDs: Set(inventory.items.map(\.id)))
        let results=try await service.execute(plan)
        try expect(results.map(\.state) == ["unknown","skipped"] && runner.upgrades.count == 1)
    }
    // Cancellation is exercised in its own task so the test runner stays usable.
    let task=Task {
        let runner=PackageFixtureRunner(), service=PackageUpdateService(runner: runner)
        runner.cancelUpgrade=true
        let inventory=try await service.inventory(.homebrew)
        let plan=try await service.prepare(inventory, selectedIDs: Set(inventory.items.map(\.id)))
        let result=try await service.execute(plan)
        try expect(result.map(\.state) == ["unknown","skipped"] && runner.upgrades.count == 1)
    }
    try await task.value
}

func nativePackageUpdatesUseOnlyGlobalExactGeneratedCommands() throws {
    #if os(macOS)
    let fixture=try Fixture(), path=fixture.workspace.appendingPathComponent(".local/bin/mise")
    try fixture.put(".local/bin/mise", "#!/bin/sh\n[ \"$MISE_AUTO_INSTALL\" = \"0\" ] || exit 4\n[ \"$HOMEBREW_NO_INSTALL_CLEANUP\" = \"1\" ] || exit 5\nprintf '%s\\n' \"$@\"\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    let runner=NativePackageUpdates(homeDirectory: fixture.workspace, executableDirectory: path.deletingLastPathComponent())
    let first=try runner.run(.installed(.mise), timeoutSeconds: 10, expectedExecutableIdentity: nil)
    try expect(String(data: first.data, encoding: .utf8) == "ls\n--global\n--installed\n--json\n")
    try expectThrows { try runner.run(.upgrade(.mise, kind: "tool", token: "node"), timeoutSeconds: 10, expectedExecutableIdentity: nil) }
    let command=try runner.run(.upgrade(.mise, kind: "tool", token: "node"), timeoutSeconds: 10, expectedExecutableIdentity: first.executableIdentity)
    try expect(String(data: command.data, encoding: .utf8) == "upgrade\n--global\n--no-prune\nnode\n")
    try fixture.put(".local/bin/mise", "#!/bin/sh\nprintf 'replacement'\n")
    try expectThrows { try runner.run(.upgrade(.mise, kind: "tool", token: "node"), timeoutSeconds: 10, expectedExecutableIdentity: first.executableIdentity) }
    let outside=NativePackageUpdates(homeDirectory: fixture.workspace, executableDirectory: fixture.workspace.deletingLastPathComponent())
    try expectThrows { try outside.run(.installed(.homebrew), timeoutSeconds: 10, expectedExecutableIdentity: nil) }
    #endif
}
