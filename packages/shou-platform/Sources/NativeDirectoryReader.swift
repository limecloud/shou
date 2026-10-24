import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
struct NativeDirectoryEntry {
    let name: String
    var entry: FileEntry?
    let flags: UInt32
}

#if canImport(Darwin)
/// Regular files use bulk metadata only when every identity field is present.
/// Directories and links retain exact stat-based evidence, including allocation.
enum NativeDirectoryReader {
    /// A failed bulk page falls back only for names not already consumed.
    /// All callers share the same no-follow metadata parsing and read budgets.
    static func enumerate(_ descriptor: Int32, limit: Int, deadline: ContinuousClock.Instant,
                          cancelled: @Sendable () -> Bool, checkpoint: () throws -> Void,
                          consume: ([NativeDirectoryEntry]) throws -> Void) throws -> Bool {
        struct ListingLimit: Error {}
        var seen=Set<String>(), entries=[NativeDirectoryEntry](), truncated=false
        func accept(_ batch: [NativeDirectoryEntry]) throws {
            for entry in batch where seen.insert(entry.name).inserted {
                guard entries.count < limit else { throw ListingLimit() }
                entries.append(entry)
            }
        }
        do {
            if try !enumerateBulk(descriptor, checkpoint: checkpoint, consume: accept) {
                let listing=try NativeDefinitionFiles.names(descriptor, limit: limit, deadline: deadline, cancelled: cancelled)
                try accept(listing.names.map { NativeDirectoryEntry(name: $0, entry: nil, flags: 0) })
                truncated=listing.truncated
            }
        } catch is ListingLimit { truncated=true }
        // Bounded target scans retain deterministic depth-first coverage. Full
        // disk measurement calls enumerateBulk directly and keeps streaming.
        entries.sort { $0.name < $1.name }
        for offset in stride(from: 0, to: entries.count, by: 256) {
            try checkpoint()
            try consume(Array(entries[offset..<min(offset + 256, entries.count)]))
        }
        return truncated
    }

    static func enumerateBulk(_ descriptor: Int32, checkpoint: () throws -> Void, consume: ([NativeDirectoryEntry]) throws -> Void) throws -> Bool {
        let copy=openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { return false }
        defer { close(copy) }
        let common=UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
            ATTR_CMN_OWNERID | ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        let files=UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        var attributes=attrlist()
        attributes.bitmapcount=UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr=common | UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR)
        attributes.fileattr=files
        let capacity=64 * 1024
        let buffer=UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            try checkpoint()
            let count=getattrlistbulk(copy, &attributes, buffer, capacity, UInt64(FSOPT_NOFOLLOW))
            // Retry through the original stat-based reader from an untouched
            // descriptor if a filesystem omits attributes or rejects bulk I/O.
            guard count >= 0, count <= capacity / 24 else { return false }
            if count == 0 { return true }
            var result=[NativeDirectoryEntry]()
            result.reserveCapacity(Int(count))
            var offset=0
            for _ in 0..<count {
                if result.count % 128 == 0 { try checkpoint() }
                guard offset + 4 <= capacity else { return false }
                let length=Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 24, length <= capacity - offset else { return false }
                let end=offset + length
                var cursor=offset + 4
                func take<T>(_ type: T.Type) throws -> T {
                    guard MemoryLayout<T>.size <= end - cursor else { throw ShouError("bulk_metadata", "Incomplete bulk metadata.") }
                    let value=buffer.loadUnaligned(fromByteOffset: cursor, as: type)
                    cursor += MemoryLayout<T>.size
                    return value
                }
                do {
                    let returned=try take(attribute_set_t.self)
                    let error=returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 ? try take(UInt32.self) : 0
                    guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { return false }
                    let referenceOffset=cursor, reference=try take(attrreference_t.self)
                    let nameStart=referenceOffset + Int(reference.attr_dataoffset), nameLength=Int(reference.attr_length)
                    guard nameStart >= cursor, nameLength > 0, nameStart <= end, nameLength <= end - nameStart,
                          buffer.load(fromByteOffset: nameStart + nameLength - 1, as: UInt8.self) == 0 else { return false }
                    let bytes=UnsafeRawBufferPointer(start: buffer.advanced(by: nameStart), count: nameLength - 1)
                    guard let name=String(bytes: bytes, encoding: .utf8), !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return false }
                    guard name != "." && name != ".." else { offset=end; continue }
                    // Missing/error records still get a fresh fstatat below.
                    if error != 0 || returned.commonattr & common != common {
                        result.append(NativeDirectoryEntry(name: name, entry: nil, flags: 0)); offset=end; continue
                    }
                    let device=try take(dev_t.self), type=try take(UInt32.self)
                    let modified=try take(timespec.self), changed=try take(timespec.self)
                    let owner=try take(UInt32.self), mode=try take(UInt32.self), flags=try take(UInt32.self), inode=try take(UInt64.self)
                    guard device >= 0, (0..<1_000_000_000).contains(modified.tv_nsec),
                          (0..<1_000_000_000).contains(changed.tv_nsec) else { return false }
                    // ATTR_CMN_OBJTYPE uses the fsobj_type enum (VREG=1, VDIR=2),
                    // rather than the mode bits returned by stat(2).
                    if type == 2 {
                        // This classifies a directory for the caller's exact stat refresh.
                        // Common attributes do not include its POSIX link count or allocation.
                        let entry=FileEntry(path: name, kind: "directory", device: UInt64(device), inode: inode,
                            logicalBytes: 0, allocatedBytes: 0,
                            modifiedNanoseconds: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec),
                            changedNanoseconds: Int64(changed.tv_sec) * 1_000_000_000 + Int64(changed.tv_nsec),
                            mode: mode | UInt32(S_IFDIR), owner: owner, links: 1)
                        result.append(NativeDirectoryEntry(name: name, entry: entry, flags: flags)); offset=end; continue
                    }
                    if type != 1 || returned.fileattr & files != files {
                        result.append(NativeDirectoryEntry(name: name, entry: nil, flags: 0)); offset=end; continue
                    }
                    let links=try take(UInt32.self), allocated=try take(Int64.self), logical=try take(Int64.self)
                    guard links > 0, allocated >= 0, logical >= 0 else { return false }
                    let entry=FileEntry(path: name, kind: "file", device: UInt64(device), inode: inode, logicalBytes: logical,
                        allocatedBytes: allocated, modifiedNanoseconds: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec),
                        changedNanoseconds: Int64(changed.tv_sec) * 1_000_000_000 + Int64(changed.tv_nsec),
                        mode: mode | UInt32(S_IFREG), owner: owner, links: UInt64(links))
                    result.append(NativeDirectoryEntry(name: name, entry: entry, flags: flags))
                } catch { return false }
                offset=end
            }
            // Commit each validated kernel page before requesting the next one.
            // Exceptionally wide directories retain the batched metadata path.
            try consume(result)
        }
    }
}

#endif
#endif
