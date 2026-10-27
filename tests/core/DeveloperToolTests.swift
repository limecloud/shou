import Foundation
import ShouCore
import ShouPlatform

private final class DeveloperFixturePlatform: DeveloperToolOperating, @unchecked Sendable {
    var installed=[String]()
    var source="fixture-manager"
    var recipe="fixture-recipe"
    var noChange=false
    var calls=[DeveloperToolAction]()
    func inspect(_ package: DeveloperToolPackage) throws -> DeveloperToolInspection {
        .init(package: package, installedVersions: installed, availableVersion: "1.0", dependencies: ["fixture-library"], sourceIdentity: source, packageIdentity: recipe, scope: "generated fixture", issue: nil)
    }
    func perform(_ action: DeveloperToolAction, expected: DeveloperToolInspection, expiresAt: Date) throws {
        calls.append(action)
        if !noChange { installed = action == .install ? ["1.0"] : [] }
    }
}
private final class DeveloperFixtureClock: @unchecked Sendable {
    var date=Date()
}
func developerCatalogCoversCategoriesWithoutInventingSources() throws {
    let catalog=try DeveloperToolCatalog.bundled()
    try expect(catalog.categories.count == 17 && catalog.tools.count >= 73)
    try expect(catalog.tools.contains { $0.id == "claude-code" && $0.isAI })
    try expect(catalog.tools.contains { $0.id == "nginx" && !$0.isAI })
    let object=try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as! [String:Any]
    var bad=object, tools=object["tools"] as! [[String:Any]]
    tools[0]["homepage"]="javascript:alert(1)"; bad["tools"]=tools
    try expectThrows { try DeveloperToolCatalog.decode(JSONSerialization.data(withJSONObject: bad)) }
    try expect(!DeveloperToolPackage(provider: "homebrew", kind: "formula", token: "--all").valid)
    try expect(!DeveloperToolPackage(provider: "homebrew", kind: "formula", token: "evil/tap/tool").valid)
    try expect(!DeveloperToolPackage(provider: "winget", kind: "package", token: "Some.Tool --force").valid)
}
func developerToolsRequireFrozenSingleUsePlansAndJournalResults() async throws {
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled(), platform=DeveloperFixturePlatform()
    let service=DeveloperToolService(catalog: catalog, platform: platform, makeStore: { fixture.store })
    let package=try require(catalog.tools.first { $0.id == "mkcert" }?.packages.first)
    let state=try await service.inspect(toolID: "mkcert", package: package)
    let plan=try await service.prepare(toolID: "mkcert", action: .install, expected: state)
    let result=try await service.execute(plan, confirmedID: plan.id)
    try expect(result.state == "succeeded" && result.observedVersions == ["1.0"])
    try expect(try fixture.store.read("developer-tool-intents", id: plan.id) != nil)
    try expect(try fixture.store.read("developer-tool-results", id: plan.id) != nil)
    try await expectThrows { try await service.execute(plan, confirmedID: plan.id) }
    let installed=try await service.inspect(toolID: "mkcert", package: package)
    let remove=try await service.prepare(toolID: "mkcert", action: .uninstall, expected: installed)
    try expect(try await service.execute(remove, confirmedID: remove.id).state == "succeeded")
    try expect(platform.calls == [.install, .uninstall])
}
func developerToolsRejectIdentityDriftExpiryAndUnrecordedMutation() async throws {
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled(), platform=DeveloperFixturePlatform(), clock=DeveloperFixtureClock()
    let package=try require(catalog.tools.first { $0.id == "mkcert" }?.packages.first)
    let service=DeveloperToolService(catalog: catalog, platform: platform, makeStore: { fixture.store }, now: { clock.date })
    for field in ["recipe","source","version","expiry","confirmation"] {
        platform.source="fixture-manager"; platform.recipe="fixture-recipe"; platform.installed=[]; clock.date=Date()
        let state=try await service.inspect(toolID: "mkcert", package: package)
        let plan=try await service.prepare(toolID: "mkcert", action: .install, expected: state)
        switch field {
        case "recipe": platform.recipe="changed"
        case "source": platform.source="changed"
        case "version": platform.installed=["another-version"]
        case "expiry": clock.date.addTimeInterval(121)
        default: break
        }
        try await expectThrows { try await service.execute(plan, confirmedID: field == "confirmation" ? "wrong" : plan.id) }
    }
    try expect(platform.calls.isEmpty)
    try await expectThrows { try await service.inspect(toolID: "nginx", package: package) }
    platform.installed=[]; platform.source="fixture-manager"; platform.recipe="fixture-recipe"
    let broken=DeveloperToolService(catalog: catalog, platform: platform, makeStore: { throw ShouError("io_error", "Generated journal failure.") })
    let state=try await broken.inspect(toolID: "mkcert", package: package)
    let plan=try await broken.prepare(toolID: "mkcert", action: .install, expected: state)
    try await expectThrows { try await broken.execute(plan, confirmedID: plan.id) }
    try expect(platform.calls.isEmpty)
}
func developerToolsDoNotTreatManagerCompletionAsSuccess() async throws {
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled(), platform=DeveloperFixturePlatform()
    platform.noChange=true
    let service=DeveloperToolService(catalog: catalog, platform: platform, makeStore: { fixture.store })
    let package=try require(catalog.tools.first { $0.id == "mkcert" }?.packages.first)
    let state=try await service.inspect(toolID: "mkcert", package: package)
    let plan=try await service.prepare(toolID: "mkcert", action: .install, expected: state)
    try expect(try await service.execute(plan, confirmedID: plan.id).state == "unknown")
}
func nativeDeveloperToolsUseGeneratedExactInstallAndUninstall() async throws {
    #if os(macOS)
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled()
    let script="""
    #!/bin/sh
    [ "$HOMEBREW_NO_AUTO_UPDATE" = "1" ] || exit 9
    [ "$HOMEBREW_NO_INSTALL_CLEANUP" = "1" ] || exit 10
    printf '%s\\n' "$@" >> "$HOME/arguments"
    if [ "$1" = info ] && [ "$2" = --json=v2 ] && [ "$3" = --formula ] && [ "$4" = mkcert ]; then
      if [ -f "$HOME/installed" ]; then v='[{"version":"1.0"}]'; else v='[]'; fi
      printf '{"formulae":[{"full_name":"mkcert","tap":"homebrew/core","installed":%s,"versions":{"stable":"1.0"},"dependencies":[],"revision":0}],"casks":[]}\\n' "$v"
    elif [ "$1" = install ] && [ "$2" = --formula ] && [ "$3" = mkcert ]; then
      printf 'generated fixture' > "$HOME/installed"
    elif [ "$1" = uninstall ] && [ "$2" = --formula ] && [ "$3" = mkcert ]; then
      /bin/rm "$HOME/installed"
    else exit 11; fi
    """
    try fixture.put("bin/brew", script)
    try fixture.put("database/personal-data", "generated retained database")
    let executable=fixture.workspace.appendingPathComponent("bin/brew")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let service=DeveloperToolService(catalog: catalog, platform: NativeDeveloperTools(homeDirectory: fixture.workspace, generatedExecutable: executable), makeStore: { fixture.store })
    let package=try require(catalog.tools.first { $0.id == "mkcert" }?.packages.first)
    for action in [DeveloperToolAction.install, .uninstall] {
        let inspection=try await service.inspect(toolID: "mkcert", package: package)
        let plan=try await service.prepare(toolID: "mkcert", action: action, expected: inspection)
        try expect(try await service.execute(plan, confirmedID: plan.id).state == "succeeded")
    }
    let log=try String(contentsOf: fixture.workspace.appendingPathComponent("arguments"), encoding: .utf8)
    try expect(log.contains("install\n--formula\nmkcert\n") && log.contains("uninstall\n--formula\nmkcert\n"))
    try expect(!log.contains("--force") && !log.contains("--zap") && !log.contains("sudo"))
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("database/personal-data"), encoding: .utf8) == "generated retained database")
    #endif
}
func developerDiscoveryPreservesMultipleCopiesWithoutExecutingThem() throws {
    #if os(macOS)
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled()
    for (folder,version) in [(".bun/install/global","1.0"),(".nvm/versions/node/v24","2.0"),("manual-node","3.0")] {
        try fixture.put(folder+"/lib/node_modules/@anthropic-ai/claude-code/package.json", "{\"name\":\"@anthropic-ai/claude-code\",\"version\":\"\(version)\"}")
        try fixture.put(folder+"/lib/node_modules/@anthropic-ai/claude-code/cli.js", "#!/bin/sh\nprintf executed > \"$HOME/should-not-exist\"\n")
        let target=fixture.workspace.appendingPathComponent(folder+"/lib/node_modules/@anthropic-ai/claude-code/cli.js")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let bin=fixture.workspace.appendingPathComponent(folder+"/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: target)
    }
    try fixture.put("manual/hermes", "#!/bin/sh\nexit 1\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.workspace.appendingPathComponent("manual/hermes").path)
    let directories=[".bun/install/global/bin",".nvm/versions/node/v24/bin","manual-node/bin","manual"].map { fixture.workspace.appendingPathComponent($0).path }
    let scan=try NativeDeveloperToolInventory(homeDirectory: fixture.workspace, generatedSearchDirectories: directories).scan(catalog)
    let copies=scan.installations.filter { $0.toolID == "claude-code" }
    try expect(copies.count == 3 && Set(copies.compactMap(\.version)) == ["1.0","2.0","3.0"])
    try expect(Set(copies.map(\.source)) == ["Bun storage", "nvm storage", "Node package"])
    try expect(copies.allSatisfy { $0.launchPaths.count == 1 && $0.launchPaths[0].hasSuffix("/bin/claude") && $0.path.hasSuffix("/cli.js") })
    try expect(scan.installations.contains { $0.toolID == "hermes" && $0.version == nil && $0.status == "detected" })
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("should-not-exist").path))
    #endif
}

func aiWorkspaceSummarizesNamesWithoutExposingPrivateValues() throws {
    let json=Data(#"{"mcpServers":{"fixture":{"command":"secret-command","args":["secret-argument"],"env":{"TOKEN":"secret-key"}}},"provider":{"fixture-provider":{"apiKey":"secret-key"}}}"#.utf8)
    try expect(try AIWorkspaceSummary.names(data: json, format: "json", kind: "mcp") == ["fixture"])
    try expect(try AIWorkspaceSummary.names(data: json, format: "json", kind: "configuration") == ["fixture-provider"])
    let toml=Data("[mcp_servers.fixture]\nenv={TOKEN=\"secret-key\"}\n[model_providers.fixture-provider]\napi_key=\"secret-key\"\n".utf8)
    try expect(try AIWorkspaceSummary.names(data: toml, format: "toml", kind: "mcp") == ["fixture"])
    try expect(try AIWorkspaceSummary.names(data: toml, format: "toml", kind: "configuration") == ["fixture-provider"])
    try expectThrows { try AIWorkspaceSummary.names(data: Data(repeating: 32, count: 262_145), format: "json", kind: "mcp") }
    try expectThrows { try AIWorkspaceSummary.names(data: Data("value='''\n[mcp_servers.fake]\n'''".utf8), format: "toml", kind: "mcp") }
    #if os(macOS)
    let fixture=try Fixture()
    try fixture.put(".claude.json", String(decoding: json, as: UTF8.self))
    try fixture.put(".claude/skills/generated/SKILL.md", "generated private body")
    try fixture.put(".claude/CLAUDE.md", "generated private instructions")
    try FileManager.default.createSymbolicLink(at: fixture.workspace.appendingPathComponent(".claude/settings.json"), withDestinationURL: fixture.workspace.appendingPathComponent(".claude.json"))
    let snapshot=try NativeAIWorkspace(homeDirectory: fixture.workspace).inspect(toolID: "claude-code")
    try expect(snapshot.resources.first { $0.kind == "configuration" }?.state == "unavailable")
    try expect(snapshot.resources.first { $0.kind == "mcp" }?.names == ["fixture"])
    try expect(snapshot.resources.first { $0.kind == "skills" }?.names == ["generated"])
    try expect(!snapshot.resources.flatMap(\.names).contains { $0.contains("secret") || $0.contains("private") })
    #endif
}
