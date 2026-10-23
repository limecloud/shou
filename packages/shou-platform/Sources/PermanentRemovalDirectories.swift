import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
/// Retain only the current ancestry, opening each directory without following
/// links. Recheck its attachment before every mutation, including cached paths.
final class PermanentRemovalDirectories {
    private struct Frame {
        let name: String
        let descriptor: Int32
        let identity: FileEntry
    }
    private let filesystemRoot: Int32
    private let targetDepth: Int
    private let anchorPath: String?
    private let directories: [String: FileEntry]
    private var frames=[Frame]()

    init(path: String, manifest: [FileEntry]) throws {
        directories=Dictionary(uniqueKeysWithValues: manifest.filter { $0.kind == "directory" }.map { ($0.path, $0) })
        let components: [String]
        #if canImport(Darwin)
        let (parent, name)=try SecurePaths.parent(path)
        filesystemRoot=parent; components=[name]; targetDepth=0
        do { anchorPath=try Self.directoryPath(parent) }
        catch { close(parent); throw error }
        #else
        components=try SecurePaths.components(path)
        guard !components.isEmpty else { throw ShouError("plan_stale", "Receipt root changed.") }
        targetDepth=components.count - 1; anchorPath=nil
        filesystemRoot=open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard filesystemRoot >= 0 else { throw SecurePaths.failure("Open root", path: path) }
        #endif
        guard let root=directories["."] else {
            close(filesystemRoot)
            throw ShouError("plan_stale", "Receipt root changed.")
        }
        do {
            var parent=filesystemRoot
            for (depth, name) in components.enumerated() {
                let expected: FileEntry
                if depth == targetDepth { expected=root }
                else {
                    var metadata=stat()
                    guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecurePaths.failure("Inspect receipt ancestor", path: path) }
                    expected=SecurePaths.entry(metadata, path: components.prefix(depth + 1).joined(separator: "/"))
                }
                let frame=try openDirectory(parent: parent, name: name, expected: expected, searchOnly: depth < targetDepth)
                frames.append(frame); parent=frame.descriptor
            }
        } catch {
            for frame in frames.reversed() { close(frame.descriptor) }
            close(filesystemRoot)
            throw error
        }
    }

    deinit {
        for frame in frames.reversed() { close(frame.descriptor) }
        close(filesystemRoot)
    }

    func parent(of entry: FileEntry) throws -> (Int32, String) {
        if Task.isCancelled { throw ShouError("cancelled", "Permanent removal cancelled; inspect the partial result.") }
        #if canImport(Darwin)
        // The kernel path detects a renamed/replaced absolute ancestor without
        // reopening it for every file. Relative attachments are checked below.
        guard try Self.directoryPath(filesystemRoot) == anchorPath else { throw ShouError("plan_stale", "Receipt root changed.") }
        #endif
        let parts=entry.path.split(separator: "/").map(String.init)
        guard entry.path == "." || StorageRemovalPolicy.validRelative(entry.path), let name=parts.last else {
            throw ShouError("plan_stale", "Receipt entry path is invalid.")
        }
        let ancestry=entry.path == "." ? [] : Array(parts.dropLast())
        var shared=0
        let rootCount=targetDepth + 1
        while shared < ancestry.count, shared + rootCount < frames.count, frames[shared + rootCount].name == ancestry[shared] { shared += 1 }
        while frames.count > shared + rootCount { close(frames.removeLast().descriptor) }
        var parent=filesystemRoot
        for frame in frames {
            try verify(parent: parent, name: frame.name, expected: frame.identity)
            parent=frame.descriptor
        }
        for depth in shared..<ancestry.count {
            let relative=ancestry.prefix(depth + 1).joined(separator: "/")
            guard let expected=directories[relative] else { throw ShouError("plan_stale", "Receipt directory is missing.") }
            let frame=try openDirectory(parent: parent, name: ancestry[depth], expected: expected)
            frames.append(frame); parent=frame.descriptor
        }
        let rootParent=targetDepth == 0 ? filesystemRoot : frames[targetDepth - 1].descriptor
        return entry.path == "." ? (rootParent, frames[targetDepth].name) : (parent, name)
    }

    #if canImport(Darwin)
    private static func directoryPath(_ descriptor: Int32) throws -> String {
        var buffer=[CChar](repeating: 0, count: Int(PATH_MAX))
        let result=buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { throw ShouError("plan_stale", "Receipt root changed.") }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    #endif

    private func verify(parent: Int32, name: String, expected: FileEntry) throws {
        var metadata=stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR, UInt64(metadata.st_dev) == expected.device,
              UInt64(metadata.st_ino) == expected.inode, UInt32(metadata.st_uid) == expected.owner,
              UInt32(metadata.st_mode) == expected.mode else {
            throw ShouError("plan_stale", "Receipt directory changed; permanent removal stopped.")
        }
    }

    private func openDirectory(parent: Int32, name: String, expected: FileEntry, searchOnly: Bool = false) throws -> Frame {
        try verify(parent: parent, name: name, expected: expected)
        #if canImport(Darwin)
        let access=searchOnly ? O_SEARCH : O_RDONLY | O_DIRECTORY
        #else
        let access=O_RDONLY | O_DIRECTORY
        #endif
        let descriptor=openat(parent, name, access | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SecurePaths.failure("Open receipt directory without following links", path: expected.path) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0, SecurePaths.entry(metadata, path: expected.path).sameObject(as: expected) else {
            close(descriptor)
            throw ShouError("plan_stale", "Receipt directory changed while opening it.")
        }
        return Frame(name: name, descriptor: descriptor, identity: expected)
    }
}
#endif
