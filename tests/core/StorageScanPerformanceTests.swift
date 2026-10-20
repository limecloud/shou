import Foundation
import ShouCore
import ShouPlatform

func storageBulkMetadataPreservesExactStatEvidence() throws {
    let fixture=try Fixture()
    let deep=(0..<20).map { "level-" + String($0) }.joined(separator: "/")
    for index in 0..<64 {
        try fixture.put(deep + "/数据-" + String(index) + "-é.bin", String(repeating: "x", count: index * 128))
    }
    try fixture.put("first/original", String(repeating: "h", count: 16_384))
    try fixture.put("second/keep", "keep")
    try FileManager.default.linkItem(at: fixture.workspace.appendingPathComponent("first/original"),
        to: fixture.workspace.appendingPathComponent("second/alias"))
    try FileManager.default.createSymbolicLink(atPath: fixture.workspace.appendingPathComponent("outside-link").path,
        withDestinationPath: "/Users")
    let sparse=fixture.workspace.appendingPathComponent("sparse.bin")
    try Data().write(to: sparse)
    let handle=try FileHandle(forWritingTo: sparse)
    try handle.truncate(atOffset: 16 * 1024 * 1024)
    try handle.close()
    let reference=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
    let url=fixture.base.appendingPathComponent("metadata-catalog.sqlite")
    let measurement=try fixture.fs.measureStorage(fixture.workspace.path, catalog: url, cancelled: { false }, progress: { _ in })
    let catalog=try StorageCatalog(url: url)
    var actual=[FileEntry]()
    try catalog.forEachEntry { actual.append($0) }
    try expect(reference.complete && measurement.tree.complete)
    try expect(measurement.entryCount == reference.entries.count)
    try expect(actual.sorted { $0.path < $1.path } == reference.entries.sorted { $0.path < $1.path })
    let expected=try require(StorageIndex(entries: reference.entries).nodes["."])
    let root=try require(catalog.entry(at: "."))
    try expect(root.node.logicalBytes == expected.logicalBytes && root.node.allocatedBytes == expected.allocatedBytes)
    try expect(root.node.fileCount == expected.fileCount)
    let sparseEntry=try require(catalog.entry(at: "sparse.bin"))
    try expect(sparseEntry.entry.logicalBytes == 16 * 1024 * 1024 && sparseEntry.entry.allocatedBytes < sparseEntry.entry.logicalBytes)
}

func storageCatalogParentIDsPreserveNestedNamesAndTotals() throws {
    let fixture=try Fixture(), url=fixture.base.appendingPathComponent("parent-catalog.sqlite")
    let catalog=try StorageCatalog(url: url, create: true)
    let identity=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    var root=try catalog.append(identity, name: ".", parentID: 0)
    var directory=identity; directory.path="nested"; directory.inode += 1
    var parent=try catalog.append(directory, name: "nested", parentID: root.id)
    var file=identity; file.path="nested/name.bin"; file.kind="file"; file.inode += 2
    file.links=1; file.logicalBytes=8192; file.allocatedBytes=8192
    let child=try catalog.append(file, name: "name.bin", parentID: parent.id)
    parent.node.logicalBytes += child.node.logicalBytes; parent.node.allocatedBytes += child.node.allocatedBytes
    parent.node.fileCount += child.node.fileCount; parent.node.isComplete=true
    try catalog.setTotals(parent.node, id: parent.id)
    root.node.logicalBytes += parent.node.logicalBytes; root.node.allocatedBytes += parent.node.allocatedBytes
    root.node.fileCount += parent.node.fileCount; root.node.isComplete=true
    try catalog.setTotals(root.node, id: root.id)
    try catalog.seal()
    let loaded=try StorageCatalog(url: url)
    try expect(try loaded.children(of: "nested").map(\.entry) == [file])
    try expect(try loaded.entry(at: "nested")?.node.allocatedBytes == parent.node.allocatedBytes)
    try expect(try loaded.entry(at: ".")?.node.fileCount == 1)
}
