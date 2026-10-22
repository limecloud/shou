#if os(Windows)
import Foundation
import ShouCore
import CShouWindows

enum WindowsNative {
    static func check(_ code: Int32, path: String) throws {
        guard code == 0 else {
            let category: String
            let win32=UInt32(bitPattern: code)
            let number=win32 & 0xffff0000 == 0x80070000 ? Int32(win32 & 0xffff) : code
            switch number {
            case 2, 3: category="not_found"
            case 5: category="permission_denied"
            case 32, 33: category="store_busy"
            case 80, 183: category="restore_conflict"
            case 223, 234, 1460: category="resource_limit"
            case 1223: category="cancelled"
            case 1006: category="plan_stale"
            default: category="capability_unavailable"
            }
            throw ShouError(category, "Windows could not safely complete the file operation.", details: ["path": path, "win32_code": String(code)])
        }
    }
    static func string(_ operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32, path: String) throws -> String {
        var pointer: UnsafeMutablePointer<CChar>?
        let status=operation(&pointer)
        defer { shou_win_free(pointer) }
        try check(status, path: path)
        guard let pointer, let value=String(validatingCString: pointer) else { throw ShouError("io_error", "Windows returned an invalid UTF-8 path.") }
        return value
    }
    static func metadata(_ path: String) throws -> shou_win_info {
        var value=shou_win_info(); try check(shou_win_stat(path, &value), path: path); return value
    }
    static func entry(_ raw: shou_win_info, path: String) -> FileEntry {
        var value=FileEntry(path: path, kind: raw.kind == 2 ? "directory" : "file", device: raw.volume, inode: 0,
            logicalBytes: raw.logical_bytes, allocatedBytes: raw.allocated_bytes, modifiedNanoseconds: raw.modified_ns,
            changedNanoseconds: raw.changed_ns, mode: raw.attributes, owner: raw.current_user == 1 ? 0 : .max, links: UInt64(raw.links))
        let id=withUnsafeBytes(of: raw.file_id) { $0.map { String(format: "%02x", $0) }.joined() }
        let sid=withUnsafeBytes(of: raw.owner_sid) { bytes in String(cString: bytes.bindMemory(to: CChar.self).baseAddress!) }
        value.windowsIdentity=WindowsFileIdentity(volume: raw.volume, fileId: id, ownerSid: sid)
        return value
    }
    static func read(_ path: String, limit: Int) throws -> Data {
        var bytes: UnsafeMutableRawPointer?, count=0
        let status=shou_win_read(path, limit, &bytes, &count)
        defer { shou_win_free(bytes) }; try check(status, path: path)
        guard let bytes else { return Data() }; return Data(bytes: bytes, count: count)
    }
    static func savedInfo(_ entry: FileEntry) throws -> shou_win_info {
        guard let identity=entry.windowsIdentity, identity.fileId.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil,
              identity.ownerSid.range(of: "^S-1-[0-9]+(-[0-9]+)+$", options: .regularExpression) != nil,
              identity.ownerSid.utf8.count < 192, ["directory", "file"].contains(entry.kind), entry.links <= UInt32.max else {
            throw ShouError("plan_stale", "The recorded Windows identity is invalid.")
        }
        var raw=shou_win_info()
        raw.volume=identity.volume; raw.logical_bytes=entry.logicalBytes; raw.allocated_bytes=entry.allocatedBytes
        raw.modified_ns=entry.modifiedNanoseconds; raw.changed_ns=entry.changedNanoseconds
        raw.attributes=UInt32(entry.mode); raw.links=UInt32(entry.links); raw.kind=entry.kind == "directory" ? 2 : 1
        let characters=Array(identity.fileId)
        let bytes=try stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            guard let byte=UInt8(String(characters[index...index+1]), radix: 16) else { throw ShouError("plan_stale", "The recorded Windows File ID is invalid.") }
            return byte
        }
        withUnsafeMutableBytes(of: &raw.file_id) { $0.copyBytes(from: bytes) }
        withUnsafeMutableBytes(of: &raw.owner_sid) { $0.copyBytes(from: identity.ownerSid.utf8CString.map { UInt8(bitPattern: $0) }) }
        return raw
    }
}

public struct NativeFileSystem: PlatformFileSystem {
    private let applicationDataAccess: WindowsApplicationDataAccess?
    public init(applicationDataAccess: WindowsApplicationDataAccess? = nil) { self.applicationDataAccess=applicationDataAccess }
    public var platform: String { "windows" }
    public var caseSensitivePaths: Bool { false }
    public var supportsTrash: Bool { ProcessInfo.processInfo.environment["SHOU_WINDOWS_EXPERIMENTAL_RECYCLE"] == "1" }
    public var trashUnavailableReason: String? { supportsTrash ? nil : "Windows Recycle Bin operations are disabled by default; enable explicitly for isolated native validation." }
    public func normalizedPath(_ path: String) throws -> String {
        guard !path.contains("\0") else { throw ShouError("invalid_argument", "Paths cannot contain NUL bytes.") }
        return try WindowsNative.string({ shou_win_normalize(path, $0) }, path: path)
    }
    public func locationAvailability(_ path: String) -> LocationAvailability {
        do { return try WindowsNative.metadata(path).kind == 2 ? .available : .unavailable("Select a regular directory.") }
        catch let error as ShouError where error.code == "not_found" { return .missing }
        catch { return .unavailable(error.localizedDescription) }
    }
    public func targetAvailability(_ path: String) -> LocationAvailability {
        do { _=try WindowsNative.metadata(path); return .available }
        catch let error as ShouError where error.code == "not_found" { return .missing }
        catch { return .unavailable(error.localizedDescription) }
    }
    private func protectedRoot(_ path: String, allowCacheRoot: Bool = false, allowCacheTarget: Bool = false, allowDataParent: Bool = false, allowDataTarget: Bool = false) -> Bool {
        let path=path.lowercased(), env=ProcessInfo.processInfo.environment
        func normalize(_ value: String?) -> String? { value.flatMap { try? normalizedPath($0).lowercased() } }
        let home=normalize(env["USERPROFILE"])
        let protected=[env["SystemRoot"], env["ProgramFiles"], env["ProgramFiles(x86)"], env["ProgramData"], env["PUBLIC"], env["OneDrive"], env["OneDriveConsumer"], env["OneDriveCommercial"], LocalRecordStore.defaultDirectory.path,
            home.map { $0 + "/.ssh" }, home.map { $0 + "/.gnupg" }].compactMap(normalize)
        if path.count <= 3 || path == home || path.split(separator: "/").contains("$recycle.bin") || protected.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        if let home, path == home + "/appdata" || path.hasPrefix(home + "/appdata/") {
            if allowDataParent && applicationDataAccess?.permitsParent(path)==true { return false }
            if allowDataTarget && applicationDataAccess?.permitsTarget(path)==true { return false }
            guard let access=try? WindowsCacheAccess(homeDirectory: URL(fileURLWithPath: home)) else { return true }
            return !((allowCacheRoot && access.permitsRoot(path)) || (allowCacheTarget && access.permitsTarget(path)))
        }
        return false
    }
    public func rootIdentity(_ path: String) throws -> FileEntry {
        let path=try normalizedPath(path), raw=try WindowsNative.metadata(path)
        guard raw.kind == 2, raw.current_user == 1, !protectedRoot(path, allowCacheRoot: true, allowDataParent: true) else { throw ShouError("permission_denied", "Select a local user-owned directory outside protected system and Shou locations.") }
        return WindowsNative.entry(raw, path: ".")
    }
    public func cleanupTargetIdentity(_ path: String) throws -> FileEntry {
        let path=try normalizedPath(path), raw=try WindowsNative.metadata(path)
        guard raw.kind == 2, raw.current_user == 1, !protectedRoot(path, allowCacheTarget: true) else {
            throw ShouError("permission_denied", "Select a local user-owned cleanup directory outside protected data.")
        }
        return WindowsNative.entry(raw, path: ".")
    }
    private func verifyMutationParent(_ path: String) throws {
        if applicationDataAccess?.permitsTarget(path)==true {
            guard !protectedRoot(path,allowDataTarget: true) else { throw ShouError("permission_denied", "Application data is outside the reviewed user scope.") }
            let parent=String(path[..<path.lastIndex(of: "/")!]),raw=try WindowsNative.metadata(parent)
            guard raw.kind==2,raw.current_user==1 else { throw ShouError("permission_denied", "Application data parent is not owned by the current user.") }
            return
        }
        guard !protectedRoot(path, allowCacheTarget: true) else { throw ShouError("permission_denied", "Only declared cache targets may be changed inside AppData.") }
        let parent=URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let home=try? normalizedPath(FileManager.default.homeDirectoryForCurrentUser.path),
           let access=try? WindowsCacheAccess(homeDirectory: URL(fileURLWithPath: home)), access.permitsTarget(path) {
            let raw=try WindowsNative.metadata(parent)
            guard raw.kind == 2, raw.current_user == 1 else { throw ShouError("permission_denied", "The cache parent must be a local user-owned directory.") }
        } else { _=try rootIdentity(parent) }
    }
    public func analysisRootIdentity(_ path: String) throws -> FileEntry {
        let raw=try WindowsNative.metadata(path)
        guard raw.kind == 2 else { throw ShouError("invalid_argument", "Select a regular local directory.") }
        return WindowsNative.entry(raw, path: ".")
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled, progress: { _ in })
    }
    private func validateReadBudget(_ budget: ScanBudget) throws {
        guard (1...1_000_000).contains(budget.maxEntries), budget.maxSeconds.isFinite, budget.maxSeconds > 0, budget.maxSeconds <= 600,
              (0...128).contains(budget.maxDepth) else { throw ShouError("invalid_argument", "Invalid scan budget.") }
    }
    public func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try validateReadBudget(budget)
        let path=try normalizedPath(path), deadline=Date().addingTimeInterval(budget.maxSeconds)
        var entries=[FileEntry](), issues=[String](), completePaths=[String]()
        func checkpoint() throws {
            if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            guard entries.count < budget.maxEntries, Date() < deadline else { throw ShouError("resource_limit", "The scan budget was exhausted.") }
        }
        func visit(_ absolute: String, relative: String, depth: Int, volume: UInt64?) throws -> Bool {
            try checkpoint()
            let raw=try WindowsNative.metadata(absolute)
            if let volume, raw.volume != volume { throw ShouError("capability_unavailable", "The scan does not cross volumes.") }
            entries.append(WindowsNative.entry(raw, path: relative))
            if entries.count % 128 == 0 { progress(ScanProgress(stage: "scanning", entryCount: entries.count, currentPath: absolute)) }
            guard raw.kind == 2 else { return true }
            guard depth < budget.maxDepth else { issues.append(relative + ": depth limit"); return false }
            let text=try WindowsNative.string({ shou_win_list(absolute, max(1, budget.maxEntries-entries.count), $0) }, path: absolute)
            var complete=true
            for name in text.split(separator: "\n").map(String.init).sorted() {
                do {
                    let child=relative == "." ? name : relative + "/" + name
                    if try !visit(absolute + "/" + name, relative: child, depth: depth+1, volume: raw.volume) { complete=false }
                } catch let error as ShouError where error.code == "cancelled" { throw error }
                catch { complete=false; issues.append((relative == "." ? name : relative + "/" + name) + ": " + error.localizedDescription) }
                if entries.count >= budget.maxEntries || Date() >= deadline { complete=false; break }
            }
            if try WindowsNative.entry(WindowsNative.metadata(absolute), path: relative) != WindowsNative.entry(raw, path: relative) {
                complete=false; issues.append(relative + ": directory changed during traversal")
            }
            if complete { completePaths.append(relative) }; return complete
        }
        let complete: Bool
        do { complete=try visit(path, relative: ".", depth: 0, volume: nil) }
        catch let error as ShouError where error.code == "cancelled" { throw error }
        catch { if entries.isEmpty { throw error }; issues.append(error.localizedDescription); complete=false }
        return TreeSnapshot(entries: entries.sorted { $0.path < $1.path }, complete: complete, issues: issues, caseSensitive: false, completedPaths: completePaths, discoveryComplete: complete)
    }
    public func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try validateReadBudget(budget)
        return try inspectCleanupTree(normalizedPath(path), rules: rules, budget: budget, cancelled: cancelled, progress: progress)
    }
    func measureCleanupTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try inspect(path, budget: budget, cancelled: cancelled, progress: progress)
    }
    public func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspectFileTarget(path, budget: budget, cancelled: cancelled, largeFile: false)
    }
    public func inspectStorageTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspectFileTarget(path, budget: budget, cancelled: cancelled, largeFile: true)
    }
    public func inspectTrashTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        guard isTrashLocation(path) else { throw ShouError("permission_denied", "Only an exact recorded Recycle Bin item can be inspected.") }
        return try inspectStorageTarget(path, budget: budget, cancelled: cancelled)
    }
    private func inspectFileTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool, largeFile: Bool) throws -> TreeSnapshot {
        let tree=try inspect(path, budget: budget, cancelled: cancelled)
        guard tree.entries.first?.kind == "file" else { return tree }
        var result=tree
        if largeFile {
            result.entries[0].contentDigest=try windowsStorageFileDigest(path, entry: tree.entries[0], maxSeconds: budget.maxSeconds, cancelled: cancelled)
        } else {
            let data=try WindowsNative.read(path, limit: 16_777_216)
            guard WindowsNative.entry(try WindowsNative.metadata(path), path: ".") == tree.entries[0] else { throw ShouError("plan_stale", "The file changed while reading its contents.") }
            result.entries[0].contentDigest=Digest.sha256(data)
        }
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Target inspection stopped.") }
        return result
    }
    private func verify(_ path: String, expected: [FileEntry], trash: Bool = false) throws -> shou_win_info {
        let tree=try inspectStorageTarget(path, budget: ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), cancelled: { Task.isCancelled })
        guard tree.complete, tree.entries.count == expected.count,
            zip(tree.entries, expected).allSatisfy({ a,b in a == b || (trash && a.matchesTrashRoot(as: b)) }) else { throw ShouError("plan_stale", "The full target manifest changed.") }
        return try WindowsNative.metadata(path)
    }
    public func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        guard supportsTrash else { throw ShouError("capability_unavailable", trashUnavailableReason!) }
        try verifyMutationParent(try normalizedPath(path))
        var raw=try verify(path, expected: expected)
        var resultingPath: String?
        do {
            let result=try mutation({ shou_win_recycle(path, &raw, $0) }, source: path, unknown: "trash_outcome_unknown")
            resultingPath=result
            let destination=try normalizedPath(result)
            guard isTrashLocation(destination) else { throw ShouError("trash_outcome_unknown", "The system did not return a verifiable Recycle Bin item.") }
            let tree=try inspectStorageTarget(destination, budget: ScanBudget(maxEntries: 1_000_000, maxSeconds: 600), cancelled: { false })
            let verified=tree.complete && tree.entries.count == expected.count && zip(tree.entries,expected).allSatisfy { a,b in a == b || a.matchesTrashRoot(as: b) }
            return TrashResult(path: destination, manifest: tree.entries, verified: verified)
        } catch {
            if let resultingPath { throw ShouError("trash_outcome_unknown", "The Recycle Bin result could not be verified. Inspect history before taking further action.", details: ["resulting_path": resultingPath]) }
            throw error
        }
    }
    public func isTrashLocation(_ path: String) -> Bool {
        guard let normalized=try? normalizedPath(path), let raw=try? WindowsNative.metadata(normalized), raw.current_user == 1 else { return false }
        let identity=WindowsNative.entry(raw, path: ".").windowsIdentity!
        let parts=normalized.split(separator: "/")
        return parts.count == 4 && parts[1].lowercased() == "$recycle.bin" && parts[2] == identity.ownerSid && parts[3].hasPrefix("$R")
    }
    public func restore(_ path: String, to destination: String, expected: [FileEntry]) throws {
        guard supportsTrash else { throw ShouError("capability_unavailable", trashUnavailableReason!) }
        guard isTrashLocation(path) else { throw ShouError("permission_denied", "Only the exact recorded Recycle Bin item may be restored.") }
        guard case .missing=targetAvailability(destination) else { throw ShouError("restore_conflict", "The restore destination already exists or is inaccessible.") }
        try verifyMutationParent(try normalizedPath(destination))
        var raw=try verify(path, expected: expected, trash: true)
        let actual=try mutation({ shou_win_restore(path, destination, &raw, $0) }, source: path, unknown: "restore_outcome_unknown")
        guard try normalizedPath(actual).lowercased() == normalizedPath(destination).lowercased() else { throw ShouError("restore_outcome_unknown", "The system restored the item to a different path.", details: ["resulting_path": actual]) }
        do { _=try verify(destination, expected: expected, trash: true) }
        catch { throw ShouError("restore_outcome_unknown", "The restored item's metadata could not be verified.", details: ["resulting_path": actual]) }
    }
    private func mutation(_ operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32, source: String, unknown: String) throws -> String {
        var pointer: UnsafeMutablePointer<CChar>?
        let status=operation(&pointer)
        defer { shou_win_free(pointer) }
        let actual=pointer.flatMap { String(validatingCString: $0) }
        if status != 0 {
            if actual != nil || (try? WindowsNative.metadata(source)) == nil {
                throw ShouError(unknown, "Windows returned an uncertain mutation outcome.", details: ["resulting_path": actual ?? "", "win32_code": String(status)])
            }
            try WindowsNative.check(status, path: source)
        }
        guard let actual, !actual.isEmpty else { throw ShouError(unknown, "Windows did not return the resulting item path.") }
        return actual
    }
    public func purge(_ path: String, expected: [FileEntry]) throws {
        let path=try normalizedPath(path)
        if !isTrashLocation(path) {
            try verifyMutationParent(path)
        }
        let root=try verify(path, expected: expected, trash: true)
        var manifest=try expected.map(WindowsNative.savedInfo)
        guard let rootIndex=expected.firstIndex(where: { $0.path == "." }) else { throw ShouError("plan_stale", "The target manifest has no root.") }
        var current=WindowsNative.entry(root, path: ".")
        current.contentDigest=expected[rootIndex].contentDigest
        let saved=expected[rootIndex]
        guard current == saved || current.matchesTrashRoot(as: saved) else { throw ShouError("plan_stale", "The target root changed before removal.") }
        manifest[rootIndex]=root
        var names=[CChar](), offsets=[Int](), digests=[CChar](), digestOffsets=[Int]()
        for entry in expected {
            offsets.append(names.count); names.append(contentsOf: entry.path.utf8CString)
            digestOffsets.append(digests.count); digests.append(contentsOf: (entry.contentDigest ?? "").utf8CString)
        }
        var removed=0
        // Keep contiguous UTF-8 storage alive without recursion or per-entry allocations.
        let code=names.withUnsafeBufferPointer { buffer in
            let pointers=offsets.map { buffer.baseAddress?.advanced(by: $0) }
            return digests.withUnsafeBufferPointer { digestBuffer in
                let digestPointers=digestOffsets.map { digestBuffer.baseAddress?.advanced(by: $0) }
                return manifest.withUnsafeBufferPointer { metadata in
                    shou_win_purge(path, pointers, digestPointers, metadata.baseAddress, metadata.count, { Task.isCancelled ? 1 : 0 }, &removed)
                }
            }
        }
        if code != 0, removed > 0 {
            throw ShouError("purge_outcome_unknown", "Permanent removal stopped after removing \(removed) manifest entries. Inspect the partial result before any further action.", details: ["path": path, "win32_code": String(code)])
        }
        if code == 1223 { throw ShouError("cancelled", "Permanent removal cancelled before any entries were removed.") }
        try WindowsNative.check(code, path: path)
    }
    public func availableBytes(_ path: String) -> Int64? {
        var count: UInt64=0
        guard shou_win_available(path, &count) == 0, count <= UInt64(Int64.max) else { return nil }; return Int64(count)
    }
}

public enum WindowsConsole {
    public static func readInput(_ bytes: inout [UInt8]) throws -> Int {
        var count: UInt32=0
        let code=bytes.withUnsafeMutableBytes { shou_win_stdin($0.baseAddress, UInt32($0.count), &count) }
        try WindowsNative.check(code, path: "stdin")
        return Int(count)
    }
    public static func confirm(review: String, phrase: String, locale: String) throws {
        let prompt=locale == "zh-CN" ? "\n请核对以上范围，输入 \(phrase) 确认：\n" : "\nReview this scope. Type \(phrase) to confirm:\n"
        let status=shou_win_console_confirm(review, prompt, phrase)
        guard status == 0 else { throw ShouError(status == 6 ? "confirmation_required" : "cancelled", "Interactive confirmation was not completed. No targets were changed.") }
    }
}
#endif
