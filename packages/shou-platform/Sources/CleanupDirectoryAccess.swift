import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Keep discovery and budget allocation shared while each platform supplies
/// no-follow directory and metadata reads.
final class CleanupDirectoryAccess {
    private let path: String
    private let descriptor: Int32

    init(_ path: String, cancelled: @Sendable () -> Bool) throws {
        self.path=path
        descriptor=try SecurePaths.directory(path, cancelled: cancelled)
    }
    deinit {
        close(descriptor)
    }
    func entry(relative: String) throws -> FileEntry {
        var value=stat()
        guard fstat(descriptor, &value) == 0 else { throw SecurePaths.failure("Inspect directory", path: path) }
        return SecurePaths.entry(value, path: relative)
    }
    func child(_ name: String, relative: String) throws -> FileEntry? {
        var value=stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw SecurePaths.failure("Inspect child", path: path + "/" + name)
        }
        #if canImport(Darwin)
        if value.st_flags & UInt32(SF_DATALESS) != 0 { throw ShouError("cloud_placeholder", "Cloud placeholder: " + relative) }
        #endif
        return SecurePaths.entry(value, path: relative)
    }
    func names(limit: Int, deadline: ContinuousClock.Instant, cancelled: @Sendable () -> Bool) throws -> (names: [String], truncated: Bool) {
        return try NativeDefinitionFiles.names(descriptor, limit: limit, deadline: deadline, cancelled: cancelled)
    }
    static func metadata(_ path: String, relative: String, cancelled: @Sendable () -> Bool) throws -> FileEntry {
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        let (parent, name)=try SecurePaths.parent(path, cancelled: cancelled)
        defer { close(parent) }
        var value=stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect path", path: path) }
        return SecurePaths.entry(value, path: relative)
    }
}
