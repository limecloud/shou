import Foundation
import ShouCore
import ShouPlatform
import CShouWindows

func windowsStorageMeasurementPreservesIdentitiesAndNativeCursors(root: String) throws {
    let fs=NativeFileSystem(), path=root + "/storage-measurement"
    try privateDirectory(path)
    for name in ["a", "z-later"] { try privateDirectory(path + "/" + name) }
    try write(path + "/a/first.bin", String(repeating: "x", count: 8192))
    try write(path + "/z-later/second.bin", String(repeating: "z", count: 4096))
    try FileManager.default.linkItem(atPath: path + "/a/first.bin", toPath: path + "/z-later/alias.bin")
    let store=try LocalRecordStore(directory: URL(fileURLWithPath: root + "/storage-records"))
    let url=try store.storageCatalogURL(id: "native-measurement")!
    let measured=try fs.measureStorage(path, catalog: url, cancelled: { false }, progress: { _ in })
    try require(measured.tree.complete && measured.entryCount == 6, "Native streaming measurement lost entries or coverage")
    // Reopen through the store, including on elevated CI accounts whose token
    // default owner can be Administrators. Direct SQLite reads bypass this gate.
    try require(try store.storageCatalogURL(id: "native-measurement") == url, "SQLite catalog must retain the current user's private ownership")
    var catalogIdentity=shou_win_info();try native(shou_win_stat(url.path,&catalogIdentity))
    try require(catalogIdentity.current_user==1 && catalogIdentity.links==1 && catalogIdentity.kind==1, "Private catalog identity is invalid")
    let unchanged=try Data(contentsOf: url)
    try require(shou_win_create_private_catalog(url.path)==80, "Creating a catalog must refuse an existing database")
    try require(try Data(contentsOf: url)==unchanged, "Existing database was overwritten during catalog creation")
    do {
        let catalog=try StorageCatalog(url: url), baseline=try fs.inspect(path, budget: ScanBudget(), cancelled: { false })
        let expected=StorageIndex(entries: baseline.entries)
        var entries=[FileEntry](); try catalog.forEachEntry { entries.append($0) }
        try require(entries.sorted { $0.path < $1.path } == baseline.entries, "SQLite lost Windows file identities or metadata")
        let total=try catalog.entry(at: ".")!
        try require(total.node.allocatedBytes == expected.nodes["."]?.allocatedBytes && total.node.fileCount == 3,
            "Native hard links must be charged once without hiding file names")
        try require(try catalog.entry(at: "z-later")?.node.isComplete == true, "Later sibling directory was not measured")
    }
    var raw=shou_win_info(), cursor: OpaquePointer?
    try native(shou_win_stat(path, &raw)); try native(shou_win_directory_open(path, &raw, &cursor))
    guard let cursor else { throw Failure(message: "Native directory cursor missing") }
    defer { shou_win_directory_close(cursor) }
    var names=Set<String>()
    while true {
        var value: UnsafeMutablePointer<CChar>?
        let code=shou_win_directory_next(cursor, &value)
        defer { shou_win_free(value) }
        if code == 18 { break }
        try native(code)
        guard let value else { throw Failure(message: "Native cursor returned no name") }
        names.insert(String(cString: value))
    }
    try require(names == ["a", "z-later"], "Cursor names are incomplete")
    try native(shou_win_directory_verify(cursor, &raw))
    try write(path + "/new-child.bin", "changed while enumerating")
    try require(shou_win_directory_verify(cursor, &raw) != 0, "Cursor must detect directory changes")
    let cancelledURL=try store.storageCatalogURL(id: "cancelled-measurement")!
    do {
        _ = try fs.measureStorage(path, catalog: cancelledURL, cancelled: { true }, progress: { _ in })
        throw Failure(message: "Cancelled measurement succeeded")
    } catch let error as ShouError { try require(error.code == "cancelled", "Unexpected measurement cancellation error") }
    try require(!FileManager.default.fileExists(atPath: cancelledURL.path), "An already cancelled measurement must not create an index")
    try require(try store.ids("storage-scans").isEmpty, "Direct measurements must not publish scan records")
    print("PASS native storage cursors, complete Windows identities, hard links, sibling coverage and cancellation")

    let large=path + "/large-file.bin", bytes=Data(repeating: 0x65, count: 17 * 1024 * 1024)
    try bytes.withUnsafeBytes { try native(shou_win_write(large, $0.baseAddress, $0.count)) }
    let largeTree=try fs.inspectStorageTarget(large, budget: ScanBudget(), cancelled: { false })
    try require(largeTree.complete && largeTree.entries.count == 1 && largeTree.entries[0].contentDigest == Digest.sha256(bytes),
        "Files larger than 16 MiB need complete streaming digests")
    var largeInfo=shou_win_info(); try native(shou_win_stat(large, &largeInfo))
    var checks=0, hash: UnsafeMutablePointer<CChar>?
    let cancelled=withUnsafeMutablePointer(to: &checks) { pointer in
        shou_win_hash(large, &largeInfo, 30_000, { context in
            let counter=context!.assumingMemoryBound(to: Int.self)
            counter.pointee += 1; return counter.pointee >= 4 ? 1 : 0
        }, pointer, &hash)
    }
    shou_win_free(hash)
    try require(cancelled == 1223 && checks == 4, "Streaming hashing must observe cancellation between bounded reads")
    var prefix: UnsafeMutableRawPointer?, prefixCount=0
    try native(shou_win_preview_read(large, &largeInfo, 262144, &prefix, &prefixCount))
    try require(prefix != nil && prefixCount == 262144, "Preview must return only the bounded prefix of a large file")
    if let prefix { try require(Data(bytes: prefix, count: prefixCount) == bytes.prefix(prefixCount), "Preview prefix differs from the generated fixture") }
    shou_win_free(prefix); prefix=nil
    var changedInfo=largeInfo; changedInfo.logical_bytes += 1
    try require(shou_win_preview_read(large, &changedInfo, 262144, &prefix, &prefixCount)==1006 && prefix == nil && prefixCount==0, "Stale preview evidence returned content")
    try require(shou_win_preview_read(large, &largeInfo, 4194305, &prefix, &prefixCount)==87 && prefix == nil, "Preview byte budget must be enforced natively")
    try fs.purge(large, expected: largeTree.entries)
    try require(!FileManager.default.fileExists(atPath: large), "Reviewed large-file permanent removal failed")
    print("PASS native large-file hashing, cooperative cancellation and reviewed permanent removal")
}
