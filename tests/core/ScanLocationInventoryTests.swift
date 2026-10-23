import Foundation
import ShouCore

func scanLocationInventoryDistinguishesAutomaticIncludedAndCacheRoots() async throws {
    let fixture=try Fixture()
    try fixture.put("Projects/one/Cargo.toml", "fixture")
    try fixture.put("extra-collection/keep.txt", "retain generated fixture")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace)
    let automatic=try await engine.addWorkspace(path: fixture.workspace.path + "/Projects/one", rootRef: "automatic-fixture")
    let extra=try await engine.addWorkspace(path: fixture.workspace.path + "/extra-collection", rootRef: "included-fixture")
    let cache=try require(KnownLocations.catalog(homeDirectory: fixture.workspace, platform: fixture.fs.platform).first)
    try FileManager.default.createDirectory(atPath: cache.path, withIntermediateDirectories: true)
    _ = try await engine.addWorkspace(path: cache.path, rootRef: "cache-fixture")
    let before=try Digest.of(await engine.configuration())
    let inventory=try await engine.scanLocations()
    try expect(try await engine.configuration().revision == inventory.configurationRevision)
    try expect(inventory.entries.contains { $0.workspaceId == automatic.id && $0.origin == "automatic" && !$0.canRemove })
    try expect(inventory.entries.contains { $0.workspaceId == extra.id && $0.origin == "included" && $0.canRemove && $0.availability == "available" })
    try expect(inventory.entries.contains { $0.id == cache.id && $0.origin == "builtin" && !$0.canRemove && $0.workspaceId == nil })
    try expect(inventory.entries.filter { $0.path == cache.path }.count == 1)
    try expect(try Digest.of(await engine.configuration()) == before)
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("extra-collection/keep.txt"), encoding: .utf8) == "retain generated fixture")
    try expect(try fixture.store.ids("scans").isEmpty && fixture.store.ids("history").isEmpty)
}

func conventionalLocationScopeUsesPlatformPathBoundaries() throws {
    let home=URL(fileURLWithPath: "/C:/Users/fixture", isDirectory: true)
    try expect(try ProjectLocations.isConventional("c:\\USERS\\fixture\\PROJECTS\\one", homeDirectory: home, platform: "windows"))
    try expect(try ProjectLocations.isConventional("C:/Users/fixture/Documents/dev", homeDirectory: home, platform: "windows"))
    try expect(try !ProjectLocations.isConventional("C:/Users/fixture/Projects-archive", homeDirectory: home, platform: "windows"))
    try expect(try !ProjectLocations.isConventional("D:/Users/fixture/Projects", homeDirectory: home, platform: "windows"))
    let macHome=URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    try expect(try ProjectLocations.isConventional("/Users/fixture/Projects/one", homeDirectory: macHome, platform: "macos"))
    try expect(try !ProjectLocations.isConventional("/Users/fixture/PROJECTS/one", homeDirectory: macHome, platform: "macos"))
}
