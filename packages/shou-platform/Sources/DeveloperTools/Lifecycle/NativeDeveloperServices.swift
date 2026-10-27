import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativeDeveloperServices: DeveloperServiceOperating {
    private let home: URL
    private let generatedExecutable: URL?
    private let generatedServiceExecutable: URL?
    #if os(macOS)
    private let instances: NativeDeveloperInstances
    #endif
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, generatedExecutable: URL? = nil, generatedServiceExecutable: URL? = nil) {
        home=homeDirectory; self.generatedExecutable=generatedExecutable; self.generatedServiceExecutable=generatedServiceExecutable
        #if os(macOS)
        instances=NativeDeveloperInstances(homeDirectory: homeDirectory, generatedRoot: generatedExecutable == nil ? nil : homeDirectory)
        #endif
    }
    public func scan(catalog: DeveloperToolCatalog, inventory: DeveloperToolInventory) throws -> DeveloperServiceSnapshot {
        #if os(macOS)
        var rows=[DeveloperService](), issues=[String]()
        do {
            let managed=try managedSnapshot(catalog: catalog, inventory: inventory)
            rows=managed.services; issues=managed.issues
        } catch {
            if generatedExecutable != nil { throw error }
            if (error as? ShouError)?.code != "tool_not_installed" { issues.append("Some service sources could not be verified.") }
        }
        let local=try instances.scan(inventory: inventory, excluding: Set(rows.compactMap(\.processID)), toolIDs: Set(catalog.tools.map(\.id)))
        return .init(services: rows + local.services, issues: Array(Set(issues + local.issues)))
        #else
        throw unavailable()
        #endif
    }
    #if os(macOS)
    private func managedSnapshot(catalog: DeveloperToolCatalog, inventory: DeveloperToolInventory) throws -> DeveloperServiceSnapshot {
        guard catalog.tools.contains(where: { tool in inventory.installations.contains { $0.toolID == tool.id && $0.source == "Homebrew" } }) else { return .init(services: [], issues: []) }
        let adapter=manager()
        let executable: String
        do { executable=try adapter.manager().0 } catch {
            if (error as? ShouError)?.code == "tool_not_installed" { return .init(services: [], issues: []) }
            throw error
        }
        let data=try process(executable, ["services", "list", "--json"])
        guard let items=try JSONSerialization.jsonObject(with: data) as? [[String:Any]], items.count <= 512 else { throw unavailable() }
        var rows=[DeveloperService](), issues=[String]()
        for item in items {
            try Task.checkCancellation()
            guard let name=item["name"] as? String, DeveloperToolPackage(provider: "homebrew", kind: "formula", token: name).valid,
                  let tool=catalog.tools.first(where: { $0.packages.contains { $0.provider == "homebrew" && $0.token == name } }),
                  inventory.installations.contains(where: { $0.toolID == tool.id && $0.source == "Homebrew" }) else { continue }
            do {
                let data=try process(executable, ["services", "info", name, "--json"])
                guard let details=try JSONSerialization.jsonObject(with: data) as? [[String:Any]], details.count == 1,
                      details[0]["name"] as? String == name else { throw unavailable() }
                rows.append(try observe(details[0], toolID: tool.id, token: name))
            }
            catch {
                if generatedExecutable != nil { throw error }
                issues.append("Some service sources could not be verified.")
                for copy in inventory.installations where copy.toolID == tool.id && copy.source == "Homebrew" && copy.path.contains("/Cellar/" + name + "/") {
                    rows.append(.init(id: Digest.sha256(Data(("unverified-homebrew:" + name + ":" + copy.path).utf8)), toolID: tool.id, source: "Homebrew", name: name,
                                      version: copy.version ?? "", installationPath: copy.path, configurationPath: "", state: "unknown", registeredAtLogin: false,
                                      identity: Digest.sha256(Data(copy.id.utf8)), definitionIdentity: "unverified", issue: "developer_service_unavailable"))
                }
            }
        }
        return .init(services: rows, issues: Array(Set(issues)))
    }
    #endif
    public func inspect(_ expected: DeveloperService) throws -> DeveloperService {
        #if os(macOS)
        if expected.source == "Local instance" { return try instances.inspect(expected) }
        guard expected.source == "Homebrew", DeveloperToolPackage(provider: "homebrew", kind: "formula", token: expected.name).valid else { throw unavailable() }
        let (executable,_)=try manager().manager()
        let data=try process(executable, ["services", "info", expected.name, "--json"])
        guard let rows=try JSONSerialization.jsonObject(with: data) as? [[String:Any]], rows.count == 1,
              rows[0]["name"] as? String == expected.name else { throw unavailable() }
        return try observe(rows[0], toolID: expected.toolID, token: expected.name)
        #else
        throw unavailable()
        #endif
    }
    public func setRunning(_ running: Bool, expected: DeveloperService, expiresAt: Date) throws {
        #if os(macOS)
        if expected.source == "Local instance" { return try instances.setRunning(running, expected: expected, expiresAt: expiresAt) }
        guard expected.controllable, try inspect(expected) == expected, expiresAt > Date() else { throw unavailable() }
        // Unload/load the verified launchd job without changing its persistent plist
        // or disabled override. `brew services kill` refuses KeepAlive jobs with exit 0.
        let label="homebrew.mxcl." + expected.name
        let executable=generatedServiceExecutable?.path ?? "/bin/launchctl"
        if let generatedServiceExecutable {
            guard generatedExecutable != nil, generatedServiceExecutable.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/") else { throw unavailable() }
        }
        let job=try loadedJob(expected)
        let domain=job?.domain ?? "gui/\(getuid())"
        let previousPID=job?.pid
        let previousProcess=previousPID.flatMap { processBinding($0, installation: expected.installationPath) }
        if !running && generatedServiceExecutable == nil {
            guard job != nil, previousPID != nil, previousProcess != nil else { throw unavailable() }
        }
        let command: [String]
        if running {
            command=job == nil ? ["bootstrap", domain, expected.configurationPath] : ["kickstart", domain + "/" + label]
        } else { command=["bootout", domain + "/" + label] }
        _ = try process(executable, command, timeout: 15)
        let deadline=min(expiresAt, Date().addingTimeInterval(15))
        while Date() < deadline {
            let state: String
            if generatedServiceExecutable != nil { state=try inspect(expected).state }
            else {
                let result=try NativeStartupCommand.run(["print", domain + "/" + label], deadline: .now.advanced(by: .seconds(2)))
                state=LaunchctlStateParser.runtimeState(status: result.status, output: result.output)
            }
            let oldExited: Bool
            if !running, let previousPID, let previousProcess { oldExited=try processExited(previousPID, binding: previousProcess) }
            else { oldExited=true }
            if running ? state == "running" : ["stopped", "not_loaded"].contains(state) && oldExited { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ShouError("developer_service_transition_timeout", "The service did not reach the requested state. Inspect its log.")
        #else
        throw unavailable()
        #endif
    }
    public func readLog(_ expected: DeveloperService, errorLog: Bool = false) throws -> String {
        #if os(macOS)
        let current=try inspect(expected)
        guard current.definitionIdentity == expected.definitionIdentity,
              let path=errorLog ? current.errorLogPath : current.logPath else { throw unavailable() }
        let (parent,name)=try SecurePaths.parent(path, cancelled: { false }); defer { close(parent) }
        let descriptor=openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ShouError("developer_service_log_unavailable", "The service log cannot be read.") }
        defer { close(descriptor) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              [0,getuid()].contains(metadata.st_uid), metadata.st_size >= 0 else { throw unavailable() }
        let offset=max(0, metadata.st_size - 65_536)
        guard lseek(descriptor, offset, SEEK_SET) >= 0 else { throw unavailable() }
        var bytes=[UInt8](repeating: 0, count: 65_536)
        let count=Darwin.read(descriptor, &bytes, bytes.count)
        guard count >= 0 else { throw unavailable() }
        var text=String(decoding: bytes.prefix(count), as: UTF8.self)
        if offset > 0, let end=text.firstIndex(of: "\n") { text=String(text[text.index(after: end)...]) }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
        #else
        throw unavailable()
        #endif
    }
    #if os(macOS)
    private struct LoadedJob { let domain: String; let pid: Int32? }
    private func loadedJob(_ expected: DeveloperService) throws -> LoadedJob? {
        if generatedServiceExecutable != nil { return nil }
        let label="homebrew.mxcl." + expected.name
        for domain in ["gui/\(getuid())", "user/\(getuid())"] {
            let result=try NativeStartupCommand.run(["print", domain + "/" + label], deadline: .now.advanced(by: .seconds(3)))
            let state=LaunchctlStateParser.runtimeState(status: result.status, output: result.output)
            if state == "not_loaded" { continue }
            guard result.status == 0 else { throw unavailable() }
            // The loaded definition can differ from the plist currently on disk.
            // Bind both before unloading it, rather than trusting the label alone.
            func field(_ key: String) -> String? {
                result.output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("\t" + key + " = ") }
                    .map { String($0.dropFirst(key.count + 4)).trimmingCharacters(in: .whitespaces) }
            }
            guard let path=field("path"), physicalPath(path) == physicalPath(expected.configurationPath) else { throw unavailable() }
            let (parent,name)=try SecurePaths.parent(expected.configurationPath, cancelled: { false }); defer { close(parent) }
            let bytes=try NativeDefinitionFiles.bytes(directory: parent, name: name, path: expected.configurationPath, deadline: .now.advanced(by: .seconds(3)), cancelled: { false })
            guard let definition=try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String:Any],
                  let arguments=definition["ProgramArguments"] as? [String], let program=arguments.first,
                  let loadedProgram=field("program"), physicalPath(loadedProgram) == physicalPath(program) else { throw unavailable() }
            let lines=result.output.components(separatedBy: "\n")
            guard let start=lines.firstIndex(of: "\targuments = {"),
                  let end=lines[(start+1)...].firstIndex(of: "\t}"),
                  lines[(start+1)..<end].allSatisfy({ $0.hasPrefix("\t\t") }),
                  lines[(start+1)..<end].map({ String($0.dropFirst(2)) }) == arguments else { throw unavailable() }
            return LoadedJob(domain: domain, pid: field("pid").flatMap(Int32.init))
        }
        return nil
    }
    private func manager() -> NativeDeveloperTools {
        if let generatedExecutable { return .init(homeDirectory: home, generatedExecutable: generatedExecutable) }
        return .init(homeDirectory: home)
    }
    private func process(_ path: String, _ arguments: [String], timeout: Double = 30) throws -> Data {
        try NativeManagedToolProcess(homeDirectory: home).run(path, arguments: arguments, timeout: timeout, observeCancellation: false)
    }
    private func observe(_ row: [String:Any], toolID: String, token: String) throws -> DeveloperService {
        let adapter=manager(), package=DeveloperToolPackage(provider: "homebrew", kind: "formula", token: token)
        let inspection=try adapter.inspect(package)
        let (_,managerIdentity)=try adapter.manager()
        guard inspection.sourceIdentity == managerIdentity, inspection.installedVersions.count == 1,
              let running=row["running"] as? Bool, let registered=row["registered"] as? Bool,
              let file=row["file"] as? String, file.hasPrefix("/"), file.utf8.count <= 4096 else { throw unavailable() }
        let resolved=URL(fileURLWithPath: physicalPath(file))
        let prefix=generatedExecutable == nil ? (managerIdentity.hasPrefix("/opt/homebrew/") ? "/opt/homebrew" : "/usr/local") : home.path
        let installation=prefix + "/Cellar/" + token + "/" + inspection.installedVersions[0]
        let registration=home.appendingPathComponent("Library/LaunchAgents/homebrew.mxcl." + token + ".plist").path
        guard resolved.path.hasPrefix(installation + "/") || resolved.path == registration else { throw unavailable() }
        let (parent,name)=try SecurePaths.parent(resolved.path, cancelled: { false }); defer { close(parent) }
        let bytes=try NativeDefinitionFiles.bytes(directory: parent, name: name, path: resolved.path, deadline: .now.advanced(by: .seconds(3)), cancelled: { false })
        if resolved.path == registration {
            let packaged=installation + "/homebrew.mxcl." + token + ".plist"
            let (directory,filename)=try SecurePaths.parent(packaged, cancelled: { false }); defer { close(directory) }
            guard try NativeDefinitionFiles.bytes(directory: directory, name: filename, path: packaged, deadline: .now.advanced(by: .seconds(3)), cancelled: { false }) == bytes else { throw unavailable() }
        }
        guard let plist=try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String:Any],
              let arguments=plist["ProgramArguments"] as? [String], let executable=arguments.first,
              physicalPath(executable).hasPrefix(installation + "/") else { throw unavailable() }
        let owner=row["user"] as? String
        let status=row["status"] as? String
        let runningOwned = !running || generatedExecutable != nil || currentUserProcess(row["pid"], installation: installation)
        let issue = !runningOwned || registered && owner != NSUserName() || owner != nil && owner != NSUserName() || !["none", "started", "stopped"].contains(status ?? "") ? "developer_service_unavailable" : nil
        let definition=Digest.sha256(Data((managerIdentity + "\0" + inspection.packageIdentity + "\0" + Digest.sha256(bytes)).utf8))
        let processIdentity=(row["pid"] as? NSNumber).flatMap { processBinding($0.int32Value, installation: installation) }
        let evidence=try JSONSerialization.data(withJSONObject: ["definition":definition, "service":row, "process":processIdentity ?? "not_running"], options: [.sortedKeys])
        return .init(id: Digest.sha256(Data(("homebrew:" + token).utf8)), toolID: toolID, source: "Homebrew", name: token,
                     version: inspection.installedVersions[0], installationPath: installation, configurationPath: resolved.path,
                     state: issue == nil ? (running ? "running" : "stopped") : "unknown", registeredAtLogin: registered, identity: Digest.sha256(evidence), definitionIdentity: definition, issue: issue, logPath: logLocation(plist["StandardOutPath"], prefix: prefix), errorLogPath: logLocation(plist["StandardErrorPath"], prefix: prefix), processID: running ? (row["pid"] as? NSNumber)?.int32Value : nil)
    }
    private func logLocation(_ value: Any?, prefix: String) -> String? {
        guard let path=value as? String, path.hasPrefix("/"), path.utf8.count <= 4096, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        let standardized=URL(fileURLWithPath: path).standardized.path
        return standardized.hasPrefix(prefix + "/var/log/") || standardized.hasPrefix(home.path + "/Library/Logs/") ? standardized : nil
    }
    private func physicalPath(_ path: String) -> String {
        let resolved=URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/var/") ? "/private" + resolved : resolved
    }
    private func currentUserProcess(_ value: Any?, installation: String) -> Bool {
        guard let number=value as? NSNumber, number.int64Value > 0, number.int64Value <= Int32.max else { return false }
        return processBinding(number.int32Value, installation: installation) != nil
    }
    private func processExited(_ pid: Int32, binding: String) throws -> Bool {
        var info=proc_bsdinfo(); let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return info.pbi_status == 5 || !binding.hasPrefix("\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec):")
        }
        if kill(pid, 0) == -1 && errno == ESRCH { return true }
        throw unavailable()
    }
    private func processBinding(_ pid: Int32, installation: String) -> String? {
        guard pid > 0 else { return nil }
        var info=proc_bsdinfo(); let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(), info.pbi_pid == UInt32(pid) else { return nil }
        var buffer=[UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length=proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, let path=String(bytes: buffer.prefix(Int(length)).prefix(while: { $0 != 0 }), encoding: .utf8),
              physicalPath(path).hasPrefix(installation + "/") else { return nil }
        var after=proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec, after.pbi_uid == info.pbi_uid else { return nil }
        return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec):" + physicalPath(path)
    }
    #endif
    private func unavailable() -> ShouError { ShouError("developer_service_unavailable", "The exact current-user service could not be verified.") }
}

public extension DeveloperServiceController {
    static func native() throws -> DeveloperServiceController {
        .init(catalog: try .bundled(), platform: NativeDeveloperServices(), makeStore: { try LocalRecordStore() })
    }
}
