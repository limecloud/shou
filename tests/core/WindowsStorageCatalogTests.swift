import Foundation
import ShouCore
import CSQLite

func storageCatalogPreservesWindowsIdentitiesAndHardLinks() throws {
    let fixture=try Fixture(), url=try require(fixture.store.storageCatalogURL(id: "windows-identities"))
    let volume=UInt64.max - 123
    var root=FileEntry(path: ".", kind: "directory", device: volume, inode: 0, logicalBytes: 0, allocatedBytes: 0,
        modifiedNanoseconds: 10, changedNanoseconds: 20, mode: 16, owner: 0, links: 1)
    root.windowsIdentity=WindowsFileIdentity(volume: volume, fileId: "0123456789abcdef0123456789abcdef", ownerSid: "S-1-5-21-100-200-300-1001")
    func file(_ name: String, _ fileID: String, on device: UInt64 = volume) -> FileEntry {
        var entry=root; entry.path=name; entry.kind="file"; entry.links=2; entry.mode=32
        entry.logicalBytes=2_097_152; entry.allocatedBytes=2_097_152; entry.device=device
        entry.windowsIdentity=WindowsFileIdentity(volume: device, fileId: fileID, ownerSid: root.windowsIdentity!.ownerSid)
        return entry
    }
    let first=file("a.bin", "aaaaaaaaaaaaaaaa0000000000000001")
    let second=file("b.bin", "aaaaaaaaaaaaaaaa0000000000000002")
    let alias=file("c.bin", first.windowsIdentity!.fileId)
    let anotherVolume=file("d.bin", first.windowsIdentity!.fileId, on: volume - 1)
    let entries=[root, first, second, alias, anotherVolume]
    do {
        let catalog=try StorageCatalog(url: url, create: true)
        var total=try catalog.append(root)
        for entry in entries.dropFirst() {
            let node=try catalog.append(entry)
            total.logicalBytes += node.logicalBytes; total.allocatedBytes += node.allocatedBytes; total.fileCount += node.fileCount
        }
        total.isComplete=true; try catalog.setTotals(total); try catalog.seal()
    }
    let catalog=try StorageCatalog(url: url)
    var loaded=[FileEntry]()
    try catalog.forEachEntry { loaded.append($0) }
    try expect(loaded.sorted { $0.path < $1.path } == entries)
    try expect(try catalog.entry(at: ".")?.entry.windowsIdentity == root.windowsIdentity)
    try expect(try catalog.entry(at: ".")?.node.allocatedBytes == 6_291_456)
    try expect(try catalog.entry(at: ".")?.node.fileCount == 4)
    try expect(try catalog.entry(at: "c.bin")?.node.allocatedBytes == 0)
    try expect(try catalog.entry(at: "b.bin")?.node.allocatedBytes == 2_097_152)
    try expect(try catalog.entry(at: "d.bin")?.node.allocatedBytes == 2_097_152)
    try expect(StorageIndex(entries: entries).nodes["."]?.allocatedBytes == 6_291_456)
}

func storageCatalogRetainsLegacySchemaAndRejectsCorruptWindowsIdentity() throws {
    let fixture=try Fixture()
    func execute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        try expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }
    let legacy=try require(fixture.store.storageCatalogURL(id: "legacy-schema"))
    try execute(legacy, "PRAGMA user_version=1; CREATE TABLE entries(id INTEGER PRIMARY KEY,path TEXT,parent INTEGER,name TEXT,kind TEXT,device INTEGER,inode INTEGER,logical INTEGER,allocated INTEGER,modified INTEGER,changed INTEGER,mode INTEGER,owner INTEGER,links INTEGER,total_logical INTEGER,total_allocated INTEGER,files INTEGER,newest INTEGER,complete INTEGER); INSERT INTO entries VALUES(1,'.',0,'.','directory',7,8,0,4096,10,20,448,501,1,0,4096,0,10,1);")
    let old=try StorageCatalog(url: legacy)
    let oldRoot=try require(old.entry(at: "."))
    try expect(oldRoot.entry.device == 7 && oldRoot.entry.inode == 8 && oldRoot.entry.windowsIdentity == nil)
    try expect(oldRoot.node.allocatedBytes == 4096 && oldRoot.node.isComplete == true)
    let url=try require(fixture.store.storageCatalogURL(id: "corrupt-windows-schema"))
    do {
        let catalog=try StorageCatalog(url: url, create: true)
        var root=oldRoot.entry
        root.windowsIdentity=WindowsFileIdentity(volume: 7, fileId: "00000000000000000000000000000008", ownerSid: "S-1-5-21-501")
        _ = try catalog.append(root); try catalog.seal()
    }
    try execute(url, "UPDATE entries SET windows_owner_sid=NULL;")
    try expectThrows { _ = try StorageCatalog(url: url).entry(at: ".") }
    try execute(url, "UPDATE entries SET windows_owner_sid='S-1-5-21-501',windows_file_id='truncated';")
    try expectThrows { _ = try StorageCatalog(url: url).entry(at: ".") }
}

func storageCatalogPagesDirectoryWorkWhileDescendantsAreInserted() throws {
    let fixture=try Fixture(), url=try require(fixture.store.storageCatalogURL(id: "directory-work"))
    let catalog=try StorageCatalog(url: url, create: true)
    let root=try fixture.fs.analysisRootIdentity(fixture.workspace.path)
    let parent=try catalog.append(root, name: ".", parentID: 0)
    for index in 0..<503 {
        var entry=root; entry.path=String(format: "directory-%03d", index); entry.inode += UInt64(index + 1)
        _ = try catalog.append(entry, name: entry.path, parentID: parent.id)
    }
    var visited=[String]()
    try catalog.forEachChildDirectory(parentID: parent.id) { id, row in
        visited.append(row.entry.path)
        var child=row.entry; child.path += "/nested"; child.inode += 10_000
        _ = try catalog.append(child, name: "nested", parentID: id)
        var total=row.node; total.isComplete=true
        try catalog.setTotals(total, id: id)
    }
    try expect(visited.count == 503 && Set(visited).count == 503 && visited == visited.sorted())
    try expect(visited.last == "directory-502")
    try catalog.seal()
    try expect(try catalog.entry(at: "directory-502/nested")?.entry.path == "directory-502/nested")
}
