import Foundation

public struct DeveloperService: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let toolID: String
    public let source: String
    public let name: String
    public let version: String
    public let installationPath: String
    public let configurationPath: String
    public let state: String
    public let registeredAtLogin: Bool
    public let identity: String
    public let definitionIdentity: String
    public let issue: String?
    public let logPath: String?
    public let errorLogPath: String?
    public let processID: Int32?
    public var controllable: Bool { issue == nil && ["running", "stopped"].contains(state) }
    public init(id: String, toolID: String, source: String, name: String, version: String, installationPath: String, configurationPath: String, state: String, registeredAtLogin: Bool, identity: String, definitionIdentity: String, issue: String?, logPath: String? = nil, errorLogPath: String? = nil, processID: Int32? = nil) {
        self.id=id; self.toolID=toolID; self.source=source; self.name=name; self.version=version
        self.installationPath=installationPath; self.configurationPath=configurationPath; self.state=state
        self.processID=processID
        self.registeredAtLogin=registeredAtLogin; self.identity=identity; self.definitionIdentity=definitionIdentity; self.issue=issue; self.logPath=logPath; self.errorLogPath=errorLogPath
    }
}
public struct DeveloperServiceSnapshot: Sendable {
    public let services: [DeveloperService]
    public let issues: [String]
    public init(services: [DeveloperService], issues: [String]) { self.services=services; self.issues=issues }
}
public enum DeveloperServiceAction: String, Codable, Sendable { case start, stop, restart }
public struct DeveloperServiceProgress: Sendable {
    public let serviceID: String
    public let stage: String
    public init(serviceID: String, stage: String) { self.serviceID=serviceID; self.stage=stage }
}

public struct DeveloperServiceResult: Codable, Sendable {
    public let id: String
    public let service: DeveloperService
    public let requestedRunning: Bool
    public let action: DeveloperServiceAction
    public let state: String
    public let observed: DeveloperService?
    public let failureCode: String?
    public let stage: String?
    public init(id: String, service: DeveloperService, requestedRunning: Bool, action: DeveloperServiceAction, state: String, observed: DeveloperService?, failureCode: String? = nil, stage: String? = nil) {
        self.id=id; self.service=service; self.requestedRunning=requestedRunning; self.action=action; self.state=state; self.observed=observed; self.failureCode=failureCode; self.stage=stage
    }
}
public protocol DeveloperServiceOperating: Sendable {
    func scan(catalog: DeveloperToolCatalog, inventory: DeveloperToolInventory) throws -> DeveloperServiceSnapshot
    func inspect(_ expected: DeveloperService) throws -> DeveloperService
    func setRunning(_ running: Bool, expected: DeveloperService, expiresAt: Date) throws
}

/// A switch is the explicit request for this displayed source/version. It is not
/// installation, login-start registration, process adoption or permission to delete data.
public actor DeveloperServiceController {
    private let catalog: DeveloperToolCatalog
    private let platform: any DeveloperServiceOperating
    private let makeStore: @Sendable () throws -> any RecordStore
    private var observations=[String:DeveloperService]()
    public init(catalog: DeveloperToolCatalog, platform: any DeveloperServiceOperating, makeStore: @escaping @Sendable () throws -> any RecordStore) {
        self.catalog=catalog; self.platform=platform; self.makeStore=makeStore
    }
    public func scan(_ inventory: DeveloperToolInventory, toolID: String? = nil, toolIDs: Set<String>? = nil) throws -> DeveloperServiceSnapshot {
        guard toolID == nil || toolIDs == nil else { throw changed() }
        let ids=toolID.map { Set([$0]) } ?? toolIDs
        let selected=ids.map { ids in catalog.tools.filter { ids.contains($0.id) } } ?? catalog.tools
        guard !selected.isEmpty else { throw changed() }
        if let ids { observations=observations.filter { !ids.contains($0.value.toolID) } }
        else { observations.removeAll() }
        let scoped=DeveloperToolCatalog(schemaVersion: catalog.schemaVersion, categories: catalog.categories, tools: selected)
        let snapshot=try platform.scan(catalog: scoped, inventory: inventory)
        guard snapshot.services.count <= 512, Set(snapshot.services.map(\.id)).count == snapshot.services.count,
              snapshot.services.allSatisfy({ row in !row.identity.isEmpty && selected.contains { $0.id == row.toolID } }) else { throw changed() }
        for row in snapshot.services { observations[row.id]=row }
        return snapshot
    }
    public func setRunning(_ running: Bool, expected: DeveloperService) throws -> DeveloperServiceResult {
        try perform(running ? .start : .stop, expected: expected)
    }
    public func perform(_ action: DeveloperServiceAction, expected: DeveloperService, progress: (@Sendable (DeveloperServiceProgress) -> Void)? = nil) throws -> DeveloperServiceResult {
        let running=action != .stop
        guard observations.removeValue(forKey: expected.id) == expected, expected.controllable,
              action == .restart ? expected.state == "running" : running != (expected.state == "running") else { throw changed() }
        let deadline=Date().addingTimeInterval(120), store=try makeStore(), lease=try store.lock()
        defer { lease.release() }
        try Task.checkCancellation()
        guard try platform.inspect(expected) == expected else { throw changed() }
        let id=UUID().uuidString
        let intent=DeveloperServiceResult(id: id, service: expected, requestedRunning: running, action: action, state: "requested", observed: nil)
        try store.write("developer-service-intents", id: id, data: Codec.encode(intent))
        let result: DeveloperServiceResult
        var dispatched=false
        var stage="checking"
        func report(_ value: String) { progress?(.init(serviceID: expected.id, stage: value)) }
        do {
            try Task.checkCancellation()
            dispatched=true
            var current=expected
            if action == .restart {
                stage="stopping"; report(stage)
                try platform.setRunning(false, expected: current, expiresAt: deadline)
                let after=try platform.inspect(current)
                guard sameDefinition(after, expected), after.state == "stopped", after.controllable else { throw changed() }
                current=after
                let intermediate=DeveloperServiceResult(id: id, service: expected, requestedRunning: running, action: action, state: "stopped", observed: after)
                try store.write("developer-service-stages", id: id, data: Codec.encode(intermediate))
                report("stopped")
                try Task.checkCancellation()
                guard deadline > Date() else { throw changed() }
            }
            stage=running ? "starting" : "stopping"; report(stage)
            try platform.setRunning(running, expected: current, expiresAt: deadline)
            stage="verifying"; report(stage)
            let observed=try platform.inspect(expected)
            let verified=observed.issue == nil && observed.state == (running ? "running" : "stopped") && sameDefinition(observed, expected)
            result = .init(id: id, service: expected, requestedRunning: running, action: action, state: verified ? "succeeded" : "unknown", observed: observed,
                failureCode: verified ? nil : "developer_service_verification_failed", stage: verified ? nil : stage)
        } catch {
            let after=try? platform.inspect(expected)
            let partial=action == .restart && (after.map { sameDefinition($0, expected) && $0.controllable && $0.state == "stopped" } ?? false)
            result = .init(id: id, service: expected, requestedRunning: running, action: action, state: partial ? "partial" : dispatched ? "unknown" : "not_started", observed: after, failureCode: (error as? ShouError)?.code ?? "developer_service_unavailable", stage: stage)
        }
        try store.write("developer-service-results", id: id, data: Codec.encode(result))
        if result.state == "succeeded", let observed=result.observed { observations[observed.id]=observed }
        return result
    }
    private func sameDefinition(_ row: DeveloperService, _ expected: DeveloperService) -> Bool {
        row.id == expected.id && row.toolID == expected.toolID && row.source == expected.source && row.name == expected.name && row.version == expected.version &&
        row.installationPath == expected.installationPath && row.configurationPath == expected.configurationPath && row.definitionIdentity == expected.definitionIdentity && row.registeredAtLogin == expected.registeredAtLogin && row.logPath == expected.logPath && row.errorLogPath == expected.errorLogPath
    }
    private func changed() -> ShouError { ShouError("developer_service_changed", "Refresh the exact service source and state before trying again.") }
}
