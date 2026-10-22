import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Discovery enumerates profile names only; it never opens history or cookie rows.
#if canImport(Darwin) || canImport(Glibc)
public struct NativePrivacySources: PrivacySourceDiscovering {
    public init() {}
    public func discover(home: URL) throws -> [PrivacySourceDefinition] {
        var result=[PrivacySourceDefinition]()
        for (name, bundle, root) in PrivacySourcePolicy.chromiumRoots {
            let profiles=try profileNames(home.appendingPathComponent(root).path).filter { $0 == "Default" || $0.range(of: "^Profile [0-9]+$", options: .regularExpression) != nil }
            for profile in profiles {
                let prefix=root + "/" + profile + "/"
                result.append(PrivacySourceDefinition(browser: .chromium, browserName: name, bundleIdentifier: bundle, profile: profile, kind: .history, relativePath: prefix + "History"))
                // Both historical and current locations are separate exact sources.
                for suffix in ["Cookies", "Network/Cookies"] where exists(home.appendingPathComponent(prefix + suffix).path) {
                    result.append(PrivacySourceDefinition(browser: .chromium, browserName: name, bundleIdentifier: bundle, profile: profile, kind: .cookies, relativePath: prefix + suffix))
                }
            }
        }
        let firefox="Library/Application Support/Firefox/Profiles"
        for profile in try profileNames(home.appendingPathComponent(firefox).path) {
            for (kind, suffix) in [(PrivacyDataKind.history, "places.sqlite"), (.cookies, "cookies.sqlite")] {
                result.append(PrivacySourceDefinition(browser: .firefox, browserName: "Firefox", bundleIdentifier: "org.mozilla.firefox", profile: profile, kind: kind, relativePath: firefox + "/" + profile + "/" + suffix))
            }
        }
        #if os(macOS)
        let includeSafari=true
        #else
        let includeSafari=exists(home.appendingPathComponent("Library/Safari").path)
        #endif
        if includeSafari {
            result.append(PrivacySourceDefinition(browser: .safari, browserName: "Safari", bundleIdentifier: "com.apple.Safari", profile: "Default", kind: .history, relativePath: "Library/Safari/History.db"))
            for kind in [PrivacyDataKind.cookies, .siteStorage, .passwords, .autofill] {
                result.append(PrivacySourceDefinition(browser: .safari, browserName: "Safari", bundleIdentifier: "com.apple.Safari", profile: "Default", kind: kind, relativePath: "", unsupported: true))
            }
        }
        return result
    }
    public func evidence(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> [FileEntry] {
        guard (source.platform ?? "macos") == "macos", PrivacySourcePolicy.valid(source) else { throw ShouError("permission_denied", "Privacy source is outside known browser locations.") }
        let path=home.appendingPathComponent(source.relativePath).path
        let (parent, name)=try SecurePaths.parent(path)
        defer { close(parent) }
        var directory=stat()
        guard fstat(parent, &directory) == 0, directory.st_uid == getuid() else { throw safeFailure() }
        if writable, faccessat(parent, ".", W_OK | X_OK, 0) != 0 { throw safeFailure() }
        var entries=[SecurePaths.entry(directory, path: "parent")]
        // Retain every directory identity from the home root to the database parent.
        var prefix=home.path
        for component in source.relativePath.split(separator: "/").dropLast() {
            prefix += "/" + component
            let descriptor=try SecurePaths.directory(prefix, readFinalDirectory: false)
            defer { close(descriptor) }
            var metadata=stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o022 == 0 else { throw safeFailure() }
            entries.append(SecurePaths.entry(metadata, path: String(prefix.dropFirst(home.path.count + 1))))
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var metadata=stat()
            let relative=name + suffix
            if fstatat(parent, relative, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
                if !suffix.isEmpty && errno == ENOENT { continue }
                throw safeFailure()
            }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1,
                  metadata.st_mode & 0o022 == 0 else { throw safeFailure() }
            let descriptor=openat(parent, relative, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw safeFailure() }
            var opened=stat(); let status=fstat(descriptor, &opened); close(descriptor)
            guard status == 0, opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else { throw safeFailure() }
            // SHM and rollback journals are checked for safety, not retained as data evidence.
            if suffix.isEmpty || (suffix == "-wal" && metadata.st_size > 32) { entries.append(SecurePaths.entry(metadata, path: "database" + suffix)) }
        }
        return entries
    }
    private func profileNames(_ path: String) throws -> [String] {
        if !exists(path) { return [] }
        let descriptor=try SecurePaths.directory(path)
        defer { close(descriptor) }
        let names=try SecurePaths.names(descriptor)
        guard names.count <= 256 else { throw ShouError("privacy_source_limit", "Too many browser profiles; no privacy scan was saved.") }
        return names.filter { name in
            var metadata=stat()
            return fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 && metadata.st_mode & S_IFMT == S_IFDIR && metadata.st_uid == getuid()
        }
    }
    private func exists(_ path: String) -> Bool {
        var metadata=stat()
        // A denied path must remain observable as a failure, not become an empty profile.
        if lstat(path, &metadata) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }
    private func safeFailure() -> ShouError {
        ShouError(errno == EACCES || errno == EPERM ? "permission_denied" : "privacy_identity_unavailable", "The privacy database identity or access could not be verified.")
    }
}
#elseif !os(Windows)
public struct NativePrivacySources: PrivacySourceDiscovering {
    public init() {}
    public func discover(home: URL) throws -> [PrivacySourceDefinition] {
        throw ShouError("capability_unavailable", "Browser privacy sources are unavailable on this platform.")
    }
    public func evidence(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> [FileEntry] {
        throw ShouError("capability_unavailable", "Browser privacy sources are unavailable on this platform.")
    }
}
#endif
