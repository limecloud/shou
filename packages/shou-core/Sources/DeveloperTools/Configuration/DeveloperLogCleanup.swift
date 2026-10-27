import Foundation

public struct DeveloperLogInspection: Codable, Equatable, Sendable {
    public let toolID: String
    public let file: FileEntry
    public let writable: Bool
    public init(toolID: String, file: FileEntry, writable: Bool) { self.toolID=toolID; self.file=file; self.writable=writable }
}
public struct DeveloperLogCleanupPlan: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let inspection: DeveloperLogInspection
    public let expiresAt: Date
}
public struct DeveloperLogCleanupResult: Codable, Sendable {
    public let plan: DeveloperLogCleanupPlan
    public let state: String
    public let observed: DeveloperLogInspection?
    public let issue: String?
}
public protocol DeveloperLogCleaning: Sendable {
    func inspect() throws -> DeveloperLogInspection
    func clear(expected: DeveloperLogInspection) throws
}
/// Clearing preserves the file, so a service's open descriptor does not retain
/// an unlinked log. Only one current exact-file review authorizes truncation.
public actor DeveloperLogCleanup {
    private let platform: any DeveloperLogCleaning
    private let makeStore: @Sendable () throws -> any RecordStore
    private let now: @Sendable () -> Date
    private var current: DeveloperLogCleanupPlan?
    public init(platform: any DeveloperLogCleaning, makeStore: @escaping @Sendable () throws -> any RecordStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.platform=platform; self.makeStore=makeStore; self.now=now
    }
    public func prepare() throws -> DeveloperLogCleanupPlan {
        current=nil
        let value=try platform.inspect()
        try requireUnprotected(value.file.path,store:makeStore())
        guard !value.toolID.isEmpty, value.file.path.hasPrefix("/"), value.file.kind == "file", value.file.links == 1,
              value.writable, value.file.logicalBytes > 0 else { throw failure("developer_log_unavailable") }
        let plan=DeveloperLogCleanupPlan(id:UUID().uuidString,inspection:value,expiresAt:now().addingTimeInterval(120))
        current=plan; return plan
    }
    public func execute(_ plan: DeveloperLogCleanupPlan, confirmedID: String) throws -> DeveloperLogCleanupResult {
        let saved=current; current=nil
        guard saved == plan, confirmedID == plan.id, now() < plan.expiresAt else { throw failure("confirmation_required") }
        let store=try makeStore(), lease=try store.lock(); defer { lease.release() }
        try requireUnprotected(plan.inspection.file.path,store:store)
        guard try platform.inspect() == plan.inspection, now() < plan.expiresAt else { throw failure("developer_log_changed") }
        try store.write("developer-log-cleanup-intents",id:plan.id,data:Codec.encode(plan))
        try Task.checkCancellation()
        let result: DeveloperLogCleanupResult
        do {
            try platform.clear(expected:plan.inspection)
            let after=try platform.inspect()
            let verified=after.toolID == plan.inspection.toolID && after.file.path == plan.inspection.file.path &&
                after.file.sameObject(as:plan.inspection.file) && after.file.logicalBytes == 0
            result = .init(plan:plan,state:verified ? "succeeded" : "unknown",observed:after,issue:verified ? nil : "developer_log_unverified")
        } catch {
            result = .init(plan:plan,state:"unknown",observed:nil,issue:(error as? ShouError)?.code ?? "developer_log_unavailable")
        }
        try store.write("developer-log-cleanup-results",id:plan.id,data:Codec.encode(result))
        return result
    }
    private func requireUnprotected(_ path: String, store: any RecordStore) throws {
        let target=StorageRemovalPolicy.canonical(path)
        guard !store.protectedPaths.contains(where:{ root in
            let protected=StorageRemovalPolicy.canonical(root)
            return target == protected || target.hasPrefix(protected + "/")
        }) else { throw failure("protected_path") }
    }
    private func failure(_ code: String) -> ShouError { ShouError(code,"Reload the exact log and review its current file before clearing it.") }
}
