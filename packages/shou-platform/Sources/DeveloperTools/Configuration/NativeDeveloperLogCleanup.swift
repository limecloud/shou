import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct NativeDeveloperLogCleanup: DeveloperLogCleaning {
    private let toolID: String
    private let path: String
    private let home: URL
    private let currentUser: UInt32
    private let privileged: Bool
    public init(toolID: String, target: DeveloperLogTarget, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.toolID=toolID; path=target.path; home=homeDirectory; currentUser=getuid(); privileged=false }
    init(toolID: String, target: DeveloperLogTarget, homeDirectory: URL, currentUser: UInt32) { self.toolID=toolID; path=target.path; home=homeDirectory; self.currentUser=currentUser; privileged=true }
    public func inspect() throws -> DeveloperLogInspection {
        if !privileged, NativeSystemAuthorization.shared.administratorState == .authorized, NativeAuthorizedConfiguration.supports(path,configuration:false,home:home.path) {
            let reply=try NativeSystemAuthorization.shared.perform(.logInspect,path:path,toolID:toolID)
            guard let inspection=reply.logInspection else { throw AuthorizationChannel.failure() }
            return inspection
        }
        let physical=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
        let protected=[".ssh",".gnupg",".aws",".kube","Library/Keychains","Library/Mobile Documents","Library/CloudStorage"].map { home.appendingPathComponent($0).resolvingSymlinksInPath().path } + [LocalRecordStore.defaultDirectory.resolvingSymlinksInPath().path]
        guard !protected.contains(where:{ physical == $0 || physical.hasPrefix($0 + "/") }) else { throw failure() }
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessFailure() }; defer { close(fd) }
        let value=try metadata(fd)
        let writable=value.mode & 0o022 == 0 && (privileged || value.owner == currentUser && access(path,W_OK) == 0)
        if !writable, value.mode & 0o022 == 0, NativeAuthorizedConfiguration.supports(path,configuration:false,home:home.path) {
            throw ShouError("permission_denied","Administrator authorization is needed to clear this log.",details:["path":path,"access_requirement":SystemAccessRequirement.administrator.rawValue])
        }
        return .init(toolID:toolID,file:value,writable:writable)
    }
    public func clear(expected: DeveloperLogInspection) throws {
        guard expected.toolID == toolID, expected.file.path == path, expected.writable else { throw failure() }
        if !privileged, expected.file.owner != currentUser || access(path,W_OK) != 0 {
            _ = try NativeSystemAuthorization.shared.perform(.logClear,path:path,logInspection:expected)
            return
        }
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessFailure() }; defer { close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw failure() }; defer { flock(fd,LOCK_UN) }
        let fresh=try metadata(fd)
        guard fresh == expected.file, (privileged || fresh.owner == currentUser && access(path,W_OK) == 0), fresh.mode & 0o022 == 0,
              try inspect() == expected else { throw failure() }
        guard ftruncate(fd,0) == 0, fsync(fd) == 0 else { throw failure() }
    }
    private func metadata(_ fd: Int32) throws -> FileEntry {
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              [0,currentUser].contains(info.st_uid) else { throw failure() }
        return SecurePaths.entry(info,path:path)
    }
    private func failure() -> ShouError { ShouError("developer_log_changed","The log changed or cannot be cleared. Reload its exact file before trying again.") }
    private func accessFailure() -> ShouError {
        errno == EACCES || errno == EPERM ? SecurePaths.failure("Open selected service log",path:path) : failure()
    }
}
#endif
