import Foundation
import ShouCore
import ShouPlatform

private struct CleanupLocationFixture: CleanupLocationReading {
    let listing: [String: CleanupDirectoryListing]
    var volumes: [CleanupScanVolume]=[]
    func childDirectories(_ path: String) throws -> CleanupDirectoryListing { listing[path] ?? .init(paths: []) }
    func localVolumes() throws -> [CleanupScanVolume] { volumes }
}

func cleanupStandardScopeDiscoversArbitraryFoldersAndPreservesSavedPolicies() async throws {
    let fixture=try Fixture(), home=fixture.workspace.path
    try fixture.put("Documents/dev/one/Cargo.toml", "fixture")
    try fixture.put("Documents/dev/one/target/generated.bin")
    try fixture.put("Documents/客户工程/two/Cargo.toml", "fixture")
    try fixture.put("Documents/客户工程/two/target/generated.bin")
    try fixture.put("自定义目录/three/Cargo.toml", "fixture")
    try fixture.put("自定义目录/three/target/generated.bin")
    let reader=CleanupLocationFixture(listing: [home: .init(paths: [home + "/Documents", home + "/自定义目录", home + "/Library", home + "/.hidden", "/outside-injected"]),
        home + "/Documents": .init(paths: [home + "/Documents/dev", home + "/Documents/客户工程"])])
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace, cleanupLocations: reader)
    let saved=try await engine.addWorkspace(path: home + "/Documents/dev", rootRef: "saved-dev")
    _ = try await engine.setRule(ruleId: "shou.builtin.rust-target", workspaceId: saved.id, enabled: false)
    let before=try await engine.configuration()
    let locations=try await engine.projectLocations()
    try expect(Set(locations.map(\.path)) == Set([saved.path, home + "/Documents/客户工程", home + "/自定义目录"]))
    try expect(try await engine.configuration().revision == before.revision)
    let result=try await engine.scanKnownLocations(includeProjects: true)
    try expect(result.snapshots.count == 3)
    try expect(result.snapshots.first { $0.workspace.id == saved.id }?.candidates.allSatisfy { !$0.ruleIds.contains("shou.builtin.rust-target") } == true)
    try expect(result.snapshots.filter { $0.workspace.id != saved.id }.allSatisfy { $0.candidates.contains { $0.ruleIds.contains("shou.builtin.rust-target") } })
    try expect(try Digest.of(await engine.configuration().bindings) == Digest.of(before.bindings))
}

func cleanupFolderAndVolumeScopesStayWithinRequestedRoots() async throws {
    let fixture=try Fixture(), home=fixture.workspace.path
    for name in ["first", "second", "disk"] { try fixture.put(name + "/Cargo.toml", "fixture"); try fixture.put(name + "/target/generated.bin") }
    let reader=CleanupLocationFixture(listing: [home: .init(paths: [home + "/first", home + "/second"])],
        volumes: [.init(path: home + "/disk", name: "Generated disk", isSystem: false)])
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence(), homeDirectory: fixture.workspace, cleanupLocations: reader)
    let custom=try await engine.scanKnownLocations(includeProjects: true, scope: .folders([home + "/second", home + "/second"]))
    try expect(custom.snapshots.map { $0.workspace.path } == [home + "/second"])
    let disks=try await engine.projectLocations(scope: .volumes([home + "/disk"]))
    try expect(Set(disks.filter(\.exists).map(\.path)) == Set([home + "/first", home + "/second", home + "/disk"]))
    try await expectThrows { try await engine.projectLocations(scope: .volumes([home + "/not-mounted"])) }
    try await expectThrows { try await engine.projectLocations(scope: .folders([])) }
    try expect(try await engine.history().isEmpty)
}

func cleanupDiscoveryReportsIncompleteListingsWithoutExpandingSavedScopes() async throws {
    let fixture=try Fixture(), home=fixture.workspace.path
    try fixture.put("collection/child/keep.txt", "retain")
    let reader=CleanupLocationFixture(listing: [home: .init(paths: [home + "/collection"], complete: false)])
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace, cleanupLocations: reader)
    _ = try await engine.addWorkspace(path: home + "/collection", rootRef: "saved")
    let locations=try await engine.projectLocations()
    try expect(locations.contains { $0.path == home && $0.availabilityIssue != nil && !$0.exists })
    let scoped=try await engine.projectLocations(scope: .folders([home + "/collection/child"]))
    try expect(scoped.allSatisfy { !$0.exists } && scoped.contains { $0.availabilityIssue != nil })
    try expect(try String(contentsOfFile: home + "/collection/child/keep.txt", encoding: .utf8) == "retain")
}

func nativeCleanupLocationsListsOnlyImmediateRealDirectories() throws {
    let fixture=try Fixture(), home=fixture.workspace.path
    try fixture.put("自定义工程/nested/keep.txt")
    try fixture.put("plain-file.txt")
    try FileManager.default.createSymbolicLink(atPath: home + "/linked-project", withDestinationPath: home + "/自定义工程")
    let paths=try NativeCleanupLocations().childDirectories(home)
    try expect(paths.complete && paths.paths.contains(home + "/自定义工程"))
    try expect(!paths.paths.contains(home + "/linked-project") && !paths.paths.contains(home + "/plain-file.txt") && !paths.paths.contains(home + "/自定义工程/nested"))
}
