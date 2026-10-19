import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
enum SecurePaths {
    static func failure(_ operation: String, path: String) -> ShouError {
        let code = errno
        return ShouError(code == EACCES || code == EPERM ? "permission_denied" : "io_error", "\(operation): \(String(cString: strerror(code)))", details: ["path": path])
    }
    static func components(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ShouError("invalid_argument", "An absolute local path is required.") }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else { throw ShouError("invalid_argument", "Dot path components are not supported.") }
        return components
    }
    static func directory(_ path: String, readFinalDirectory: Bool = true) throws -> Int32 {
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        let components = try components(path)
        #if canImport(Darwin)
        // Traversing an ancestor does not require permission to list its contents.
        // In particular, inspect only a returned Trash item, never the entire Trash.
        let searchOnly=O_SEARCH
        #else
        let searchOnly=O_RDONLY | O_DIRECTORY
        #endif
        let rootAccess=components.isEmpty && readFinalDirectory ? O_RDONLY | O_DIRECTORY : searchOnly
        var current = open("/", rootAccess | O_CLOEXEC)
        guard current >= 0 else { throw failure("Open root", path: path) }
        var returned=false
        defer { if !returned { close(current) } }
        for (index, part) in components.enumerated() {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            let access=readFinalDirectory && index == components.count - 1 ? O_RDONLY | O_DIRECTORY : searchOnly
            let next = openat(current, part, access | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure("Open directory without following links", path: path) }
            close(current)
            current = next
        }
        if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        returned=true
        return current
    }
    static func parent(_ path: String) throws -> (Int32, String) {
        let parts = try components(path)
        guard let name = parts.last else { throw ShouError("invalid_argument", "Filesystem roots are protected.") }
        return (try directory("/" + parts.dropLast().joined(separator: "/"), readFinalDirectory: false), name)
    }
    static func entry(_ metadata: stat, path: String) -> FileEntry {
        let type = metadata.st_mode & S_IFMT
        let kind = type == S_IFDIR ? "directory" : type == S_IFREG ? "file" : type == S_IFLNK ? "symlink" : "special"
        #if canImport(Darwin)
        let modified = Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtimespec.tv_nsec)
        let changed = Int64(metadata.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(metadata.st_ctimespec.tv_nsec)
        #else
        let modified = Int64(metadata.st_mtim.tv_sec) * 1_000_000_000 + Int64(metadata.st_mtim.tv_nsec)
        let changed = Int64(metadata.st_ctim.tv_sec) * 1_000_000_000 + Int64(metadata.st_ctim.tv_nsec)
        #endif
        return FileEntry(path: path, kind: kind, device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), logicalBytes: kind == "file" ? Int64(metadata.st_size) : 0,
            allocatedBytes: Int64(metadata.st_blocks) * 512, modifiedNanoseconds: modified, changedNanoseconds: changed,
            mode: UInt32(metadata.st_mode), owner: UInt32(metadata.st_uid), links: UInt64(metadata.st_nlink))
    }
    static func names(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw failure("Read directory", path: "<descriptor>") }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let pointer = readdir(stream) {
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pointer.pointee.d_name)) { String(validatingCString: $0) }
            }
            guard let name else { throw ShouError("capability_unavailable", "Non-UTF-8 filenames cannot be safely represented in this build.") }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw failure("Enumerate directory", path: "<descriptor>") }
        return result.sorted()
    }
}
#endif
