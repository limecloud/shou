import Foundation
import ShouCore

func moleRulesKeepProfilesGamesAndDeveloperState() async throws {
    struct Sample {
        let location: String
        let selected: [String]
        let retained: [String]
    }
    let samples: [Sample] = [
        .init(location: "steam", selected: ["htmlcache", "depotcache", "steamapps/shadercache", "logs"], retained: ["steamapps/common/Game", "steamapps/workshop", "userdata/account/remote", "config"]),
        .init(location: "minecraft", selected: ["webcache", "logs", "crash-reports"], retained: ["saves/World", "mods", "screenshots", "resourcepacks", "launcher_accounts"]),
        .init(location: "pcsx2", selected: ["cache"], retained: ["bios", "memcards", "sstates", "games"]),
        .init(location: "zed", selected: ["node/cache", "node/node-v22/cache"], retained: ["node/node-v22/bin", "extensions", "db", "settings"]),
        .init(location: "codebuddy-cn", selected: ["Cache", "CachedExtensionVSIXs", "logs"], retained: ["User/globalStorage", "User/workspaceStorage", "Backups", "extensions"]),
        .init(location: "qoder", selected: ["GPUCache", "CachedData", "logs"], retained: ["User/globalStorage", "User/workspaceStorage", "Backups", "projects"]),
        .init(location: "spacedrive", selected: ["thumbnails"], retained: ["libraries", "database", "files"]),
        .init(location: "wetype", selected: ["DictUpdate", "com.onevcat.Kingfisher.ImageCache.WeType"], retained: ["UserDictionary", "Engine", "settings"]),
        .init(location: "dia", selected: ["Default/GPUCache", "Profile 2/DawnWebGPUCache", "component_crx_cache"], retained: ["Default/Sessions", "Default/Local Storage", "Default/IndexedDB", "Default/Extensions", "Default/Network"]),
        .init(location: "dia-downloads", selected: ["Default/Cache", "Profile 2/Code Cache"], retained: ["Default/Cookies", "Default/History", "Default/Sessions"]),
        .init(location: "helium", selected: ["Default/GPUCache", "Profile 2/Application Cache", "ShaderCache"], retained: ["Default/Local Storage", "Default/Bookmarks", "Default/Login Data", "Default/Extensions"]),
        .init(location: "firefox-support", selected: ["account.default/cache2"], retained: ["account.default/storage", "account.default/bookmarkbackups", "account.default/sessionstore-backups", "account.default/extensions"]),
        .init(location: "vscode", selected: ["WebStorage/panel/CacheStorage", "logs"], retained: ["WebStorage/panel/IndexedDB", "User/globalStorage", "User/workspaceStorage", "Backups"]),
        .init(location: "notion", selected: ["Partitions/account/Service Worker/CacheStorage"], retained: ["Partitions/account/Service Worker/Database", "Partitions/account/IndexedDB", "Partitions/account/Local Storage"]),
        .init(location: "android-generated", selected: ["cache", "build-cache"], retained: ["avd/Personal.avd", "debug.keystore", "adbkey", "repositories"]),
        .init(location: "expo-downloads", selected: ["schema-cache", "native-modules-cache"], retained: ["state", "devices", "settings", "credentials"]),
        .init(location: "opam-downloads", selected: ["download-cache"], retained: ["default/bin", "default/lib", "repo", "config"]),
        .init(location: "docker-buildx", selected: ["cache"], retained: ["instances", "refs", "activity", "current"]),
        .init(location: "application-logs", selected: ["Zed", "Claude", "JetBrains"], retained: ["OtherApp", "PersonalDiagnostics"])
    ]
    let fixture=try Fixture()
    let locations=try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "macos")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    for sample in samples {
        let location=try require(locations.first { $0.id == sample.location })
        let prefix=String(location.path.dropFirst(fixture.workspace.path.count + 1))
        for path in sample.selected + sample.retained { try fixture.put(prefix + "/" + path + "/payload.bin") }
        let workspace=try await engine.addWorkspace(path: location.path, rootRef: "mole-boundary-" + location.id)
        let rules=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos")
        let tree=try fixture.fs.inspect(location.path, budget: ScanBudget(), cancelled: { false })
        let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: rules, now: Date())
        for path in sample.selected { try expect(candidates.contains { $0.relativePath == path && $0.eligible }) }
        for path in sample.retained {
            try expect(!candidates.contains { $0.eligible && ($0.relativePath == path || path.hasPrefix($0.relativePath + "/")) })
        }
    }
}

func moleRulesRetainProtectedContentsAndPlatformBoundaries() async throws {
    let fixture=try Fixture()
    let templates=try BuiltinCatalog.templates().filter { $0.platforms == ["macos"] }
    try expect(!templates.isEmpty)
    let locations=try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "macos")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace)
    for template in templates {
        let location=try require(locations.first { $0.id == template.location })
        let relative=template.patterns[0].replacingOccurrences(of: "*", with: "fixture")
        let prefix=String(location.path.dropFirst(fixture.workspace.path.count + 1))
        try fixture.put(prefix + "/" + relative + "/identity.pem", "generated protected fixture")
        let workspace=try await engine.workspaceForKnownLocation(location.id)
        let tree=try fixture.fs.inspect(location.path, budget: ScanBudget(), cancelled: { false })
        let rule=try template.rule(rootRef: workspace.rootRef)
        let candidates=try Analysis.candidates(tree: tree, workspace: workspace, rules: [rule], now: Date())
        let target=try require(candidates.first { $0.relativePath == relative })
        try expect(!target.eligible && target.reasons.contains("protected_content"))
        try expect(rule.platforms == ["macos"] && !rule.scope.followSymlinks && !rule.scope.crossFilesystems)
        try expect(!template.patterns.contains { ["**", "*", "User", "userdata", "saves", "profiles", "Sessions"].contains($0) })
        let windows=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "windows")
        try expect(!windows.contains { $0.id == template.id })
    }
}
