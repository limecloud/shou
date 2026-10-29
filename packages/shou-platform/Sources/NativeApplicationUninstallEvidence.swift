import Foundation
import ShouCore
#if os(macOS)
import AppKit
import Darwin
#endif

public struct NativeApplicationUninstallEvidence: ApplicationUninstallChecking {
    private let homeDirectory: URL
    private let readWorkerExecutable: URL?
    private let currentUser: UInt32
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, readWorkerExecutable: URL? = nil, currentUser: UInt32? = nil) {
        self.homeDirectory=homeDirectory; self.readWorkerExecutable=readWorkerExecutable
        #if os(macOS)
        self.currentUser=currentUser ?? getuid()
        #else
        self.currentUser=currentUser ?? 0
        #endif
    }
    public func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts {
        guard let value=try facts(for: [application])[application.id] else { throw unavailable() }
        return value
    }
    public func facts(for applications: [ApplicationDefinition]) throws -> [String: ApplicationUninstallFacts] {
        #if os(macOS)
        if applications.isEmpty { return [:] }
        let deadline=ContinuousClock.now.advanced(by: .seconds(3))
        let needed=proc_listpids(UInt32(PROC_UID_ONLY), currentUser, nil, 0)
        guard needed > 0, needed <= 262_144 else { throw unavailable() }
        var pids=[pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 256)
        let capacity=Int32(pids.count * MemoryLayout<pid_t>.stride)
        let returned=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), currentUser, $0.baseAddress, capacity) }
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
            result[application.id]=ApplicationUninstallFacts(currentUser: currentUser, running: running,
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
            // A package-manager update can unlink an executable while its process
            // remains alive. Verify its kernel-cached executable instead of making
            // every unrelated application unavailable for uninstall.
            if pathError == ENOENT { return try cachedExecutablePath(for: pid) }
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
            // proc_pidpath can also return ESRCH for a live process. After one
            // retry, use the same identity-checked kernel cache as for ENOENT;
            // this never treats an unreadable live process as exited.
            if attempt == 1 { return try cachedExecutablePath(for: pid) }
            usleep(1_000)
        }
        throw unavailable()
    }
    private func cachedExecutablePath(for pid: pid_t) throws -> String? {
        func identity() throws -> proc_bsdinfo? {
            var info=proc_bsdinfo()
            let size=Int32(MemoryLayout<proc_bsdinfo>.stride)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) != size {
                if kill(pid, 0) != 0 && errno == ESRCH { return nil }
                throw unavailable()
            }
            guard info.pbi_pid == UInt32(pid), info.pbi_uid == currentUser else { throw unavailable() }
            return info.pbi_status == UInt32(SZOMB) ? nil : info
        }
        guard let before=try identity() else { return nil }
        var query=[Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        var count=0
        let sized=query.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), nil, &count, nil, 0) }
        guard sized == 0, count > MemoryLayout<Int32>.size, count <= 2_097_152 else {
            if try identity() == nil { return nil }
            throw unavailable()
        }
        var buffer=[UInt8](repeating: 0, count: count)
        // KERN_PROCARGS2 also returns arguments and environment. Retain only its
        // executable prefix and erase the temporary bytes without logging them.
        defer { buffer.withUnsafeMutableBytes { bytes in _ = bytes.initializeMemory(as: UInt8.self, repeating: 0) } }
        let result=query.withUnsafeMutableBufferPointer { query in
            buffer.withUnsafeMutableBytes { sysctl(query.baseAddress, UInt32(query.count), $0.baseAddress, &count, nil, 0) }
        }
        guard let after=try identity() else { return nil }
        guard result == 0, before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec,
              count > MemoryLayout<Int32>.size, count <= buffer.count else { throw unavailable() }
        let path: String?=buffer.withUnsafeBytes { bytes in
            let prefix=bytes[MemoryLayout<Int32>.size..<count].prefix(while: { $0 != 0 })
            guard !prefix.isEmpty, prefix.count < 4 * Int(MAXPATHLEN) else { return nil }
            return String(bytes: prefix, encoding: .utf8)
        }
        guard let path, path.hasPrefix("/") else { throw unavailable() }
        let resolved=URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix("/var/") ? "/private" + resolved : resolved
    }
    #endif
    public func containerIdentifier(at path: String) throws -> String {
        #if os(macOS)
        if let readWorkerExecutable { return try NativeReadClient(executable: readWorkerExecutable).containerIdentifier(path) }
        #endif
        return try containerIdentifierDirect(at: path)
    }
    func containerIdentifierDirect(at path: String) throws -> String {
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
        if let readWorkerExecutable {
            return try NativeReadClient(executable: readWorkerExecutable).groupContainerPaths(home: homeDirectory, bundleIdentifier: bundleIdentifier)
        }
        #endif
        return try groupContainerPathsDirect(for: bundleIdentifier)
    }
    func groupContainerPathsDirect(for bundleIdentifier: String) throws -> [String] {
        #if os(macOS)
        guard ApplicationDefinition.isValidBundleIdentifier(bundleIdentifier) else {
            throw ShouError("ownership_unverified", "Group container ownership could not be verified.")
        }
        let root=homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true).path
        let descriptor: Int32
        do { descriptor=try SecurePaths.directory(root) }
        catch let error as ShouError where error.code == "io_error" || error.code == "permission_denied" { throw error }
        catch { return [] }
        defer { close(descriptor) }
        let listing=try NativeDefinitionFiles.names(descriptor, limit: 2_048, deadline: ContinuousClock.now.advanced(by: .seconds(3)))
        guard !listing.truncated else { throw ShouError("resource_limit", "Group container discovery exceeded its read limit.") }
        let deadline=ContinuousClock.now.advanced(by: .seconds(3))
        var matches: [String]=[]
        for name in listing.names {
            if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
            guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Group container discovery exceeded its read limit.") }
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
