#if os(Windows)
import Foundation
import ShouCore
import CShouWindows

private final class WindowsPrivacyAccess: PrivacySourceAccess, @unchecked Sendable {
    private let lock=NSLock()
    private var handle: OpaquePointer?
    init(_ handle: OpaquePointer) { self.handle=handle }
    func release() {
        lock.lock(); defer { lock.unlock() }
        if let handle { shou_win_privacy_release(handle); self.handle=nil }
    }
    deinit { release() }
}

/// Only standard per-user profiles are discovered; no browsing rows are enumerated.
public struct NativePrivacySources: PrivacySourceDiscovering {
    public init() {}
    public func discover(home: URL) throws -> [PrivacySourceDefinition] {
        var result=[PrivacySourceDefinition]()
        for (name, identifier, root) in PrivacySourcePolicy.windowsChromiumRoots {
            for profile in try profiles(home.appendingPathComponent(root).path) where profile == "Default" || profile.range(of: "^Profile [0-9]+$", options: .regularExpression) != nil {
                let prefix=root + "/" + profile + "/"
                result.append(.init(browser: .chromium, browserName: name, bundleIdentifier: identifier, profile: profile, kind: .history, relativePath: prefix + "History", platform: "windows"))
                for suffix in ["Cookies", "Network/Cookies"] where try exists(home.appendingPathComponent(prefix + suffix).path) {
                    result.append(.init(browser: .chromium, browserName: name, bundleIdentifier: identifier, profile: profile, kind: .cookies, relativePath: prefix + suffix, platform: "windows"))
                }
            }
        }
        let root="AppData/Roaming/Mozilla/Firefox/Profiles"
        for profile in try profiles(home.appendingPathComponent(root).path) {
            for (kind, suffix) in [(PrivacyDataKind.history, "places.sqlite"), (.cookies, "cookies.sqlite")] {
                result.append(.init(browser: .firefox, browserName: "Firefox", bundleIdentifier: "org.mozilla.firefox", profile: profile, kind: kind, relativePath: root + "/" + profile + "/" + suffix, platform: "windows"))
            }
        }
        return result
    }

    public func acquire(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> any PrivacySourceAccess {
        try Task.checkCancellation()
        guard source.platform == "windows", PrivacySourcePolicy.valid(source) else { throw ShouError("permission_denied", "Privacy source is outside known Windows browser locations.") }
        var handle: OpaquePointer?
        try WindowsNative.check(shou_win_privacy_acquire(home.path, home.appendingPathComponent(source.relativePath).path, writable ? 1 : 0, &handle), path: "browser database")
        guard let handle else { throw ShouError("privacy_identity_unavailable", "The browser database could not be pinned.") }
        return WindowsPrivacyAccess(handle)
    }

    public func evidence(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> [FileEntry] {
        let access=try acquire(source: source, home: home, writable: writable)
        defer { access.release() }
        let path=home.appendingPathComponent(source.relativePath).path
        var result=[WindowsNative.entry(try WindowsNative.metadata(URL(fileURLWithPath: path).deletingLastPathComponent().path), path: "parent")]
        var prefix=home.path
        for component in source.relativePath.split(separator: "/").dropLast() {
            try Task.checkCancellation()
            prefix += "/" + component
            result.append(WindowsNative.entry(try WindowsNative.metadata(prefix), path: String(prefix.dropFirst(home.path.count + 1))))
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let metadata: shou_win_info
            do { metadata=try WindowsNative.metadata(path + suffix) }
            catch let error as ShouError where !suffix.isEmpty && error.code == "not_found" { continue }
            guard metadata.kind == 1, metadata.links == 1, metadata.current_user == 1 else { throw ShouError("privacy_identity_unavailable", "The browser database identity could not be verified.") }
            if suffix.isEmpty || (suffix == "-wal" && metadata.logical_bytes > 32) { result.append(WindowsNative.entry(metadata, path: "database" + suffix)) }
        }
        return result
    }

    private func profiles(_ path: String) throws -> [String] {
        try Task.checkCancellation()
        guard try exists(path) else { return [] }
        let metadata=try WindowsNative.metadata(path)
        guard metadata.kind == 2 else { throw ShouError("privacy_identity_unavailable", "The browser profiles directory could not be verified.") }
        try WindowsNative.check(shou_win_privacy_directory(path), path: "browser profiles")
        let names=try WindowsNative.string({ shou_win_list(path, 256, $0) }, path: "browser profiles")
        var result=[String]()
        for name in names.split(separator: "\n").map(String.init).sorted() {
            try Task.checkCancellation()
            let item=try WindowsNative.metadata(path + "/" + name)
            if item.kind == 2 {
                try WindowsNative.check(shou_win_privacy_directory(path + "/" + name), path: "browser profile")
                result.append(name)
            }
        }
        guard WindowsNative.entry(try WindowsNative.metadata(path), path: ".") == WindowsNative.entry(metadata, path: ".") else { throw ShouError("plan_stale", "Browser profiles changed during discovery.") }
        return result
    }
    private func exists(_ path: String) throws -> Bool {
        do { _=try WindowsNative.metadata(path); return true }
        catch let error as ShouError where error.code == "not_found" { return false }
    }
}
#endif
