import Foundation

/// MySQL has its own task contract. Installation, process control and database
/// administration deliberately do not share a generic "tool action" model.
public struct MySQLConnection: Equatable, Sendable {
    public let installationPath: String
    public let port: Int
    public let socket: String?
    public init(installationPath: String, port: Int = 3306, socket: String? = nil) {
        self.installationPath=installationPath; self.port=port; self.socket=socket
    }
    public func validate() throws {
        guard installationPath.hasPrefix("/"), !installationPath.contains("\0"), (1...65535).contains(port),
              socket == nil || (socket!.hasPrefix("/") && !socket!.contains("\0") && socket!.utf8.count <= 1024) else { throw MySQLAdministrationError.invalid() }
    }
}
// Never Codable: credentials must not enter operation records or UI diagnostics.
public struct MySQLCredentials: Sendable {
    public let user: String
    public let password: String
    public init(user: String, password: String) { self.user=user; self.password=password }
}
public struct MySQLDatabase: Identifiable, Equatable, Sendable {
    public let name: String
    public let charset: String
    public var id: String { name }
    public var system: Bool { ["mysql","information_schema","performance_schema","sys"].contains(name) }
    public init(name: String, charset: String) { self.name=name; self.charset=charset }
}
public struct MySQLAccount: Identifiable, Equatable, Sendable {
    public let user: String
    public let host: String
    public let plugin: String
    public var id: String { user + "\0" + host }
    public init(user: String, host: String, plugin: String) { self.user=user; self.host=host; self.plugin=plugin }
}
public struct MySQLServerIdentity: Equatable, Sendable {
    public let uuid: String
    public let version: String
    public let port: Int
    public let socket: String
    public let dataDirectory: String
    public let authenticatedAccount: String
    public init(uuid: String, version: String, port: Int, socket: String, dataDirectory: String, authenticatedAccount: String) {
        self.uuid=uuid; self.version=version; self.port=port; self.socket=socket; self.dataDirectory=dataDirectory; self.authenticatedAccount=authenticatedAccount
    }
}
public struct MySQLSnapshot: Sendable {
    public let server: MySQLServerIdentity
    public let databases: [MySQLDatabase]
    public let accounts: [MySQLAccount]
    public let accountsReadable: Bool
    public init(server: MySQLServerIdentity, databases: [MySQLDatabase], accounts: [MySQLAccount], accountsReadable: Bool) {
        self.server=server; self.databases=databases; self.accounts=accounts; self.accountsReadable=accountsReadable
    }
}
public enum MySQLMutation: Sendable {
    case createDatabase(name: String, charset: String)
    case createAccount(database: String, user: String, password: String)
    case changePassword(account: MySQLAccount, password: String)
    public var action: String {
        switch self { case .createDatabase: "create_database"; case .createAccount: "create_account"; case .changePassword: "change_password" }
    }
    public var target: String {
        switch self { case .createDatabase(let name,_): name; case .createAccount(let database,let user,_): database + " · " + user + "@localhost"; case .changePassword(let account,_): account.user + "@" + account.host }
    }
    public func validate(snapshot: MySQLSnapshot) throws {
        switch self {
        case .createDatabase(let name,let charset):
            guard Self.validName(name, limit: 64), ["utf8mb4","utf8","gbk","big5"].contains(charset), !snapshot.databases.contains(where: { $0.name == name }), !MySQLDatabase(name: name, charset: charset).system else { throw MySQLAdministrationError.invalid() }
        case .createAccount(let database,let user,let password):
            guard snapshot.accountsReadable, snapshot.databases.contains(where: { $0.name == database && !$0.system }), Self.validName(user, limit: 32), user != "root",
                  !snapshot.accounts.contains(where: { $0.user == user }), Self.validPassword(password) else { throw MySQLAdministrationError.invalid() }
        case .changePassword(let account,let password):
            guard snapshot.accountsReadable, snapshot.accounts.contains(account), Self.validPassword(password) else { throw MySQLAdministrationError.invalid() }
        }
    }
    public static func validName(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.range(of: "^[A-Za-z0-9_$-]+$", options: .regularExpression) != nil
    }
    private static func validPassword(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 1024 && !value.contains("\0") && !value.contains("\n") && !value.contains("\r") }
}
public protocol MySQLAdminOperating: Sendable {
    func inspect(_ connection: MySQLConnection, credentials: MySQLCredentials) throws -> MySQLSnapshot
    func mutate(_ mutation: MySQLMutation, connection: MySQLConnection, credentials: MySQLCredentials, expected: MySQLServerIdentity) throws
    func backup(_ database: MySQLDatabase, connection: MySQLConnection, credentials: MySQLCredentials, expected: MySQLServerIdentity, directory: String) throws -> String
}
public struct MySQLReview: Sendable {
    public let id: String
    public let action: String
    public let target: String
    public let server: MySQLServerIdentity
    public let expiresAt: Date
}
public struct MySQLOperationReceipt: Codable, Sendable {
    public let id: String
    public let action: String
    public let target: String
    public let serverUUID: String
    public let state: String
    public let failureCode: String?
}
public struct MySQLBackupReceipt: Sendable {
    public let database: String
    public let path: String?
    public let state: String
    public let failureCode: String?
}
public actor MySQLAdministration {
    private let platform: any MySQLAdminOperating
    private let makeStore: @Sendable () throws -> any RecordStore
    private var connection: MySQLConnection?
    private var credentials: MySQLCredentials?
    private var snapshot: MySQLSnapshot?
    private var pending: (MySQLReview, MySQLMutation)?
    public init(platform: any MySQLAdminOperating, makeStore: @escaping @Sendable () throws -> any RecordStore) { self.platform=platform; self.makeStore=makeStore }
    public func disconnect() { connection=nil; credentials=nil; snapshot=nil; pending=nil }
    public func connect(_ connection: MySQLConnection, credentials: MySQLCredentials) throws -> MySQLSnapshot {
        disconnect(); try connection.validate()
        guard !credentials.user.isEmpty, credentials.user.utf8.count <= 128, !credentials.user.contains("\0") else { throw MySQLAdministrationError.invalid() }
        let observed=try platform.inspect(connection, credentials: credentials)
        guard !observed.server.uuid.isEmpty else { throw MySQLAdministrationError.changed() }
        self.connection=connection; self.credentials=credentials; snapshot=observed
        return observed
    }
    public func refresh() throws -> MySQLSnapshot {
        pending=nil
        guard let connection, let credentials, let snapshot else { throw MySQLAdministrationError.changed() }
        let current=try platform.inspect(connection, credentials: credentials)
        guard current.server == snapshot.server else { disconnect(); throw MySQLAdministrationError.changed() }
        self.snapshot=current; return current
    }
    public func prepare(_ mutation: MySQLMutation) throws -> MySQLReview {
        let current=try refresh(); try mutation.validate(snapshot: current)
        let review=MySQLReview(id: UUID().uuidString, action: mutation.action, target: mutation.target, server: current.server, expiresAt: Date().addingTimeInterval(120))
        pending=(review,mutation); return review
    }
    public func execute(_ id: String) throws -> MySQLOperationReceipt {
        let selected=pending; pending=nil
        guard let (review,mutation)=selected, review.id == id, review.expiresAt > Date(), let connection, let credentials else { throw MySQLAdministrationError.changed() }
        let store=try makeStore(), lease=try store.lock(); defer { lease.release() }
        let current=try platform.inspect(connection, credentials: credentials)
        guard current.server == review.server else { throw MySQLAdministrationError.changed() }
        try mutation.validate(snapshot: current)
        func receipt(_ state: String, _ code: String? = nil) -> MySQLOperationReceipt { .init(id: review.id, action: review.action, target: review.target, serverUUID: review.server.uuid, state: state, failureCode: code) }
        try store.write("mysql-admin-intents", id: id, data: Codec.encode(receipt("requested")))
        let result: MySQLOperationReceipt
        do {
            try platform.mutate(mutation, connection: connection, credentials: credentials, expected: current.server)
            // Password verification is performed by the adapter with the new
            // credentials. The old login may cease to work after this operation.
            result=receipt("succeeded")
        } catch { result=receipt("needs_verification", (error as? ShouError)?.code ?? "mysql_operation_failed") }
        try store.write("mysql-admin-results", id: id, data: Codec.encode(result))
        snapshot=nil
        return result
    }
    public func backup(databases: [MySQLDatabase], directory: String) throws -> [MySQLBackupReceipt] {
        let current=try refresh()
        guard let connection, let credentials, !databases.isEmpty, databases.count <= 256,
              Set(databases.map(\.name)).count == databases.count, databases.allSatisfy({ current.databases.contains($0) && !$0.system }) else { throw MySQLAdministrationError.invalid() }
        var results=[MySQLBackupReceipt]()
        for database in databases {
            try Task.checkCancellation()
            do {
                let path=try platform.backup(database,connection:connection,credentials:credentials,expected:current.server,directory:directory)
                results.append(.init(database:database.name,path:path,state:"exported",failureCode:nil))
            } catch {
                let failure=error as? ShouError
                results.append(.init(database:database.name,path:failure?.details["partial_path"],state:"failed",failureCode:failure?.code ?? "mysql_backup_failed"))
            }
        }
        return results
    }
}
public enum MySQLAdministrationError {
    public static func invalid() -> ShouError { ShouError("mysql_invalid_request", "Check the database name, account, character set and selected instance.") }
    public static func changed() -> ShouError { ShouError("mysql_instance_changed", "Reconnect to the selected MySQL instance before continuing.") }
}
