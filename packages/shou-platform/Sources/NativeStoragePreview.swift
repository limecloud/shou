import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct NativeStoragePreview: StoragePreviewReading {
    public init() {}
    public func read(_ path: String, expected: FileEntry, maximumBytes: Int, cancelled: @Sendable () -> Bool) throws -> Data {
        guard expected.kind == "file", (1...4_194_304).contains(maximumBytes) else { throw ShouError("invalid_argument", "Choose a regular file within the preview budget.") }
        if cancelled() { throw ShouError("cancelled", "Preview stopped.") }
        #if os(Windows)
        var saved=try WindowsNative.savedInfo(expected), bytes: UnsafeMutableRawPointer?, count=0
        let code=shou_win_preview_read(path, &saved, maximumBytes, &bytes, &count)
        defer { shou_win_free(bytes) }
        try WindowsNative.check(code, path: path)
        if cancelled() { throw ShouError("cancelled", "Preview stopped.") }
        guard let bytes else { throw ShouError("io_error", "Preview could not be read.") }
        return Data(bytes: bytes, count: count)
        #else
        let (parent, name)=try SecurePaths.parent(path, cancelled: cancelled)
        defer { close(parent) }
        #if canImport(Darwin)
        var before=stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect preview", path: path) }
        guard before.st_flags & UInt32(SF_DATALESS) == 0 else { throw ShouError("cloud_placeholder", "Cloud placeholders are not opened for preview.") }
        #endif
        let descriptor=openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecurePaths.failure("Open preview without following links", path: path) }
        defer { close(descriptor) }
        func verify() throws {
            var opened=stat(), current=stat()
            guard fstat(descriptor, &opened) == 0, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  SecurePaths.entry(opened, path: expected.path).metadata == expected.metadata,
                  SecurePaths.entry(current, path: expected.path).metadata == expected.metadata else { throw ShouError("plan_stale", "File changed since analysis. Scan again before previewing.") }
            #if canImport(Darwin)
            guard opened.st_flags & UInt32(SF_DATALESS) == 0, current.st_flags & UInt32(SF_DATALESS) == 0 else { throw ShouError("cloud_placeholder", "Cloud placeholders are not opened for preview.") }
            #endif
        }
        try verify()
        let deadline=ContinuousClock.now.advanced(by: .seconds(10))
        var data=Data(), buffer=[UInt8](repeating: 0, count: min(maximumBytes, 65_536))
        while data.count < maximumBytes {
            if cancelled() { throw ShouError("cancelled", "Preview stopped.") }
            guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Preview read limit reached.") }
            let wanted=min(buffer.count, maximumBytes - data.count)
            let count=buffer.withUnsafeMutableBytes { raw in
                #if canImport(Darwin)
                Darwin.read(descriptor, raw.baseAddress, wanted)
                #else
                Glibc.read(descriptor, raw.baseAddress, wanted)
                #endif
            }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SecurePaths.failure("Read preview", path: path) }
            data.append(contentsOf: buffer.prefix(count))
        }
        try verify(); return data
        #endif
    }
}
