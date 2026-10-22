import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

public struct WindowsCleanupOwnerClosing: CleanupOwnerClosing {
    public init() {}
    public func inspect(identifiers: Set<String>) throws -> [CleanupOwnerTarget] {
        #if os(Windows)
        var result=[CleanupOwnerTarget]()
        for identifier in identifiers.sorted() {
            try Task.checkCancellation()
            let name=try executable(identifier)
            var pointer: UnsafeMutablePointer<shou_win_close_process>?, count=0
            try WindowsNative.check(shou_win_close_process_inventory(name, &pointer, &count), path: name)
            defer { shou_win_free(pointer) }
            guard count <= 256, count == 0 || pointer != nil else { throw ShouError("application_activity_unavailable", "Application process evidence exceeded its bounds.") }
            let processes=(0..<count).map { index -> CleanupOwnerProcess in
                var raw=pointer![index]
                let path=withUnsafeBytes(of: &raw.executable_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let owner=withUnsafeBytes(of: &raw.owner_sid) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                return .init(pid: raw.pid, created: raw.created, session: raw.session, ownerSid: owner, executablePath: path,
                    executableIdentity: WindowsNative.entry(raw.executable_identity, path: "executable"))
            }
            if !processes.isEmpty { result.append(.init(identifier: identifier, name: String(name.dropLast(4)), processes: processes)) }
        }
        return result
        #else
        throw ShouError("capability_unavailable", "Windows normal-close requests require Windows.")
        #endif
    }
    public func requestClose(_ target: CleanupOwnerTarget) throws {
        #if os(Windows)
        let name=try executable(target.identifier)
        let processes=try target.processes.map { process -> shou_win_close_process in
            guard process.pid != 0, process.session != 0, process.created != 0, !process.ownerSid.contains("\0"), !process.executablePath.contains("\0"),
                  process.ownerSid.utf8.count < 192, process.executablePath.utf8.count < 4096 else { throw ShouError("plan_stale", "Application process identity is invalid.") }
            var raw=shou_win_close_process(); raw.pid=process.pid; raw.created=process.created; raw.session=process.session
            withUnsafeMutableBytes(of: &raw.owner_sid) { $0.copyBytes(from: process.ownerSid.utf8CString.map { UInt8(bitPattern: $0) }) }
            withUnsafeMutableBytes(of: &raw.executable_path) { $0.copyBytes(from: process.executablePath.utf8CString.map { UInt8(bitPattern: $0) }) }
            raw.executable_identity=try WindowsNative.savedInfo(process.executableIdentity)
            return raw
        }
        try WindowsNative.check(processes.withUnsafeBufferPointer {
            shou_win_request_process_close(name, $0.baseAddress, $0.count, { _ in Task.isCancelled ? 1 : 0 }, nil)
        }, path: name)
        #else
        throw ShouError("capability_unavailable", "Windows normal-close requests require Windows.")
        #endif
    }
    public func isRunning(identifier: String) throws -> Bool {
        try NativeApplicationActivity().runningBundleIdentifiers(in: [identifier]).contains(identifier)
    }
    private func executable(_ identifier: String) throws -> String {
        guard let name=WindowsApplicationActivity.executableNames[identifier] else { throw ShouError("application_activity_unavailable", "Application has no verified Windows process mapping.") }
        return name
    }
}
