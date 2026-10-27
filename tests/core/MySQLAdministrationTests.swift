import Foundation
import ShouCore
import ShouPlatform

private final class MySQLAdminFixture: MySQLAdminOperating, @unchecked Sendable {
    var uuid="generated-mysql-instance"
    var databases=[MySQLDatabase(name:"generated_app",charset:"utf8mb4")]
    var accounts=[MySQLAccount(user:"root",host:"localhost",plugin:"caching_sha2_password"),MySQLAccount(user:"same",host:"localhost",plugin:"caching_sha2_password"),MySQLAccount(user:"same",host:"127.0.0.1",plugin:"caching_sha2_password")]
    var dispatches=0, backups=0
    var failAfterDispatch=false
    var failingBackup: String?
    var identity: MySQLServerIdentity { .init(uuid:uuid,version:"8.0.40",port:3306,socket:"/generated/mysql.sock",dataDirectory:"/generated/data",authenticatedAccount:"root@localhost") }
    func inspect(_ connection: MySQLConnection, credentials: MySQLCredentials) throws -> MySQLSnapshot { .init(server:identity,databases:databases,accounts:accounts,accountsReadable:true) }
    func mutate(_ mutation: MySQLMutation, connection: MySQLConnection, credentials: MySQLCredentials, expected: MySQLServerIdentity) throws {
        dispatches += 1
        if failAfterDispatch { throw ShouError("generated_sql_failure","Generated partial failure.") }
        if case .createDatabase(let name,let charset)=mutation { databases.append(.init(name:name,charset:charset)) }
    }
    func backup(_ database: MySQLDatabase, connection: MySQLConnection, credentials: MySQLCredentials, expected: MySQLServerIdentity, directory: String) throws -> String {
        backups += 1
        if database.name == failingBackup { throw ShouError("generated_dump_failure","Generated dump failure.",details:["partial_path":directory + "/failed.sql.partial"]) }
        return directory + "/generated.sql"
    }
}
private final class MySQLRegistryFixture: MySQLInstanceRegistryOperating, @unchecked Sendable {
    var revision="generated-revision-1"
    var dispatches=0
    let group=MySQLInstanceGroup(id:"generated",name:"Generated",installation:"/generated/mysql",configuration:"/generated/my.cnf",dataDirectory:"/generated/data",socket:"/generated/mysql.sock",port:23317,version:"8.0.40")
    func inspectGroup(_ group: MySQLInstanceGroup, for change: MySQLGroupChange) throws -> MySQLGroupObservation { .init(group:group,revision:revision,port:23318,socket:group.socket) }
    func applyGroup(_ change: MySQLGroupChange, expected: MySQLGroupObservation) throws { dispatches += 1 }
}
func mysqlInstanceRegistrationBindsReviewsAndRequiresDurableIntent() async throws {
    let fixture=try Fixture(), platform=MySQLRegistryFixture()
    let controller=MySQLInstanceRegistry(platform:platform,makeStore:{ fixture.store })
    try await expectThrows { try await controller.prepare(.rename("\n"),group:platform.group) }
    let stale=try await controller.prepare(.refreshRegistration,group:platform.group)
    platform.revision="generated-revision-2"
    try await expectThrows { try await controller.execute(stale.id) }
    try expect(platform.dispatches == 0)
    let review=try await controller.prepare(.unregister,group:platform.group)
    try await controller.execute(review.id)
    try await expectThrows { try await controller.execute(review.id) }
    try expect(platform.dispatches == 1)
    let record=try require(try fixture.store.read("mysql-group-change-intents",id:review.id))
    try expect(String(decoding:record,as:UTF8.self).contains("unregister"))
    let denied=MySQLInstanceRegistry(platform:platform,makeStore:{ throw ShouError("generated_journal_failure","Generated journal failure.") })
    let blocked=try await denied.prepare(.rename("New generated name"),group:platform.group)
    try await expectThrows { try await denied.execute(blocked.id) }
    try expect(platform.dispatches == 1)
}
func mysqlAdminUsesExactHostAndSingleUseSecretFreeReviews() async throws {
    let fixture=try Fixture(), platform=MySQLAdminFixture()
    let controller=MySQLAdministration(platform:platform,makeStore:{ fixture.store })
    let connection=MySQLConnection(installationPath:"/generated/mysql")
    let snapshot=try await controller.connect(connection,credentials:.init(user:"root",password:"generated-login-secret"))
    try expect(snapshot.accounts[1].id != snapshot.accounts[2].id)
    let review=try await controller.prepare(.changePassword(account:snapshot.accounts[2],password:"generated-new-secret"))
    let result=try await controller.execute(review.id)
    try expect(result.state == "succeeded" && result.target == "same@127.0.0.1")
    let bytes=try require(try fixture.store.read("mysql-admin-intents",id:review.id))
    let text=String(decoding:bytes,as:UTF8.self)
    try expect(!text.contains("generated-login-secret") && !text.contains("generated-new-secret"))
    try await expectThrows { try await controller.execute(review.id) }
    try expect(platform.dispatches == 1)
}
func mysqlAdminRejectsStaleServersExistingAccountsAndUnjournaledChanges() async throws {
    let fixture=try Fixture(), platform=MySQLAdminFixture()
    let controller=MySQLAdministration(platform:platform,makeStore:{ fixture.store })
    let connection=MySQLConnection(installationPath:"/generated/mysql")
    _ = try await controller.connect(connection,credentials:.init(user:"root",password:""))
    for name in ["mysql","generated_app","x`; DROP DATABASE mysql; --",""] {
        try await expectThrows { try await controller.prepare(.createDatabase(name:name,charset:"utf8mb4")) }
    }
    try await expectThrows { try await controller.prepare(.createAccount(database:"generated_app",user:"same",password:"secret")) }
    let review=try await controller.prepare(.createDatabase(name:"new_generated",charset:"utf8mb4"))
    platform.uuid="different-server-at-same-port"
    try await expectThrows { try await controller.execute(review.id) }
    try expect(platform.dispatches == 0)
    let denied=MySQLAdministration(platform:platform,makeStore:{ throw ShouError("generated_journal_failure","Generated journal failure.") })
    _ = try await denied.connect(connection,credentials:.init(user:"root",password:""))
    let blocked=try await denied.prepare(.createDatabase(name:"new_generated",charset:"utf8mb4"))
    try await expectThrows { try await denied.execute(blocked.id) }
    try expect(platform.dispatches == 0)
    try await expectThrows { try await denied.execute(blocked.id) }
}
func mysqlAdminKeepsPartialOutcomesAndRejectsSystemBackups() async throws {
    let fixture=try Fixture(), platform=MySQLAdminFixture()
    let controller=MySQLAdministration(platform:platform,makeStore:{ fixture.store })
    _ = try await controller.connect(.init(installationPath:"/generated/mysql"),credentials:.init(user:"root",password:""))
    try await expectThrows { try await controller.backup(databases:[.init(name:"mysql",charset:"utf8mb4")],directory:"/generated/backups") }
    try expect(platform.backups == 0)
    let files=try await controller.backup(databases:platform.databases,directory:"/generated/backups")
    try expect(files.count == 1 && platform.backups == 1)
    platform.databases.append(.init(name:"generated_second",charset:"utf8mb4")); platform.failingBackup="generated_second"
    let mixed=try await controller.backup(databases:platform.databases,directory:"/generated/backups")
    try expect(mixed.map(\.state) == ["exported","failed"] && mixed[1].path == "/generated/backups/failed.sql.partial")
    let review=try await controller.prepare(.createDatabase(name:"partial_generated",charset:"utf8mb4"))
    platform.failAfterDispatch=true
    let result=try await controller.execute(review.id)
    try expect(result.state == "needs_verification" && result.failureCode == "generated_sql_failure")
    try await expectThrows { try await controller.execute(review.id) }
    try await expectThrows { try await controller.refresh() }
    try expect(platform.dispatches == 1)
}
func mysqlConfigurationRejectsChangesLinksAndKeepsSourceScope() throws {
    #if os(macOS)
    let fixture=try Fixture()
    let platform=NativeMySQLConfiguration(recordsDirectory:fixture.workspace.appendingPathComponent("edit-records"))
    let source="[mysqld]\nport = 3317\nsocket=/private/var/tmp/generated.sock\n!include /generated/other.cnf\n"
    try fixture.put("my.cnf",source)
    let path=fixture.workspace.appendingPathComponent("my.cnf").path
    let document=try platform.read(path)
    try expect(document.options["port"] == "3317" && document.options["socket"] == "/private/var/tmp/generated.sock")
    let saved=try platform.save(source + "# generated edit\n",expected:document)
    try expect(saved.text.hasSuffix("# generated edit\n"))
    try expectThrows { try platform.save("stale",expected:document) }
    try FileManager.default.createSymbolicLink(atPath:fixture.workspace.appendingPathComponent("linked.cnf").path,withDestinationPath:path)
    try expectThrows { try platform.read(fixture.workspace.appendingPathComponent("linked.cnf").path) }
    try fixture.put("bounded.log",(0..<400).map { "generated line \($0)" }.joined(separator:"\n"))
    let tail=try platform.log(path:fixture.workspace.appendingPathComponent("bounded.log").path)
    try expect(tail.split(separator:"\n").count == 200 && tail.contains("generated line 399") && !tail.contains("generated line 100\n"))
    #endif
}

/// Opt-in, actual MySQL engine, isolated data and private Unix socket only.
/// Does not connect to, stop or modify any existing server.
func mysqlNativeAdministrationUsesGeneratedActualEngine() async throws -> Bool {
    #if os(macOS)
    guard let bin=ProcessInfo.processInfo.environment["SHOU_TEST_MYSQL_BIN"] else { return false }
    let fm=FileManager.default
    let root=URL(fileURLWithPath:"/private/var/tmp/shou-mysql-engine-" + UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    defer { try? fm.removeItem(at:root) }
    let data=root.appendingPathComponent("data"), socket=root.appendingPathComponent("mysql.sock").path
    func command(_ name: String,_ arguments: [String], input: String? = nil) throws {
        let process=Process(); process.executableURL=URL(fileURLWithPath:bin + "/" + name); process.arguments=arguments
        let diagnostic=try FileHandle(forWritingTo:createFile(root.appendingPathComponent(UUID().uuidString + ".log")))
        defer { try? diagnostic.close() }; process.standardOutput=diagnostic; process.standardError=diagnostic
        if let input { let pipe=Pipe(); process.standardInput=pipe; try process.run(); try pipe.fileHandleForWriting.write(contentsOf:Data(input.utf8)); try pipe.fileHandleForWriting.close() } else { try process.run() }
        process.waitUntilExit(); try expect(process.terminationStatus == 0)
    }
    try command("mysqld",["--no-defaults","--initialize-insecure","--datadir=" + data.path])
    let process=Process(); process.executableURL=URL(fileURLWithPath:bin + "/mysqld")
    process.arguments=["--no-defaults","--datadir=" + data.path,"--skip-networking","--socket=" + socket,"--pid-file=" + root.appendingPathComponent("mysql.pid").path,"--log-error=" + root.appendingPathComponent("error.log").path,"--mysqlx=OFF"]
    process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let connection=MySQLConnection(installationPath:URL(fileURLWithPath:bin).deletingLastPathComponent().path,socket:socket)
    let credentials=MySQLCredentials(user:"root",password:"")
    let platform=NativeMySQLAdministration()
    var ready: MySQLSnapshot?
    for _ in 0..<100 {
        if let value=try? platform.inspect(connection,credentials:credentials) { ready=value; break }
        try await Task.sleep(for:.milliseconds(100))
    }
    if ready == nil {
        if let log=try? String(contentsOf:root.appendingPathComponent("error.log"),encoding:.utf8) { print("Generated engine startup log:\n" + log.suffix(8192)) }
        do { try command("mysql",["--no-defaults","--protocol=SOCKET","--socket=" + socket,"--user=root"],input:"SELECT @@server_uuid,@@version,@@port,HEX(@@socket),HEX(@@datadir),HEX(CURRENT_USER());") }
        catch { print("Generated client probe failed: \(error)") }
        for file in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension == "log" && file.lastPathComponent != "error.log" {
            if let value=try? String(contentsOf:file,encoding:.utf8), !value.isEmpty { print("Generated command diagnostic:\n" + value.suffix(4096)) }
        }
    }
    let initial=try require(ready)
    try expect(initial.accountsReadable && initial.databases.contains(where:{ $0.name == "mysql" }))
    let fixture=try Fixture(), controller=MySQLAdministration(platform:platform,makeStore:{ fixture.store })
    _ = try await controller.connect(connection,credentials:credentials)
    let review=try await controller.prepare(.createDatabase(name:"shou_generated_app",charset:"utf8mb4"))
    try expect(try await controller.execute(review.id).state == "succeeded")
    let after=try await controller.connect(connection,credentials:credentials)
    try expect(after.databases.contains(where:{ $0.name == "shou_generated_app" }))
    try command("mysql",["--no-defaults","--protocol=SOCKET","--socket=" + socket,"--user=root"],input:"CREATE DATABASE shouXgeneratedXapp;")
    let account=try await controller.prepare(.createAccount(database:"shou_generated_app",user:"shou_generated",password:"generated-'\\-secret"))
    try expect(try await controller.execute(account.id).state == "succeeded")
    let restricted=try platform.inspect(connection,credentials:.init(user:"shou_generated",password:"generated-'\\-secret"))
    try expect(restricted.databases.contains(where:{ $0.name == "shou_generated_app" }) && !restricted.databases.contains(where:{ $0.name == "shouXgeneratedXapp" }))
    let state=try await controller.connect(connection,credentials:credentials)
    let created=try require(state.accounts.first(where:{ $0.user == "shou_generated" && $0.host == "localhost" }))
    let password=try await controller.prepare(.changePassword(account:created,password:"new-generated-'\\-secret"))
    try expect(try await controller.execute(password.id).state == "succeeded")
    _ = try await controller.connect(connection,credentials:credentials)
    try command("mysql",["--no-defaults","--protocol=SOCKET","--socket=" + socket,"--user=root"],input:"CREATE TABLE shou_generated_app.generated_records (id INT PRIMARY KEY); INSERT INTO shou_generated_app.generated_records VALUES (42);")
    let files=try await controller.backup(databases:[.init(name:"shou_generated_app",charset:"utf8mb4")],directory:root.path)
    try expect(files.count == 1 && files[0].state == "exported")
    let dump=try String(contentsOfFile:require(files[0].path),encoding:.utf8)
    try expect(dump.contains("generated_records") && dump.contains("42"))
    // Actually restore the generated dump into another fresh data directory is
    // outside this test; do not call a dump a proven recoverable backup.
    process.terminate(); process.waitUntilExit()
    let groupPlatform=NativeMySQLInstances(baseDirectory:root.appendingPathComponent("g"),recordsDirectory:fixture.store.directory)
    let group=try groupPlatform.create(name:"Generated independent instance",installation:connection.installationPath,version:initial.server.version,port:23317,password:"generated-initial-'\\-secret")
    try expect(try groupPlatform.groups().contains(where:{ $0.id == group.id }))
    try expect(!fm.fileExists(atPath:URL(fileURLWithPath:group.configuration).deletingLastPathComponent().appendingPathComponent("initialize.sql").path))
    let instances=NativeDeveloperInstances(makeStore:{ fixture.store })
    let inventory=DeveloperToolInventory(installations:[.init(toolID:"mysql",source:"Homebrew",version:initial.server.version,path:connection.installationPath,evidence:"generated actual engine",status:"registered")],issues:[])
    let stopped=try require(try instances.scan(inventory:inventory,toolIDs:["mysql"]).services.first(where:{ $0.configurationPath == group.configuration }))
    defer { if let running=try? instances.inspect(stopped), running.state == "running" { try? instances.setRunning(false,expected:running,expiresAt:Date().addingTimeInterval(30)) } }
    try expect(stopped.state == "stopped" && stopped.controllable)
    try instances.setRunning(true,expected:stopped,expiresAt:Date().addingTimeInterval(30))
    let grouped=MySQLConnection(installationPath:group.installation,port:group.port,socket:group.socket)
    var groupReady: MySQLSnapshot?
    for _ in 0..<100 {
        if let value=try? platform.inspect(grouped,credentials:.init(user:"root",password:"generated-initial-'\\-secret")) { groupReady=value; break }
        try await Task.sleep(for:.milliseconds(100))
    }
    try expect(try require(groupReady).server.dataDirectory.hasPrefix(group.dataDirectory))
    let running=try instances.inspect(stopped)
    let registry=MySQLInstanceRegistry(platform:groupPlatform,makeStore:{ fixture.store })
    try await expectThrows { try await registry.prepare(.unregister,group:group) }
    try await expectThrows { try await registry.prepare(.refreshRegistration,group:group) }
    try instances.setRunning(false,expected:running,expiresAt:Date().addingTimeInterval(30))
    try expect(try instances.inspect(stopped).state == "stopped")
    let config=NativeMySQLConfiguration(recordsDirectory:fixture.store.directory)
    let original=try config.read(group.configuration)
    _ = try config.save(original.text.replacingOccurrences(of:"port=23317",with:"port=23318") + "# generated re-registration\n",expected:original)
    try expect(!instances.scan(inventory:inventory,toolIDs:["mysql"]).services.contains(where:{ $0.configurationPath == group.configuration }))
    let update=try await registry.prepare(.refreshRegistration,group:group)
    try expect(update.observation.port == 23318)
    try await registry.execute(update.id)
    let updated=try require(try groupPlatform.groups().first(where:{ $0.id == group.id }))
    try expect(updated.port == 23318)
    let refreshed=try require(try instances.scan(inventory:inventory,toolIDs:["mysql"]).services.first(where:{ $0.configurationPath == group.configuration }))
    try expect(refreshed.controllable && refreshed.state == "stopped")
    try instances.setRunning(true,expected:refreshed,expiresAt:Date().addingTimeInterval(30))
    let changedConnection=MySQLConnection(installationPath:group.installation,port:23318,socket:group.socket)
    var changedReady: MySQLSnapshot?
    for _ in 0..<100 {
        if let value=try? platform.inspect(changedConnection,credentials:.init(user:"root",password:"generated-initial-'\\-secret")) { changedReady=value; break }
        try await Task.sleep(for:.milliseconds(100))
    }
    try expect(try require(changedReady).server.port == 23318)
    try expect(changedReady?.server.uuid == groupReady?.server.uuid)
    try instances.setRunning(false,expected:try instances.inspect(refreshed),expiresAt:Date().addingTimeInterval(30))
    let rename=try await registry.prepare(.rename("Renamed generated instance"),group:updated)
    try await registry.execute(rename.id)
    let renamed=try require(try groupPlatform.groups().first(where:{ $0.id == group.id }))
    try expect(renamed.name == "Renamed generated instance")
    let staleConfig=try await registry.prepare(.refreshRegistration,group:renamed)
    let current=try config.read(group.configuration)
    _ = try config.save(current.text + "# changed after review\n",expected:current)
    try await expectThrows { try await registry.execute(staleConfig.id) }
    let rejected=try config.read(group.configuration)
    _ = try config.save(rejected.text + "!include /generated/other.cnf\n",expected:rejected)
    try await expectThrows { try await registry.prepare(.refreshRegistration,group:renamed) }
    for option in ["loose-bind-address=0.0.0.0", "bind-add=0.0.0.0", "loose-datadir=/generated/other", "plugin-load-add=generated.so"] {
        _ = try config.save(rejected.text + option + "\n",expected:try config.read(group.configuration))
        try await expectThrows { try await registry.prepare(.refreshRegistration,group:renamed) }
    }
    _ = try config.save(rejected.text.replacingOccurrences(of:"/slow.log",with:"/other-slow.log"),expected:try config.read(group.configuration))
    try await expectThrows { try await registry.prepare(.refreshRegistration,group:renamed) }
    _ = try config.save(rejected.text + "max-connections=50\n",expected:try config.read(group.configuration))
    _ = try await registry.prepare(.refreshRegistration,group:renamed)
    let detach=try await registry.prepare(.unregister,group:renamed)
    try await registry.execute(detach.id)
    try expect(try groupPlatform.groups().isEmpty)
    try expect(!instances.scan(inventory:inventory,toolIDs:["mysql"]).services.contains(where:{ $0.configurationPath == group.configuration }))
    try expect(fm.fileExists(atPath:group.dataDirectory + "/auto.cnf") && fm.fileExists(atPath:group.configuration))
    print("Actual MySQL generated engines: database creation, exact grants, password changes, SQL export, secure initialization, native lifecycle, running-registration refusal, config re-registration to port 23318, same-server UUID, rename, stale/include/alias/abbreviation/plugin/path rejection, supported tuning and unregister preserving all data passed. No existing servers were changed.")
    return true
    #else
    return false
    #endif
}
private func createFile(_ url: URL) throws -> URL {
    guard FileManager.default.createFile(atPath:url.path,contents:Data(),attributes:[.posixPermissions:0o600]) else { throw ShouError("fixture_failure","Cannot create generated output.") }; return url
}
