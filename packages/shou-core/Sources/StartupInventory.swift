import Foundation

public struct StartupInventoryOptions: Sendable {
    public var includeSystem: Bool
    public var maxEntries: Int
    public var maxSeconds: Double
    public init(includeSystem: Bool = false, maxEntries: Int = 2_000, maxSeconds: Double = 5) {
        self.includeSystem=includeSystem; self.maxEntries=maxEntries; self.maxSeconds=maxSeconds
    }
    public func validate() throws {
        guard (1...10_000).contains(maxEntries), maxSeconds.isFinite, maxSeconds > 0, maxSeconds <= 30 else {
            throw ShouError("invalid_argument", "Startup inventory budgets are outside the supported limits.")
        }
    }
}

public struct StartupLocation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let kind: String
    public let scope: String
    public let systemOwned: Bool
    public init(id: String, path: String, kind: String, scope: String, systemOwned: Bool = false) {
        self.id=id; self.path=path; self.kind=kind; self.scope=scope; self.systemOwned=systemOwned
    }
}

public struct StartupDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceId: String
    public let path: String
    public let label: String
    public let programPath: String?
    public let disabledByDefinition: Bool
    public let triggers: [String]
    // A definition does not establish launchd overrides, registration or process state.
    public let configuredState: String
    public let runtimeState: String
    public let controlCapability: String
    public init(sourceId: String, path: String, label: String, programPath: String?, disabledByDefinition: Bool, triggers: [String]) {
        self.id=Digest.sha256(Data((sourceId + "\0" + path).utf8))
        self.sourceId=sourceId; self.path=path; self.label=label; self.programPath=programPath
        self.disabledByDefinition=disabledByDefinition; self.triggers=triggers
        self.configuredState="unknown"; self.runtimeState="unknown"; self.controlCapability="system_settings"
    }
}

public struct StartupInventoryIssue: Codable, Sendable, Equatable {
    public let sourceId: String
    public let path: String
    public let code: String
    public init(sourceId: String, path: String, code: String) { self.sourceId=sourceId; self.path=path; self.code=code }
}

public struct StartupSourceCoverage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { location.id }
    public let location: StartupLocation
    public let status: String
    public let entryCount: Int
    public let definitionCount: Int
    public init(location: StartupLocation, status: String, entryCount: Int, definitionCount: Int) {
        self.location=location; self.status=status; self.entryCount=entryCount; self.definitionCount=definitionCount
    }
}

public struct StartupInventory: Codable, Sendable, Equatable {
    public let checkedAt: Date
    public let scope: String
    public let status: String
    public let includeSystem: Bool
    public let sources: [StartupSourceCoverage]
    public let items: [StartupDefinition]
    public let issues: [StartupInventoryIssue]
    public let unavailableSources: [String]
    public init(checkedAt: Date, includeSystem: Bool, sources: [StartupSourceCoverage], items: [StartupDefinition], issues: [StartupInventoryIssue]) {
        self.checkedAt=checkedAt; self.includeSystem=includeSystem; self.sources=sources; self.items=items; self.issues=issues
        self.scope="launchd_definitions"; self.unavailableSources=["login_items", "background_task_registrations", "embedded_helpers"]
        self.status=sources.allSatisfy { ["complete", "missing"].contains($0.status) } && issues.isEmpty ? "complete" : "partial"
    }
}

public protocol StartupInventoryReading: Sendable {
    func read(options: StartupInventoryOptions) throws -> StartupInventory
}

/// Read-only discovery is independent of cleanup storage and execution authority.
public actor StartupInventoryService {
    private let source: any StartupInventoryReading
    public init(source: any StartupInventoryReading) { self.source=source }
    public func scan(options: StartupInventoryOptions = StartupInventoryOptions()) throws -> StartupInventory {
        try options.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
        return try source.read(options: options)
    }
}
