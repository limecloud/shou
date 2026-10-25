import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Explicitly requested, metadata-only observation; never opens the business
/// store, creates directories, reads credentials or starts subprocesses.
public enum NativeDiagnostics {
    public static func collect(applicationVersion: String, directory: URL = LocalRecordStore.defaultDirectory) throws -> DiagnosticReport {
        try Task.checkCancellation()
        let process=ProcessInfo.processInfo, version=process.operatingSystemVersion
        let attributes=try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)
        #if os(macOS)
        let platform="macos"
        #else
        let platform="linux"
        #endif
        #if arch(arm64)
        let architecture="arm64"
        #elseif arch(x86_64)
        let architecture="x86_64"
        #else
        let architecture="unknown"
        #endif
        let access: DiagnosticDiskAccess = switch NativeDiskAccess.check() {
        case .available: .available
        case .limited: .limited
        case .unknown: .unknown
        case .notRequired: .notRequired
        }
        let records=recordState(directory)
        try Task.checkCancellation()
        return DiagnosticReport(applicationVersion: applicationVersion, platform: platform, architecture: architecture,
            systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", processorCount: process.processorCount,
            physicalMemoryBytes: process.physicalMemory, capacityBytes: (attributes?[.systemSize] as? NSNumber)?.int64Value,
            freeBytes: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value, diskAccess: access, records: records)
    }

    private static func recordState(_ directory: URL) -> DiagnosticRecordState {
        #if canImport(Darwin) || canImport(Glibc)
        var before=stat()
        guard lstat(directory.path, &before) == 0 else { return errno == ENOENT ? .missing : .unavailable }
        guard before.st_mode & S_IFMT == S_IFDIR, before.st_uid == getuid(), before.st_mode & 0o077 == 0 else { return .unsafe }
        guard let descriptor=try? SecurePaths.directory(directory.path) else { return .unavailable }
        defer { close(descriptor) }
        var current=stat()
        guard fstat(descriptor, &current) == 0 else { return .unavailable }
        guard current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              current.st_mode & S_IFMT == S_IFDIR, current.st_uid == getuid(), current.st_mode & 0o077 == 0 else { return .unsafe }
        return .privateDirectory
        #else
        return .unavailable
        #endif
    }
}
