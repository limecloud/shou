import Foundation
import ShouCore
#if os(macOS)
import Darwin

/// Runtime instances are independent of the manager that installed their binary.
/// Only a complete, module-specific restart recipe makes an instance controllable.
public final class NativeDeveloperInstances: @unchecked Sendable {
    private struct ProcessIdentity: Equatable {
        let pid: Int32
        let parent: Int32
        let uid: UInt32
        let born: String
        let executable: String
        let arguments: [String]
        let directory: String
    }
    private struct Recipe: Codable, Equatable {
        let tool: String
        let executable: String
        let installation: String
        let version: String
        let arguments: [String]
        let configuration: String
        let pidFile: String?
        let log: String?
        let directory: String
        let identity: String
        var disabled: Bool? = nil
        var id: String { Digest.sha256(Data((tool + "\0" + executable + "\0" + configuration + "\0" + arguments.joined(separator: "\0")).utf8)) }
    }
    private let home: URL
    private let generatedRoot: URL?
    private let makeStore: @Sendable () throws -> any RecordStore
    private let mutex=NSLock()
    private var recipes=[String:Recipe]()
    private var spawned=[Int32:String]()
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, generatedRoot: URL? = nil,
                makeStore: @escaping @Sendable () throws -> any RecordStore = { try LocalRecordStore() }) {
        home=homeDirectory; self.generatedRoot=generatedRoot; self.makeStore=makeStore
    }
    public func scan(inventory: DeveloperToolInventory, excluding: Set<Int32> = [], toolIDs: Set<String>? = nil) throws -> DeveloperServiceSnapshot {
        mutex.lock(); defer { mutex.unlock() }
        let processes=try snapshot()
        let supervised=try supervisedPIDs()
        var issues=[String](), rows=[DeveloperService](), found=Set<String>()
        if let stored=try? makeStore().boundedRecords("developer-instance-recipes", limit: 256) {
            if stored.truncated { issues.append("Some service sources could not be verified.") }
            for record in stored.records where record.byteCount <= 65_536 {
                if let data=try? makeStore().read(record.collection, id: record.id), let recipe=try? Codec.decode(Recipe.self, from: data) {
                    recipes.removeValue(forKey:recipe.id)
                    if tryValid(recipe) { recipes[recipe.id]=recipe }
                }
            }
        }
        for process in processes where !excluding.contains(process.pid) {
            try Task.checkCancellation()
            guard let tool=tool(process.executable), toolIDs?.contains(tool) != false, !isWorker(process, all: processes) else { continue }
            let install=inventory.installations.first { $0.toolID == tool && (process.executable == NativeDeveloperInstancePaths.physical($0.path) || process.executable.hasPrefix(NativeDeveloperInstancePaths.physical($0.path) + "/")) }
            if let recipe=recipe(process, tool: tool, installation: install) {
                recipes[recipe.id]=recipe; found.insert(recipe.id)
                rows.append(row(recipe, process: process, issue: isSupervised(process, jobs: supervised) ? "developer_instance_supervisor_unverified" : nil))
            } else {
                let id=Digest.sha256(Data(("process:\(process.pid):" + process.born).utf8))
                rows.append(.init(id: id, toolID: tool, source: "Local instance", name: URL(fileURLWithPath: process.executable).lastPathComponent + ", PID \(process.pid)",
                    version: install?.version ?? "", installationPath: install?.path ?? URL(fileURLWithPath: process.executable).deletingLastPathComponent().path,
                    configurationPath: "", state: "running", registeredAtLogin: false, identity: id, definitionIdentity: id, issue: directoryWritable(process.directory) ? "developer_instance_directory_writable" : "developer_instance_recipe_missing", processID: process.pid))
            }
        }
        for recipe in recipes.values where toolIDs?.contains(recipe.tool) != false && !found.contains(recipe.id) && tryValid(recipe) {
            // Never report a stopped recipe when a live root with its executable
            // has unreadable/rewritten arguments that could be this same instance.
            let ambiguous=processes.contains { !excluding.contains($0.pid) && !isWorker($0, all: processes) && couldBeUnresolvedInstance($0,recipe:recipe) }
            rows.append(row(recipe, process: nil, issue: ambiguous ? "developer_instance_recipe_missing" : nil))
        }
        let counts=Dictionary(grouping: rows, by: \.id).mapValues(\.count)
        if counts.values.contains(where: { $0 > 1 }) { issues.append("Some service sources could not be verified.") }
        let unique=rows.map { row in
            guard counts[row.id, default: 0] > 1 else { return row }
            return DeveloperService(id: row.identity, toolID: row.toolID, source: row.source, name: row.name, version: row.version,
                installationPath: row.installationPath, configurationPath: row.configurationPath, state: row.state,
                registeredAtLogin: row.registeredAtLogin, identity: row.identity, definitionIdentity: row.definitionIdentity,
                issue: "developer_instance_ambiguous", logPath: row.logPath, errorLogPath: row.errorLogPath, processID: row.processID)
        }
        return .init(services: unique, issues: issues)
    }
    public func inspect(_ expected: DeveloperService) throws -> DeveloperService {
        mutex.lock(); defer { mutex.unlock() }
        return try inspectLocked(expected)
    }
    /// Called only after an explicit new, isolated MySQL instance was initialized.
    /// Registering a recipe does not start the server or grant future actions.
    public func registerMySQL(installation: String, configuration: String, dataDirectory: String, pidFile: String, errorLog: String, version: String) throws -> DeveloperService {
        mutex.lock(); defer { mutex.unlock() }
        _ = try verifyStoppedMySQLLocked(installation:installation,configuration:configuration,dataDirectory:dataDirectory)
        let executable=NativeDeveloperInstancePaths.physical(installation + "/bin/mysqld")
        let process=ProcessIdentity(pid:0,parent:1,uid:getuid(),born:"new",executable:executable,
            arguments:[executable,"--defaults-file=" + configuration,"--pid-file=" + pidFile,"--log-error=" + errorLog],directory:dataDirectory)
        guard let recipe=recipe(process,tool:"mysql",installation:nil,verifyPID:false) else { throw unavailable() }
        let store=try makeStore()
        try store.write("developer-instance-recipes",id:recipe.id.replacingOccurrences(of:"sha256:",with:""),data:Codec.encode(recipe))
        recipes[recipe.id]=recipe
        return row(recipe,process:nil,issue:nil)
    }
    /// A metadata operation must never claim that a live/ambiguous instance is
    /// stopped. Explicit other configurations can coexist with this instance.
    public func verifyStoppedMySQL(installation: String, configuration: String, dataDirectory: String, allowMissingDirectory: Bool = false) throws -> String {
        mutex.lock(); defer { mutex.unlock() }
        return try verifyStoppedMySQLLocked(installation:installation,configuration:configuration,dataDirectory:dataDirectory,allowMissingDirectory:allowMissingDirectory)
    }
    private func verifyStoppedMySQLLocked(installation: String, configuration: String, dataDirectory: String, allowMissingDirectory: Bool = false) throws -> String {
        let executable=NativeDeveloperInstancePaths.physical(installation + "/bin/mysqld")
        let program=try fileIdentity(executable,contents:false).0
        let directory: String
        var info=stat()
        if allowMissingDirectory, lstat(dataDirectory,&info) != 0, errno == ENOENT { directory="absent:" + dataDirectory }
        else { directory=try directoryIdentity(dataDirectory) }
        for item in try snapshot(requireReadableExecutable:executable) where item.executable == executable {
            if let other=MySQLInstanceRecipe.dataDirectory(arguments:item.arguments,requireNoDefaults:true),
               FileManager.default.fileExists(atPath:dataDirectory), other != NativeDeveloperInstancePaths.physical(dataDirectory) { continue }
            guard let explicit=NativeDeveloperInstanceRecipes.adapter(tool:"mysql")?.explicitConfiguration(in:item.arguments),
                  NativeDeveloperInstancePaths.physical(explicit) != NativeDeveloperInstancePaths.physical(configuration) else {
                throw ShouError("mysql_group_running","Stop this exact instance and refresh its status before changing its registration.")
            }
        }
        return program + "\0" + directory
    }
    public func forgetStoppedMySQL(installation: String, configuration: String, dataDirectory: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        _ = try verifyStoppedMySQLLocked(installation:installation,configuration:configuration,dataDirectory:dataDirectory,allowMissingDirectory:true)
        let store=try makeStore(), stored=try store.boundedRecords("developer-instance-recipes",limit:256)
        guard !stored.truncated else { throw unavailable() }
        for record in stored.records {
            guard let bytes=try store.read(record.collection,id:record.id), bytes.count <= 65_536,
                  var recipe=try? Codec.decode(Recipe.self,from:bytes) else { throw unavailable() }
            if recipe.tool == "mysql", recipe.configuration == configuration,
               NativeDeveloperInstancePaths.physical(recipe.executable) == NativeDeveloperInstancePaths.physical(installation + "/bin/mysqld") {
                recipe.disabled=true
                try store.write(record.collection,id:record.id,data:Codec.encode(recipe)); recipes.removeValue(forKey:recipe.id)
            }
        }
    }
    private func inspectLocked(_ expected: DeveloperService) throws -> DeveloperService {
        guard let recipe=recipes[expected.id], tryValid(recipe) else { throw unavailable() }
        let processes=try snapshot()
        let matching=processes.filter { !isWorker($0, all: processes) && matches($0, recipe: recipe) }
        guard matching.count <= 1 else { throw unavailable() }
        let ambiguous=matching.isEmpty && processes.contains { !isWorker($0, all: processes) && couldBeUnresolvedInstance($0,recipe:recipe) }
        let supervised=try supervisedPIDs()
        return row(recipe, process: matching.first, issue: matching.first.map { isSupervised($0, jobs: supervised) } == true ? "developer_instance_supervisor_unverified" : ambiguous ? "developer_instance_recipe_missing" : nil)
    }
    public func setRunning(_ running: Bool, expected: DeveloperService, expiresAt: Date) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard expected.controllable, try inspectLocked(expected) == expected, let recipe=recipes[expected.id], expiresAt > Date() else { throw unavailable() }
        // Persist the verified recovery recipe before stopping. It contains only
        // approved module arguments and paths, never a process environment/password.
        try makeStore().write("developer-instance-recipes", id: String(recipe.id.suffix(64)), data: Codec.encode(recipe))
        var stopping=[ProcessIdentity]()
        var startedPID: Int32?
        if running {
            startedPID=try spawn(recipe)
        } else {
            let all=try snapshot(), roots=all.filter { !isWorker($0, all: all) && matches($0, recipe: recipe) }
            guard roots.count == 1, let root=roots.first, process(root.pid) == root else { throw unavailable() }
            stopping=[root]
            var added=true
            while added {
                let children=all.filter { item in item.executable == root.executable && stopping.contains { $0.pid == item.parent } && !stopping.contains(item) }
                stopping += children; added = !children.isEmpty
            }
            // Do not broaden a root into name-based process kills or use SIGKILL.
            guard kill(root.pid, recipe.tool == "nginx" ? SIGQUIT : SIGTERM) == 0 else { throw unavailable() }
        }
        let deadline=min(expiresAt, Date().addingTimeInterval(15))
        let startedAt=Date()
        while Date() < deadline {
            let observed=try inspectLocked(expected)
            let childrenExited=try stopping.allSatisfy { try !stillAlive($0) }
            if observed.controllable && observed.state == (running ? "running" : "stopped") && childrenExited { return }
            if let startedPID, Date().timeIntervalSince(startedAt) > 0.5, observed.state != "running",
               kill(startedPID, 0) == -1 && errno == ESRCH {
                throw ShouError("developer_service_start_failed", "The instance exited during startup. Its output was retained in the startup log.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ShouError("developer_service_transition_timeout", "The instance did not reach the requested state. Inspect its log.")
    }
    private func row(_ recipe: Recipe, process: ProcessIdentity?, issue: String?) -> DeveloperService {
        .init(id: recipe.id, toolID: recipe.tool, source: "Local instance", name: URL(fileURLWithPath: recipe.executable).lastPathComponent,
            version: recipe.version, installationPath: recipe.installation, configurationPath: recipe.configuration,
            state: process == nil ? (issue == nil ? "stopped" : "unknown") : "running", registeredAtLogin: false,
            identity: Digest.sha256(Data((recipe.identity + "\0" + (process.map { "\($0.pid):\($0.born)" } ?? "stopped")).utf8)),
            definitionIdentity: recipe.identity, issue: issue, logPath: recipe.log, errorLogPath: startupLog(recipe), processID: process?.pid)
    }
    private func tool(_ executable: String) -> String? { NativeDeveloperInstanceRecipes.tool(executable: executable) }
    private func isWorker(_ process: ProcessIdentity, all: [ProcessIdentity]) -> Bool {
        process.arguments.first?.hasPrefix("nginx: worker") == true ||
        all.contains { $0.pid == process.parent && $0.executable == process.executable }
    }
    private func supervisedPIDs() throws -> Set<Int32> {
        if generatedRoot != nil { return [] }
        let observed=try NativeStartupCommand.run(["list"], deadline: .now.advanced(by: .seconds(3)))
        guard observed.status == 0 else { throw unavailable() }
        return Set(observed.output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.flatMap { Int32($0) }
        })
    }
    private func isSupervised(_ process: ProcessIdentity, jobs: Set<Int32>) -> Bool {
        generatedRoot == nil && (jobs.contains(process.pid) || process.parent != 1 && !(process.parent == getpid() && spawned[process.pid] == process.born))
    }
    private func stillAlive(_ expected: ProcessIdentity) throws -> Bool {
        var info=proc_bsdinfo(); let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return info.pbi_uid == expected.uid && "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == expected.born && info.pbi_status != 5
        }
        if kill(expected.pid, 0) == -1 && errno == ESRCH { return false }
        throw unavailable()
    }
    private func recipe(_ process: ProcessIdentity, tool: String, installation: DeveloperToolInstallation?, verifyPID: Bool = true) -> Recipe? {
        guard process.uid == getuid() else { return nil }
        let context=DeveloperInstanceRecipeContext(home: home, pid: process.pid, executable: process.executable,
            arguments: process.arguments, directory: process.directory, version: installation?.version,
            read: { path in try self.fileIdentity(path, contents: true).1 ?? Data() })
        guard let resolved=NativeDeveloperInstanceRecipes.adapter(tool: tool)?.resolve(context) else { return nil }
        let arguments=resolved.arguments, configuration=resolved.path, pidFile=resolved.pidFile, log=resolved.log
        guard configuration.hasPrefix("/"), arguments.count <= 64,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }),
              let program=try? fileIdentity(process.executable, contents: false).0,
              let config=try? fileIdentity(configuration, contents: true).0,
              let directory=try? directoryIdentity(process.directory) else { return nil }
        if verifyPID, let pidFile, let data=try? fileIdentity(pidFile, contents: true).1, let text=String(data: data, encoding: .utf8),
           let pid=Int32(text.split(whereSeparator: \.isWhitespace).first ?? ""), pid != process.pid { return nil }
        let identity=Digest.sha256(Data((program + "\0" + config + "\0" + directory + "\0" + arguments.joined(separator: "\0")).utf8))
        let parent=URL(fileURLWithPath: process.executable).deletingLastPathComponent().deletingLastPathComponent()
        return Recipe(tool: tool, executable: process.executable, installation: installation?.path ?? parent.path,
            version: installation?.version ?? (parent.path.contains("/Cellar/") ? parent.lastPathComponent : ""), arguments: arguments,
            configuration: configuration, pidFile: pidFile, log: log.flatMap { $0.hasPrefix("/") ? $0 : nil }, directory: process.directory, identity: identity)
    }
    private func matches(_ process: ProcessIdentity, recipe: Recipe) -> Bool {
        guard process.executable == recipe.executable, let current=self.recipe(process, tool: recipe.tool, installation: nil) else { return false }
        return current.id == recipe.id && current.identity == recipe.identity
    }
    private func couldBeUnresolvedInstance(_ process: ProcessIdentity, recipe: Recipe) -> Bool {
        guard process.executable == recipe.executable, self.recipe(process,tool:recipe.tool,installation:nil) == nil else { return false }
        if recipe.tool == "mysql",
           let other=MySQLInstanceRecipe.dataDirectory(arguments:process.arguments,requireNoDefaults:true),
           let current=MySQLInstanceRecipe.dataDirectory(arguments:[recipe.executable]+recipe.arguments,requireNoDefaults:false,configuration:(try? fileIdentity(recipe.configuration,contents:true).1).flatMap { $0 }.flatMap { String(data:$0,encoding:.utf8) }), other != current { return false }
        if let hint=NativeDeveloperInstanceRecipes.adapter(tool:recipe.tool)?.explicitConfiguration(in:process.arguments),
           let resolved=realpath(hint,nil) {
            defer { free(resolved) }
            // An unrelated instance with an explicit different configuration
            // cannot make this stopped recipe look running/ambiguous.
            if String(cString:resolved) != NativeDeveloperInstancePaths.physical(recipe.configuration) { return false }
        }
        return true
    }
    private func tryValid(_ recipe: Recipe) -> Bool {
        guard recipe.disabled != true, ["nginx","mysql","redis","postgresql"].contains(recipe.tool), tool(recipe.executable) == recipe.tool,
              recipe.arguments.count <= 64, recipe.arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else { return false }
        let synthetic=ProcessIdentity(pid: 0, parent: 1, uid: getuid(), born: "stored", executable: recipe.executable, arguments: [recipe.executable] + recipe.arguments, directory: recipe.directory)
        guard let parsed=self.recipe(synthetic, tool: recipe.tool, installation: nil, verifyPID: false) else { return false }
        return parsed.id == recipe.id && parsed.identity == recipe.identity && parsed.configuration == recipe.configuration && parsed.pidFile == recipe.pidFile && parsed.log == recipe.log
    }
    private func directoryIdentity(_ path: String) throws -> String {
        // Identity checks need traversal and metadata, never a directory listing.
        let descriptor=try SecurePaths.directory(path, readFinalDirectory: false); defer { close(descriptor) }
        var info=stat()
        guard fstat(descriptor, &info) == 0, [0,getuid()].contains(info.st_uid), info.st_mode & 0o022 == 0 else { throw unavailable() }
        return path + "\0\(info.st_dev):\(info.st_ino)"
    }
    private func directoryWritable(_ path: String) -> Bool {
        guard let descriptor=try? SecurePaths.directory(path, readFinalDirectory: false) else { return false }; defer { close(descriptor) }
        var info=stat()
        return fstat(descriptor,&info) == 0 && info.st_mode & 0o022 != 0
    }
    private func fileIdentity(_ path: String, contents: Bool) throws -> (String,Data?) {
        let physical=NativeDeveloperInstancePaths.physical(path)
        if let generatedRoot { guard physical.hasPrefix(NativeDeveloperInstancePaths.physical(generatedRoot.path) + "/") else { throw unavailable() } }
        let (parent,name)=try SecurePaths.parent(physical, cancelled: { false }); defer { close(parent) }
        let descriptor=openat(parent,name,(contents ? O_RDONLY : O_EVTONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw unavailable() }; defer { close(descriptor) }
        var info=stat()
        guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              [0,getuid()].contains(info.st_uid), info.st_mode & 0o022 == 0 else { throw unavailable() }
        let identity="\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        guard contents else { return (physical + "\0" + identity,nil) }
        guard info.st_size >= 0, info.st_size <= 262_144 else { throw unavailable() }
        var bytes=[UInt8](repeating:0,count:Int(info.st_size)), offset=0
        while offset < bytes.count {
            let remaining=bytes.count-offset
            let count=bytes.withUnsafeMutableBytes { Darwin.read(descriptor,$0.baseAddress!.advanced(by: offset),remaining) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw unavailable() }; offset += count
        }
        var after=stat()
        guard fstat(descriptor, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
              after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw unavailable() }
        let data=Data(bytes)
        return (physical + "\0" + identity + "\0" + Digest.sha256(data),data)
    }
    private func snapshot(requireReadableExecutable: String? = nil) throws -> [ProcessIdentity] {
        let required=proc_listpids(UInt32(PROC_ALL_PIDS),0,nil,0)
        guard required > 0, required < 8192 * 4 else { throw unavailable() }
        var pids=[Int32](repeating:0,count:Int(required)/4+128)
        let count=pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS),0,$0.baseAddress,Int32($0.count)) }
        guard count >= 0, Int(count) < pids.count*4 else { throw unavailable() }
        return try pids.prefix(Int(count)/4).compactMap { pid in
            guard pid > 0 else { return nil }
            if let item=process(pid) { return item }
            if let expected=requireReadableExecutable {
                var path=[UInt8](repeating:0,count:4096)
                let length=proc_pidpath(pid,&path,4096)
                if length > 0, String(decoding:path.prefix(Int(length)).prefix(while:{ $0 != 0 }),as:UTF8.self) == expected {
                    var info=proc_bsdinfo()
                    if proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                       info.pbi_uid == getuid(), info.pbi_status != 5 { throw unavailable() }
                }
            }
            return nil
        }
    }
    private func process(_ pid: Int32) -> ProcessIdentity? {
        var info=proc_bsdinfo(); let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size) == size, info.pbi_uid == getuid() else { return nil }
        var path=[UInt8](repeating:0,count:4096)
        let count=proc_pidpath(pid,&path,4096)
        guard count > 0 else { return nil }
        let executable=String(decoding:path.prefix(Int(count)).prefix(while: { $0 != 0 }),as:UTF8.self)
        if let generatedRoot, !executable.hasPrefix(NativeDeveloperInstancePaths.physical(generatedRoot.path) + "/") { return nil }
        // Only inspect service executables and their direct supervisor shapes.
        guard tool(executable) != nil || ["bash","sh"].contains(URL(fileURLWithPath: executable).lastPathComponent) else { return nil }
        var mib:[Int32]=[CTL_KERN,KERN_PROCARGS2,pid], length=262_144, bytes=[UInt8](repeating:0,count:262_144)
        guard sysctl(&mib,3,&bytes,&length,nil,0) == 0, length > 4 else { return nil }
        let argc=bytes.withUnsafeBytes { $0.loadUnaligned(as:Int32.self) }
        guard (1...64).contains(argc) else { return nil }
        var offset=4
        while offset < length && bytes[offset] != 0 { offset += 1 }
        while offset < length && bytes[offset] == 0 { offset += 1 }
        var arguments=[String]()
        for _ in 0..<argc {
            guard offset < length else { break }
            let start=offset
            while offset < length && bytes[offset] != 0 { offset += 1 }
            arguments.append(String(decoding: bytes[start..<offset],as:UTF8.self)); offset += 1
        }
        var after=proc_bsdinfo()
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,size) == size,
              after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec, after.pbi_uid == info.pbi_uid else { return nil }
        var paths=proc_vnodepathinfo()
        let pathsSize=Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, pathsSize) == pathsSize else { return nil }
        let directory=withUnsafeBytes(of: paths.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard directory.hasPrefix("/") else { return nil }
        return .init(pid:pid,parent:Int32(info.pbi_ppid),uid:info.pbi_uid,born:"\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",executable:executable,arguments:arguments,directory:directory)
    }
    private var outputDirectory: URL { (generatedRoot ?? LocalRecordStore.defaultDirectory).appendingPathComponent("developer-instance-output", isDirectory: true) }
    private func startupLog(_ recipe: Recipe) -> String { outputDirectory.appendingPathComponent(recipe.id + ".log").path }
    private func openStartupLog(_ recipe: Recipe) throws -> Int32 {
        if generatedRoot == nil { _ = try makeStore() }
        let parent=try SecurePaths.directory(outputDirectory.deletingLastPathComponent().path); defer { close(parent) }
        if mkdirat(parent, "developer-instance-output", 0o700) != 0 && errno != EEXIST { throw unavailable() }
        let directory=openat(parent, "developer-instance-output", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw unavailable() }; defer { close(directory) }
        var info=stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw unavailable() }
        let descriptor=openat(directory, recipe.id + ".log", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw unavailable() }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              ftruncate(descriptor, 0) == 0 else { close(descriptor); throw unavailable() }
        return descriptor
    }
    private func spawn(_ recipe: Recipe) throws -> Int32 {
        guard tryValid(recipe) else { throw unavailable() }
        let output=try openStartupLog(recipe); defer { close(output) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw unavailable() }; defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw unavailable() }; defer { posix_spawnattr_destroy(&attributes) }
        // A cooperative Swift worker can have blocked signals. A daemon must
        // receive its own normal signal mask rather than inherit that thread.
        var mask=sigset_t(), defaults=sigset_t()
        sigemptyset(&mask); sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
        guard posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0, posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setpgroup(&attributes,0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions,recipe.directory) == 0 else { throw unavailable() }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, output) == 0 else { throw unavailable() }
        let argv=([recipe.executable]+recipe.arguments).map { strdup($0) } + [nil]
        let env=["HOME":home.path,"PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8","LC_ALL":"en_US.UTF-8"]
        let envp=env.map { strdup($0.key+"="+$0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid:Int32=0
        let result=argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { environment in
            posix_spawn(&pid,recipe.executable,&actions,&attributes,args.baseAddress!,environment.baseAddress!)
        } }
        guard result == 0 else { throw ShouError("developer_service_spawn_failed","The same instance could not be started.") }
        let child=pid
        var info=proc_bsdinfo(); let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, size) == size { spawned[child]="\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" }
        DispatchQueue.global(qos: .utility).async { var status:Int32=0; while waitpid(child,&status,0) < 0 && errno == EINTR {} }
        return child
    }
    private func unavailable() -> ShouError { ShouError("developer_instance_unverified","The exact instance and restart recipe could not be verified.") }
}
#endif
