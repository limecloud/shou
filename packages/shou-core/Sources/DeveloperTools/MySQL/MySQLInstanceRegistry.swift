import Foundation

public struct MySQLInstanceGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let installation: String
    public let configuration: String
    public let dataDirectory: String
    public var socket: String
    public var port: Int
    public let version: String
    public var registered: Bool?
    public init(id: String, name: String, installation: String, configuration: String, dataDirectory: String, socket: String, port: Int, version: String, registered: Bool? = nil) {
        self.id=id; self.name=name; self.installation=installation; self.configuration=configuration
        self.dataDirectory=dataDirectory; self.socket=socket; self.port=port; self.version=version; self.registered=registered
    }
}
public enum MySQLGroupChange: Sendable {
    case refreshRegistration
    case rename(String)
    case unregister
    public var action: String {
        switch self { case .refreshRegistration: "refresh_registration"; case .rename: "rename"; case .unregister: "unregister" }
    }
}
public struct MySQLGroupObservation: Equatable, Sendable {
    public let group: MySQLInstanceGroup
    public let revision: String
    public let port: Int
    public let socket: String
    public init(group: MySQLInstanceGroup, revision: String, port: Int, socket: String) {
        self.group=group; self.revision=revision; self.port=port; self.socket=socket
    }
}
public struct MySQLGroupReview: Identifiable, Sendable {
    public let id: String
    public let observation: MySQLGroupObservation
    public let change: MySQLGroupChange
    public let expiresAt: Date
}
public protocol MySQLInstanceRegistryOperating: Sendable {
    func inspectGroup(_ group: MySQLInstanceGroup, for change: MySQLGroupChange) throws -> MySQLGroupObservation
    func applyGroup(_ change: MySQLGroupChange, expected: MySQLGroupObservation) throws
}
/// Registration changes never start, initialize or remove database files.
/// Lifecycle controls continue to use the separate service controller.
public actor MySQLInstanceRegistry {
    private let platform: any MySQLInstanceRegistryOperating
    private let makeStore: @Sendable () throws -> any RecordStore
    private var pending: MySQLGroupReview?
    public init(platform: any MySQLInstanceRegistryOperating, makeStore: @escaping @Sendable () throws -> any RecordStore) {
        self.platform=platform; self.makeStore=makeStore
    }
    public func prepare(_ change: MySQLGroupChange, group: MySQLInstanceGroup) throws -> MySQLGroupReview {
        pending=nil
        if case .rename(let name)=change {
            guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
                  !name.contains(where:{ $0.isNewline || $0 == "\0" }) else { throw MySQLAdministrationError.invalid() }
        }
        let value=MySQLGroupReview(id:UUID().uuidString,observation:try platform.inspectGroup(group,for:change),change:change,expiresAt:Date().addingTimeInterval(120))
        pending=value; return value
    }
    public func execute(_ id: String) throws {
        guard let review=pending, review.id == id else { throw stale() }
        pending=nil
        guard review.expiresAt > Date() else { throw stale() }
        let store=try makeStore(), lease=try store.lock(); defer { lease.release() }
        guard try platform.inspectGroup(review.observation.group,for:review.change) == review.observation else { throw stale() }
        let record=["group":review.observation.group.id,"action":review.change.action,"revision":review.observation.revision]
        try store.write("mysql-group-change-intents",id:id,data:JSONSerialization.data(withJSONObject:record))
        do { try platform.applyGroup(review.change,expected:review.observation) }
        catch {
            try? store.write("mysql-group-change-results",id:id,data:JSONSerialization.data(withJSONObject:["group":review.observation.group.id,"state":"needs_verification"]))
            throw ShouError("mysql_group_needs_verification","The registration result needs verification. Refresh its state before continuing; database files were not removed.")
        }
        try store.write("mysql-group-change-results",id:id,data:JSONSerialization.data(withJSONObject:["group":review.observation.group.id,"state":"verified"]))
    }
    private func stale() -> ShouError { ShouError("mysql_group_changed","The instance registration changed. Refresh and review it again.") }
}
