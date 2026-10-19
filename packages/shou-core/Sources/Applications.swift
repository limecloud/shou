import Foundation

public struct ApplicationCatalogOptions: Sendable {
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
