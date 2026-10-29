import Foundation

public struct ApplicationCatalogOptions: Sendable {
    public static let maxContainerDepth=8
    public var includeSystem: Bool
    public var maxEntries: Int
    public var maxSeconds: Double
    public init(includeSystem: Bool = false, maxEntries: Int = 4_000, maxSeconds: Double = 10) {
        self.includeSystem=includeSystem; self.maxEntries=maxEntries; self.maxSeconds=maxSeconds
    }
    public func validate() throws {
        guard (1...20_000).contains(maxEntries), maxSeconds.isFinite, (1...30).contains(maxSeconds) else {
            throw ShouError("invalid_argument", "Application discovery budgets are outside the supported limits.")
        }
    }
}

public struct ApplicationSource: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let systemOwned: Bool
    public init(id: String, path: String, systemOwned: Bool = false) {
        self.id=id; self.path=path; self.systemOwned=systemOwned
    }
}

public struct ApplicationDefinition: Codable, Sendable, Equatable, Identifiable {
    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*$", options: .regularExpression) != nil
    }
    public var isSystemApplication: Bool {
        source.systemOwned || path.hasPrefix("/System/") ||
            (identity.kind == "symlink" && bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true)
    }
    public static let metadataIssues: Set<String> = ["invalid_bundle_identifier", "application_metadata_missing", "unsupported_bundle",
        "invalid_application_metadata", "linked_definition", "unsupported_definition", "definition_too_large"]
    public let id: String
    public let path: String
    public let source: ApplicationSource
    public let identity: FileEntry
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let executableName: String?
    public let infoDigest: String?
    public init(path: String, source: ApplicationSource, identity: FileEntry, name: String,
                bundleIdentifier: String?, version: String?, executableName: String?, infoDigest: String?) {
        self.id=Digest.sha256(Data((path + "\0" + String(identity.device) + ":" + String(identity.inode)).utf8))
        self.path=path; self.source=source; self.identity=identity; self.name=name
        self.bundleIdentifier=bundleIdentifier; self.version=version; self.executableName=executableName; self.infoDigest=infoDigest
    }
}

public struct ApplicationCatalogIssue: Codable, Sendable, Equatable {
    public let path: String
    public let code: String
    public init(path: String, code: String) { self.path=path; self.code=code }
}

public struct ApplicationSourceCoverage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { source.id }
    public let source: ApplicationSource
    public let status: String
    public let entryCount: Int
    public let applicationCount: Int
    public init(source: ApplicationSource, status: String, entryCount: Int, applicationCount: Int) {
        self.source=source; self.status=status; self.entryCount=entryCount; self.applicationCount=applicationCount
    }
}

public struct ApplicationCatalog: Codable, Sendable, Equatable {
    public let checkedAt: Date
    public let scope: String
    public let status: String
    public let sources: [ApplicationSourceCoverage]
    public let items: [ApplicationDefinition]
    public let issues: [ApplicationCatalogIssue]
    public let unavailableSources: [String]
    public init(checkedAt: Date, sources: [ApplicationSourceCoverage], items: [ApplicationDefinition], issues: [ApplicationCatalogIssue]) {
        self.checkedAt=checkedAt; self.scope="application_directories"; self.sources=sources; self.items=items; self.issues=issues
        self.status=issues.isEmpty && sources.allSatisfy { ["complete", "missing"].contains($0.status) } ? "complete" : "partial"
        self.unavailableSources=["other_accounts", "custom_install_locations", "package_receipts", "embedded_helpers"]
    }
}

public protocol ApplicationCatalogReading: Sendable {
    func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog
    func application(at path: String) throws -> ApplicationDefinition
    func measureSummary(for application: ApplicationDefinition, budget: ScanBudget, progress: @Sendable (ScanProgress) -> Void) throws -> ApplicationSummaryMeasurement
}
public extension ApplicationCatalogReading {
    func measureSummary(for application: ApplicationDefinition, budget: ScanBudget, progress: @Sendable (ScanProgress) -> Void) throws -> ApplicationSummaryMeasurement {
        throw ShouError("capability_unavailable", "Application size measurement is unavailable.")
    }
}

public struct ApplicationSummaryMeasurement: Sendable {
    public let allocatedBytesEstimate: Int64
    public let owner: UInt32
    public let containsForeignOwnedContent: Bool
    public let lastUsed: Date?
    public let issues: [String]
    public var requiresAdministrator: Bool = false
    public init(allocatedBytesEstimate: Int64, owner: UInt32, containsForeignOwnedContent: Bool = false, lastUsed: Date? = nil, issues: [String] = []) {
        self.allocatedBytesEstimate=allocatedBytesEstimate; self.owner=owner; self.containsForeignOwnedContent=containsForeignOwnedContent
        self.lastUsed=lastUsed; self.issues=issues
    }
}

public struct ApplicationSummary: Codable, Sendable, Identifiable {
    public var id: String { application.id }
    public let application: ApplicationDefinition
    public let allocatedBytesEstimate: Int64?
    public let status: String
    public let lastUsed: Date?
    public let issues: [String]
    public var sizeIsLowerBound: Bool {
        issues.contains { !ApplicationDefinition.metadataIssues.contains($0) && !["application_activity_unavailable", "linked_application", "application_link_target_missing", "multiply_linked_content"].contains($0) }
    }
}
public struct ApplicationSummaryProgress: Sendable {
    public let processedCount: Int
    public let applicationCount: Int
    public let currentPath: String
}
public struct ApplicationSummaryCatalog: Codable, Sendable {
    public let catalog: ApplicationCatalog
    public let items: [ApplicationSummary]
    public var status: String { catalog.status == "complete" && items.allSatisfy { $0.issues.isEmpty } ? "complete" : "partial" }
}

extension ShouEngine {
    /// One inventory and activity snapshot; only requested reviews persist manifests.
    public func applicationSummaries(options: ApplicationCatalogOptions = ApplicationCatalogOptions(), budget: ScanBudget = ScanBudget(),
                                     progress: @Sendable (ApplicationSummaryProgress) -> Void = { _ in },
                                     onSummary: @Sendable (ApplicationSummary) -> Void = { _ in }) throws -> ApplicationSummaryCatalog {
        try options.validate(); try budget.validate()
        let catalog=try applications(options: options)
        let facts: [String: ApplicationUninstallFacts]
        var activityIssue: String?
        do { facts=try uninstallEvidence.facts(for: catalog.items) }
        catch let error as ShouError { if error.code == "cancelled" { throw error }; facts=[:]; activityIssue=error.code }
        var summaries=[ApplicationSummary]()
        for app in catalog.items {
            if Task.isCancelled { throw ShouError("cancelled", "Application summary stopped.") }
            let processedCount=summaries.count
            progress(ApplicationSummaryProgress(processedCount: processedCount, applicationCount: catalog.items.count, currentPath: app.path))
            let activity=facts[app.id]
            var issues=catalog.issues.filter { $0.path == app.path }.map(\.code)
            if let activityIssue { issues.append(activityIssue) }
            let summary=try makeApplicationSummary(app, activity: activity, issues: issues, budget: budget, progress: { _ in
                progress(ApplicationSummaryProgress(processedCount: processedCount, applicationCount: catalog.items.count, currentPath: app.path))
            })
            summaries.append(summary); onSummary(summary)
            progress(ApplicationSummaryProgress(processedCount: summaries.count, applicationCount: catalog.items.count, currentPath: app.path))
        }
        if Task.isCancelled { throw ShouError("cancelled", "Application summary stopped.") }
        return ApplicationSummaryCatalog(catalog: catalog, items: summaries)
    }
    public func applicationSummary(at path: String, budget: ScanBudget = ScanBudget()) throws -> ApplicationSummary {
        try budget.validate()
        let app=try applicationCatalog.application(at: path)
        let activity=try uninstallEvidence.facts(for: app)
        return try makeApplicationSummary(app, activity: activity, issues: [], budget: budget, progress: { _ in })
    }
    private func makeApplicationSummary(_ app: ApplicationDefinition, activity: ApplicationUninstallFacts?, issues initialIssues: [String], budget: ScanBudget,
                                        progress: @Sendable (ScanProgress) -> Void) throws -> ApplicationSummary {
        var issues=initialIssues
        if app.bundleIdentifier == nil || app.infoDigest == nil { issues.append("application_metadata_missing") }
        if !app.isSystemApplication, app.identity.kind == "symlink", issues.contains("application_link_target_missing"),
           let shortcut=try? filesystem.applicationShortcut(app.path), shortcut.identity.metadata == app.identity {
            return ApplicationSummary(application: app, allocatedBytesEstimate: max(0, shortcut.identity.allocatedBytes),
                status: shortcut.requiresAdministrator ? "admin-required" : "shortcut", lastUsed: nil,
                issues: Array(Set(issues.filter { $0 != "application_activity_unavailable" })).sorted())
        }
        var measurement: ApplicationSummaryMeasurement?
        do {
            measurement=try applicationCatalog.measureSummary(for: app, budget: budget, progress: progress)
        } catch let error as ShouError { if error.code == "cancelled" { throw error }; issues.append(error.code) }
        if let measurement { issues.append(contentsOf: measurement.issues) }
        let status: String
        let blockingIssues=issues.filter { !ApplicationDefinition.metadataIssues.contains($0) && $0 != "multiply_linked_content" }
        if app.isSystemApplication || activity?.currentApplication == true { status="protected" }
        else if activity?.running == true { status="running" }
        else if activity == nil || measurement == nil || !blockingIssues.isEmpty || app.identity.kind != "directory" { status="unavailable" }
        else if let activity, (measurement?.owner ?? app.identity.owner) != activity.currentUser || measurement?.containsForeignOwnedContent == true || measurement?.requiresAdministrator == true { status="admin-required" }
        else if issues.contains("multiply_linked_content") { status="trash-required" }
        else { status="ready" }
        return ApplicationSummary(application: app, allocatedBytesEstimate: measurement?.allocatedBytesEstimate, status: status,
            lastUsed: measurement?.lastUsed, issues: Array(Set(issues)).sorted())
    }

}

public struct UnavailableApplicationCatalog: ApplicationCatalogReading {
    public init() {}
    public func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog { throw ShouError("capability_unavailable", "Application discovery is unavailable.") }
    public func application(at path: String) throws -> ApplicationDefinition { throw ShouError("capability_unavailable", "Application discovery is unavailable.") }
}

public actor ApplicationCatalogService {
    private let source: any ApplicationCatalogReading
    public init(source: any ApplicationCatalogReading) { self.source=source }
    public func scan(options: ApplicationCatalogOptions = ApplicationCatalogOptions()) throws -> ApplicationCatalog {
        try options.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
        return try source.read(options: options)
    }
}
