import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)

/// Shared bounded, no-follow reads for definition inventories and file targets.
enum NativeDefinitionFiles {
    private static func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw ShouError("cancelled", "Definition scan stopped.") }
    }
    static func names(_ descriptor: Int32, limit: Int, deadline: ContinuousClock.Instant, cancelled: @Sendable () -> Bool = { Task.isCancelled }) throws -> (names: [String], truncated: Bool) {
        let copy=dup(descriptor)
        guard copy >= 0, let stream=fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw ShouError("io_error", "Definition directory could not be read.")
        }
        defer { closedir(stream) }
        var names: [String]=[]
        while true {
            try checkCancellation(cancelled)
            if ContinuousClock.now >= deadline { return (names.sorted(), true) }
            errno=0
            guard let pointer=readdir(stream) else {
                guard errno == 0 else { throw ShouError("io_error", "Definition directory could not be read.") }
                return (names.sorted(), false)
            }
            let name=withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pointer.pointee.d_name)) { String(validatingCString: $0) }
            }
            guard let name else { throw ShouError("invalid_filename", "Definition filename cannot be represented.") }
            if name == "." || name == ".." { continue }
            if names.count == limit { return (names.sorted(), true) }
            names.append(name)
        }
    }
    static func bytes(directory: Int32, name: String, path: String, maximumBytes: Int = 262_144, deadline: ContinuousClock.Instant, cancelled: @Sendable () -> Bool = { Task.isCancelled }) throws -> Data {
        let descriptor=openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code=errno
            throw ShouError(code == ELOOP ? "linked_definition" : code == EPERM || code == EACCES ? "permission_denied" : "io_error", "Definition could not be read.")
        }
        let handle=FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before=stat()
        guard fstat(descriptor, &before) == 0 else { throw ShouError("io_error", "Definition could not be read.") }
        guard before.st_mode & S_IFMT == S_IFREG else { throw ShouError("unsupported_definition", "Definition is not a regular file.") }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw ShouError("definition_too_large", "Definition exceeds the read limit.") }
        var data=Data()
        while data.count <= maximumBytes {
            try checkCancellation(cancelled)
            guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Definition read limit reached.") }
            let bytes: Data?
            do { bytes=try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) }
            catch { throw ShouError("io_error", "Definition could not be read.") }
            guard let bytes, !bytes.isEmpty else { break }
            data.append(bytes)
        }
        guard data.count <= maximumBytes else { throw ShouError("definition_too_large", "Definition exceeds the read limit.") }
        var after=stat(), current=stat()
        guard fstat(descriptor, &after) == 0, fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(before, path: path) == SecurePaths.entry(after, path: path),
              SecurePaths.entry(after, path: path) == SecurePaths.entry(current, path: path), data.count == after.st_size else {
            throw ShouError("definition_changed", "Definition changed while reading.")
        }
        return data
    }
}
#endif
