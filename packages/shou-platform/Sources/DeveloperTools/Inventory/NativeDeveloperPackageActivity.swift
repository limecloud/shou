import Foundation
import ShouCore
#if os(macOS)
import Darwin
import AppKit

/// Read image paths only; package uninstall never stops an unrelated process.
public struct NativeDeveloperPackageActivity: Sendable {
    private let prefixes: [String]
    public init(prefixes: [String] = ["/opt/homebrew","/usr/local"]) { self.prefixes=prefixes }
    public func requireInactive(_ package: DeveloperToolPackage) throws {
        guard package.valid, package.provider == "homebrew" else { throw failure() }
        let roots=prefixes.map { URL(fileURLWithPath:$0).appendingPathComponent(package.kind == "cask" ? "Caskroom" : "Cellar").appendingPathComponent(package.token).resolvingSymlinksInPath().path + "/" }
        let names=try executableNames(roots)
        let required=proc_listpids(UInt32(PROC_UID_ONLY),getuid(),nil,0)
        guard required > 0, required < 8192 * 4 else { throw failure() }
        var pids=[Int32](repeating:0,count:Int(required)/4+128)
        let count=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY),getuid(),$0.baseAddress,Int32($0.count)) }
        guard count >= 0, Int(count) < pids.count*4 else { throw failure() }
        for pid in pids.prefix(Int(count)/4) where pid > 0 {
            var bytes=[UInt8](repeating:0,count:4096)
            let length=proc_pidpath(pid,&bytes,4096)
            let appPath=length <= 0 ? NSRunningApplication(processIdentifier:pid)?.executableURL?.resolvingSymlinksInPath().path : nil
            if length <= 0, appPath == nil {
                var info=proc_bsdinfo()
                if proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                   info.pbi_uid == getuid(), info.pbi_status != 5 {
                    let name=withUnsafeBytes(of:info.pbi_comm) { String(decoding:$0.prefix(while:{ $0 != 0 }),as:UTF8.self) }
                    // An unreadable image with a matching executable basename
                    // remains unknown. Unrelated GUI/helper names do not block
                    // every package uninstall on a normal protected desktop.
                    if name.isEmpty || names.contains(where:{ $0.hasPrefix(name) || name.hasPrefix($0) }) { throw failure() }
                }
                continue
            }
            let rawPath=appPath ?? String(decoding:bytes.prefix(Int(length)).prefix(while:{ $0 != 0 }),as:UTF8.self)
            let path=URL(fileURLWithPath:rawPath).resolvingSymlinksInPath().standardizedFileURL.path
            if roots.contains(where:{ path.hasPrefix($0) }) {
                throw ShouError("developer_tool_running","Stop the instances using this installation before uninstalling it.")
            }
        }
    }
    private func executableNames(_ roots: [String]) throws -> Set<String> {
        var names=Set<String>(), count=0
        for root in roots {
            var info=stat()
            if lstat(root,&info) != 0 { if errno == ENOENT { continue }; throw failure() }
            var failed=false
            guard let files=FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[],options:[],errorHandler:{ _,_ in failed=true; return false }) else { throw failure() }
            while let path=files.nextObject() as? URL {
                count += 1; guard count <= 40_000 else { throw failure() }
                var file=stat()
                guard lstat(path.path,&file) == 0 else { throw failure() }
                if file.st_mode & S_IFMT != S_IFDIR, file.st_mode & 0o111 != 0 { names.insert(path.lastPathComponent) }
            }
            if failed { throw failure() }
        }
        return names
    }
    private func failure() -> ShouError { ShouError("developer_tool_activity_unavailable","Running programs could not be verified. Refresh before uninstalling.") }
}
#endif
