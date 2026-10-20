import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
private struct StorageReadEntry {
    let name: String
    var entry: FileEntry?
    let flags: UInt32
}

#if canImport(Darwin)
/// Bulk metadata is used only when every deletion identity field is present.
/// Directories and links retain the exact stat-based path, including allocation.
private enum StorageBulkReader {
    static func entries(_ descriptor: Int32, checkpoint: () throws -> Void) throws -> [StorageReadEntry]? {
        let copy=openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { return nil }
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
        var result=[StorageReadEntry]()
        while true {
            try checkpoint()
            let count=getattrlistbulk(copy, &attributes, buffer, capacity, UInt64(FSOPT_NOFOLLOW))
            // Retry through the original stat-based reader from an untouched
            // descriptor if a filesystem omits attributes or rejects bulk I/O.
            guard count >= 0 else { return nil }
            if count == 0 { return result.sorted { $0.name < $1.name } }
            var offset=0
            for _ in 0..<count {
                // Keep metadata retention bounded for exceptionally wide
                // directories. The fallback still measures every sibling.
                if result.count >= 65_536 { return nil }
                if result.count % 128 == 0 { try checkpoint() }
                guard offset + 4 <= capacity else { return nil }
                let length=Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 24, length <= capacity - offset else { return nil }
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
                    guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { return nil }
                    let referenceOffset=cursor, reference=try take(attrreference_t.self)
                    let nameStart=referenceOffset + Int(reference.attr_dataoffset), nameLength=Int(reference.attr_length)
                    guard nameStart >= cursor, nameLength > 0, nameStart <= end, nameLength <= end - nameStart,
                          buffer.load(fromByteOffset: nameStart + nameLength - 1, as: UInt8.self) == 0 else { return nil }
                    let bytes=UnsafeRawBufferPointer(start: buffer.advanced(by: nameStart), count: nameLength - 1)
                    guard let name=String(bytes: bytes, encoding: .utf8), !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return nil }
                    guard name != "." && name != ".." else { offset=end; continue }
                    // Missing/error records still get a fresh fstatat below.
                    if error != 0 || returned.commonattr & common != common {
                        result.append(StorageReadEntry(name: name, entry: nil, flags: 0)); offset=end; continue
                    }
                    let device=try take(dev_t.self), type=try take(UInt32.self)
                    let modified=try take(timespec.self), changed=try take(timespec.self)
                    let owner=try take(UInt32.self), mode=try take(UInt32.self), flags=try take(UInt32.self), inode=try take(UInt64.self)
                    if type != 1 || returned.fileattr & files != files {
                        result.append(StorageReadEntry(name: name, entry: nil, flags: 0)); offset=end; continue
                    }
                    let links=try take(UInt32.self), allocated=try take(Int64.self), logical=try take(Int64.self)
                    guard device >= 0, links > 0, allocated >= 0, logical >= 0,
                          (0..<1_000_000_000).contains(modified.tv_nsec), (0..<1_000_000_000).contains(changed.tv_nsec) else { return nil }
                    let entry=FileEntry(path: name, kind: "file", device: UInt64(device), inode: inode, logicalBytes: logical,
                        allocatedBytes: allocated, modifiedNanoseconds: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec),
                        changedNanoseconds: Int64(changed.tv_sec) * 1_000_000_000 + Int64(changed.tv_nsec),
                        mode: mode | UInt32(S_IFREG), owner: owner, links: UInt64(links))
                    result.append(StorageReadEntry(name: name, entry: entry, flags: flags))
                } catch { return nil }
                offset=end
            }
        }
    }
}
#endif

extension NativeFileSystem {
    public var supportsStorageCatalog: Bool { true }
    public func measureStorage(_ path: String, catalog: URL, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement {
        if let executable=storageReadWorkerExecutable {
            return try NativeReadClient(executable: executable).measureStorage(path, catalog: catalog, cancelled: cancelled, progress: progress)
        }
        return try measureStorageDirect(path, catalog: catalog, cancelled: cancelled, progress: progress)
    }
    func measureStorageDirect(_ path: String, catalog: URL, cancelled: @Sendable () -> Bool,
                              progress: @Sendable (ScanProgress) -> Void, maxSeconds: TimeInterval = 3600) throws -> StorageMeasurement {
        let privacy=scanPrivacyPolicy
        try privacy.checkRoot(path)
        let root=try SecurePaths.directory(path, cancelled: cancelled)
        defer { close(root) }
        var metadata=stat()
        guard fstat(root, &metadata) == 0 else { throw SecurePaths.failure("Inspect analysis root", path: path) }
        let identity=SecurePaths.entry(metadata, path: "."), database=try StorageCatalog(url: catalog, create: true)
        let rootRow=try database.append(identity, name: ".", parentID: 0)
        let deadline=ContinuousClock.now.advanced(by: .seconds(maxSeconds))
        var count=1, issues=[String](), issueCount=0, issueBytes=0, lastReport=ContinuousClock.now
        func issue(_ value: String) {
            issueCount += 1
            if issues.count < 10_000 && issueBytes + value.utf8.count <= 2_097_152 {
                issues.append(value); issueBytes += value.utf8.count
            }
        }
        func checkCancellation() throws {
            if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Space analysis stopped.") }
        }
        func visit(_ descriptor: Int32, _ entry: FileEntry, _ initial: StorageNode, _ id: Int64, _ depth: Int) throws -> StorageNode {
            try checkCancellation()
            var total=initial
            let initialIssues=issueCount
            if ContinuousClock.now >= deadline || depth > 512 {
                issue("resource_limit: " + entry.path)
                total.isComplete=false; try database.setTotals(total, id: id); return total
            }
            var directories=[(String, FileEntry, StorageNode, Int64)]()
            do {
                // Discover every immediate sibling before descending. There is
                // deliberately no deletion-manifest entry cap in measurement.
                #if canImport(Darwin)
                let bulk=try StorageBulkReader.entries(descriptor, checkpoint: checkCancellation)
                #else
                let bulk: [StorageReadEntry]?=nil
                #endif
                let children=try bulk ?? SecurePaths.names(descriptor).map { StorageReadEntry(name: $0, entry: nil, flags: 0) }
                for childEntry in children {
                    let name=childEntry.name
                    try checkCancellation()
                    if ContinuousClock.now >= deadline { issue("resource_limit: " + entry.path); break }
                    let child=entry.path == "." ? name : entry.path + "/" + name
                    var item: FileEntry, flags=childEntry.flags
                    if let measured=childEntry.entry { item=measured; item.path=child }
                    else {
                        var info=stat()
                        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { issue("unreadable: " + child); continue }
                        item=SecurePaths.entry(info, path: child)
                        #if canImport(Darwin)
                        flags=info.st_flags
                        #endif
                    }
                    let row: (id: Int64, node: StorageNode)
                    let foreign=item.device != identity.device
                    #if canImport(Darwin)
                    let cloud=flags & UInt32(SF_DATALESS) != 0
                    #else
                    let cloud=false
                    #endif
                    if foreign || cloud {
                        // Preserve the boundary as a visible, unmeasured row.
                        var opaque=item; opaque.kind="special"; opaque.logicalBytes=0; opaque.allocatedBytes=0
                        row=try database.append(opaque, name: name, parentID: id, complete: false)
                        issue((foreign ? "cross_filesystem: " : "cloud_placeholder: ") + child)
                    } else { row=try database.append(item, name: name, parentID: id) }
                    let node=row.node
                    count += 1
                    if !foreign && !cloud && item.kind == "directory" { directories.append((name, item, node, row.id)) }
                    total.logicalBytes += node.logicalBytes; total.allocatedBytes += node.allocatedBytes
                    total.fileCount += node.fileCount
                    total.newestModifiedNanoseconds=max(total.newestModifiedNanoseconds, node.newestModifiedNanoseconds)
                    if count % 128 == 0 && lastReport.duration(to: .now) >= .milliseconds(250) {
                        progress(ScanProgress(stage: "scanning", entryCount: count, currentPath: child)); lastReport = .now
                    }
                }
                for (name, child, node, childID) in directories {
                    try checkCancellation()
                    if privacy.requiresAuthorization(path + "/" + child.path) {
                        issue("authorization_required: " + child.path); continue
                    }
                    let sub=openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard sub >= 0 else { issue("unreadable_directory: " + child.path); continue }
                    let measured: StorageNode
                    do {
                        defer { close(sub) }
                        var opened=stat()
                        if fstat(sub, &opened) == 0 && SecurePaths.entry(opened, path: child.path).sameObject(as: child) {
                            measured=try visit(sub, child, node, childID, depth + 1)
                        } else { issue("changed_directory: " + child.path); continue }
                    }
                    total.logicalBytes += measured.logicalBytes - node.logicalBytes
                    total.allocatedBytes += measured.allocatedBytes - node.allocatedBytes
                    total.fileCount += measured.fileCount - node.fileCount
                    total.newestModifiedNanoseconds=max(total.newestModifiedNanoseconds, measured.newestModifiedNanoseconds)
                }
                var after=stat()
                if fstat(descriptor, &after) != 0 || SecurePaths.entry(after, path: entry.path) != entry {
                    issue("changed_during_scan: " + entry.path)
                }
            } catch let error as ShouError where error.code == "cancelled" { throw error }
            catch {
                // Storage failures must fail the whole unpublished index.
                if let error=error as? ShouError, error.code == "store_corrupt" { throw error }
                issue("unreadable_directory: " + entry.path)
            }
            total.isComplete=issueCount == initialIssues
            try database.setTotals(total, id: id)
            return total
        }
        progress(ScanProgress(stage: "scanning", entryCount: count, currentPath: path))
        let total=try visit(root, identity, rootRow.node, rootRow.id, 0)
        try checkCancellation()
        let limited=issues.contains { $0.hasPrefix("resource_limit") }
        progress(ScanProgress(stage: "analysis", entryCount: count, currentPath: path, limitReached: limited))
        try database.seal(checkpoint: checkCancellation)
        if issueCount > issues.count { issues.append("additional_coverage_issues: " + String(issueCount - issues.count)) }
        let values=try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return StorageMeasurement(tree: TreeSnapshot(entries: [identity], complete: total.isComplete == true, issues: issues,
            caseSensitive: values?.volumeSupportsCaseSensitiveNames ?? true), entryCount: count)
    }
}
#endif
