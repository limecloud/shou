import Foundation
import ShouCore
import ShouPlatform

func storageBrowsingSelectionSharesProtectionAndHierarchyWithoutMutation() async throws {
    for indexed in [false, true] {
        let fixture=try Fixture()
        try fixture.put("project/a/file.bin"); try fixture.put("project/b/other.bin")
        try fixture.put(".ssh/fixture-key", "generated protected fixture")
        let fs: any PlatformFileSystem=indexed ? fixture.fs : FixtureFileSystem(native: fixture.fs, trash: fixture.trash)
        let engine=ShouEngine(store: fixture.store, filesystem: fs, homeDirectory: fixture.workspace)
        let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "browse-fixture")
        let scan=try await engine.scanStorage(path: fixture.workspace.path)
        try expect((scan.catalogId != nil) == indexed)
        let before=try Digest.of(await engine.configuration())
        let browse=try await engine.storageBrowsePage(scanId: scan.id)
        try expect(browse.removalReasons[".ssh"] != nil && browse.removalReasons["project"] == nil)
        let selected=try await engine.storageSelection(scanId: scan.id, paths: [], targets: ["project", "project/a/file.bin"], selected: true)
        try expect(selected.paths == ["project"])
        let reduced=try await engine.storageSelection(scanId: scan.id, paths: selected.paths, targets: ["project/a/file.bin"], selected: false)
        try expect(!StorageSelection.contains("project/a/file.bin", in: Set(reduced.paths)))
        try expect(StorageSelection.contains("project/b/other.bin", in: Set(reduced.paths)))
        try expect(StorageSelection.contains("project/target/artifact.bin", in: Set(reduced.paths)))
        try expect(reduced.allocatedBytes < selected.allocatedBytes)
        try expect(try await engine.storageSelection(scanId: scan.id, paths: reduced.paths, targets: ["project"], selected: false).paths.isEmpty)
        for invalid in [["."], ["../project"], ["absent"], ["project", "project"], [".ssh"]] {
            try await expectThrows { try await engine.storageSelection(scanId: scan.id, paths: [], targets: invalid, selected: true) }
        }
        try expect(try Digest.of(await engine.configuration()) == before)
        try expect(try fixture.store.ids("storage-plans").isEmpty && fixture.store.ids("history").isEmpty)
        _ = try await engine.setExclusion(workspaceId: workspace.id, pattern: "project/b/**", remove: false)
        let changed=try await engine.storageBrowsePage(scanId: scan.id)
        try expect(changed.removalReasons["project"] != nil)
        try await expectThrows { try await engine.storageSelection(scanId: scan.id, paths: [], targets: ["project"], selected: true) }
        try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("project/b/other.bin"), encoding: .utf8) == "fixture")
    }
}

func storageBrowsingPagesAreBoundedAndExpandedSelectionsNeverTruncate() async throws {
    let fixture=try Fixture()
    for index in 0..<202 { try fixture.put("wide/file-\(index).bin") }
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let first=try await engine.storageBrowsePage(scanId: scan.id, path: "wide")
    try expect(first.directory.children.count == 200 && first.directory.totalCount == 202 && first.directory.nextOffset == 200)
    let second=try await engine.storageBrowsePage(scanId: scan.id, path: "wide", offset: 200)
    try expect(second.directory.children.count == 2 && second.directory.nextOffset == nil)
    let target="wide/file-201.bin"
    let selection=try await engine.storageSelection(scanId: scan.id, paths: ["wide"], targets: [target], selected: false)
    try expect(selection.paths.count == 201 && !selection.paths.contains(target))
    try await expectThrows { try await engine.storageSelection(scanId: scan.id, paths: [], targets: (0...5000).map { "wide/file-\($0).bin" }, selected: true) }
    try await expectThrows { try await engine.storageBrowsePage(scanId: scan.id, path: "wide", offset: -1) }
    try expect(try fixture.store.ids("storage-plans").isEmpty)
}
