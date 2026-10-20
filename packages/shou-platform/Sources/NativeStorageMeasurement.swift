import Foundation
import ShouCore
import Dispatch
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
/// Regular files use bulk metadata only when every identity field is present.
/// Directories and links retain exact stat-based evidence, including allocation.
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
                    guard device >= 0, (0..<1_000_000_000).contains(modified.tv_nsec),
                          (0..<1_000_000_000).contains(changed.tv_nsec) else { return nil }
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
                        result.append(StorageReadEntry(name: name, entry: entry, flags: flags)); offset=end; continue
                    }
                    if type != 1 || returned.fileattr & files != files {
                        result.append(StorageReadEntry(name: name, entry: nil, flags: 0)); offset=end; continue
                    }
                    let links=try take(UInt32.self), allocated=try take(Int64.self), logical=try take(Int64.self)
                    guard links > 0, allocated >= 0, logical >= 0 else { return nil }
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

/// Shared state for the bounded directory reader. Filesystem reads happen on independent
/// workers; SQLite remains a single writer protected by this lock. This keeps the index durable
/// without serializing the expensive directory metadata calls.
private final class StorageParallelState: @unchecked Sendable {
    let catalog: StorageCatalog
    let cancelled: @Sendable () -> Bool
    let progress: @Sendable (ScanProgress) -> Void
    let deadline: Date
    let lock=NSLock()
    var count=1
    var issueCount=0
    var issues=[String]()
    var issueBytes=0
    var lastReport=Date()
    var failure: (any Error)?

    init(catalog: StorageCatalog, cancelled: @escaping @Sendable () -> Bool,
         progress: @escaping @Sendable (ScanProgress) -> Void, maxSeconds: TimeInterval) {
        self.catalog=catalog; self.cancelled=cancelled
        self.progress=progress; deadline=Date().addingTimeInterval(maxSeconds)
    }

    func check() throws {
        lock.lock(); let failure=failure; let expired=Date() >= deadline; lock.unlock()
        if let failure { throw failure }
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Space analysis stopped.") }
        if expired { throw ShouError("resource_limit", "Space analysis reached its time limit.") }
    }

    /// Commit may proceed after a resource limit so the caller can publish a truthful partial
    /// catalog. Cancellation and storage corruption still abort publication.
    func checkForCommit() throws {
        lock.lock(); let failure=failure; lock.unlock()
        if let failure { throw failure }
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Space analysis stopped.") }
    }

    func issue(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        issueCount += 1
        if issues.count < 10_000 && issueBytes + value.utf8.count <= 2_097_152 {
            issues.append(value); issueBytes += value.utf8.count
        }
    }

    func fail(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure=error }
    }

    func throwIfFailed() throws {
        lock.lock(); let failure=failure; lock.unlock()
        if let failure { throw failure }
    }

    func append(_ entry: FileEntry, name: String, parentID: Int64, complete: Bool? = nil) throws -> (id: Int64, node: StorageNode) {
        lock.lock(); defer { lock.unlock() }
        return try catalog.append(entry, name: name, parentID: parentID, complete: complete)
    }

    func setTotals(_ node: StorageNode, id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try catalog.setTotals(node, id: id)
    }

    func recordEntry(_ path: String) {
        var update=false, value=0
        lock.lock()
        count += 1; value=count
        if count % 128 == 0 && Date().timeIntervalSince(lastReport) >= 0.25 {
            lastReport=Date(); update=true
        }
        lock.unlock()
        if update { progress(ScanProgress(stage: "scanning", entryCount: value, currentPath: path)) }
    }

    func result() -> (count: Int, issues: [String]) {
        lock.lock(); defer { lock.unlock() }
        var values=issues
        if issueCount > values.count { values.append("additional_coverage_issues: " + String(issueCount - values.count)) }
        return (count, values)
    }
}

private final class StorageChildResults: @unchecked Sendable {
    private let lock=NSLock()
    private var values=[String: StorageNode]()
    func append(_ value: StorageNode) { lock.lock(); values[value.path]=value; lock.unlock() }
    func snapshot() -> [String: StorageNode] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Submit only active readers to GCD. Waiting directories remain data in a FIFO instead of
/// consuming dispatch threads blocked on a semaphore.
private final class StorageDirectoryScheduler: @unchecked Sendable {
    private let lock=NSLock()
    private let queue=DispatchQueue(label: "dev.limecloud.shou.storage-read", attributes: .concurrent)
    private let limit: Int
    private var active=0, head=0
    private var pending=[(@Sendable () -> Void)?]()
    init(limit: Int) { self.limit=limit }
    func submit(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        if active >= limit {
            pending.append(operation)
            lock.unlock()
            return
        }
        active += 1
        lock.unlock()
        queue.async {
            var current: (@Sendable () -> Void)?=operation
            while let operation=current {
                operation()
                self.lock.lock()
                if self.head < self.pending.count {
                    current=self.pending[self.head]
                    self.pending[self.head]=nil
                    self.head += 1
                } else {
                    self.pending.removeAll(keepingCapacity: true)
                    self.head=0
                    self.active -= 1
                    current=nil
                }
                self.lock.unlock()
            }
        }
    }
}

/// The unsafe task handle stays within withUnsafeCurrentTask's synchronous scope, including
/// all worker joins. GCD workers have no Swift current task of their own.
private final class StorageScanCancellation: @unchecked Sendable {
    let task: UnsafeCurrentTask?
    let callback: @Sendable () -> Bool
    init(task: UnsafeCurrentTask?, callback: @escaping @Sendable () -> Bool) {
        self.task=task; self.callback=callback
    }
    var isCancelled: Bool { task?.isCancelled == true || callback() }
}
#endif

extension NativeFileSystem {
    func measureStorageImpl(_ path: String, catalog: URL, cancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement {
        if let executable=storageReadWorkerExecutable {
            return try NativeReadClient(executable: executable).measureStorage(path, catalog: catalog, cancelled: cancelled, progress: progress)
        }
        return try measureStorageDirect(path, catalog: catalog, cancelled: cancelled, progress: progress)
    }

#if canImport(Darwin)
    /// Measures independent directories concurrently while keeping one serialized catalog writer.
    /// APFS metadata latency, rather than CPU arithmetic, dominates a full-volume scan; a bounded
    /// directory pool therefore improves throughput without creating unbounded filesystem or UI
    /// pressure. The worker pool is deliberately limited to eight readers and all identity checks
    /// remain no-follow and fail-closed.
    private func measureStorageParallel(_ path: String, catalog: URL, cancelled: @escaping @Sendable () -> Bool,
                                        progress: @escaping @Sendable (ScanProgress) -> Void,
                                        maxSeconds: TimeInterval = 3600) throws -> StorageMeasurement {
        let privacy=scanPrivacyPolicy
        try privacy.checkRoot(path)
        let root=try SecurePaths.directory(path, cancelled: cancelled)
        defer { close(root) }
        var metadata=stat()
        guard fstat(root, &metadata) == 0 else { throw SecurePaths.failure("Inspect analysis root", path: path) }
        let identity=SecurePaths.entry(metadata, path: ".")
        let database=try StorageCatalog(url: catalog, create: true)
        let rootRow=try database.append(identity, name: ".", parentID: 0)
        let state=StorageParallelState(catalog: database, cancelled: cancelled, progress: progress, maxSeconds: maxSeconds)
        progress(ScanProgress(stage: "scanning", entryCount: 1, currentPath: path))

        let requestedWorkers=ProcessInfo.processInfo.environment["SHOU_STORAGE_SCAN_WORKERS"].flatMap(Int.init)
        let workers=max(1, min(8, requestedWorkers ?? ProcessInfo.processInfo.activeProcessorCount))
        let queue=DispatchQueue(label: "dev.limecloud.shou.storage-finalize", attributes: .concurrent)
        let scheduler=StorageDirectoryScheduler(limit: workers)
        let work=DispatchGroup()
        let rootResult=StorageChildResults()

        @Sendable func enqueue(_ operation: @escaping @Sendable () -> Void) {
            work.enter()
            scheduler.submit {
                defer { work.leave() }
                operation()
            }
        }

        @Sendable func openDirectory(_ relativePath: String, expected: FileEntry) throws -> Int32 {
            let absolute=relativePath == "." ? path : path + "/" + relativePath
            // O_NOFOLLOW_ANY covers every path component and cannot be combined with
            // O_NOFOLLOW (Darwin returns EINVAL for that combination).
            let descriptor=open(absolute, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw SecurePaths.failure("Open analysis directory", path: absolute) }
            var opened=stat()
            guard fstat(descriptor, &opened) == 0,
                  SecurePaths.entry(opened, path: relativePath).sameObject(as: expected) else {
                close(descriptor); throw ShouError("changed_directory", "A directory changed while it was queued.")
            }
            return descriptor
        }

        @Sendable func finalize(_ entry: FileEntry, _ node: StorageNode, _ id: Int64,
                      _ locallyIncomplete: Bool, _ children: [StorageNode], _ result: StorageChildResults) throws -> StorageNode {
            var total=node
            let measured=result.snapshot()
            for child in children where measured[child.path] != nil {
                let value=measured[child.path]!
                total.logicalBytes += value.logicalBytes - child.logicalBytes
                total.allocatedBytes += value.allocatedBytes - child.allocatedBytes
                total.fileCount += value.fileCount - child.fileCount
                total.newestModifiedNanoseconds=max(total.newestModifiedNanoseconds, value.newestModifiedNanoseconds)
            }
            // Re-open each completed directory once to detect replacement or metadata changes
            // that happened while descendants were being read.
            var changed=false
            if let descriptor=try? openDirectory(entry.path, expected: entry) {
                var current=stat()
                if fstat(descriptor, &current) != 0 || SecurePaths.entry(current, path: entry.path) != entry {
                    state.issue("changed_during_scan: " + entry.path)
                    changed=true
                }
                close(descriptor)
            } else {
                state.issue("unreadable_directory: " + entry.path)
                changed=true
            }
            let descendantsComplete=children.allSatisfy { child in
                measured[child.path]?.isComplete == true
            }
            total.isComplete = !locallyIncomplete && !changed && descendantsComplete
            try state.setTotals(total, id: id)
            return total
        }

        @Sendable func visit(_ descriptor: Int32, _ entry: FileEntry, _ initial: StorageNode, _ id: Int64, _ depth: Int,
                   _ completion: @escaping @Sendable (StorageNode) -> Void) throws {
            var locallyIncomplete=false
            do { try state.check() }
            catch let error as ShouError where error.code == "resource_limit" {
                state.issue("resource_limit: " + entry.path)
                var limited=initial; limited.isComplete=false
                try state.setTotals(limited, id: id); completion(limited); return
            }
            if depth > 512 {
                state.issue("resource_limit: " + entry.path)
                var limited=initial; limited.isComplete=false
                try state.setTotals(limited, id: id); completion(limited); return
            }
            var total=initial
            var directories=[(String, FileEntry, StorageNode, Int64)]()
            do {
                #if canImport(Darwin)
                let bulk=try StorageBulkReader.entries(descriptor, checkpoint: state.check)
                #else
                let bulk: [StorageReadEntry]?=nil
                #endif
                let children=try bulk ?? SecurePaths.names(descriptor).map { StorageReadEntry(name: $0, entry: nil, flags: 0) }
                for childEntry in children {
                    try state.check()
                    let name=childEntry.name
                    let child=entry.path == "." ? name : entry.path + "/" + name
                    var item: FileEntry, flags=childEntry.flags
                    if let measured=childEntry.entry {
                        item=measured; item.path=child
                        // Directory link counts are not part of the portable bulk common
                        // attribute set. Refresh only directory records; regular files retain
                        // the fully batched metadata path, avoiding one stat call per file.
                        if item.kind == "directory" {
                            var directoryInfo=stat()
                            if fstatat(descriptor, name, &directoryInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                                item=SecurePaths.entry(directoryInfo, path: child)
                            } else {
                                state.issue("unreadable: " + child)
                                locallyIncomplete=true
                                continue
                            }
                        }
                    }
                    else {
                        var info=stat()
                        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                            state.issue("unreadable: " + child)
                            locallyIncomplete=true
                            continue
                        }
                        item=SecurePaths.entry(info, path: child)
                        flags=info.st_flags
                    }
                    let foreign=item.device != identity.device
                    let cloud=flags & UInt32(SF_DATALESS) != 0
                    var opaque=item
                    if foreign || cloud {
                        opaque.kind="special"; opaque.logicalBytes=0; opaque.allocatedBytes=0
                        state.issue((foreign ? "cross_filesystem: " : "cloud_placeholder: ") + child)
                        locallyIncomplete=true
                    }
                    let row=try state.append(opaque, name: name, parentID: id, complete: (foreign || cloud) ? false : nil)
                    state.recordEntry(child)
                    let node=row.node
                    total.logicalBytes += node.logicalBytes; total.allocatedBytes += node.allocatedBytes
                    total.fileCount += node.fileCount
                    total.newestModifiedNanoseconds=max(total.newestModifiedNanoseconds, node.newestModifiedNanoseconds)
                    if !foreign && !cloud && item.kind == "directory" { directories.append((name, item, node, row.id)) }
                }
            } catch let error as ShouError where error.code == "cancelled" || error.code == "store_corrupt" {
                throw error
            } catch let error as ShouError where error.code == "resource_limit" {
                state.issue("resource_limit: " + entry.path)
                locallyIncomplete=true
            } catch {
                state.issue("unreadable_directory: " + entry.path)
                locallyIncomplete=true
            }

            guard !directories.isEmpty else {
                let result=try finalize(entry, total, id, locallyIncomplete, [], StorageChildResults())
                completion(result); return
            }
            let childGroup=DispatchGroup(), childResults=StorageChildResults()
            for (_, child, node, childID) in directories {
                if privacy.requiresAuthorization(path + "/" + child.path) {
                    state.issue("authorization_required: " + child.path)
                    locallyIncomplete=true
                    continue
                }
                childGroup.enter()
                enqueue {
                    let sub: Int32
                    do { sub=try openDirectory(child.path, expected: child) }
                    catch {
                        state.issue("unreadable_directory: " + child.path)
                        childGroup.leave()
                        return
                    }
                    defer { close(sub) }
                    do {
                        try visit(sub, child, node, childID, depth + 1) { measured in
                            childResults.append(measured)
                            childGroup.leave()
                        }
                    } catch {
                        state.fail(error)
                        childGroup.leave()
                    }
                }
            }
            // Finalization runs outside a reader slot. This avoids a semaphore deadlock when all
            // readers have discovered children and are waiting for those children to finish.
            work.enter()
            childGroup.notify(queue: queue) {
                defer { work.leave() }
                do {
                    let result=try finalize(entry, total, id, locallyIncomplete, directories.map { $0.2 }, childResults)
                    completion(result)
                } catch {
                    state.fail(error)
                    // Wake every ancestor even when SQLite or revalidation fails; otherwise
                    // a parent DispatchGroup can retain an unfinished child indefinitely.
                    var failed=initial; failed.isComplete=false
                    completion(failed)
                }
            }
        }

        enqueue {
            do {
                try visit(root, identity, rootRow.node, rootRow.id, 0) { measured in rootResult.append(measured) }
            } catch { state.fail(error) }
        }
        work.wait()
        try state.throwIfFailed()
        guard let total=rootResult.snapshot()["."] else { throw ShouError("io_error", "Space analysis did not produce a root measurement.") }
        try state.throwIfFailed()
        let result=state.result()
        let limited=result.issues.contains { $0.hasPrefix("resource_limit") }
        progress(ScanProgress(stage: "analysis", entryCount: result.count, currentPath: path, limitReached: limited))
        try database.seal(checkpoint: { try state.checkForCommit() })
        let values=try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return StorageMeasurement(tree: TreeSnapshot(entries: [identity], complete: total.isComplete == true, issues: result.issues,
            caseSensitive: values?.volumeSupportsCaseSensitiveNames ?? true), entryCount: result.count)
    }
#endif

    func measureStorageDirect(_ path: String, catalog: URL, cancelled: @escaping @Sendable () -> Bool,
                              progress: @escaping @Sendable (ScanProgress) -> Void, maxSeconds: TimeInterval = 3600) throws -> StorageMeasurement {
#if canImport(Darwin)
        return try withUnsafeCurrentTask { task in
            let cancellation=StorageScanCancellation(task: task, callback: cancelled)
            return try measureStorageParallel(path, catalog: catalog, cancelled: { cancellation.isCancelled }, progress: progress, maxSeconds: maxSeconds)
        }
#else
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
#endif
    }
}
#endif
