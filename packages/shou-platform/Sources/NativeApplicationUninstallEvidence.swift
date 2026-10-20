import Foundation
import ShouCore
#if os(macOS)
import AppKit
import Darwin
#endif

public struct NativeApplicationUninstallEvidence: ApplicationUninstallChecking {
    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.homeDirectory=homeDirectory }
    public func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts {
        guard let value=try facts(for: [application])[application.id] else { throw unavailable() }
        return value
    }
    public func facts(for applications: [ApplicationDefinition]) throws -> [String: ApplicationUninstallFacts] {
        #if os(macOS)
        if applications.isEmpty { return [:] }
        let deadline=ContinuousClock.now.advanced(by: .seconds(3))
        let needed=proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0, needed <= 262_144 else { throw unavailable() }
        var pids=[pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 256)
        let capacity=Int32(pids.count * MemoryLayout<pid_t>.stride)
        let returned=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, capacity) }
        guard returned > 0, returned < capacity, returned % Int32(MemoryLayout<pid_t>.stride) == 0 else { throw unavailable() }
        let runningIdentifiers=Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var executablePaths=[String]()
        for pid in pids.prefix(Int(returned) / MemoryLayout<pid_t>.stride) where pid > 0 {
            if let path=try executablePath(for: pid, deadline: deadline) { executablePaths.append(path) }
        }
        let own=URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        var result=[String: ApplicationUninstallFacts]()
        for application in applications {
            let prefix=application.path + "/"
            let running=application.bundleIdentifier.map(runningIdentifiers.contains) == true || executablePaths.contains { $0.hasPrefix(prefix) }
            result[application.id]=ApplicationUninstallFacts(currentUser: getuid(), running: running,
                currentApplication: own.hasPrefix(prefix) || Bundle.main.bundleURL.path == application.path)
        }
        return result
        #else
        throw unavailable()
        #endif
    }
    #if os(macOS)
    private func executablePath(for pid: pid_t, deadline: ContinuousClock.Instant) throws -> String? {
        for attempt in 0...1 {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            guard ContinuousClock.now < deadline else { throw unavailable() }
            var buffer=[CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            errno=0
            let count=buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let pathError=errno
            if count > 0 {
                guard let end=buffer.firstIndex(of: 0), let path=String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8), path.hasPrefix("/") else { throw unavailable() }
                return path
            }
            if kill(pid, 0) != 0 {
                if errno == ESRCH { return nil }
                throw unavailable()
            }
            guard pathError == ESRCH else { throw unavailable() }
            var info=kinfo_proc(), size=MemoryLayout<kinfo_proc>.stride
            var query=[Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_PID), pid]
            let result=query.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
            }
            guard result == 0 else { throw unavailable() }
            // kill(pid, 0) also succeeds for zombies. Only kernel-confirmed
            // exit evidence permits skipping a process without its executable.
            if size == 0 { return nil }
            guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { throw unavailable() }
            if Int(info.kp_proc.p_stat) == Int(SZOMB) { return nil }
            // An exiting process may remain runnable briefly. Retry once;
            // unresolved live processes and permission failures stay blocked.
            guard attempt == 0 else { throw unavailable() }
            usleep(1_000)
        }
        throw unavailable()
    }
    #endif
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
    public func groupContainerPaths(for bundleIdentifier: String) throws -> [String] {
        #if os(macOS)
        guard bundleIdentifier.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            throw ShouError("ownership_unverified", "Group container ownership could not be verified.")
        }
        let root=homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true).path
        let descriptor: Int32
        do { descriptor=try SecurePaths.directory(root) }
        catch let error as ShouError where error.code == "io_error" || error.code == "permission_denied" { throw error }
        catch { return [] }
        defer { close(descriptor) }
        let listing=try NativeDefinitionFiles.names(descriptor, limit: 2_048, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
        var matches: [String]=[]
        for name in listing.names {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            guard name.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
            var metadata=stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else { continue }
            let path=root + "/" + name
            do {
                let child=try SecurePaths.directory(path)
                defer { close(child) }
                let metadataName=".com.apple.containermanagerd.metadata.plist"
                let bytes=try NativeDefinitionFiles.bytes(directory: child, name: metadataName, path: path + "/" + metadataName,
                    deadline: ContinuousClock.now.advanced(by: .seconds(2)))
                guard let dictionary=try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
                      let identifier=dictionary["MCMMetadataIdentifier"] as? String,
                      identifier == bundleIdentifier || identifier == "group." + bundleIdentifier else { continue }
                matches.append(path)
            } catch let error as ShouError {
                if error.code == "cancelled" { throw error }
                continue
            } catch { continue }
        }
        return matches.sorted()
        #else
        throw ShouError("unsupported_platform", "Group container discovery is currently available only on macOS.")
        #endif
    }
    private func unavailable() -> ShouError {
        ShouError("application_activity_unavailable", "Application processes and helpers could not be verified.")
    }
}
