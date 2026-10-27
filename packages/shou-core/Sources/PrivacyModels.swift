import Foundation

public enum PrivacyTimeRange: String, Codable, Sendable, CaseIterable {
    case lastHour = "last-hour", lastDay = "last-day", lastSevenDays = "last-seven-days", allTime = "all-time"
    public func start(at date: Date) -> Date? {
        switch self {
        case .lastHour: date.addingTimeInterval(-3600)
        case .lastDay: date.addingTimeInterval(-86400)
        case .lastSevenDays: date.addingTimeInterval(-604800)
        case .allTime: nil
        }
    }
}
public enum PrivacyBrowser: String, Codable, Sendable { case chromium, firefox, safari }
public enum PrivacyDataKind: String, Codable, Sendable { case history, cookies, siteStorage = "site-storage", passwords, autofill }
public enum PrivacySourceStatus: String, Codable, Sendable {
    case ready, empty, browserRunning = "browser-running", permissionRequired = "permission-required"
    case unsupported, schemaUnsupported = "schema-unsupported", unavailable
}

/// A source identifies a database, never an individual browsing record.
public struct PrivacySourceDefinition: Codable, Sendable, Equatable {
    public let browser: PrivacyBrowser
    public let browserName: String
    public let bundleIdentifier: String
    public let profile: String
    public let kind: PrivacyDataKind
    public let relativePath: String
    public let unsupported: Bool
    public let platform: String?
    public init(browser: PrivacyBrowser, browserName: String, bundleIdentifier: String, profile: String, kind: PrivacyDataKind, relativePath: String, unsupported: Bool = false, platform: String? = nil) {
        self.browser=browser; self.browserName=browserName; self.bundleIdentifier=bundleIdentifier; self.profile=profile; self.kind=kind; self.relativePath=relativePath; self.unsupported=unsupported; self.platform=platform
    }
}

/// Platform code discovers only known browser profiles and captures no-follow identities.
public protocol PrivacySourceDiscovering: Sendable {
    func discover(home: URL) throws -> [PrivacySourceDefinition]
    func discoverWithCoverage(home: URL) throws -> PrivacySourceDiscovery
    func evidence(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> [FileEntry]
    func acquire(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> any PrivacySourceAccess
}

/// Discovery failures describe incomplete coverage, never empty or authorized sources.
public struct PrivacySourceDiscovery: Sendable {
    public let sources: [PrivacySourceDefinition]
    public let issues: [String]
    public init(sources: [PrivacySourceDefinition], issues: [String] = []) {
        self.sources=sources; self.issues=issues
    }
}

/// Platforms can keep verified database paths pinned for the complete SQLite operation.
public protocol PrivacySourceAccess: AnyObject, Sendable { func release() }
private final class UnpinnedPrivacySourceAccess: PrivacySourceAccess { func release() {} }
extension PrivacySourceDiscovering {
    public func discoverWithCoverage(home: URL) throws -> PrivacySourceDiscovery {
        PrivacySourceDiscovery(sources: try discover(home: home))
    }
    public func acquire(source: PrivacySourceDefinition, home: URL, writable: Bool) throws -> any PrivacySourceAccess { UnpinnedPrivacySourceAccess() }
}

public struct PrivacySource: Codable, Sendable, Identifiable {
    public let id: String
    public let definition: PrivacySourceDefinition
    public var status: PrivacySourceStatus
    public var recordCount: Int64?
    public var reason: String?
    public var evidence: [FileEntry]
    public var requiresSignOutConsent: Bool { definition.kind == .cookies }
    public var eligible: Bool { status == .ready && (recordCount ?? 0) > 0 }
}
public struct PrivacyScan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let range: PrivacyTimeRange
    public let rangeStart: Date?
    public let rangeEnd: Date
    public let configurationDigest: String
    public let homeIdentity: FileEntry
    public let sources: [PrivacySource]
    public let issues: [String]
}
public struct PrivacyPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let scanId: String
    public let createdAt: Date
    public let expiresAt: Date
    public let range: PrivacyTimeRange
    public let rangeStart: Date?
    public let rangeEnd: Date
    public let configurationDigest: String
    public let homeIdentity: FileEntry
    public let sources: [PrivacySource]
    public let signOutAcknowledged: Bool
    public var state: String = "ready"
    public var digest: String = ""
    public var recordCount: Int64 { sources.reduce(0) { $0 + ($1.recordCount ?? 0) } }
    public var requiresSignOutConsent: Bool { sources.contains(where: \.requiresSignOutConsent) }
    public func calculatedDigest() throws -> String {
        var copy=self; copy.state="ready"; copy.digest=""; return try Digest.of(copy)
    }
}
public struct PrivacyConsent: Sendable {
    public let irreversibleDeletion: Bool
    public let signOut: Bool
    public init(irreversibleDeletion: Bool, signOut: Bool = false) { self.irreversibleDeletion=irreversibleDeletion; self.signOut=signOut }
}
public struct PrivacyItemResult: Codable, Sendable, Identifiable {
    public var id: String { sourceId }
    public let sourceId: String
    public var state: String
    public var removedRecords: Int64
    public var reason: String?
}
/// Durable receipts deliberately omit profile paths, URLs, domains and cookie values.
public struct PrivacyReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let planId: String
    public let createdAt: Date
    public let range: PrivacyTimeRange
    public let rangeStart: Date?
    public let rangeEnd: Date
    public var state: String
    public var items: [PrivacyItemResult]
}

extension ShouEngine {
    public func privacyService(activity: any ApplicationActivityChecking, sources: any PrivacySourceDiscovering) -> PrivacyService {
        PrivacyService(store: store, filesystem: filesystem, activity: activity, sources: sources, home: homeDirectory, now: now)
    }
}
