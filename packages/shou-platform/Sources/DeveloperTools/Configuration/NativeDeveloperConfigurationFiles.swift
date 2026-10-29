import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct DeveloperConfigurationDocument: Codable, Sendable {
    public let path: String
    public let text: String
    public let identity: FileEntry
    public let writable: Bool
    public var requiresAdministrator: Bool = false
}
/// Exact-file editing shared by software adapters. No include expansion,
/// service restart, configuration execution or plaintext journal copies.
public struct NativeDeveloperConfigurationFiles: Sendable {
    private let recordsDirectory: URL
    private let currentUser: UInt32
    private let privileged: Bool
    public init(recordsDirectory: URL = LocalRecordStore.defaultDirectory) { self.recordsDirectory=recordsDirectory; currentUser=getuid(); privileged=false }
    init(currentUser: UInt32) { recordsDirectory=LocalRecordStore.defaultDirectory; self.currentUser=currentUser; privileged=true }
    public static func accepts(_ path: String) -> Bool {
        let url=URL(fileURLWithPath:path)
        return url.lastPathComponent == "Caddyfile" || ["cnf","conf","yaml","yml","toml","json"].contains(url.pathExtension)
    }
    public func read(_ path: String) throws -> DeveloperConfigurationDocument {
        if !privileged, NativeSystemAuthorization.shared.administratorState == .authorized, NativeAuthorizedConfiguration.supports(path, configuration: true) {
            let reply=try NativeSystemAuthorization.shared.perform(.configurationRead, path: path)
            guard let document=reply.document else { throw AuthorizationChannel.failure() }
            return document
        }
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessFailure("developer_config_unavailable", path: path) }; defer { close(fd) }
        let before=try metadata(fd,path:path)
        guard before.logicalBytes <= 262_144 else { throw failure("resource_limit") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data=try handle.read(upToCount:262_145) ?? Data()
        guard data.count <= 262_144, before == (try metadata(fd,path:path)), let text=String(data:data,encoding:.utf8) else { throw failure("developer_config_changed") }
        let writable=Self.accepts(path) && before.mode & 0o022 == 0 && (privileged || before.owner == currentUser && access(path,W_OK) == 0)
        var document=DeveloperConfigurationDocument(path:path,text:text,identity:before,writable:writable)
        document.requiresAdministrator = !writable && Self.accepts(path) && before.mode & 0o022 == 0 &&
            NativeAuthorizedConfiguration.supports(path, configuration: true) && (try? NativeSystemAuthorization.workerExecutable()) != nil
        return document
    }
    public func save(_ text: String, expected: DeveloperConfigurationDocument) throws -> DeveloperConfigurationDocument {
        guard Self.accepts(expected.path), expected.writable, text.utf8.count <= 262_144, !text.contains("\0"),
              try read(expected.path).identity == expected.identity else { throw failure("developer_config_changed") }
        let store=try LocalRecordStore(directory:recordsDirectory), lease=try store.lock(); defer { lease.release() }
        let id=UUID().uuidString
        // Configuration may itself contain secrets. Journal hashes and outcome,
        // never copy its plaintext into ordinary operation records.
        let record=["path":expected.path,"before":Digest.sha256(Data(expected.text.utf8)),"after":Digest.sha256(Data(text.utf8)),"state":"requested"]
        try store.write("developer-config-edits",id:id,data:JSONSerialization.data(withJSONObject:record))
        let saved: DeveloperConfigurationDocument
        if !privileged, expected.identity.owner != currentUser || access(expected.path,W_OK) != 0 {
            let reply=try NativeSystemAuthorization.shared.perform(.configurationSave,path:expected.path,document:expected,text:text)
            guard let value=reply.document else { throw AuthorizationChannel.failure() }
            saved=value
        } else { saved=try overwrite(text,expected:expected) }
        try store.write("developer-config-edit-results",id:id,data:JSONSerialization.data(withJSONObject:["path":expected.path,"state":"saved"]))
        return saved
    }
    func overwrite(_ text: String, expected: DeveloperConfigurationDocument) throws -> DeveloperConfigurationDocument {
        guard Self.accepts(expected.path), expected.writable, text.utf8.count <= 262_144, !text.contains("\0") else { throw failure("developer_config_changed") }
        let (parent,name)=try SecurePaths.parent(expected.path); defer { close(parent) }
        let fd=openat(parent,name,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessFailure("developer_config_unavailable", path: expected.path) }; defer { close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw failure("developer_config_changed") }; defer { flock(fd,LOCK_UN) }
        let current=try read(expected.path)
        guard current.writable, try metadata(fd,path:expected.path) == expected.identity, current.text == expected.text else { throw failure("developer_config_changed") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false), data=Data(text.utf8)
        try handle.write(contentsOf:data); try handle.truncate(atOffset:UInt64(data.count)); try handle.synchronize()
        let saved=try read(expected.path)
        guard saved.text == text, saved.identity.device == expected.identity.device, saved.identity.inode == expected.identity.inode else { throw failure("developer_config_changed") }
        return saved
    }
    public func log(path: String) throws -> String {
        if !privileged, NativeSystemAuthorization.shared.administratorState == .authorized, NativeAuthorizedConfiguration.supports(path, configuration: false) {
            let reply=try NativeSystemAuthorization.shared.perform(.logRead,path:path)
            guard let text=reply.text else { throw AuthorizationChannel.failure() }
            return text
        }
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessFailure("developer_log_unavailable", path: path) }; defer { close(fd) }
        let info=try metadata(fd,path:path), offset=max(0,info.logicalBytes-65_536)
        guard lseek(fd,off_t(offset),SEEK_SET) >= 0 else { throw failure("developer_log_unavailable") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false), data=try handle.read(upToCount:65_536) ?? Data()
        var lines=String(decoding:data,as:UTF8.self).split(separator:"\n",omittingEmptySubsequences:false)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines.suffix(200).joined(separator:"\n")
    }
    private func metadata(_ fd: Int32, path: String) throws -> FileEntry {
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, [0,currentUser].contains(info.st_uid) else { throw failure("developer_config_unavailable") }
        return SecurePaths.entry(info,path:path)
    }
    private func failure(_ code: String) -> ShouError { ShouError(code,"The selected configuration file cannot be read or has changed. Reload its exact path before saving.") }
    private func accessFailure(_ code: String, path: String) -> ShouError {
        if errno == EACCES || errno == EPERM { return SecurePaths.failure("Open selected developer file",path:path) }
        return failure(code)
    }
}
#endif
