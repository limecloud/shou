import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct NativeMySQLAdministration: MySQLAdminOperating {
    public init() {}
    public func inspect(_ connection: MySQLConnection, credentials: MySQLCredentials) throws -> MySQLSnapshot {
        let server=try identity(connection, credentials)
        let databases=try rows(query("SELECT HEX(SCHEMA_NAME),DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME;", connection, credentials)).map { row in
            guard row.count == 2 else { throw failed("mysql_invalid_response") }
            return MySQLDatabase(name: try unhex(row[0]), charset: row[1])
        }
        var accounts=[MySQLAccount](), readable=true
        do {
            accounts=try rows(query("SELECT HEX(User),HEX(Host),plugin FROM mysql.user ORDER BY User,Host;", connection, credentials)).map { row in
                guard row.count == 3 else { throw failed("mysql_invalid_response") }
                return .init(user: try unhex(row[0]), host: try unhex(row[1]), plugin: row[2])
            }
        } catch { readable=false }
        guard try identity(connection, credentials) == server else { throw MySQLAdministrationError.changed() }
        return .init(server: server, databases: databases, accounts: accounts, accountsReadable: readable)
    }
    public func mutate(_ mutation: MySQLMutation, connection: MySQLConnection, credentials: MySQLCredentials, expected: MySQLServerIdentity) throws {
        guard try identity(connection, credentials) == expected else { throw MySQLAdministrationError.changed() }
        switch mutation {
        case .createDatabase(let name,let charset):
            guard MySQLMutation.validName(name, limit: 64), ["utf8mb4","utf8","gbk","big5"].contains(charset) else { throw MySQLAdministrationError.invalid() }
            _ = try query("CREATE DATABASE " + identifier(name) + " CHARACTER SET " + charset + ";", connection, credentials)
            guard try inspect(connection, credentials: credentials).databases.contains(where: { $0.name == name && $0.charset == charset }) else { throw failed("mysql_verification_failed") }
        case .createAccount(let database,let user,let password):
            let account=literal(user) + "@'localhost'"
            let partialRevokes=String(decoding:try query("SELECT @@GLOBAL.partial_revokes;",connection,credentials),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            guard ["0","1"].contains(partialRevokes) else { throw failed("mysql_invalid_response") }
            // With partial_revokes OFF, '_' and '%' are GRANT pattern
            // wildcards even inside backticks. Bind this grant to one schema.
            let grantDatabase=partialRevokes == "1" ? database : database.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"_",with:"\\_").replacingOccurrences(of:"%",with:"\\%")
            _ = try query("SET SESSION sql_mode='NO_BACKSLASH_ESCAPES'; CREATE USER " + account + " IDENTIFIED BY " + literal(password) + ";", connection, credentials)
            // No IF NOT EXISTS / ALTER fallback: an existing account must never
            // have its password changed by the create-account workflow.
            _ = try query("SET SESSION sql_mode='NO_BACKSLASH_ESCAPES'; GRANT ALL PRIVILEGES ON " + identifier(grantDatabase) + ".* TO " + account + ";", connection, credentials)
            let created=MySQLCredentials(user: user, password: password)
            let observed=try identity(connection, created)
            guard sameServer(observed,expected), observed.authenticatedAccount == user + "@localhost" else { throw failed("mysql_verification_failed") }
            let grants=try String(decoding: query("SHOW GRANTS FOR CURRENT_USER;", connection, created), as: UTF8.self)
            guard grants.contains("ON " + identifier(grantDatabase) + ".* TO ") else { throw failed("mysql_verification_failed") }
        case .changePassword(let account,let password):
            // Authenticated account changes only. Do not silently restart a
            // server in a mode that bypasses its authentication.
            _ = try query("SET SESSION sql_mode='NO_BACKSLASH_ESCAPES'; ALTER USER " + literal(account.user) + "@" + literal(account.host) + " IDENTIFIED BY " + literal(password) + ";", connection, credentials)
            let changed=MySQLCredentials(user: account.user, password: password)
            let observed=try identity(connection, changed)
            guard sameServer(observed,expected), observed.authenticatedAccount == account.user + "@" + account.host else { throw failed("mysql_verification_failed") }
        }
    }
    public func backup(_ database: MySQLDatabase, connection: MySQLConnection, credentials: MySQLCredentials, expected: MySQLServerIdentity, directory: String) throws -> String {
        guard !database.system, try identity(connection, credentials) == expected else { throw MySQLAdministrationError.changed() }
        let parent=try SecurePaths.directory(directory); defer { close(parent) }
        var info=stat()
        guard fstat(parent,&info) == 0, info.st_uid == getuid() else { throw failed("mysql_backup_unavailable") }
        let name="mysql-" + String(database.name.utf8.map { String(format: "%02x",$0) }.joined().prefix(128)) + "-" + UUID().uuidString + ".sql.partial"
        let fd=openat(parent,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw failed("mysql_backup_unavailable") }; defer { close(fd) }
        do {
        let dump=try executable(connection, name: "mysqldump")
        try withCredentials(credentials) { file in
            // Stream stdout to the already opened private file; never collect a
            // potentially large database in app memory or overwrite a backup.
            _ = try runner(file).run(dump,
                arguments: ["--defaults-file=" + file] + transport(connection) + ["--single-transaction","--quick","--skip-lock-tables","--no-tablespaces","--set-gtid-purged=OFF","--databases","--",database.name], timeout: 300, outputFileDescriptor: fd)
        }
        guard fsync(fd) == 0, fstat(fd,&info) == 0, info.st_size > 0, try identity(connection,credentials) == expected else { throw failed("mysql_backup_unverified") }
        let final=String(name.dropLast(".partial".count))
        guard renameatx_np(parent,name,parent,final,UInt32(RENAME_EXCL)) == 0, fsync(parent) == 0 else { throw failed("mysql_backup_unverified") }
        return directory + "/" + final
        } catch {
            throw ShouError((error as? ShouError)?.code ?? "mysql_backup_failed","The MySQL export failed. Completed backups remain; incomplete files have a .partial suffix.",details:["partial_path":directory + "/" + name])
        }
    }
    private func query(_ sql: String, _ connection: MySQLConnection, _ credentials: MySQLCredentials) throws -> Data {
        let client=try executable(connection, name: "mysql")
        return try withCredentials(credentials) { file in
            try runner(file).run(client,
                arguments: ["--defaults-file=" + file,"--batch","--raw","--skip-column-names","--skip-reconnect","--binary-mode","--local-infile=0","--default-character-set=utf8mb4","--connect-timeout=3"] + transport(connection), timeout: 12, standardInput: Data(sql.utf8))
        }
    }
    private func runner(_ file: String) -> NativeManagedToolProcess {
        let root=URL(fileURLWithPath:file).deletingLastPathComponent()
        // MySQL 8.0 does not support --no-login-paths. Its login-file override
        // plus an isolated HOME prevents the user's .mylogin.cnf from silently
        // changing the selected endpoint or credentials.
        return .init(homeDirectory:root,additionalEnvironment:["MYSQL_TEST_LOGIN_FILE":root.appendingPathComponent("absent.mylogin.cnf").path,"MYSQL_HOME":root.path])
    }
    private func identity(_ connection: MySQLConnection, _ credentials: MySQLCredentials) throws -> MySQLServerIdentity {
        let values=try rows(query("SELECT @@server_uuid,@@version,@@port,HEX(@@socket),HEX(@@datadir),HEX(CURRENT_USER());",connection,credentials))
        guard values.count == 1, values[0].count == 6, let port=Int(values[0][2]), !values[0][0].isEmpty else { throw failed("mysql_invalid_response") }
        let row=values[0], socket=try unhex(row[3])
        guard connection.socket.map({ $0 == socket }) ?? (port == connection.port) else { throw MySQLAdministrationError.changed() }
        return .init(uuid: row[0], version: row[1], port: port, socket: socket, dataDirectory: try unhex(row[4]), authenticatedAccount: try unhex(row[5]))
    }
    private func transport(_ connection: MySQLConnection) -> [String] {
        if let socket=connection.socket { return ["--protocol=SOCKET","--socket=" + socket] }
        return ["--protocol=TCP","--host=127.0.0.1","--port=" + String(connection.port)]
    }
    private func executable(_ connection: MySQLConnection, name: String) throws -> String {
        try connection.validate()
        let path=NativeDeveloperInstancePaths.physical(connection.installationPath + "/bin/" + name)
        let parent=try SecurePaths.parent(path); defer { close(parent.0) }
        let fd=openat(parent.0,parent.1,O_EVTONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw failed("mysql_client_unavailable") }; defer { close(fd) }
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0,
              info.st_mode & 0o022 == 0, [0,getuid()].contains(info.st_uid) else { throw failed("mysql_client_unavailable") }
        return path
    }
    private func withCredentials<T>(_ credentials: MySQLCredentials, operation: (String) throws -> T) throws -> T {
        var pattern=Array("/private/var/tmp/shou-mysql-auth-XXXXXX".utf8CString)
        let created=pattern.withUnsafeMutableBufferPointer { pointer -> String? in
            guard let directory=mkdtemp(pointer.baseAddress!) else { return nil }
            return String(cString:directory)
        }
        guard let root=created else { throw failed("io_error") }
        let path=root + "/client.cnf"
        defer { unlink(path); rmdir(root) }
        let fd=open(path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw failed("io_error") }
        do {
            let data=Data(("[client]\nuser=\"" + option(credentials.user) + "\"\npassword=\"" + option(credentials.password) + "\"\n").utf8)
            let handle=FileHandle(fileDescriptor: fd,closeOnDealloc: false)
            try handle.write(contentsOf: data); guard fsync(fd) == 0 else { throw failed("io_error") }; close(fd)
        } catch { close(fd); throw error }
        return try operation(path)
    }
    private func option(_ value: String) -> String { value.replacingOccurrences(of: "\\",with: "\\\\").replacingOccurrences(of: "\"",with: "\\\"").replacingOccurrences(of: "\n",with: "\\n").replacingOccurrences(of: "\r",with: "\\r").replacingOccurrences(of: "\t",with: "\\t") }
    private func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'",with: "''") + "'" }
    private func identifier(_ value: String) -> String { "`" + value.replacingOccurrences(of: "`",with: "``") + "`" }
    private func rows(_ data: Data) throws -> [[String]] {
        guard let text=String(data: data,encoding: .utf8) else { throw failed("mysql_invalid_response") }
        let result=text.split(separator: "\n").map { $0.split(separator: "\t",omittingEmptySubsequences: false).map(String.init) }
        guard result.count <= 10_000 else { throw failed("resource_limit") }; return result
    }
    private func unhex(_ text: String) throws -> String {
        guard text.utf8.count % 2 == 0, text.utf8.count <= 8192 else { throw failed("mysql_invalid_response") }
        var bytes=[UInt8](), index=text.startIndex
        while index < text.endIndex { let end=text.index(index,offsetBy: 2); guard let byte=UInt8(text[index..<end],radix:16) else { throw failed("mysql_invalid_response") }; bytes.append(byte); index=end }
        guard let value=String(bytes: bytes,encoding:.utf8) else { throw failed("mysql_invalid_response") }; return value
    }
    private func sameServer(_ lhs: MySQLServerIdentity, _ rhs: MySQLServerIdentity) -> Bool { lhs.uuid == rhs.uuid && lhs.version == rhs.version && lhs.port == rhs.port && lhs.socket == rhs.socket && lhs.dataDirectory == rhs.dataDirectory }
    private func failed(_ code: String) -> ShouError { ShouError(code,"The MySQL operation could not be verified. Check the selected instance and its permissions.") }
}
#endif
