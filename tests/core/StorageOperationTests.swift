import Foundation
import ShouCore
import ShouPlatform

func storageSelectionPreservesSiblingsAndDeduplicates() throws {
    let fixture=try Fixture()
    try fixture.put("project/a/file.bin"); try fixture.put("project/b/other.bin")
    let tree=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
    let index=StorageIndex(entries: tree.entries)
    try expect(StorageSelection.normalized(["project", "project/a", "project/a/file.bin"]) == ["project"])
    let selected=StorageSelection.toggle("project/a/file.bin", selected: false, paths: ["project"], index: index)
    try expect(!StorageSelection.contains("project/a/file.bin", in: selected))
    try expect(StorageSelection.contains("project/b/other.bin", in: selected))
    try expect(StorageSelection.contains("project/target/artifact.bin", in: selected))
    try expect(StorageSelection.toggle("project", selected: true, paths: selected, index: index) == ["project"])
    for invalid in [".", "../project", "/project", "a//b", "a/../b", "", "a/./b"] { try expect(!StorageRemovalPolicy.validRelative(invalid)) }
}

func storageAnalysisProtectsRootsAndDetectsChanges() async throws {
    let fixture=try Fixture(), native=NativeFileSystem()
    let engine=ShouEngine(store: fixture.store, filesystem: native)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    try expect(scan.tree.complete)
    try expect(try await engine.configuration().workspaces.isEmpty)
    try await expectThrows { try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["."]) }
    try await expectThrows { try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["../workspace"]) }
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target", "project/target/artifact.bin"], action: "permanent")
    try expect(plan.items.count == 1)
    try fixture.put("project/target/artifact.bin", "changed after review")
    let result=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(result.state == "partial" && result.items[0].state == "failed")
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/target/artifact.bin"), encoding: .utf8) == "changed after review")
    try await expectThrows { try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    var file=try require(scan.tree.entries.first { $0.path == "project/target/artifact.bin" }); file.owner=0
    for (root,path) in [("/", "System"), ("/System/Volumes/Data", "Users"), ("/", "Users/coso"), ("/", "Users/coso/.ssh"), ("/", "Users/coso/Library/CloudStorage"), ("/", "Applications")] {
        try expect(StorageRemovalPolicy.reason(root: root, path: path, entry: file, home: "/Users/coso", protectedPaths: []) != nil)
    }
    let partial=try await engine.scanStorage(path: fixture.workspace.path, budget: ScanBudget(maxEntries: 2))
    try expect(!partial.tree.complete && partial.tree.issues.contains("resource_limit"))
}

func storageRemovalRechecksCurrentExclusionsAndNewDescendants() async throws {
    let fixture=try Fixture(), native=NativeFileSystem()
    let engine=ShouEngine(store: fixture.store, filesystem: native)
    _ = try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "generated-workspace")
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project"], action: "permanent")
    _ = try await engine.setGlobalExclusion(pattern: "project/target/artifact.bin", remove: false)
    let result=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(result.items.first?.state == "skipped")
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
    _ = try await engine.setGlobalExclusion(pattern: "project/target/artifact.bin", remove: true)
    _ = try await engine.setGlobalExclusion(pattern: "project/target/keep.bin", remove: false)
    // Adding a grandchild need not change the selected parent's metadata.
    // The fresh complete subtree must still respect the exclusion.
    try fixture.put("project/target/keep.bin", "preserve this new descendant")
    try await expectThrows { try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project"], action: "permanent") }
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/keep.bin").path))
}

/// Native mutations touch only generated fixtures. Files moved to Trash are restored.
func storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: Bool = false) async throws {
    #if os(macOS)
    let fixture=try Fixture(), native=NativeFileSystem()
    let engine=ShouEngine(store: fixture.store, filesystem: native)
    let name="shou-space-generated-" + UUID().uuidString + ".bin"
    let target=fixture.workspace.appendingPathComponent(name)
    let bytes=Data(repeating: 91, count: 20_971_520)
    try bytes.write(to: target)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: [name, "project/target"])
    try expect(plan.items.count == 2)
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "completed" && receipt.operation == "storage_removal")
    try expect(receipt.items.allSatisfy { $0.state == "trashed" })
    let ids=receipt.items.map(\.id)
    let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" })
    try expect(try Data(contentsOf: target) == bytes)
    guard permanent else { return }
    let rescanned=try await engine.scanStorage(path: fixture.workspace.path)
    let permanent=try await engine.createStorageRemovalPlan(scanId: rescanned.id, paths: [name, "project/target"], action: "permanent")
    let removed=try await engine.executeStorageRemoval(planId: permanent.id, confirmedDigest: permanent.digest, entryPoint: "test")
    try expect(removed.state == "completed" && removed.items.allSatisfy { $0.state == "purged" })
    let inspection=try await engine.inspectHistory(executionId: removed.id)
    try expect(inspection.status == "complete" && inspection.items.allSatisfy { $0.state == "purged" })
    try await expectThrows { try await engine.followUpDigest(executionId: removed.id, itemIds: removed.items.map(\.id), action: "restore") }
    try expect(!FileManager.default.fileExists(atPath: target.path))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/Cargo.toml").path))
    #endif
}
