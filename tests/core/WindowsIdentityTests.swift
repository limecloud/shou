import Foundation
import ShouCore

func windowsIdentityPreservesFileIDOwnerAndLegacyRecords() throws {
    let legacy=FileEntry(path: "fixture", kind: "file", device: 42, inode: 0,
        logicalBytes: 64, allocatedBytes: 4096, modifiedNanoseconds: 1, changedNanoseconds: 2,
        mode: 0, owner: 0, links: 1)
    let encoded=try Codec.encode(legacy)
    try expect(!String(decoding: encoded, as: UTF8.self).contains("windows_identity"))
    try expect(try Codec.decode(FileEntry.self, from: encoded) == legacy)
    var first=legacy, second=legacy, root=legacy
    first.path="a"; second.path="b"; root.path="."; root.kind="directory"; root.allocatedBytes=0
    first.windowsIdentity=WindowsFileIdentity(volume: 42, fileId: "00000000000000010000000000000001", ownerSid: "S-1-5-21-1001")
    second.windowsIdentity=WindowsFileIdentity(volume: 42, fileId: "00000000000000020000000000000001", ownerSid: "S-1-5-21-1001")
    try expect(!first.sameObject(as: second))
    try expect(!first.sameObject(as: legacy) && !legacy.sameObject(as: first))
    try expect(first.hasSameOwner(as: second))
    try expect(StorageIndex(entries: [root, first, second]).nodes["."]?.allocatedBytes == 8192)
    second.windowsIdentity=WindowsFileIdentity(volume: 42, fileId: first.windowsIdentity!.fileId, ownerSid: "S-1-5-21-2002")
    try expect(first.sameObject(as: second) && !first.hasSameOwner(as: second))
    try expect(first != second)
    try expect(try Codec.decode(FileEntry.self, from: Codec.encode(first)) == first)
}
