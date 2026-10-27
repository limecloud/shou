import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct NativeMySQLInstances: MySQLInstanceRegistryOperating, Sendable {
    private let base: URL
    private let records: URL
    public init(baseDirectory: URL? = nil, recordsDirectory: URL = LocalRecordStore.defaultDirectory) {
        base=baseDirectory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ShouMySQL")
        records=recordsDirectory
    }
    public func groups() throws -> [MySQLInstanceGroup] {
        let store=try LocalRecordStore(directory:records)
        return try store.boundedRecords("mysql-instance-groups",limit:128).records.compactMap { record in
            guard record.byteCount <= 65_536, let data=try store.read(record.collection,id:record.id) else { return nil }
            guard let value=try? Codec.decode(MySQLInstanceGroup.self,from:data), value.registered != false else { return nil }
            return value
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func inspectGroup(_ group: MySQLInstanceGroup, for change: MySQLGroupChange) throws -> MySQLGroupObservation {
        let store=try LocalRecordStore(directory:records)
        guard let bytes=try store.read("mysql-instance-groups",id:group.id),
              try Codec.decode(MySQLInstanceGroup.self,from:bytes) == group, group.registered != false else { throw changed() }
        let removing: Bool
        if case .unregister=change { removing=true } else { removing=false }
        let document: MySQLConfigurationDocument?
        var metadata=stat()
        if removing, lstat(group.configuration,&metadata) != 0, errno == ENOENT { document=nil }
        else { document=try NativeMySQLConfiguration(recordsDirectory:records).read(group.configuration) }
        let instances=NativeDeveloperInstances(makeStore:{ try LocalRecordStore(directory:records) })
        let source=try instances.verifyStoppedMySQL(installation:group.installation,configuration:group.configuration,dataDirectory:group.dataDirectory,allowMissingDirectory:removing)
        var port=group.port, socket=group.socket
        if case .refreshRegistration=change {
            guard let document else { throw changed() }
            let options=try Self.registrationOptions(document.text)
            let root=URL(fileURLWithPath:group.configuration).deletingLastPathComponent()
            guard options["datadir"] == group.dataDirectory,
                  options["pid-file"] == root.appendingPathComponent("mysql.pid").path,
                  options["log-error"] == root.appendingPathComponent("error.log").path,
                  options["slow-query-log-file"] == root.appendingPathComponent("slow.log").path,
                  options["bind-address"] == "127.0.0.1", options["mysqlx"]?.uppercased() == "OFF",
                  let number=options["port"].flatMap(Int.init), (1024...65535).contains(number),
                  let path=options["socket"], path == root.appendingPathComponent("mysql.sock").path else { throw Self.unsupported() }
            port=number; socket=path
        }
        let configuration=try document.map { try Codec.encode($0.identity) + Data($0.text.utf8) } ?? Data("absent-configuration".utf8)
        return .init(group:group,revision:Digest.sha256(bytes + Data(source.utf8) + configuration),port:port,socket:socket)
    }
    public func applyGroup(_ change: MySQLGroupChange, expected: MySQLGroupObservation) throws {
        guard try inspectGroup(expected.group,for:change) == expected else { throw changed() }
        let store=try LocalRecordStore(directory:records)
        var group=expected.group
        switch change {
        case .rename(let name): group.name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        case .refreshRegistration:
            let root=URL(fileURLWithPath:group.configuration).deletingLastPathComponent()
            _ = try NativeDeveloperInstances(makeStore:{ try LocalRecordStore(directory:records) }).registerMySQL(
                installation:group.installation,configuration:group.configuration,dataDirectory:group.dataDirectory,
                pidFile:root.appendingPathComponent("mysql.pid").path,errorLog:root.appendingPathComponent("error.log").path,version:group.version)
            group.port=expected.port; group.socket=expected.socket
        case .unregister:
            // Disable the recovery recipe first. If the following metadata save
            // fails, the group stays visible for inspection without a start recipe.
            try NativeDeveloperInstances(makeStore:{ try LocalRecordStore(directory:records) }).forgetStoppedMySQL(
                installation:group.installation,configuration:group.configuration,dataDirectory:group.dataDirectory)
            group.registered=false
        }
        let bytes=try Codec.encode(group)
        try store.write("mysql-instance-groups",id:group.id,data:bytes)
        guard try store.read("mysql-instance-groups",id:group.id) == bytes else { throw changed() }
    }
    static func registrationOptions(_ text: String) throws -> [String:String] {
        // MySQL accepts loose/skip aliases and abbreviated names. Keep this
        // generated-instance path closed so another option cannot override the
        // exact connection and data paths shown in the registration review.
        let supported: Set<String> = ["bind-address","port","mysqlx","socket","datadir","pid-file","log-error","slow-query-log-file",
                                      "slow-query-log","long-query-time","max-connections","innodb-buffer-pool-size",
                                      "character-set-server","collation-server","sql-mode","default-time-zone"]
        var result=[String:String](), section=""
        for raw in text.split(whereSeparator:\.isNewline) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            guard !line.hasPrefix("!") else { throw Self.unsupported() }
            if line.hasPrefix("[") {
                guard line == "[mysqld]", section.isEmpty else { throw Self.unsupported() }
                section="mysqld"; continue
            }
            guard section == "mysqld" else { throw Self.unsupported() }
            let pair=line.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            guard pair.count == 2 else { throw Self.unsupported() }
            let key=pair[0].trimmingCharacters(in:.whitespaces).replacingOccurrences(of:"_",with:"-")
            let value=pair[1].trimmingCharacters(in:.whitespaces)
            guard supported.contains(key), result[key] == nil, !value.contains("\\"), !value.contains("#"), !value.contains(";") else { throw Self.unsupported() }
            result[key]=value.trimmingCharacters(in:CharacterSet(charactersIn:"\"'"))
        }
        return result
    }
    private func changed() -> ShouError { ShouError("mysql_group_changed","The instance registration changed. Refresh and review it again.") }
    private static func unsupported() -> ShouError { ShouError("mysql_group_config_unsupported","Registration requires one explicit mysqld section, loopback binding, and this instance's original data, PID, log and socket paths. Review the configuration before continuing.") }
    public func create(name: String, installation: String, version: String, port: Int, password: String) throws -> MySQLInstanceGroup {
        guard !name.isEmpty, name.utf8.count <= 128, (1024...65535).contains(port), !password.isEmpty,
              password.utf8.count <= 1024, !password.contains(where:{ $0 == "\0" || $0 == "\n" || $0 == "\r" }) else { throw MySQLAdministrationError.invalid() }
        let fm=FileManager.default
        try fm.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let parent=try SecurePaths.directory(base.path); defer { close(parent) }
        var info=stat()
        guard fstat(parent,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw unavailable() }
        let id=String(UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8)).lowercased()
        let root=base.appendingPathComponent(id), socket=root.appendingPathComponent("mysql.sock").path
        guard socket.utf8.count < 100, mkdirat(parent,id,0o700) == 0 else { throw unavailable() }
        let data=root.appendingPathComponent("data").path, config=root.appendingPathComponent("my.cnf").path
        let pid=root.appendingPathComponent("mysql.pid").path, log=root.appendingPathComponent("error.log").path
        let executable=NativeDeveloperInstancePaths.physical(installation + "/bin/mysqld")
        let source=try programIdentity(executable)
        let group=MySQLInstanceGroup(id:id,name:name,installation:installation,configuration:config,dataDirectory:data,socket:socket,port:port,version:version)
        let store=try LocalRecordStore(directory:records), lease=try store.lock(); defer { lease.release() }
        try store.write("mysql-instance-intents",id:id,data:Codec.encode(group))
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") + "\"" }
        let sourceText="[mysqld]\nbind-address=127.0.0.1\nport=\(port)\nmysqlx=OFF\nsocket=\(quoted(socket))\ndatadir=\(quoted(data))\npid-file=\(quoted(pid))\nlog-error=\(quoted(log))\nslow-query-log-file=\(quoted(root.appendingPathComponent("slow.log").path))\n"
        try writePrivate(Data(sourceText.utf8),path:config)
        let sql="SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';\nALTER USER 'root'@'localhost' IDENTIFIED BY '" + password.replacingOccurrences(of:"'",with:"''") + "';\n"
        do {
            // The init SQL is an unlinked private stdin file owned by the
            // process runner; no named password file remains after a crash.
            _ = try NativeManagedToolProcess(homeDirectory:root).run(executable,arguments:["--defaults-file=" + config,"--initialize","--init-file=/dev/stdin"],timeout:90,standardInput:Data(sql.utf8))
            guard try programIdentity(executable) == source else { throw unavailable() }
            _ = try NativeDeveloperInstances(makeStore:{ try LocalRecordStore(directory:records) }).registerMySQL(installation:installation,configuration:config,dataDirectory:data,pidFile:pid,errorLog:log,version:version)
            try store.write("mysql-instance-groups",id:id,data:Codec.encode(group))
            return group
        } catch {
            // Initialization failure never removes/reuses the data directory.
            try? store.write("mysql-instance-failures",id:id,data:JSONSerialization.data(withJSONObject:["state":"needs_verification","path":root.path]))
            throw ShouError("mysql_initialization_failed","The new MySQL instance could not be initialized. Its files remain for inspection; existing databases were not changed.",details:["path":root.path])
        }
    }
    private func programIdentity(_ path: String) throws -> FileEntry {
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_EVTONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw unavailable() }; defer { close(fd) }
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0, info.st_mode & 0o022 == 0, [0,getuid()].contains(info.st_uid) else { throw unavailable() }
        return SecurePaths.entry(info,path:path)
    }
    private func writePrivate(_ bytes: Data, path: String) throws {
        let (parent,name)=try SecurePaths.parent(path); defer { close(parent) }
        let fd=openat(parent,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600); guard fd >= 0 else { throw unavailable() }; defer { close(fd) }
        try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:bytes)
        guard fsync(fd) == 0 else { throw unavailable() }
    }
    private func unavailable() -> ShouError { ShouError("mysql_instance_unavailable","The new MySQL instance could not be initialized. Its files remain for inspection; existing databases were not changed.") }
}
#endif
