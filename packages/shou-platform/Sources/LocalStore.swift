import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
public final class LocalRecordStore: RecordStore, @unchecked Sendable {
    public let directory: URL
    private let root: Int32
    public var protectedPaths: [String] { [directory.path] }
    public func storageCatalogURL(id: String) throws -> URL? {
        try validate(id)
        let descriptor=try collection("storage-catalogs")
        defer { close(descriptor) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw ShouError("permission_denied", "Space analysis storage must be private to the current user.")
        }
        return directory.appendingPathComponent("storage-catalogs", isDirectory: true).appendingPathComponent(id + ".sqlite")
    }
    public static var defaultDirectory: URL {
        if let path=ProcessInfo.processInfo.environment["SHOU_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shou", isDirectory: true)
    }
    public init(directory: URL = LocalRecordStore.defaultDirectory) throws {
        self.directory=directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        root = try SecurePaths.directory(directory.path)
        var metadata = stat()
        guard fstat(root, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            close(root); throw ShouError("permission_denied", "Shou data directory must be owned by the current user and have mode 0700.")
        }
    }
    deinit { close(root) }
    private func validate(_ value: String) throws {
        guard value.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil else { throw ShouError("invalid_argument", "Invalid record identifier.") }
    }
    private func collection(_ name: String) throws -> Int32 {
        try validate(name)
        if mkdirat(root, name, 0o700) != 0 && errno != EEXIST { throw SecurePaths.failure("Create record collection", path: name) }
        let fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SecurePaths.failure("Open record collection", path: name) }
        return fd
    }
    public func read(_ collection: String, id: String) throws -> Data? {
        try validate(id)
        let dir = try self.collection(collection); defer { close(dir) }
        let fd = openat(dir, id + ".json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw SecurePaths.failure("Read record", path: id) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 268_435_456, metadata.st_uid == getuid(), metadata.st_nlink == 1 else { throw ShouError("store_corrupt", "Record has an unsupported type, owner, link count, or size.") }
        var data=Data(), buffer=[UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                #if canImport(Darwin)
                Darwin.read(fd, raw.baseAddress, raw.count)
                #else
                Glibc.read(fd, raw.baseAddress, raw.count)
                #endif
            }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SecurePaths.failure("Read record bytes", path: id) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 268_435_456 else { throw ShouError("resource_limit", "Record exceeds the storage read limit.") }
        }
        return data
    }
    public func write(_ collection: String, id: String, data: Data) throws {
        try validate(id)
        guard data.count <= 268_435_456 else { throw ShouError("resource_limit", "Record exceeds the storage read limit.") }
        let dir = try self.collection(collection); defer { close(dir) }
        let temporary = ".pending-" + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecurePaths.failure("Create durable record", path: id) }
        defer { close(fd); _ = unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset=0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                #else
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SecurePaths.failure("Write durable record", path: id) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SecurePaths.failure("Flush record", path: id) }
        #if canImport(Darwin)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw SecurePaths.failure("Synchronize record storage", path: id) }
        #endif
        guard renameat(dir, temporary, dir, id + ".json") == 0, fsync(dir) == 0 else { throw SecurePaths.failure("Commit durable record", path: id) }
    }
    public func ids(_ collection: String) throws -> [String] {
        let dir = try self.collection(collection); defer { close(dir) }
        return try SecurePaths.names(dir).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) }.sorted()
    }
    public func removeHistoryRecord(_ collection: String, id: String) throws {
        guard ["history", "followups"].contains(collection) else { throw ShouError("invalid_argument", "Only history records can be removed here.") }
        try validate(id)
        let dir=try self.collection(collection); defer { close(dir) }
        var metadata=stat()
        let name=id + ".json"
        if fstatat(dir, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw SecurePaths.failure("Inspect history record", path: id)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1 else { throw ShouError("store_corrupt", "History record identity is invalid.") }
        guard unlinkat(dir, name, 0) == 0, fsync(dir) == 0 else { throw SecurePaths.failure("Remove history record", path: id) }
    }
    public func lock() throws -> any StoreLease {
        let fd = openat(root, ".mutation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecurePaths.failure("Open mutation lock", path: directory.path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ShouError("store_busy", "Another Shou process is changing configuration or executing a plan.", retryable: true) }
        return FileLease(fd)
    }
}
private final class FileLease: StoreLease, @unchecked Sendable {
    private let mutex=NSLock()
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor=descriptor }
    func release() { mutex.lock(); defer { mutex.unlock() }; if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
#endif
