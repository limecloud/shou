import Foundation
import ShouCore

func builtinDiscoveryWorksWithoutImport() async throws {
    let fixture=try Fixture()
    try fixture.put("web/package.json", "{}")
    try fixture.put("web/node_modules/package/index.js")
    try fixture.put("web/.next/cache/data.bin")
    try fixture.put("unknown/target/keep.bin")
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    let target=try require(scan.candidates.first { $0.relativePath == "project/target" })
    try expect(target.eligible && target.ruleIds == ["shou.builtin.rust-target"])
    let dependencies=try require(scan.candidates.first { $0.relativePath == "web/node_modules" })
    try expect(dependencies.eligible && dependencies.risk == "high")
    try expect(scan.candidates.first { $0.relativePath == "web/.next" }?.eligible == true)
    try expect(scan.candidates.first { $0.relativePath == "unknown/target" }?.eligible == false)
    try expect(try await engine.configuration().rules.isEmpty)
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [target.id])
    let result=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(result.state == "completed")
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("unknown/target/keep.bin").path))
}

func disablingBuiltinInvalidatesPlan() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: FixtureFileSystem(native: fixture.fs, trash: fixture.trash), artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    let candidate=try require(scan.candidates.first(where: \.eligible))
    let plan=try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id])
    _ = try await engine.setRule(ruleId: "shou.builtin.rust-target", workspaceId: root.id, enabled: false)
    try await expectThrows { try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    let fresh=try await engine.scan(workspaceId: root.id)
    try expect(fresh.candidates.allSatisfy { !$0.eligible })
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func builtinCatalogScopeAndNamespace() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "npm")
    let rules=try await engine.builtinRules(workspaceId: root.id)
    try expect(!rules.contains { $0.id == "shou.builtin.npm-cache" })
    for template in try BuiltinCatalog.templates() { _ = try template.rule(rootRef: "test-workspace") }
    let forged=try require(rules.first)
    try await expectThrows { try await engine.importRule(Codec.encode(forged)) }
    let preset=try await engine.savePreset(name: "Built-in cleanup", workspaceId: root.id, ruleIds: ["shou.builtin.rust-target"])
    try expect(try await engine.scan(workspaceId: root.id, ruleIds: preset.ruleIds).candidates.contains(where: \.eligible))
}

func builtinCatalogBindingPreservesValidationAndIsolation() async throws {
    let fixture=try Fixture()
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    var workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "binding-first")
    let templates=try BuiltinCatalog.templates().filter { $0.location == "projects" && $0.supportedPlatforms.contains("macos") }
    let expected=try templates.map { try $0.rule(rootRef: workspace.rootRef) }
    try expect(!expected.isEmpty)
    try expect(try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos") == expected)
    workspace.rootRef="binding-second"
    let second=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos")
    try expect(second.allSatisfy { $0.scope.rootRef == "binding-second" })
    try expect(expected.allSatisfy { $0.scope.rootRef == "binding-first" })
    for root in ["", "Invalid", "../outside", String(repeating: "a", count: 81)] {
        workspace.rootRef=root
        try expectThrows { try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos") }
    }
    workspace.rootRef="binding-benchmark"
    let firstLocations=try KnownLocations.catalog(homeDirectory: fixture.workspace, platform: "macos")
    let otherHome=fixture.base.appendingPathComponent("other-home")
    let secondLocations=try KnownLocations.catalog(homeDirectory: otherHome, platform: "macos")
    try expect(firstLocations.map(\.ruleIds) == secondLocations.map(\.ruleIds))
    try expect(secondLocations.allSatisfy { $0.path.hasPrefix(otherHome.path + "/") && !$0.exists && $0.availabilityIssue == nil })
    let started=Date()
    for _ in 0..<40 {
        try expect(try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos").count == expected.count)
    }
    print("builtin binding benchmark: iterations=40 rules=\(expected.count) elapsed=\(String(format: "%.6f", Date().timeIntervalSince(started)))s")
}

func builtinRulesPreserveProtectedDescendants() async throws {
    let fixture=try Fixture()
    try fixture.put("project/target/.env", "preserve")
    try fixture.put("web/package.json", "{}")
    try fixture.put("web/node_modules/private/key.pem", "preserve")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    for path in ["project/target", "web/node_modules"] {
        let candidate=try require(scan.candidates.first { $0.relativePath == path })
        try expect(!candidate.eligible && candidate.reasons.contains("protected_content"))
        try await expectThrows { try await engine.createPlan(scanId: scan.id, candidateIds: [candidate.id]) }
    }
}

func storageAccountingAndTreemapConserveArea() throws {
    func entry(_ path: String, kind: String = "directory", inode: UInt64, bytes: Int64 = 0, modified: Int64 = 0) -> FileEntry {
        FileEntry(path: path, kind: kind, device: 1, inode: inode, logicalBytes: bytes, allocatedBytes: bytes, modifiedNanoseconds: modified, changedNanoseconds: 0, mode: 0, owner: 1, links: 1)
    }
    let entries=[entry(".", inode: 1), entry("a", inode: 2), entry("b", inode: 3), entry("a/data", kind: "file", inode: 4, bytes: 80, modified: 5), entry("b/linked", kind: "file", inode: 4, bytes: 80), entry("b/data", kind: "file", inode: 5, bytes: 20), entry("b/external", kind: "symlink", inode: 6, bytes: 1000)]
    let index=StorageIndex(entries: entries)
    try expect(index.nodes["."]?.allocatedBytes == 100)
    try expect(index.nodes["b"]?.allocatedBytes == 20)
    try expect(index.nodes["."]?.newestModifiedNanoseconds == 5)
    try expect(index.children().map(\.path) == ["a", "b"])
    for (width,height) in [(100.0,100.0),(800.0,300.0),(100.0,900.0)] {
        let tiles=SpaceMap.layout(index.children(), width: width, height: height)
        try expect(tiles.count == 2)
        try expect(abs(tiles.reduce(0) { $0 + $1.width*$1.height } - width*height) < 0.0001)
        let first=try require(tiles.first)
        try expect(abs(first.width*first.height/(width*height)-0.8) < 0.00001)
        for tile in tiles { try expect(tile.x >= 0 && tile.y >= 0 && tile.x+tile.width <= width+0.0001 && tile.y+tile.height <= height+0.0001) }
    }
    try expect(SpaceMap.layout(index.children(), width: .nan, height: 100).isEmpty)
    let deep=StorageIndex(entries: [
        entry("项目/缓存/对象/data", kind: "file", inode: 14, bytes: 32, modified: 9),
        entry("项目-archive", kind: "file", inode: 15, bytes: 8),
        entry("项目/缓存/对象", inode: 13), entry("项目", inode: 11),
        entry(".", inode: 10), entry("项目/缓存", inode: 12)
    ])
    try expect(deep.nodes["."]?.allocatedBytes == 40)
    try expect(deep.nodes["项目"]?.allocatedBytes == 32)
    try expect(deep.nodes["项目/缓存"]?.fileCount == 1)
    try expect(deep.nodes["."]?.newestModifiedNanoseconds == 9)
}

func cleanupOverviewDoesNotDoubleCount() async throws {
    let fixture=try Fixture()
    try fixture.put("project/target/nested/__pycache__/module.pyc")
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, artifactEvidence: ArtifactFixtureEvidence())
    let root=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let scan=try await engine.scan(workspaceId: root.id)
    let overview=CleanupOverview.candidates(scan.candidates)
    try expect(overview.count == 1 && overview[0].relativePath == "project/target")
    try expect(CleanupOverview.categories(scan.candidates).reduce(0) { $0 + $1.allocatedBytesEstimate } == overview[0].allocatedBytesEstimate)
}
