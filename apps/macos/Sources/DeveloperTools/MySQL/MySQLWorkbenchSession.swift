import Foundation
import Observation
import ShouCore
import ShouPlatform

struct MySQLWorkbenchTarget: Identifiable, Equatable {
    let id: String
    let title: String
    let installation: String
    let version: String
    let service: DeveloperService?
}
@MainActor @Observable final class MySQLWorkbenchSession {
    var targets=[MySQLWorkbenchTarget]()
    var targetID=""
    var target: MySQLWorkbenchTarget? { targets.first { $0.id == targetID } }
    var user="root"
    var password=""
    var port="3306"
    var socket=""
    var useSocket=false
    var snapshot: MySQLSnapshot?
    var selectedDatabases=Set<String>()
    var showSystemDatabases=false
    var databaseQuery=""
    var newDatabase=""
    var charset="utf8mb4"
    var newUser=""
    var newPassword=""
    var accountDatabase=""
    var selectedAccountID=""
    var passwordReplacement=""
    var review: MySQLReview?
    var receipt: MySQLOperationReceipt?
    var failure: String?
    var failureCode: String?
    var busy=false
    var configuration: MySQLConfigurationDocument?
    var configurationText=""
    var configurationLoading=false
    var configurationFailure: String?
    var fileMessage: String?
    var logText: String?
    var logPath=""
    var logFailure: String?
    var logLoading=false
    var backups=[MySQLBackupReceipt]()
    var notes=[String:String]()
    var groups=[MySQLInstanceGroup]()
    var groupName=""
    var groupPort="3307"
    var groupPassword=""
    var groupInstallationID=""
    var availableInstallations: [DeveloperToolInstallation] { installations }
    var groupInstallation: DeveloperToolInstallation? { installations.first { $0.id == groupInstallationID } }
    var groupReview: MySQLGroupReview?
    var groupMessage: String?
    var groupFailure: String?
    var groupNames=[String:String]()
    var groupsLoading=false
    private let controller=MySQLAdministration(platform: NativeMySQLAdministration(),makeStore: { try LocalRecordStore() })
    private let registry=MySQLInstanceRegistry(platform:NativeMySQLInstances(),makeStore:{ try LocalRecordStore() })
    private var installations=[DeveloperToolInstallation]()
    private var services=[DeveloperService]()
    private var connection: MySQLConnection?
    private var configurationTask: Task<Void,Never>?
    private var logTask: Task<Void,Never>?
    private var task: Task<Void,Never>?
    private var generation=0
    var databases: [MySQLDatabase] {
        (snapshot?.databases ?? []).filter { (showSystemDatabases || !$0.system) && (databaseQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(databaseQuery)) }
    }
    func updateTargets(installations: [DeveloperToolInstallation], services: [DeveloperService]) {
        let selectedConfiguration=target?.service?.configurationPath ?? groups.first { "group." + $0.id == targetID }?.configuration
        self.installations=installations; self.services=services
        if !installations.contains(where:{ $0.id == groupInstallationID }) { groupInstallationID=installations.first?.id ?? "" }
        let instances=services.filter { $0.configurationPath.hasSuffix(".cnf") }.map { row in
            MySQLWorkbenchTarget(id:row.id,title:row.configurationPath,installation:row.installationPath,version:row.version,service:row)
        }
        let saved=groups.filter { group in !instances.contains { $0.service?.configurationPath == group.configuration } }.map { group in
            MySQLWorkbenchTarget(id:"group." + group.id,title:group.name + ", " + group.configuration,installation:group.installation,version:group.version,service:nil)
        }
        targets=instances + saved + installations.map { .init(id:$0.id,title:($0.version ?? "MySQL") + ", " + $0.path,installation:$0.path,version:$0.version ?? "",service:nil) }
        if !targets.contains(where: { $0.id == targetID }) {
            let matching=targets.first { value in
                guard let selectedConfiguration else { return false }
                return value.service?.configurationPath == selectedConfiguration || groups.contains { $0.configuration == selectedConfiguration && value.id == "group." + $0.id }
            }
            if let first=matching ?? targets.first { select(first.id) }
        }
    }
    func select(_ id: String) {
        guard !busy else { return }
        generation += 1; targetID=id; password=""; newPassword=""; passwordReplacement=""; groupPassword=""; snapshot=nil; review=nil; receipt=nil; failure=nil; failureCode=nil; connection=nil; selectedDatabases=[]; notes=[:]
        configurationTask?.cancel(); logTask?.cancel(); configuration=nil; configurationText=""; configurationFailure=nil; logText=nil; logPath=""; logFailure=nil; logLoading=false; fileMessage=nil
        Task { await controller.disconnect() }
        loadConfiguration()
    }
    func loadConfiguration(path: String? = nil) {
        guard let target, !busy else { return }
        configurationTask?.cancel(); configurationLoading=true; configurationFailure=nil; fileMessage=nil
        let revision=generation
        let groupPath=groups.first { "group." + $0.id == target.id }?.configuration
        configurationTask=Task {
            let work=Task.detached(priority:.utility) {
                let platform=NativeMySQLConfiguration()
                guard let location=path ?? groupPath ?? platform.suggestedPath(service:target.service,installationPath:target.installation) else { return Optional<MySQLConfigurationDocument>.none }
                return try platform.read(location)
            }
            do {
                let document=try await work.value
                guard !Task.isCancelled, generation == revision else { return }
                configuration=document; configurationText=document?.text ?? ""
                if let options=document?.options {
                    port=options["port"] ?? "3306"; socket=options["socket"] ?? ""; useSocket = !socket.isEmpty
                }
            } catch { if !Task.isCancelled, generation == revision { configurationFailure="The selected MySQL file cannot be read or has changed. Reload its exact path before saving." } }
            if generation == revision { configurationLoading=false }
        }
    }
    func connect(app: AppModel) {
        guard let target, let number=Int(port), !busy, !app.busy else { return }
        let selected=MySQLConnection(installationPath:target.installation,port:number,socket:useSocket ? socket : nil)
        let credentials=MySQLCredentials(user:user,password:password)
        run(app:app,mutation:false) { [self] in
            snapshot=try await controller.connect(selected,credentials:credentials); connection=selected
            selectedDatabases=[]; review=nil; receipt=nil; backups=[]
            if let server=snapshot?.server { notes=Self.loadNotes(server.uuid) }
        }
    }
    func disconnect() {
        guard !busy else { return }
        snapshot=nil; connection=nil; review=nil; password=""; newPassword=""; passwordReplacement=""
        Task { await controller.disconnect() }
    }
    func refresh(app: AppModel) {
        run(app:app,mutation:false) { [self] in snapshot=try await controller.refresh(); review=nil }
    }
    func prepare(_ mutation: MySQLMutation, app: AppModel) {
        run(app:app,mutation:false) { [self] in review=try await controller.prepare(mutation) }
    }
    func execute(app: AppModel) {
        guard let review else { return }
        run(app:app,mutation:true) { [self] in
            self.review=nil
            receipt=try await controller.execute(review.id)
            snapshot=nil; connection=nil; password=""; newPassword=""; passwordReplacement=""
            if receipt?.state != "succeeded" { app.operationHadError=true }
        }
    }
    func backup(directory: String, app: AppModel) {
        guard let snapshot else { return }
        let selected=snapshot.databases.filter { selectedDatabases.contains($0.name) && !$0.system }
        run(app:app,mutation:true) { [self] in
            backups=try await controller.backup(databases:selected,directory:directory)
            if backups.contains(where:{ $0.state != "exported" }) { app.operationHadError=true }
        }
    }
    func saveConfiguration(app: AppModel, completed: @escaping @MainActor () -> Void) {
        guard let document=configuration else { return }
        let text=configurationText
        run(app:app,mutation:true,completion:completed) { [self] in
            let work=Task.detached { try NativeMySQLConfiguration().save(text,expected:document) }
            configuration=try await work.value; fileMessage="Configuration saved. For a stopped independent instance, review its updated registration before starting."; configurationText=configuration?.text ?? text
        }
    }
    func loadLog(slow: Bool) {
        guard !busy else { return }
        let options=configuration?.options ?? [:]
        let selected=options[slow ? "slow-query-log-file" : "log-error"] ?? (slow ? nil : target?.service?.logPath)
        let data=options["datadir"] ?? snapshot?.server.dataDirectory
        guard let selected, !selected.isEmpty else { logText=nil; logPath=""; logFailure=slow ? "No slow-query log path is configured for this instance." : "No error-log path is configured for this instance."; return }
        let path=selected.hasPrefix("/") ? selected : data.map { $0 + "/" + selected }
        guard let path else { logFailure="Choose the exact log file for this instance."; return }
        readLog(path:path)
    }
    func readLog(path: String) {
        logTask?.cancel(); logLoading=true; logPath=path; logText=nil; logFailure=nil
        let revision=generation
        logTask=Task {
            let work=Task.detached(priority:.utility) { try NativeMySQLConfiguration().log(path:path) }
            do { let value=try await work.value; guard !Task.isCancelled, generation == revision else { return }; logText=value }
            catch { if !Task.isCancelled, generation == revision { logFailure="The service log cannot be read. Check its path and access permissions." } }
            if generation == revision { logLoading=false }
        }
    }
    func setNote(_ note: String, database: String) {
        guard let uuid=snapshot?.server.uuid, note.utf8.count <= 4096 else { return }
        notes[database]=note
        UserDefaults.standard.set(notes,forKey:"mysqlNotes." + Digest.sha256(Data(uuid.utf8)))
    }
    func loadGroups() {
        guard !groupsLoading else { return }
        groupsLoading=true; groupFailure=nil
        Task {
            defer { groupsLoading=false }
            let work=Task.detached(priority:.utility) { try NativeMySQLInstances().groups() }
            do {
                groups=try await work.value
                updateTargets(installations:installations,services:services)
            } catch { groupFailure="Instance registrations could not be read. Refresh before continuing." }
        }
    }
    func selectGroup(_ group: MySQLInstanceGroup) {
        if let current=targets.first(where:{ $0.service?.configurationPath == group.configuration || $0.id == "group." + group.id }) { select(current.id) }
    }
    func clearGroupFeedback() { failure=nil; failureCode=nil; groupMessage=nil }
    func prepareGroup(_ change: MySQLGroupChange, group: MySQLInstanceGroup, app: AppModel) {
        groupReview=nil; groupMessage=nil
        run(app:app,mutation:false) { [self] in groupReview=try await registry.prepare(change,group:group) }
    }
    func executeGroup(app: AppModel, completed: @escaping @MainActor () -> Void) {
        guard let review=groupReview else { return }
        groupReview=nil
        run(app:app,mutation:true,completion:completed) { [self] in
            try await registry.execute(review.id)
            switch review.change {
            case .refreshRegistration: groupMessage="Instance registration updated. Database files were preserved; no server was started."
            case .rename: groupMessage="Instance name updated. Database files were preserved; no server was started."
            case .unregister: groupMessage="Instance unregistered. Database files remain on disk; no disk space was freed."
            }
            loadGroups()
        }
    }
    func createGroup(app: AppModel, completed: @escaping @MainActor () -> Void) {
        guard let installation=groupInstallation, let port=Int(groupPort) else { return }
        let name=groupName, password=groupPassword
        run(app:app,mutation:true,completion:completed) { [self] in
            let work=Task.detached { try NativeMySQLInstances().create(name:name,installation:installation.path,version:installation.version ?? "",port:port,password:password) }
            let group=try await work.value
            groups.append(group); groupPassword=""; groupName=""
            updateTargets(installations:installations,services:services)
        }
    }
    private static func loadNotes(_ uuid: String) -> [String:String] { UserDefaults.standard.dictionary(forKey:"mysqlNotes." + Digest.sha256(Data(uuid.utf8))) as? [String:String] ?? [:] }
    private func run(app: AppModel, mutation: Bool, completion: (@MainActor () -> Void)? = nil, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !app.busy else { return }
        busy=true; failure=nil; failureCode=nil
        if mutation { app.busy=true; app.isExecuting=true; app.operationHadError=false }
        task=Task {
            defer { busy=false; if mutation { app.busy=false; app.isExecuting=false; app.stopRequested=false }; completion?() }
            do { try await operation() }
            catch {
                // Do not interpolate the client's stderr or credential-bearing SQL.
                failure=(error as? ShouError)?.message ?? "The MySQL operation could not be verified. Check the selected instance and its permissions."
                failureCode=(error as? ShouError)?.code
                if mutation { app.operationHadError=true }
            }
        }
    }
}
