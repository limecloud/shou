import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Keep discovery and budget allocation shared while each platform supplies
/// no-follow directory and metadata reads.
final class CleanupDirectoryAccess {
    private let path: String
    #if !os(Windows)
    private let descriptor: Int32
    #endif

    init(_ path: String, cancelled: @Sendable () -> Bool) throws {
        self.path=path
        #if os(Windows)
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        guard try WindowsNative.metadata(path).kind == 2 else { throw ShouError("invalid_argument", "Select a regular directory.") }
        #else
        descriptor=try SecurePaths.directory(path, cancelled: cancelled)
        #endif
    }
    deinit {
        #if !os(Windows)
        close(descriptor)
        #endif
    }
    func entry(relative: String) throws -> FileEntry {
        #if os(Windows)
        return try WindowsNative.entry(WindowsNative.metadata(path), path: relative)
        #else
        var value=stat()
        guard fstat(descriptor, &value) == 0 else { throw SecurePaths.failure("Inspect directory", path: path) }
        return SecurePaths.entry(value, path: relative)
        #endif
    }
    func child(_ name: String, relative: String) throws -> FileEntry? {
        #if os(Windows)
        do { return try WindowsNative.entry(WindowsNative.metadata(path + "/" + name), path: relative) }
        catch let error as ShouError where error.code == "not_found" { return nil }
        #else
        var value=stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw SecurePaths.failure("Inspect child", path: path + "/" + name)
        }
        #if canImport(Darwin)
        if value.st_flags & UInt32(SF_DATALESS) != 0 { throw ShouError("cloud_placeholder", "Cloud placeholder: " + relative) }
        #endif
        return SecurePaths.entry(value, path: relative)
        #endif
    }
    func names(limit: Int, deadline: ContinuousClock.Instant, cancelled: @Sendable () -> Bool) throws -> (names: [String], truncated: Bool) {
        #if os(Windows)
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        let remaining=ContinuousClock.now.duration(to: deadline).components
        let seconds=Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { return ([], true) }
        var truncated: Int32=0
        let text=try WindowsNative.string({ shou_win_list_bounded(path, limit, UInt32(min(600_000, max(1, ceil(seconds * 1000)))), $0, &truncated, { Task.isCancelled ? 1 : 0 }) }, path: path)
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        return (text.split(separator: "\n").map(String.init).sorted(), truncated != 0)
        #else
        return try NativeDefinitionFiles.names(descriptor, limit: limit, deadline: deadline, cancelled: cancelled)
        #endif
    }
    static func metadata(_ path: String, relative: String, cancelled: @Sendable () -> Bool) throws -> FileEntry {
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        #if os(Windows)
        return try WindowsNative.entry(WindowsNative.metadata(path), path: relative)
        #else
        let (parent, name)=try SecurePaths.parent(path, cancelled: cancelled)
        defer { close(parent) }
        var value=stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect path", path: path) }
        return SecurePaths.entry(value, path: relative)
        #endif
    }
}
