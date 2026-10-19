import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin
#endif

func fileTargetsRequireBoundedContentEvidenceAndKeepLegacyManifestsStable() throws {
    let fixture=try Fixture(), path=fixture.workspace.appendingPathComponent("preferences.plist")
    let bytes=Data("generated personal preference fixture".utf8)
    try bytes.write(to: path)
    let tree=try fixture.fs.inspectTarget(path.path, budget: ScanBudget(), cancelled: { false })
    let file=try require(tree.entries.first)
    try expect(tree.complete && tree.entries.count == 1 && file.kind == "file" && file.contentDigest == Digest.sha256(bytes))
    var ctime=file; ctime.changedNanoseconds += 1
    try expect(ctime.matchesTrashRoot(as: file))
    for key in ["digest", "mtime", "mode", "identity", "path", "links"] {
        var changed=ctime
        switch key {
        case "digest": changed.contentDigest=Digest.sha256(Data("changed".utf8))
        case "mtime": changed.modifiedNanoseconds += 1
        case "mode": changed.mode ^= 0o010
        case "identity": changed.inode += 1
        case "path": changed.path="child"
        default: changed.links += 1
        }
        try expect(!changed.matchesTrashRoot(as: file))
    }
    let legacy=file.metadata
    let encoded=try Codec.encode(legacy)
    try expect(!String(decoding: encoded, as: UTF8.self).contains("content_digest"))
    try expect(try Codec.decode(FileEntry.self, from: encoded) == legacy)
    try expect(!legacy.matchesTrashRoot(as: legacy))
    try expectThrows { try fixture.fs.inspectTarget(path.path, budget: ScanBudget(maxEntries: 0), cancelled: { false }) }
    try expectThrows { try fixture.fs.inspectTarget(path.path, budget: ScanBudget(), cancelled: { true }) }
    let linked=fixture.workspace.appendingPathComponent("linked.plist")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: path)
    try expectThrows { try fixture.fs.inspectTarget(linked.path, budget: ScanBudget(), cancelled: { false }) }
    let oversized=fixture.workspace.appendingPathComponent("large.plist")
    try Data(repeating: 0, count: 16_777_217).write(to: oversized)
    try expectThrows { try fixture.fs.inspectTarget(oversized.path, budget: ScanBudget(), cancelled: { false }) }
    #if os(macOS)
    let fifo=fixture.workspace.appendingPathComponent("fifo.plist")
    try expect(mkfifo(fifo.path, 0o600) == 0)
    try expectThrows { try fixture.fs.inspectTarget(fifo.path, budget: ScanBudget(), cancelled: { false }) }
    #endif
    try expect(try Data(contentsOf: path) == bytes)
}

/// This native test moves only its generated file and always restores it; no purge.
func nativeFileTargetTrashAndConflictSafeRestore() async throws {
    #if os(macOS)
    let fixture=try Fixture(), native=NativeFileSystem()
    let path=fixture.workspace.appendingPathComponent("shou-generated-preference-" + UUID().uuidString + ".plist")
    let bytes=Data("generated file target; restore the exact content".utf8)
    try bytes.write(to: path)
    let original=try native.inspectTarget(path.path, budget: ScanBudget(), cancelled: { false })
    let moved=try native.moveToTrash(path.path, expected: original.entries)
    try expect(moved.verified && native.isTrashLocation(moved.path))
    try expect(moved.manifest.first?.contentDigest == Digest.sha256(bytes))
    try expect(!FileManager.default.fileExists(atPath: path.path))
    // A later file at the destination must survive an attempted restoration.
    let conflict=Data("new destination content must survive".utf8)
    try conflict.write(to: path)
    try expectThrows { try native.restore(moved.path, to: path.path, expected: moved.manifest) }
    try expect(try Data(contentsOf: path) == conflict)
    try FileManager.default.moveItem(at: path, to: fixture.workspace.appendingPathComponent("retained-conflict.plist"))
    try native.restore(moved.path, to: path.path, expected: moved.manifest)
    try expect(try Data(contentsOf: path) == bytes)
    try expect(!FileManager.default.fileExists(atPath: moved.path))
    let restored=try native.inspectTarget(path.path, budget: ScanBudget(), cancelled: { false })
    try expect(restored.entries.first?.matchesTrashRoot(as: original.entries[0]) == true)
    #endif
}
