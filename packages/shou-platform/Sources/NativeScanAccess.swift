import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#endif

public enum DiskAccessStatus: String, Sendable {
    case available, limited, unknown, notRequired
}

/// Operational evidence, not a query of macOS's private TCC database.
public enum NativeDiskAccess {
    public static func check() -> DiskAccessStatus {
        #if os(macOS)
        // SystemPolicyAllFiles has no interactive allow dialog. Only open the
        // system sentinel; never read its contents or probe another app's container.
        let descriptor=open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 { close(descriptor); return .available }
        return errno == EPERM || errno == EACCES ? .limited : .unknown
        #else
        return .notRequired
        #endif
    }
}

/// Avoid interactive App Data requests while broad scans run without FDA.
/// This policy never grants access, and does not classify data as disposable.
public struct ScanPrivacyPolicy: Sendable {
    public let status: DiskAccessStatus
    public let home: String
    private let protectedRoots: [String]
    public init(status: DiskAccessStatus, home: String) {
        self.status=status; self.home=home
        let base=Self.normalizedPath(home)
        protectedRoots=["Library/Containers", "Library/Group Containers", "Library/Daemon Containers",
                        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Accounts",
                        "Library/Calendars", "Library/Reminders", "Library/Photos", "Library/PersonalizationPortrait",
                        "Library/IdentityServices", "Library/Trial", "Library/Biome", "Library/IntelligencePlatform",
                        "Library/Application Support/com.apple.TCC", ".Trash"].map { base + "/" + $0.lowercased() }
    }
    public static var current: Self {
        Self(status: NativeDiskAccess.check(), home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    public func requiresAuthorization(_ path: String) -> Bool {
        guard status != .available && status != .notRequired else { return false }
        let candidate=Self.normalizedPath(path)
        return protectedRoots.contains { boundary in
            // macOS home volumes are usually case insensitive; be conservative
            // for alternative spelling, without confusing prefix siblings.
            return candidate == boundary || candidate.hasPrefix(boundary + "/")
        }
    }
    private static func normalizedPath(_ path: String) -> String {
        // Match the lexical path accepted by traversal without touching the
        // filesystem or following links while checking privacy boundaries.
        var components=[Substring]()
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(part)
        }
        var value="/" + components.joined(separator: "/").lowercased()
        let dataPrefix="/system/volumes/data"
        if value.hasPrefix(dataPrefix + "/") { value=String(value.dropFirst(dataPrefix.count)) }
        return value
    }
    public func checkRoot(_ path: String) throws {
        if requiresAuthorization(path) {
            throw ShouError("permission_denied", "Full Disk Access is needed for this protected location. Open Shou Settings to finish setup.", details: ["path": path])
        }
    }
}
