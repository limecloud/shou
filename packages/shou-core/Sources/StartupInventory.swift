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
    // Platform readers may provide bounded point-in-time observations. Unknown
    // remains valid when a source cannot be queried; these facts never grant
    // mutation authority.
    public let configuredState: String
    public let runtimeState: String
    public let controlCapability: String
    public let displayName: String?
    public let applicationPath: String?
    public let publisher: String?
    public let targetState: String
    public let removable: Bool
    public init(sourceId: String, path: String, label: String, programPath: String?, disabledByDefinition: Bool, triggers: [String], configuredState: String = "unknown", runtimeState: String = "unknown", controlCapability: String = "system_settings", displayName: String? = nil, applicationPath: String? = nil, publisher: String? = nil, targetState: String = "unknown", removable: Bool = false) {
        self.id=Digest.sha256(Data((sourceId + "\0" + path).utf8))
        self.sourceId=sourceId; self.path=path; self.label=label; self.programPath=programPath
        self.disabledByDefinition=disabledByDefinition; self.triggers=triggers
        self.configuredState=configuredState; self.runtimeState=runtimeState; self.controlCapability=controlCapability
        self.displayName=displayName; self.applicationPath=applicationPath; self.publisher=publisher
        self.targetState=targetState; self.removable=removable
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceId, path, label, programPath, disabledByDefinition, triggers, configuredState, runtimeState, controlCapability
        case displayName, applicationPath, publisher, targetState, removable
    }
    public init(from decoder: any Decoder) throws {
        let values=try decoder.container(keyedBy: CodingKeys.self)
        self.init(sourceId: try values.decode(String.self, forKey: .sourceId), path: try values.decode(String.self, forKey: .path),
            label: try values.decode(String.self, forKey: .label), programPath: try values.decodeIfPresent(String.self, forKey: .programPath),
            disabledByDefinition: try values.decode(Bool.self, forKey: .disabledByDefinition), triggers: try values.decode([String].self, forKey: .triggers),
            configuredState: try values.decodeIfPresent(String.self, forKey: .configuredState) ?? "unknown",
            runtimeState: try values.decodeIfPresent(String.self, forKey: .runtimeState) ?? "unknown",
            controlCapability: try values.decodeIfPresent(String.self, forKey: .controlCapability) ?? "system_settings",
            displayName: try values.decodeIfPresent(String.self, forKey: .displayName), applicationPath: try values.decodeIfPresent(String.self, forKey: .applicationPath),
            publisher: try values.decodeIfPresent(String.self, forKey: .publisher), targetState: try values.decodeIfPresent(String.self, forKey: .targetState) ?? "unknown",
            removable: try values.decodeIfPresent(Bool.self, forKey: .removable) ?? false)
    }
}

public enum StartupControlAction: String, Codable, Sendable {
    case enable
    case disable
    case remove
}

public struct StartupControlResult: Codable, Sendable, Equatable {
    public let definitionId: String
    public let label: String
    public let action: StartupControlAction
    public let configuredState: String
    public let runtimeState: String
    public let controlCapability: String
    public let message: String
    public init(definitionId: String, label: String, action: StartupControlAction, configuredState: String, runtimeState: String, controlCapability: String, message: String) {
        self.definitionId=definitionId; self.label=label; self.action=action; self.configuredState=configuredState; self.runtimeState=runtimeState; self.controlCapability=controlCapability; self.message=message
    }
}

/// A platform adapter must enforce its own source and identity boundaries before changing startup state.
public protocol StartupControlling: Sendable {
    func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult
}

public struct UnavailableStartupControl: StartupControlling {
    public init() {}
    public func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult {
        throw ShouError("capability_unavailable", "Direct startup control is unavailable on this platform or for this source.")
    }
}

public actor StartupControlService {
    private let controller: any StartupControlling
    public init(controller: any StartupControlling) { self.controller=controller }
    public func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult {
        guard action == .remove ? definition.removable : definition.controlCapability != "system_settings" else {
            throw ShouError("capability_unavailable", "This startup source must be managed in System Settings.")
        }
        return try controller.apply(definition: definition, action: action)
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
    public init(checkedAt: Date, includeSystem: Bool, sources: [StartupSourceCoverage], items: [StartupDefinition], issues: [StartupInventoryIssue], scope: String = "launchd_definitions", unavailableSources: [String] = ["login_items", "background_task_registrations", "embedded_helpers"]) {
        self.checkedAt=checkedAt; self.includeSystem=includeSystem; self.sources=sources; self.items=items; self.issues=issues
        self.scope=scope; self.unavailableSources=unavailableSources
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
