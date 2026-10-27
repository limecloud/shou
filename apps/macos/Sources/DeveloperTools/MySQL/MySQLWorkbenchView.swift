import SwiftUI
import AppKit
import ShouCore

struct MySQLWorkbenchView: View {
    @Bindable var model: AppModel
    @Bindable var session: MySQLWorkbenchSession
    @Bindable var tools: DeveloperToolsSession
    let mode: String
    var groupCompleted: @MainActor () -> Void = {}
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            if mode != "mysql.groups" { context }
            if let failure=session.failure { Label(model.t(failure),systemImage:"exclamationmark.triangle").foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
            if let code=session.failureCode { Text(code).font(ShouType.code).foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
            if session.busy { ProgressView().controlSize(.small) }
            if mode == "mysql.databases" { databases }
            else if mode == "mysql.groups" { groups }
            else if mode == "mysql.configuration" { configuration }
            else { logs }
        }
        .font(ShouType.body).foregroundStyle(ShouPalette.text).tint(ShouPalette.accent)
        .onChange(of:mode) { if mode == "mysql.log" || mode == "mysql.slow-log" { session.loadLog(slow:mode == "mysql.slow-log") } }
        .onChange(of:session.configurationLoading) { if !session.configurationLoading && (mode == "mysql.log" || mode == "mysql.slow-log") { session.loadLog(slow:mode == "mysql.slow-log") } }
        .onAppear { session.loadGroups(); if mode == "mysql.log" || mode == "mysql.slow-log" { session.loadLog(slow:mode == "mysql.slow-log") } }
    }
    private var context: some View {
        VStack(alignment:.leading,spacing:10) {
            Picker(model.t("Installation & Instance"),selection:Binding(get:{ session.targetID },set:{ session.select($0) })) {
                ForEach(session.targets) { target in Text(target.title).tag(target.id) }
            }.disabled(model.busy || session.busy).accessibilityIdentifier("mysql.instance")
            if let target=session.target { Text(target.installation).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
        }.padding(16).modifier(WorkspaceSurface())
    }
    private var databases: some View {
        VStack(alignment:.leading,spacing:18) {
            if let receipt=session.receipt {
                Label(model.t(receipt.state == "succeeded" ? "MySQL change verified. Reconnect to continue." : "MySQL change needs verification. Some steps may have completed; reconnect before continuing."),systemImage:receipt.state == "succeeded" ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(receipt.state == "succeeded" ? ShouPalette.accent : ShouPalette.secondary)
            }
            if let snapshot=session.snapshot {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("MySQL " + snapshot.server.version).font(ShouType.body.weight(.semibold))
                        Text(snapshot.server.authenticatedAccount + " / " + String(snapshot.server.port)).font(ShouType.body)
                        Text(snapshot.server.dataDirectory).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(model.t("Refresh")) { session.refresh(app:model) }
                    Button(model.t("Disconnect")) { session.disconnect() }
                }.disabled(session.busy || model.busy)
                HStack {
                    TextField(model.t("Filter Databases"),text:$session.databaseQuery).textFieldStyle(.roundedBorder).frame(maxWidth:280)
                    Toggle(model.t("System Databases"),isOn:$session.showSystemDatabases).toggleStyle(.checkbox)
                    Spacer()
                    Button(model.t("Back Up Selected Databases")) { chooseBackup() }
                        .disabled(session.selectedDatabases.isEmpty || session.busy || model.busy).accessibilityIdentifier("mysql.backup")
                }
                databaseTable
                if !snapshot.accountsReadable {
                    Text(model.t("Databases were read, but this login cannot read mysql.user. Account actions are unavailable.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                }
                if let review=session.review { reviewView(review) }
                else {
                    DisclosureGroup(model.t("Create Database")) { createDatabase.padding(.top,12) }.accessibilityIdentifier("mysql.create-database")
                    if snapshot.accountsReadable {
                        DisclosureGroup(model.t("Accounts & Passwords")) { accounts(snapshot).padding(.top,12) }.accessibilityIdentifier("mysql.accounts")
                    }
                }
            } else { connectionForm }
            if !session.backups.isEmpty {
                Text(model.t(session.backups.contains(where:{ $0.state == "exported" }) ? "SQL backups written. Restore has not been tested." : "SQL exports failed. Incomplete files remain marked .partial.")).font(ShouType.body)
                ForEach(session.backups,id:\.database) { backup in
                    VStack(alignment:.leading,spacing:6) {
                        Label(backup.database + " / " + model.t(backup.state == "exported" ? "Exported" : "Export Failed"),systemImage:backup.state == "exported" ? "checkmark.circle" : "exclamationmark.triangle")
                        if let path=backup.path {
                            HStack { Text(path).font(ShouType.caption).textSelection(.enabled); Spacer(); Button(model.t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) } }
                        }
                    }
                }
            }
        }
    }
    private var connectionForm: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(model.t("Connect to MySQL")).font(ShouType.body.weight(.semibold))
            ViewThatFits(in:.horizontal) {
                HStack { loginFields; transportFields }
                VStack { loginFields; transportFields }
            }
            Text(model.t("Credentials are kept for this session only.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Button(model.t("Connect & Read Databases")) { session.connect(app:model) }.buttonStyle(.borderedProminent)
                .disabled(session.target == nil || session.busy || model.busy).accessibilityIdentifier("mysql.connect")
        }.padding(18).modifier(WorkspaceSurface())
    }
    private var loginFields: some View {
        HStack {
            TextField(model.t("Username"),text:$session.user).textFieldStyle(.roundedBorder).accessibilityIdentifier("mysql.username")
            SecureField(model.t("Password"),text:$session.password).textFieldStyle(.roundedBorder).accessibilityIdentifier("mysql.password")
        }
    }
    private var transportFields: some View {
        HStack {
            Toggle(model.t("Unix Socket"),isOn:$session.useSocket).toggleStyle(.checkbox)
            if session.useSocket { TextField("/private/tmp/mysql.sock",text:$session.socket).textFieldStyle(.roundedBorder).accessibilityIdentifier("mysql.socket") }
            else { Text("127.0.0.1").font(ShouType.body).foregroundStyle(ShouPalette.secondary); TextField(model.t("Port"),text:$session.port).textFieldStyle(.roundedBorder).frame(width:70).accessibilityIdentifier("mysql.port") }
        }
    }
    private var databaseTable: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text(model.t("Database")).frame(maxWidth:.infinity,alignment:.leading)
                Text(model.t("Character Set")).frame(width:90,alignment:.leading)
                Text(model.t("Local Note")).frame(maxWidth:.infinity,alignment:.leading)
            }.font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(12)
            ShouDivider()
            if session.databases.isEmpty { Text(model.t("No matching databases.")).foregroundStyle(ShouPalette.secondary).padding(18) }
            ForEach(session.databases) { database in
                HStack(spacing:12) {
                    Toggle(database.name,isOn:Binding(get:{ session.selectedDatabases.contains(database.name) },set:{ if $0 { session.selectedDatabases.insert(database.name) } else { session.selectedDatabases.remove(database.name) } }))
                        .toggleStyle(.checkbox).disabled(database.system || session.busy || model.busy).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("mysql.database." + database.name)
                    Text(database.charset).font(ShouType.body).frame(width:90,alignment:.leading)
                    TextField(model.t("Local Note"),text:Binding(get:{ session.notes[database.name] ?? "" },set:{ session.setNote($0,database:database.name) }))
                        .textFieldStyle(.plain).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(12)
                ShouDivider()
            }
        }.modifier(WorkspaceSurface())
    }
    private var createDatabase: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                TextField(model.t("Database Name"),text:$session.newDatabase).textFieldStyle(.roundedBorder)
                Picker(model.t("Character Set"),selection:$session.charset) { ForEach(["utf8mb4","utf8","gbk","big5"],id:\.self) { Text($0).tag($0) } }.frame(width:210)
            }
            Button(model.t("Review Database Creation")) { session.prepare(.createDatabase(name:session.newDatabase,charset:session.charset),app:model) }
                .disabled(session.newDatabase.isEmpty || session.busy || model.busy)
        }
    }
    private func accounts(_ snapshot: MySQLSnapshot) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text(model.t("Accounts retain their Host. MySQL does not provide plaintext passwords.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            ForEach(snapshot.accounts) { account in
                HStack { Text(account.user + "@" + account.host).font(ShouType.body.monospaced()); Spacer(); Text(account.plugin).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
            }
            ShouDivider()
            Text(model.t("Create Local Account & Grant Database Access")).font(ShouType.body.weight(.semibold))
            HStack {
                Picker(model.t("Database"),selection:$session.accountDatabase) {
                    Text(model.t("Choose a database")).tag("")
                    ForEach(snapshot.databases.filter { !$0.system }) { Text($0.name).tag($0.name) }
                }
                TextField(model.t("New Username"),text:$session.newUser).textFieldStyle(.roundedBorder)
                SecureField(model.t("New Password"),text:$session.newPassword).textFieldStyle(.roundedBorder)
            }
            Text(model.t("A new localhost account receives privileges on this database only. Existing usernames are rejected; no global grant or GRANT OPTION is added.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Button(model.t("Review Account Creation")) { session.prepare(.createAccount(database:session.accountDatabase,user:session.newUser,password:session.newPassword),app:model) }
                .disabled(session.accountDatabase.isEmpty || session.newUser.isEmpty || session.newPassword.isEmpty || session.busy || model.busy)
            ShouDivider()
            Text(model.t("Change Account Password")).font(ShouType.body.weight(.semibold))
            HStack {
                Picker(model.t("Account"),selection:$session.selectedAccountID) {
                    Text(model.t("Choose an account")).tag("")
                    ForEach(snapshot.accounts) { Text($0.user + "@" + $0.host).tag($0.id) }
                }
                SecureField(model.t("New Password"),text:$session.passwordReplacement).textFieldStyle(.roundedBorder)
            }
            Text(model.t("This uses your authenticated session and may affect applications using that account. It does not bypass authentication or stop the database server.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Button(model.t("Review Password Change")) {
                if let account=snapshot.accounts.first(where:{ $0.id == session.selectedAccountID }) { session.prepare(.changePassword(account:account,password:session.passwordReplacement),app:model) }
            }.disabled(session.selectedAccountID.isEmpty || session.passwordReplacement.isEmpty || session.busy || model.busy)
        }
    }
    private func reviewView(_ review: MySQLReview) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.t("Review MySQL Change")).font(ShouType.body.weight(.semibold))
            Text(review.target).font(ShouType.body.monospaced()).textSelection(.enabled)
            Text("MySQL " + review.server.version + " / " + String(review.server.port) + " / " + review.server.uuid).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Text(model.t("This affects the selected live database. Multiple SQL steps are not a transaction; a failure may leave completed changes. This request expires in two minutes and is used once.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            HStack {
                Spacer(); Button(model.t("Cancel")) { session.review=nil }
                Button(model.t("Confirm MySQL Change")) { session.execute(app:model) }.buttonStyle(.borderedProminent).accessibilityIdentifier("mysql.confirm")
            }.disabled(session.busy || model.busy)
        }.padding(18).modifier(WorkspaceSurface())
    }
    private var configuration: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(model.t("MySQL Configuration")).font(ShouType.body.weight(.semibold)); Spacer()
                Button(model.t("Choose Configuration File")) { chooseFile(configuration:true) }
                Button(model.t("Reload")) { session.loadConfiguration(path:session.configuration?.path) }
            }.disabled(session.busy || model.busy || session.configurationLoading)
            if session.configurationLoading { ProgressView().controlSize(.small) }
            if let failure=session.configurationFailure { Text(model.t(failure)).foregroundStyle(ShouPalette.secondary) }
            if let document=session.configuration {
                Text(document.path).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                Text(model.t("Saving does not validate syntax or restart MySQL.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                TextEditor(text:$session.configurationText).font(ShouType.body.monospaced()).frame(minHeight:320).scrollContentBackground(.hidden)
                    .padding(10).background(ShouPalette.inset,in:RoundedRectangle(cornerRadius:ShouDesign.controlRadius)).disabled(!document.writable || session.busy || model.busy).accessibilityIdentifier("mysql.configuration.editor")
                HStack {
                    if !document.writable { Text(model.t("This file is read-only. Shou will not change its ownership or permissions.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                    Spacer()
                    Button(model.t("Save Selected Configuration")) { session.saveConfiguration(app:model,completed:groupCompleted) }.buttonStyle(.borderedProminent)
                        .disabled(!document.writable || session.configurationText == document.text || session.busy || model.busy).accessibilityIdentifier("mysql.configuration.save")
                }
            } else if !session.configurationLoading {
                Text(model.t("No exact configuration file was found. Choose this instance's .cnf file; Shou will not create or replace another version's defaults.")).foregroundStyle(ShouPalette.secondary)
            }
            if let message=session.fileMessage { Text(model.t(message)).font(ShouType.body).foregroundStyle(ShouPalette.accent) }
        }
    }
    private var logs: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(model.t(mode == "mysql.slow-log" ? "Slow Query Log" : "MySQL Error Log")).font(ShouType.body.weight(.semibold))
                Spacer()
                Button(model.t("Choose Log File")) { chooseFile(configuration:false) }
                Button(model.t("Refresh Log")) { if session.logPath.isEmpty { session.loadLog(slow:mode == "mysql.slow-log") } else { session.readLog(path:session.logPath) } }
            }.disabled(session.busy || model.busy || session.logLoading)
            if !session.logPath.isEmpty { Text(session.logPath).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
            Text(model.t("Last 200 lines, up to 64 KiB")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            if session.logLoading { ProgressView().controlSize(.small) }
            if let error=session.logFailure { Text(model.t(error)).foregroundStyle(ShouPalette.secondary) }
            if let text=session.logText {
                DeveloperLogContentView(text:text,emptyText:model.t("The log file is empty."),identifier:"mysql.log.viewer")
            }
            DeveloperLogCleanupControls(model:model,session:tools.configuration.logCleanup,toolID:"mysql",path:session.logPath,
                canReview:!session.logLoading && session.logText?.isEmpty == false,completed:{ session.logText="" })
        }
    }
    private var groups: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(model.t("Independent MySQL Instances")).font(ShouType.body.weight(.semibold)); Spacer()
                Button(model.t("Refresh Status")) { session.loadGroups(); tools.refreshServices(app:model) }
                    .disabled(session.groupsLoading || tools.servicesLoading || model.busy || session.busy)
            }
            if let failure=session.groupFailure { Label(model.t(failure),systemImage:"exclamationmark.triangle").foregroundStyle(ShouPalette.secondary) }
            if let failure=tools.serviceFailure { Label(model.t(failure),systemImage:"exclamationmark.triangle").foregroundStyle(ShouPalette.secondary) }
            if let code=tools.serviceResult?.failureCode { Text(code).font(ShouType.code).textSelection(.enabled) }
            if let message=session.groupMessage { Label(model.t(message),systemImage:"checkmark.circle").foregroundStyle(ShouPalette.accent) }
            if let review=session.groupReview { groupReview(review) }
            ForEach(session.groups) { group in
                VStack(alignment:.leading,spacing:8) {
                    ViewThatFits(in:.horizontal) {
                        HStack { groupSummary(group); Spacer(); groupControls(group) }
                        VStack(alignment:.leading,spacing:10) { groupSummary(group); groupControls(group) }
                    }
                    Text(group.dataDirectory).font(ShouType.caption).textSelection(.enabled)
                    Text(group.configuration).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    DisclosureGroup(model.t("Edit Instance Registration")) {
                        HStack {
                            TextField(group.name,text:Binding(get:{ session.groupNames[group.id] ?? group.name },set:{ session.groupNames[group.id]=$0 })).textFieldStyle(.roundedBorder).accessibilityIdentifier("mysql.group.name." + group.id)
                            Button(model.t("Review Name Change")) { session.prepareGroup(.rename(session.groupNames[group.id] ?? group.name),group:group,app:model) }
                        }.padding(.top,10)
                        Text(model.t("Stop the instance before updating its registration.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).frame(maxWidth:.infinity,alignment:.leading)
                        HStack {
                            Button(model.t("Review Updated Configuration")) { session.prepareGroup(.refreshRegistration,group:group,app:model) }.accessibilityIdentifier("mysql.group.rebind." + group.id)
                            Spacer()
                            Button(model.t("Remove Registration…")) { session.prepareGroup(.unregister,group:group,app:model) }.accessibilityIdentifier("mysql.group.unregister." + group.id)
                        }
                    }.disabled(session.busy || model.busy || session.groupReview != nil)
                    if groupService(group) == nil {
                        Text(model.t("No current verified recipe. Refresh status, or review the saved configuration before registering it again.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    }
                }.padding(16).modifier(WorkspaceSurface())
            }
            if let text=session.logText {
                DisclosureGroup(model.t("Startup Output")) {
                    Text(session.logPath).font(ShouType.caption).textSelection(.enabled)
                    ScrollView { Text(text.isEmpty ? model.t("The log file is empty.") : text).font(ShouType.code).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:140,maxHeight:260)
                }
            }
            if let failure=session.logFailure { Text(model.t(failure)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
            ShouDivider()
            DisclosureGroup(model.t("Create Independent Instance")) {
            Picker(model.t("Installation & Versions"),selection:$session.groupInstallationID) {
                ForEach(session.availableInstallations) { row in Text((row.version ?? model.t("Version not verified")) + " / " + row.path).tag(row.id) }
            }.padding(.top,12).disabled(session.busy || model.busy).accessibilityIdentifier("mysql.group.installation")
            HStack {
                TextField(model.t("Instance Name"),text:$session.groupName).textFieldStyle(.roundedBorder)
                TextField(model.t("Port"),text:$session.groupPort).textFieldStyle(.roundedBorder).frame(width:80)
                SecureField(model.t("Initial Root Password"),text:$session.groupPassword).textFieldStyle(.roundedBorder)
            }
            Text(model.t("New private instance, initially stopped.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Button(model.t("Initialize New Instance")) { session.createGroup(app:model,completed:groupCompleted) }.buttonStyle(.borderedProminent)
                .disabled(session.groupName.isEmpty || session.groupPassword.isEmpty || session.groupInstallation == nil || session.busy || model.busy).accessibilityIdentifier("mysql.group.create")
            }.accessibilityIdentifier("mysql.group.new")
        }.onAppear { session.loadGroups() }
    }
    private func groupService(_ group: MySQLInstanceGroup) -> DeveloperService? {
        let rows=tools.toolServices("mysql").filter { $0.source == "Local instance" && $0.configurationPath == group.configuration }
        return rows.count == 1 ? rows.first : nil
    }
    private func groupSummary(_ group: MySQLInstanceGroup) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(group.name).font(ShouType.body.weight(.semibold))
            HStack {
                Text("MySQL " + group.version + " / " + String(group.port))
                if let row=groupService(group) {
                    Text(model.t(tools.changingServiceID == row.id ? (tools.serviceStage == "stopping" ? "Stopping…" : "Starting…") : row.controllable ? (row.state == "running" ? "Running" : "Stopped") : "State Unknown"))
                        .foregroundStyle(row.state == "running" ? ShouPalette.accent : ShouPalette.secondary)
                    if let pid=row.processID { Text("PID \(pid)").font(ShouType.code) }
                } else { Text(model.t("State Unknown")).foregroundStyle(ShouPalette.secondary) }
            }.font(ShouType.caption)
        }
    }
    private func groupControls(_ group: MySQLInstanceGroup) -> some View {
        HStack(spacing:10) {
            if let row=groupService(group) {
                Toggle(model.t(row.state == "running" ? "Stop Service" : "Start Service"),isOn:Binding(get:{ row.state == "running" },set:{ session.clearGroupFeedback(); tools.changeService(row,running:$0,app:model) }))
                    .labelsHidden().toggleStyle(.switch).help(model.t(row.state == "running" ? "Stop Service" : "Start Service"))
                    .disabled(model.busy || session.busy || session.groupReview != nil || tools.servicesLoading || tools.staleServiceIDs.contains(row.id) || !row.controllable)
                    .accessibilityIdentifier("mysql.group.switch." + group.id)
                Button(model.t("Restart Service")) { session.clearGroupFeedback(); tools.performService(.restart,expected:row,app:model) }
                    .disabled(model.busy || session.busy || session.groupReview != nil || tools.servicesLoading || tools.staleServiceIDs.contains(row.id) || !row.controllable || row.state != "running")
                    .accessibilityIdentifier("mysql.group.restart." + group.id)
            }
            Menu(model.t("Manage Instance")) {
                Button(model.t("Databases & Accounts")) { openGroup(group,mode:"mysql.databases") }
                Button(model.t("Configuration File")) { openGroup(group,mode:"mysql.configuration") }
                Button(model.t("Logs")) { openGroup(group,mode:"mysql.log") }
                Button(model.t("Slow Query Log")) { openGroup(group,mode:"mysql.slow-log") }
                if let row=groupService(group), let path=row.errorLogPath {
                    Button(model.t("Startup Output")) { session.readLog(path:path) }
                }
                ShouDivider()
                Button(model.t("Copy Socket Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(group.socket,forType:.string) }
                Button(model.t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:group.configuration)]) }
            }.fixedSize().disabled(model.busy || session.busy || session.groupReview != nil)
        }
    }
    private func openGroup(_ group: MySQLInstanceGroup, mode: String) { session.selectGroup(group); tools.detailTab=mode }
    private func groupReview(_ review: MySQLGroupReview) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.t("Review Instance Registration")).font(ShouType.body.weight(.semibold))
            Text(review.observation.group.name).font(ShouType.body.weight(.semibold))
            Text(review.observation.group.configuration).font(ShouType.caption).textSelection(.enabled)
            switch review.change {
            case .rename(let name): Text(model.t("New Instance Name") + ": " + name)
            case .refreshRegistration:
                Text(model.t("Port") + ": " + String(review.observation.port))
                Text(review.observation.socket).font(ShouType.caption).textSelection(.enabled)
                Text(model.t("The next start will use this exact configuration. Data is not initialized, moved or removed, and no server is started by this action."))
            case .unregister: Text(model.t("Only the stopped instance's registration is removed. Its database, configuration and logs stay on disk. This does not free disk space."))
            }
            HStack {
                Text(model.t("This review expires in two minutes and can be used once.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                Spacer()
                Button(model.t("Cancel")) { session.groupReview=nil }
                Button(model.t("Confirm Registration Change")) { session.executeGroup(app:model,completed:groupCompleted) }.buttonStyle(.borderedProminent).accessibilityIdentifier("mysql.group.confirm")
            }.disabled(model.busy || session.busy)
        }.padding(18).modifier(WorkspaceSurface())
    }
    private func chooseFile(configuration: Bool) {
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        if panel.runModal() == .OK, let url=panel.url { if configuration { session.loadConfiguration(path:url.path) } else { session.readLog(path:url.path) } }
    }
    private func chooseBackup() {
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.canCreateDirectories=true; panel.allowsMultipleSelection=false
        if panel.runModal() == .OK, let url=panel.url { session.backup(directory:url.path,app:model) }
    }
}
