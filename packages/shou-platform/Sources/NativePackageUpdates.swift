import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativePackageUpdates: PackageUpdateRunning {
    private let homeDirectory: URL
    private let executableDirectory: URL?
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.homeDirectory=homeDirectory; self.executableDirectory=nil }
    /// Explicit generated-tool substitution for native acceptance. The directory
    /// must be inside the supplied home and never falls back to real managers.
    public init(homeDirectory: URL, executableDirectory: URL) { self.homeDirectory=homeDirectory; self.executableDirectory=executableDirectory }
    public var miseGlobalConfigurationPaths: Set<String> {
        Set([".config/mise/config.toml", ".mise.toml", ".tool-versions"].map { homeDirectory.appendingPathComponent($0).path })
    }
    public func run(_ command: PackageUpdateCommand, timeoutSeconds: Double, expectedExecutableIdentity: String?) throws -> PackageUpdateOutput {
        #if os(macOS)
        guard command.valid, timeoutSeconds.isFinite, (1...300).contains(timeoutSeconds) else { throw ShouError("invalid_argument", "Invalid package manager operation.") }
        guard !command.mutating || expectedExecutableIdentity != nil else { throw ShouError("confirmation_required", "Package upgrades require a reviewed executable identity.") }
        let executable=try locate(command.provider), before=try identity(executable)
        guard expectedExecutableIdentity == nil || expectedExecutableIdentity == executable + ":" + before else { throw ShouError("tool_changed", "The package manager changed after review.") }
        let process=NativeManagedToolProcess(homeDirectory: homeDirectory, additionalEnvironment: [
            "NO_COLOR":"1", "TERM":"dumb", "MISE_COLOR":"0", "MISE_AUTO_INSTALL":"0", "MISE_NOT_FOUND_AUTO_INSTALL":"0", "MISE_YES":"0"
        ])
        let data=try process.run(executable, arguments: command.arguments, timeout: timeoutSeconds)
        guard try identity(executable) == before else { throw ShouError("tool_changed", "The package manager changed while running.") }
        return .init(data: data, executableIdentity: executable + ":" + before)
        #else
        throw ShouError("capability_unavailable", "This package manager source is available on macOS.")
        #endif
    }
    #if os(macOS)
    private func locate(_ provider: PackageUpdateProvider) throws -> String {
        let name=provider == .homebrew ? "brew" : "mise"
        var paths=["/opt/homebrew/bin/"+name, "/usr/local/bin/"+name]
        // A home-scoped fixture or a standard user-local installation is supported;
        // arbitrary PATH entries never become executable authority.
        if provider == .mise { paths.insert(homeDirectory.appendingPathComponent(".local/bin/mise").path, at: 0) }
        if let executableDirectory {
            let home=homeDirectory.resolvingSymlinksInPath().path
            let directory=executableDirectory.resolvingSymlinksInPath().path
            guard directory.hasPrefix(home + "/") else { throw ShouError("invalid_argument", "Generated managers must remain inside the isolated home.") }
            paths=[URL(fileURLWithPath: directory).appendingPathComponent(name).path]
        }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let resolved=URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if executableDirectory != nil {
                guard resolved.hasPrefix(homeDirectory.resolvingSymlinksInPath().path + "/") else { throw ShouError("invalid_argument", "Generated managers cannot resolve outside the isolated home.") }
            }
            _ = try identity(resolved)
            return resolved
        }
        throw ShouError("tool_not_installed", "The package manager is not installed in a supported location.")
    }
    private func identity(_ path: String) throws -> String {
        var metadata=stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              [0,getuid()].contains(metadata.st_uid), metadata.st_mode & 0o022 == 0 else { throw ShouError("permission_denied", "The package manager has an unsupported owner or writable permissions.") }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
    }
    #endif
}

public extension PackageUpdateService {
    static func native() -> PackageUpdateService { .init(runner: NativePackageUpdates()) }
}
