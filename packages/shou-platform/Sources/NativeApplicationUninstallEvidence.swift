import Foundation
import ShouCore
#if os(macOS)
import AppKit
import Darwin
#endif

public struct NativeApplicationUninstallEvidence: ApplicationUninstallChecking {
    public init() {}
    public func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts {
        #if os(macOS)
        let deadline=ContinuousClock.now.advanced(by: .seconds(3))
        let needed=proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0, needed <= 262_144 else { throw unavailable() }
        var pids=[pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 256)
        let capacity=Int32(pids.count * MemoryLayout<pid_t>.stride)
        let returned=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, capacity) }
        guard returned > 0, returned < capacity, returned % Int32(MemoryLayout<pid_t>.stride) == 0 else { throw unavailable() }
        var running=application.bundleIdentifier.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        let prefix=application.path + "/"
        for pid in pids.prefix(Int(returned) / MemoryLayout<pid_t>.stride) where pid > 0 {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            guard ContinuousClock.now < deadline else { throw unavailable() }
            var buffer=[CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count=buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard count > 0 else {
                // An exited process needs no protection. A live process whose
                // executable cannot be verified keeps the action unavailable.
                if kill(pid, 0) != 0 && errno == ESRCH { continue }
                throw unavailable()
            }
            guard let end=buffer.firstIndex(of: 0), let path=String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8), path.hasPrefix("/") else { throw unavailable() }
            if path.hasPrefix(prefix) { running=true }
        }
        let own=URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        return ApplicationUninstallFacts(currentUser: getuid(), running: running, currentApplication: own.hasPrefix(prefix) || Bundle.main.bundleURL.path == application.path)
        #else
        throw unavailable()
        #endif
    }
    public func containerIdentifier(at path: String) throws -> String {
        #if os(macOS)
        let descriptor=try SecurePaths.directory(path)
        defer { close(descriptor) }
        let name=".com.apple.containermanagerd.metadata.plist"
        let bytes=try NativeDefinitionFiles.bytes(directory: descriptor, name: name, path: path + "/" + name, deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        guard let dictionary=try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              let identifier=dictionary["MCMMetadataIdentifier"] as? String, identifier.utf8.count <= 255 else {
            throw ShouError("ownership_unverified", "Container ownership could not be verified.")
        }
        return identifier
        #else
        throw ShouError("ownership_unverified", "Container ownership could not be verified.")
        #endif
    }
    private func unavailable() -> ShouError {
        ShouError("application_activity_unavailable", "Application processes and helpers could not be verified.")
    }
}
