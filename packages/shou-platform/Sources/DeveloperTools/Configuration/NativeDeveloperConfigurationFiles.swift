import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct DeveloperConfigurationDocument: Sendable {
    public let path: String
    public let text: String
    public let identity: FileEntry
    public let writable: Bool
}
/// Exact-file editing shared by software adapters. No include expansion,
/// service restart, configuration execution or plaintext journal copies.
public struct NativeDeveloperConfigurationFiles: Sendable {
    private let recordsDirectory: URL
    public init(recordsDirectory: URL = LocalRecordStore.defaultDirectory) { self.recordsDirectory=recordsDirectory }
    public static func accepts(_ path: String) -> Bool {
        let url=URL(fileURLWithPath:path)
        return url.lastPathComponent == "Caddyfile" || ["cnf","conf","yaml","yml","toml","json"].contains(url.pathExtension)
    }
    public func read(_ path: String) throws -> DeveloperConfigurationDocument {
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("developer_config_unavailable") }; defer { close(fd) }
        let before=try metadata(fd,path:path)
        guard before.logicalBytes <= 262_144 else { throw failure("resource_limit") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        let data=try handle.read(upToCount:262_145) ?? Data()
        guard data.count <= 262_144, before == (try metadata(fd,path:path)), let text=String(data:data,encoding:.utf8) else { throw failure("developer_config_changed") }
        return .init(path:path,text:text,identity:before,writable:Self.accepts(path) && before.owner == getuid() && before.mode & 0o200 != 0 && before.mode & 0o022 == 0)
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
        let (parent,name)=try SecurePaths.parent(expected.path); defer { close(parent) }
        let fd=openat(parent,name,O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("developer_config_unavailable") }; defer { close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw failure("developer_config_changed") }; defer { flock(fd,LOCK_UN) }
        guard try metadata(fd,path:expected.path) == expected.identity, try read(expected.path).text == expected.text else { throw failure("developer_config_changed") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false), data=Data(text.utf8)
        try handle.write(contentsOf:data); try handle.truncate(atOffset:UInt64(data.count)); try handle.synchronize()
        let saved=try read(expected.path)
        guard saved.text == text, saved.identity.device == expected.identity.device, saved.identity.inode == expected.identity.inode else { throw failure("developer_config_changed") }
        try store.write("developer-config-edit-results",id:id,data:JSONSerialization.data(withJSONObject:["path":expected.path,"state":"saved"]))
        return saved
    }
    public func log(path: String) throws -> String {
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("developer_log_unavailable") }; defer { close(fd) }
        let info=try metadata(fd,path:path), offset=max(0,info.logicalBytes-65_536)
        guard lseek(fd,off_t(offset),SEEK_SET) >= 0 else { throw failure("developer_log_unavailable") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false), data=try handle.read(upToCount:65_536) ?? Data()
        var lines=String(decoding:data,as:UTF8.self).split(separator:"\n",omittingEmptySubsequences:false)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines.suffix(200).joined(separator:"\n")
    }
    private func metadata(_ fd: Int32, path: String) throws -> FileEntry {
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, [0,getuid()].contains(info.st_uid) else { throw failure("developer_config_unavailable") }
        return SecurePaths.entry(info,path:path)
    }
    private func failure(_ code: String) -> ShouError { ShouError(code,"The selected configuration file cannot be read or has changed. Reload its exact path before saving.") }
}
#endif
