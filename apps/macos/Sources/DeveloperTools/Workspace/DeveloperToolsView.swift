import SwiftUI
import ShouCore
import ShouPlatform
import AppKit

struct DeveloperToolsView: View {
    @Bindable var model: AppModel
    @Bindable var session: DeveloperToolsSession
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ShouDivider()
            if session.collection == "catalog" { catalogView }
            else { HStack(spacing: 0) {
                toolRail.frame(width: ShouDesign.toolRailWidth)
                ShouDivider(vertical: true)
                Group {
                    if let tool=session.focused { detail(tool) }
                    else {
                        VStack(spacing: 16) {
                            WorkspacePageArtwork(kind: .projects).frame(width: 180, height: 130).accessibilityHidden(true)
                            Text(model.t("Add tools to your workspace")).font(ShouType.body.weight(.semibold))
                            Button(model.t("Add Tools")) { session.collection="catalog"; session.query=""; session.category="all" }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("developer.workspace.add")
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .font(ShouType.body).foregroundStyle(ShouPalette.text).tint(ShouPalette.accent)
            .onAppear { session.changeArea(model.section); if session.inventory == nil { session.scanInstalled(app: model) } }
            .onChange(of: session.collection) { session.reconcileFocus() }
            .onChange(of: session.query) { session.reconcileFocus() }
            .onChange(of: session.category) { session.reconcileFocus() }
            .onChange(of: session.installedOnly) { session.reconcileFocus() }
    }
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                WorkspacePageArtwork(kind: .projects).frame(width: 44, height: 36).accessibilityHidden(true)
                Picker(model.t("Tool collection"), selection: $session.collection) {
                    Text(model.t("My Workspace")).tag("workspace")
                    Text(model.t("Add Tools")).tag("catalog")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 236).disabled(model.busy || session.plan != nil).accessibilityIdentifier("developer.collection")
                if session.collection == "catalog" {
                    Toggle(model.t("Installed Only"), isOn: $session.installedOnly).toggleStyle(.checkbox).disabled(model.busy)
                }
                Spacer(minLength: 0)
                TextField(model.t("Search developer tools"), text: $session.query)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 260).disabled(model.busy).accessibilityIdentifier("developer.search")
                Button(model.t(session.inventoryLoading ? "Scanning Installed Tools…" : "Refresh Tools & Services")) { session.scanInstalled(app: model) }
                    .disabled(model.busy || session.inventoryLoading).accessibilityIdentifier("developer.scan")
            }
            if let failure=session.serviceFailure ?? session.failure {
                Text(model.t(failure)).font(ShouType.body).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            }
            if let inventory=session.inventory, !inventory.issues.isEmpty || !(session.services?.issues.isEmpty ?? true) {
                Text(model.t("Some sources could not be read."))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if session.serviceResult?.state == "succeeded" { Text(model.t(session.serviceResult?.action == .restart ? "Service restarted and verified." : "Service state verified.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
            if session.inventoryLoading { ProgressView().controlSize(.small) }
        }.padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 12)
    }
    private var catalogView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(session.categories) { group in
                    let tools=session.tools.filter { $0.category == group.id }
                    if !tools.isEmpty {
                        Text(model.t(group.title)).font(ShouType.body.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 0) {
                            ForEach(tools) { tool in
                                HStack(spacing: 12) {
                                    monogram(tool).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(model.t(tool.name)).font(ShouType.body.weight(.medium))
                                        Text(model.t(toolStatus(tool.id))).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                                        let sources=Array(Set(session.installations(tool.id).map(\.source))).sorted()
                                        if !sources.isEmpty { Text(sources.map { model.t($0) }.joined(separator: " / ")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(1) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Toggle(model.t("Add to Workspace"), isOn: Binding(get: { session.favorites.contains(tool.id) }, set: { _ in session.toggleFavorite(tool.id) }))
                                        .toggleStyle(.switch).labelsHidden().controlSize(.small).disabled(model.busy)
                                        .accessibilityLabel(model.t(session.favorites.contains(tool.id) ? "Remove from Workspace" : "Add to Workspace") + " / " + tool.name)
                                        .accessibilityIdentifier("developer.workspace.select." + tool.id)
                                }.padding(.vertical, 14).padding(.horizontal, 12)
                                    .overlay(alignment: .bottom) { ShouDivider() }
                            }
                        }
                    }
                }
                if session.tools.isEmpty { Text(model.t("No matching developer tools.")).foregroundStyle(ShouPalette.secondary) }
            }.padding(ShouDesign.workspaceInset)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var toolRail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(session.categories) { group in
                    let tools=session.tools.filter { $0.category == group.id }
                    if !tools.isEmpty {
                        Text(model.t(group.title)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(.top, 14).padding(.horizontal, 12)
                        ForEach(tools) { tool in
                            HStack(spacing: 8) {
                                Button { session.open(tool) } label: {
                                    HStack(spacing: 9) {
                                        Text(String(tool.name.prefix(1)).uppercased()).font(ShouType.body.weight(.semibold))
                                            .foregroundStyle(ShouPalette.accent).frame(width: 26, height: 28)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(model.t(tool.name)).font(ShouType.body.weight(session.focusedID == tool.id ? .semibold : .regular)).lineLimit(2)
                                            Text(model.t(toolStatus(tool.id))).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("developer.tool." + tool.id)
                                let services=session.toolServices(tool.id)
                                if services.count == 1, let service=services.first { serviceSwitch(service, showsProgress: false) }
                                else if services.count > 1 {
                                    Image(systemName:"chevron.right").font(ShouType.caption).foregroundStyle(ShouPalette.secondary).accessibilityHidden(true)
                                }
                            }.padding(.horizontal, 10).padding(.vertical, 5)
                                .background(session.focusedID == tool.id ? ShouPalette.selection : .clear, in: RoundedRectangle(cornerRadius: ShouDesign.navRadius))
                                .contextMenu { Button(model.t("Remove from Workspace")) { session.toggleFavorite(tool.id) }.disabled(model.busy) }
                        }
                    }
                }
                if session.tools.isEmpty { Text(model.t("No matching developer tools.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary).padding(12) }
            }.padding(12)
        }.background(ShouPalette.inset)
    }
    private func serviceSwitch(_ service: DeveloperService, showsProgress: Bool = true) -> some View {
        Group {
            if session.changingServiceID == service.id {
                if showsProgress { ProgressView().controlSize(.small).frame(width: 40) }
            }
            else if service.controllable && !session.staleServiceIDs.contains(service.id) {
                Toggle(model.t("Service"), isOn: Binding(get: { service.state == "running" }, set: { session.changeService(service, running: $0, app: model) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(model.busy || session.inventoryLoading || session.checkingServices(service.toolID))
                    .help(service.source + " / " + service.version + "\n" + service.installationPath + "\n" + model.t("Start or stop this service now. Existing login-start registration is preserved."))
                    .accessibilityLabel(model.t(service.state == "running" ? "Stop Service" : "Start Service") + " / " + service.name + " / " + service.source)
                    .accessibilityIdentifier("developer.service." + service.id)
            } else {
                Text(model.t(service.state == "external" ? "External Service" : "Unverified")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(.horizontal, 7).padding(.vertical, 4).background(ShouPalette.inset, in: Capsule())
            }
        }
    }
    private func monogram(_ tool: DeveloperToolDefinition) -> some View {
        Text(String(tool.name.prefix(2)).uppercased()).font(ShouType.title)
            .foregroundStyle(ShouPalette.accent).frame(width: 42, height: 42)
            .background(ShouPalette.selection, in: RoundedRectangle(cornerRadius: ShouDesign.controlRadius))
    }
    private func favorite(_ id: String) -> some View {
        Button(model.t("Remove from Workspace")) { session.toggleFavorite(id) }
            .accessibilityIdentifier("developer.workspace.remove." + id)
    }
    private func detail(_ tool: DeveloperToolDefinition) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                monogram(tool)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t(tool.name)).font(ShouType.title)

                }
                Spacer()
                favorite(tool.id).disabled(model.busy)
                Link(model.t("Official Guide"), destination: URL(string: tool.homepage)!)
            }.padding(ShouDesign.workspaceInset)
            ShouDivider()
            if tool.id == "mysql" {
                ScrollView(.horizontal,showsIndicators:false) {
                    Picker(model.t("MySQL Tasks"),selection:$session.detailTab) {
                        Text(model.t("Service")).tag("mysql.service")
                        Text(model.t("Version Management")).tag("installation")
                        Text(model.t("Databases & Accounts")).tag("mysql.databases")
                        Text(model.t("Configuration File")).tag("mysql.configuration")
                        Text(model.t("Logs")).tag("mysql.log")
                        Text(model.t("Slow Query Log")).tag("mysql.slow-log")
                        Text(model.t("Instance Groups")).tag("mysql.groups")
                    }.pickerStyle(.segmented).labelsHidden().disabled(model.busy || session.mysql.busy || session.plan != nil).accessibilityIdentifier("mysql.tasks")
                        .padding(.horizontal,ShouDesign.workspaceInset).padding(.vertical,10)
                }
            } else {
                HStack {
                    Picker(model.t("Tool Details"), selection: $session.detailTab) {
                        Text(model.t("Overview")).tag("overview")
                        Text(model.t("Installation & Versions")).tag("installation")
                        if NativeDeveloperConfiguration.supportedTools.contains(tool.id) {
                            Text(model.t("Configuration File")).tag("service.configuration")
                            Text(model.t("Logs")).tag("service.logs")
                        }
                        if AIWorkspaceSummary.supportedTools.contains(tool.id) { Text(model.t("Configuration & Extensions")).tag("configuration") }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440).disabled(model.busy || session.plan != nil)
                    Spacer()
                }.padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 12)
            }
            if session.detailTab == "installation" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        sourceChip("all", "All Sources")
                        ForEach(Array(Set(session.installations(tool.id).map(\.source))).sorted(), id: \.self) { source in sourceChip(source, source) }
                    }.padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 8)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tool.id == "mysql", session.detailTab.hasPrefix("mysql.") {
                        if session.detailTab == "mysql.service" {
                            if !session.installations(tool.id).isEmpty { installedCopies(tool) }
                            HStack {
                                Spacer()
                                Button(model.t("Manage Databases")) { session.detailTab="mysql.databases" }.buttonStyle(.borderedProminent).accessibilityIdentifier("mysql.manage")
                            }
                            serviceDetails(tool)
                        } else { MySQLWorkbenchView(model:model,session:session.mysql,tools:session,mode:session.detailTab,groupCompleted:{ session.refreshServices(app:model) }) }
                    } else if session.detailTab.hasPrefix("service.") {
                        DeveloperConfigurationView(model:model,tools:session,session:session.configuration,logs:session.detailTab == "service.logs")
                    } else if session.detailTab == "overview" {
                        if !session.installations(tool.id).isEmpty { installedCopies(tool) }
                        serviceDetails(tool)
                        if session.installations(tool.id).isEmpty {
                            Button(model.t("Version Management")) { session.detailTab="installation" }.buttonStyle(.borderedProminent)
                        }
                    } else if session.detailTab == "configuration" {
                        if session.changingServiceID != nil || session.serviceResult != nil { serviceDetails(tool) }
                        workspaceView
                    } else {
                    if !session.installations(tool.id).isEmpty { installedCopies(tool) }
                    if !session.packages.isEmpty { availableVersions(tool).id(tool.id) }
                    if let result=session.result { resultView(result) }
                    if let failure=session.failure { Label(model.t(failure), systemImage: "exclamationmark.triangle").foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
                    if session.executing && session.changingServiceID == nil {
                        HStack(spacing: 14) { ProgressView(); Text(model.t("The package manager is working. Shou will wait for its result before closing.")) }
                    } else if session.packages.isEmpty || !["all", "Homebrew"].contains(session.sourceFilter) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.t("Native source not connected yet")).font(ShouType.body.weight(.semibold))
                            Text(model.t("Not connected. Use the official guide."))
                                .foregroundStyle(ShouPalette.secondary)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
                    } else if let plan=session.plan { review(plan) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(ShouDesign.workspaceInset)
            }
            if session.plan != nil {
                ShouDivider()
                HStack {
                    Text(model.t("This review is valid for two minutes and can be used once.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                    Spacer()
                    Button(model.t("Cancel")) { session.plan=nil }.disabled(model.busy)
                    Button(model.t(session.plan?.action == .install ? "Confirm Installation" : "Confirm Uninstall")) { session.execute(app: model) }
                        .buttonStyle(.borderedProminent).tint(session.plan?.action == .uninstall ? ShouPalette.danger : ShouPalette.accent)
                        .disabled(model.busy).accessibilityIdentifier("developer.confirm")
                }.padding(ShouDesign.workspaceInset)
            }
        }
        .onAppear { updateTargets(tool) }
        .onChange(of:tool.id) { updateTargets(tool) }
        .onChange(of:session.inventory?.installations) { updateTargets(tool) }
        .onChange(of:session.services?.services) { updateTargets(tool) }
    }
    private func updateTargets(_ tool: DeveloperToolDefinition) {
        if tool.id == "mysql" { updateMySQLTargets() }
        else { session.configuration.update(toolID:tool.id,installations:session.installations(tool.id),services:session.toolServices(tool.id)) }
    }
    private func updateMySQLTargets() { session.mysql.updateTargets(installations:session.installations("mysql"),services:session.toolServices("mysql")) }
    private func availableVersions(_ tool: DeveloperToolDefinition) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(model.t("Available Packages")).font(ShouType.body.weight(.semibold))
                Spacer()
                Button(model.t("Refresh Versions")) { session.loadVersions() }.disabled(model.busy || session.versionsLoading)
            }
            if session.versionsLoading { ProgressView().controlSize(.small) }
            HStack {
                Text("Homebrew").frame(maxWidth:.infinity,alignment:.leading)
                Text(model.t("Available Version")).frame(width:100,alignment:.leading)
                Text(model.t("Installed Version")).frame(width:140,alignment:.leading)
                Spacer().frame(width:130)
            }.font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            ForEach(session.versionInspections,id:\.package.id) { value in
                HStack {
                    Text(value.package.token).font(ShouType.body.weight(.medium)).frame(maxWidth:.infinity,alignment:.leading)
                    Text(value.availableVersion ?? model.t("Unavailable")).font(ShouType.body).frame(width:100,alignment:.leading)
                    Text(value.installed ? value.installedVersions.joined(separator:", ") : model.t("Not installed by this source")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).frame(width:140,alignment:.leading)
                    Button(model.t(value.installed ? "Review Uninstall" : "Review Installation")) {
                        session.package=value.package; session.inspection=value
                        session.prepare(value.installed ? .uninstall : .install,app:model)
                    }.disabled(model.busy || !value.allows(value.installed ? .uninstall : .install)).tint(value.installed ? ShouPalette.danger : ShouPalette.accent).frame(width:130,alignment:.trailing)
                }
                ShouDivider()
            }
        }.padding(18).modifier(WorkspaceSurface()).onAppear { if session.versionInspections.isEmpty { session.loadVersions() } }
    }
    private func sourceChip(_ id: String, _ title: String) -> some View {
        Button { session.sourceFilter=id; session.plan=nil; session.inspection=nil } label: {
            Text(model.t(title)).font(ShouType.body.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 6)
                .foregroundStyle(session.sourceFilter == id ? ShouPalette.accent : ShouPalette.secondary)
                .background(session.sourceFilter == id ? ShouPalette.selection : ShouPalette.inset, in: Capsule())
        }.buttonStyle(.plain).disabled(model.busy || session.plan != nil)
    }
    private func installedCopies(_ tool: DeveloperToolDefinition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("Existing Installations")).font(ShouType.body.weight(.semibold))
            HStack(spacing: 12) {
                Text(model.t("Version")).frame(width: ShouDesign.toolVersionWidth, alignment: .leading)
                Text(model.t("Path")).frame(maxWidth: .infinity, alignment: .leading)
                Text(model.t("Installation Source")).frame(width: ShouDesign.toolSourceWidth, alignment: .leading)
                Text(model.t("Service")).frame(width: ShouDesign.toolServiceWidth)
                Text(model.t("Actions")).frame(width:100)
            }.font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            ShouDivider()
            ForEach(session.installations(tool.id).filter { session.sourceFilter == "all" || $0.source == session.sourceFilter }) { row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.version ?? model.t("Version not verified")).font(ShouType.body.weight(.medium)).frame(width: ShouDesign.toolVersionWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.path).font(ShouType.body).textSelection(.enabled)
                        if !row.launchPaths.isEmpty {
                            Text(model.t("Launch Paths") + "\n" + row.launchPaths.joined(separator: "\n")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.t(row.source)).font(ShouType.body).foregroundStyle(ShouPalette.secondary).frame(width: ShouDesign.toolSourceWidth, alignment: .leading)
                    Group {
                        if let service=session.serviceForInstallation(row) {
                            Text(model.t(service.state == "running" ? "Running" : service.state == "stopped" ? "Stopped" : "State Unknown"))
                                .font(ShouType.caption).foregroundStyle(service.state == "running" ? ShouPalette.accent : ShouPalette.secondary)
                        }
                        else if session.servicesForInstallation(row).count > 1 {
                            Text(model.t("Multiple Services")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        } else { Text("—").foregroundStyle(ShouPalette.secondary).help(model.t("Service control is not connected for this installation.")) }
                    }.frame(width: ShouDesign.toolServiceWidth)
                    Group { if session.managedPackage(row) != nil {
                        Button(model.t("Review Uninstall")) { session.reviewUninstall(row,app:model) }
                            .tint(ShouPalette.danger)
                            .disabled(model.busy || session.inventoryLoading || session.servicesLoading || session.servicesForInstallation(row).contains(where:{ $0.state != "stopped" }))
                            .help(model.t("Stop the instances using this installation before uninstalling it."))
                            .accessibilityIdentifier("developer.installation.uninstall." + row.id)
                    } else { Color.clear.frame(height:1) } }.frame(width:100)
                }
                ShouDivider()
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
    }
    private func serviceState(_ row: DeveloperService) -> String {
        if session.changingServiceID == row.id {
            if let stage=session.serviceStage {
                return switch stage { case "checking": "Checking Service…"; case "stopping": "Stopping…"; case "stopped": "Service stopped. Starting…"; case "starting": "Starting…"; default: "Verifying Service…" }
            }
            return switch session.changingServiceAction { case .restart: "Restarting…"; case .start: "Starting…"; default: "Stopping…" }
        }
        return switch row.state {
        case "running": "Running"
        case "stopped": "Stopped"
        case "external": "Running Elsewhere"
        case "starting": "Starting…"
        case "stopping": "Stopping…"
        default: "State Unknown"
        }
    }
    private func toolStatus(_ id: String) -> String {
        if session.inventoryLoading { return "Inspecting…" }
        if session.checkingServices(id) { return "Checking Service…" }
        let rows=session.toolServices(id)
        if rows.count == 1, let row=rows.first { return serviceState(row) }
        if rows.count > 1 { return "Multiple Services" }
        let copies=session.installations(id)
        return copies.isEmpty ? "Not found in scanned sources" : copies.contains { $0.status == "registered" } ? "Installed" : "Detected executable"
    }
    private func serviceDetails(_ tool: DeveloperToolDefinition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.t("Service Instances")).font(ShouType.body.weight(.semibold))
                Spacer()
                if let observed=session.servicesObservedAt { Text(model.t("Last Checked") + ": " + observed.formatted(date: .omitted, time: .standard)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                Button(model.t(session.servicesLoading ? "Checking Service…" : "Refresh Status")) { session.refreshServices(app: model) }.disabled(model.busy || session.inventoryLoading || session.servicesLoading)
            }
            ForEach(session.toolServices(tool.id)) { row in
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack { instanceSummary(row); Spacer(); instanceActions(row) }
                        VStack(alignment: .leading, spacing: 10) { instanceSummary(row); instanceActions(row) }
                    }
                    if row.issue != nil { Text(model.t(instanceIssue(row.issue))).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
                    else if row.registeredAtLogin {
                        Label(model.t("Starts at Login"), systemImage: "power").font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    }
                    HStack(spacing: 12) {
                        if row.logPath != nil { Button(model.t("View Service Log")) { session.loadLog(row) }.disabled(session.logLoading) }
                        if row.errorLogPath != nil, row.errorLogPath != row.logPath { Button(model.t("View Error Log")) { session.loadLog(row, errorLog: true) }.disabled(session.logLoading) }
                        if row.logPath != nil || row.errorLogPath != nil {
                            Menu(model.t("Show in Finder")) {
                                if let path=row.logPath { Button(model.t("Reveal Output Log")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) } }
                                if let path=row.errorLogPath, path != row.logPath { Button(model.t("Reveal Error Log")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) } }
                            }.fixedSize().disabled(model.busy)
                        }
                    }
                    Text(row.configurationPath).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ShouPalette.inset, in: RoundedRectangle(cornerRadius: ShouDesign.insetRadius))
            }
            if session.toolServices(tool.id).isEmpty { Text(model.t(session.inventoryLoading || session.servicesLoading ? "Service discovery is running in the background. You can keep browsing tools." : "No verified service instances in the scanned sources.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
            if let result=session.serviceResult, result.service.toolID == tool.id, let code=result.failureCode {
                Label(model.t(serviceFailureMessage(result.stage)), systemImage: "exclamationmark.triangle")
                    .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                Text(code).font(ShouType.code).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            }
            if session.logLoading { Text(model.t("Reading service log…")).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
            if let failure=session.logFailure { Text(model.t(failure)).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
            if let text=session.logText {
                HStack {
                    Text(model.t("Service Log")).font(ShouType.body.weight(.medium))
                    Spacer()
                    Button(model.t("Close")) { session.logText=nil; session.logService=nil }
                }
                if let row=session.logService { Text(model.t(row.source) + " / " + row.configurationPath).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
                DeveloperLogCleanupControls(model:model,session:session.configuration.logCleanup,toolID:tool.id,path:session.logPath,
                    canReview:!session.logLoading && !text.isEmpty,completed:{ session.logText="" })
                ScrollView([.horizontal,.vertical]) {
                    Text(text.isEmpty ? model.t("No log entries yet.") : text).font(ShouType.code)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }.frame(minHeight: 180, maxHeight: 320).background(ShouPalette.inset, in: RoundedRectangle(cornerRadius: ShouDesign.insetRadius))
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
    }
    private func instanceSummary(_ row: DeveloperService) -> some View {
        HStack {
            Label(model.t(serviceState(row)), systemImage: row.state == "running" ? "circle.fill" : "circle")
                .foregroundStyle(row.state == "running" ? ShouPalette.accent : ShouPalette.secondary)
            Text(model.t(row.source) + " / " + (row.version.isEmpty ? model.t("Version not verified") : row.version)).foregroundStyle(ShouPalette.secondary)
            if let pid=row.processID { Text("PID \(pid)").font(ShouType.code).foregroundStyle(ShouPalette.secondary) }
        }.font(ShouType.body)
    }
    private func instanceActions(_ row: DeveloperService) -> some View {
        HStack {
            serviceSwitch(row)
            if session.changingServiceID != row.id {
                Button(model.t("Restart Service")) { session.performService(.restart, expected: row, app: model) }
                    .disabled(model.busy || session.inventoryLoading || session.servicesLoading || !row.controllable || row.state != "running" || session.staleServiceIDs.contains(row.id))
                    .accessibilityIdentifier("developer.restart." + row.id)
            }
            if row.controllable {
                Button(model.t("Show Service Definition")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.configurationPath)]) }.disabled(model.busy)
            }
        }.font(ShouType.body)
    }
    private func serviceFailureMessage(_ stage: String?) -> String {
        switch stage {
        case "stopping": "Stopping failed. No new instance was started."
        case "starting": "Starting failed. Check the service log before retrying."
        case "verifying": "The requested state could not be verified. Refresh status before retrying."
        default: "The service could not be verified before the action. Refresh status before retrying."
        }
    }
    private func instanceIssue(_ issue: String?) -> String {
        switch issue {
        case "developer_instance_ambiguous": "Multiple processes match this instance configuration. Its switch is unavailable until their identities can be distinguished."
        case "developer_instance_recipe_missing": "This instance is running. Its exact configuration must be verified before restart; no process will be stopped while its recovery recipe is incomplete."
        case "developer_instance_supervisor_unverified": "This instance has a supervisor. Its lifecycle must be controlled through that exact supervisor to avoid automatic respawn."
        case "developer_instance_directory_writable": "This instance's working directory is writable by a group or other users. Its process is running, but restart is unavailable until the directory can be verified. Shou does not change its permissions."
        default: "This service source or definition could not be verified. Its switch is unavailable."
        }
    }
    private func facts(_ value: DeveloperToolInspection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShouDivider()
            fact("Installed Version", value.installed ? value.installedVersions.joined(separator: " / ") : model.t("Not installed by this source"))
            fact("Available Version", value.availableVersion ?? model.t("Unavailable"))
            fact("Installation Scope", value.scope)
            if !value.dependencies.isEmpty { fact("Declared Dependencies", value.dependencies.joined(separator: ", ")) }
            if value.issue != nil { Text(model.t("This source cannot currently install the tool. Existing managed versions may still be uninstalled.")).foregroundStyle(ShouPalette.secondary) }
            HStack {
                if value.allows(.install) {
                    Button(model.t("Review Installation")) { session.prepare(.install, app: model) }.buttonStyle(.borderedProminent)
                }
                if value.allows(.uninstall) {
                    Button(model.t("Review Uninstall")) { session.prepare(.uninstall, app: model) }.tint(ShouPalette.danger)
                }
            }.disabled(model.busy)
        }
    }
    private var workspaceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.t("Configuration & Extensions"), systemImage: "slider.horizontal.3").font(ShouType.body.weight(.semibold))
                Spacer()
                Button(model.t("Refresh")) { session.loadWorkspace() }.disabled(session.workspaceLoading)
            }
            if session.workspaceLoading { ProgressView() }
            ForEach(session.workspace?.resources ?? []) { resource in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(model.t(workspaceTitle(resource.kind))).font(ShouType.body.weight(.medium))
                        Spacer()
                        Text(model.t(resource.state == "present" ? "Found" : resource.state == "missing" ? "Not found in this location" : resource.state == "partial" ? "Partial coverage" : "Could not inspect"))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        if ["present", "partial"].contains(resource.state) {
                            Button(model.t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: resource.path)]) }
                        }
                    }
                    Text(resource.path).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    if !resource.names.isEmpty { Text(resource.names.joined(separator: "\n")).font(ShouType.body).textSelection(.enabled) }
                }
                ShouDivider()
            }
            Text(model.t("Known user locations; activation not verified."))
                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
    }
    private func workspaceTitle(_ kind: String) -> String {
        switch kind {
        case "mcp": "MCP Declarations"
        case "skills": "Installed Skills"
        case "instructions": "Global Instructions"
        default: "Provider Configuration"
        }
    }
    private func review(_ plan: DeveloperToolPlan) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(model.t(plan.action == .install ? "Review Installation" : "Review Uninstall"), systemImage: plan.action == .install ? "shippingbox" : "trash")
                .font(ShouType.body.weight(.semibold))
            fact("Installation Source", "Homebrew / " + plan.inspection.package.token)
            fact("Version", plan.action == .install ? plan.inspection.availableVersion ?? "" : plan.inspection.installedVersions.joined(separator: " / "))
            fact("Installation Scope", plan.inspection.scope)
            if plan.action == .install && !session.installations(plan.toolID).isEmpty {
                Label(model.t("Other installations will be kept. This installs an additional copy from the selected source."), systemImage: "square.on.square")
                    .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            }
            if !plan.inspection.dependencies.isEmpty { fact("Declared Dependencies", plan.inspection.dependencies.joined(separator: ", ")) }
            Text(model.t(plan.action == .install
                ? "Homebrew will install this package and may install or upgrade its dependencies. It may run package setup steps. Shou does not automatically install Homebrew, use sudo or accept license agreements."
                : "Homebrew will permanently uninstall this package. Shou does not request data removal, zap, force or dependency cleanup. Package uninstall hooks may still change files they own; back up important data first."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
    }
    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(model.t(title)).foregroundStyle(ShouPalette.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(ShouType.body)
    }
    private func resultView(_ result: DeveloperToolResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.t(result.state == "succeeded" ? "Developer tool change verified" : "Developer tool result needs verification"), systemImage: result.state == "succeeded" ? "checkmark.circle" : "exclamationmark.triangle")
                .font(ShouType.body.weight(.semibold))
            Text(model.t(result.state == "succeeded" ? "The installed package state matches the requested operation." : "The package manager may have changed files. Inspect the source before trying again; Shou will not retry automatically."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            Button(model.t("Inspect Again")) { session.inspect(app: model) }.disabled(model.busy)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).modifier(WorkspaceSurface())
    }
}
