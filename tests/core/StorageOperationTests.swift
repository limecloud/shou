import Foundation
import ShouCore
import ShouPlatform

func storageReviewRefreshesDirectoryChangesBeforeConfirmation() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    // Build output can change between discovery and review. The confirmation
    // must describe the new complete manifest, while later changes still fail.
    try fixture.put("project/target/new-output.bin", "new generated build output")
    let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target"], action: "permanent")
    try expect(plan.items[0].manifest.contains { $0.path == "new-output.bin" })
    let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "completed" && receipt.items[0].state == "purged")
    try expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target").path))
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/Cargo.toml").path))
}

func storageIncompleteReviewReportsCauseAndRemainsRetryable() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: NativeFileSystem())
    try fixture.put("project/target/additional.bin", "generated fixture")
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    do {
        _ = try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target"], budget: ScanBudget(maxEntries: 1))
        throw CheckFailure(description: "Incomplete review must remain read-only.")
    } catch let error as ShouError {
        try expect(error.code == "resource_limit" && error.details["path"] == "project/target")
        try expect(error.details["reasons"]?.contains("resource_limit") == true)
    }
    try expect(try fixture.store.ids("storage-plans").isEmpty)
    let retry=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: ["project/target"])
    try expect(retry.items.count == 1)
}

func storageNativeRemovalReportsManifestProgress() async throws {
    let fixture=try Fixture(), native=NativeFileSystem()
    var values=[(Int, Int)]()
    let path=fixture.workspace.appendingPathComponent("project/target").path
    let tree=try native.inspectStorageTarget(path, budget: ScanBudget(), cancelled: { false })
    try native.purge(path, expected: tree.entries, progress: { done, total, _ in values.append((done, total)) })
    try expect(values.last?.0 == tree.entries.count && values.last?.1 == tree.entries.count)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/Cargo.toml").path))
}

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
    let excluded: Set<String>=["project/a/file.bin", "project/target"]
    let batch=StorageSelection.setting(excluded, selected: false, in: ["project"], index: index)
    try expect(!StorageSelection.contains("project/a/file.bin", in: batch))
    try expect(!StorageSelection.contains("project/target/artifact.bin", in: batch))
    try expect(StorageSelection.contains("project/b/other.bin", in: batch))
    try expect(StorageSelection.setting(excluded, selected: true, in: ["project"], index: index) == ["project"])
    try expect(StorageSelection.setting([], selected: false, in: selected, index: index) == selected)
    // Whole-folder selection must remain practical beyond the old bulk-reader
    // cutoff, including a filtered deselection from a selected ancestor.
    let nodes=(0..<70_000).map {
        StorageNode(path: "wide/file-\($0)", kind: "file", logicalBytes: 4096, allocatedBytes: 4096,
            fileCount: 1, newestModifiedNanoseconds: 0)
    }
    let wide=StorageIndex(nodes: nodes), paths=Set(nodes.map(\.path))
    let started=Date()
    let all=StorageSelection.setting(paths, selected: true, in: ["unrelated"], index: wide)
    try expect(all.count == 70_001 && all.contains("unrelated"))
    let filtered=Set(nodes.enumerated().filter { $0.offset.isMultiple(of: 2) }.map { $0.element.path })
    let remaining=StorageSelection.setting(filtered, selected: false, in: ["wide", "unrelated"], index: wide)
    try expect(remaining == paths.subtracting(filtered).union(["unrelated"]))
    try expect(!StorageSelection.contains("wide/file-0/child", in: remaining))
    try expect(StorageSelection.contains("wide/file-1/child", in: remaining))
    print("storage wide selection: entries=70000 select-and-filtered-deselect=\(String(format: "%.3f", Date().timeIntervalSince(started)))s")
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
    let fixture=try Fixture(), native=NativeFileSystem(scanPrivacyPolicy: .init(status: .limited, home: FileManager.default.homeDirectoryForCurrentUser.path))
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
    // Receipt verification may inspect exactly the moved target. Ordinary scans
    // retain their protected-Trash boundary even when the OS permits the read.
    let directory=try require(receipt.items.first { $0.relativePath == "project/target" }?.trashPath)
    try expectThrows { try native.inspect(directory, budget: ScanBudget(), cancelled: { false }) }
    try expectThrows { try native.inspectTrashTarget(fixture.workspace.path, budget: ScanBudget(), cancelled: { false }) }
    let trashInspection=try await engine.inspectHistory(executionId: receipt.id)
    try expect(trashInspection.items.allSatisfy { $0.state == "verified_trash" })
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
