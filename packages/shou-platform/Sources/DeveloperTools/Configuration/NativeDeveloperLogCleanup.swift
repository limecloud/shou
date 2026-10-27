import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct NativeDeveloperLogCleanup: DeveloperLogCleaning {
    private let toolID: String
    private let path: String
    private let home: URL
    public init(toolID: String, target: DeveloperLogTarget, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.toolID=toolID; path=target.path; home=homeDirectory }
    public func inspect() throws -> DeveloperLogInspection {
        let physical=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
        let protected=[".ssh",".gnupg",".aws",".kube","Library/Keychains","Library/Mobile Documents","Library/CloudStorage"].map { home.appendingPathComponent($0).resolvingSymlinksInPath().path } + [LocalRecordStore.defaultDirectory.resolvingSymlinksInPath().path]
        guard !protected.contains(where:{ physical == $0 || physical.hasPrefix($0 + "/") }) else { throw failure() }
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        let value=try metadata(fd)
        return .init(toolID:toolID,file:value,writable:value.owner == getuid() && value.mode & 0o200 != 0 && value.mode & 0o022 == 0)
    }
    public func clear(expected: DeveloperLogInspection) throws {
        guard expected.toolID == toolID, expected.file.path == path, expected.writable else { throw failure() }
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw failure() }; defer { flock(fd,LOCK_UN) }
        let fresh=try metadata(fd)
        guard fresh == expected.file, fresh.owner == getuid(), fresh.mode & 0o200 != 0, fresh.mode & 0o022 == 0,
              try inspect() == expected else { throw failure() }
        guard ftruncate(fd,0) == 0, fsync(fd) == 0 else { throw failure() }
    }
    private func metadata(_ fd: Int32) throws -> FileEntry {
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              [0,getuid()].contains(info.st_uid) else { throw failure() }
        return SecurePaths.entry(info,path:path)
    }
    private func failure() -> ShouError { ShouError("developer_log_changed","The log changed or cannot be cleared. Reload its exact file before trying again.") }
}
#endif
