import Foundation

/// Installation registrations are facts about the platform installer, not
/// ownership evidence or permission to delete an installation directory.
public struct RegisteredApplication: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceId: String
    public let registration: String
    public let name: String
    public let version: String?
    public let publisher: String?
    public let installLocation: String?
    public let estimatedBytes: Int64?
    public let kind: String
    public let systemComponent: Bool
    public let uninstallAvailable: Bool?
    public let packageFamilyName: String?
    public let evidenceDigest: String
}

public struct RegisteredApplicationCatalog: Codable, Sendable {
    public let checkedAt: Date
    public let scope: String
    public let status: String
    public let sources: [ApplicationSourceCoverage]
    public let items: [RegisteredApplication]
    public let issues: [ApplicationCatalogIssue]
    public let unavailableSources: [String]
    public init(checkedAt: Date, sources: [ApplicationSourceCoverage], items: [RegisteredApplication], issues: [ApplicationCatalogIssue]) {
        self.checkedAt=checkedAt; self.scope="windows_registered_applications"
        self.status=issues.isEmpty && sources.allSatisfy { ["complete", "missing"].contains($0.status) } ? "complete" : "partial"
        self.sources=sources; self.items=items; self.issues=issues
        self.unavailableSources=["other_accounts", "unregistered_portable_applications", "custom_unregistered_installations", "application_data_ownership", "measured_disk_usage", "last_used_time"]
    }
}
