import SwiftUI
import AppKit
import ServiceManagement
import ShouCore

private struct StartupControlRequest: Identifiable {
    let id=UUID()
    let definition: StartupDefinition
    let action: StartupControlAction
}

struct StartupInventoryView: View {
    @Bindable var model: AppModel
    @State private var search=""
    @State private var selection: String?
    @State private var showCoverage=false
    @State private var pendingControl: StartupControlRequest?
    private var items: [StartupDefinition] {
        (model.startupInventory?.items ?? []).filter {
            search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) || ($0.programPath?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
    private var selected: StartupDefinition? { items.first { $0.id == selection } }
    var body: some View {
        GeometryReader { geometry in
            content.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .task(id: model.initializing) {
            if !model.initializing && model.startupInventory == nil && !model.busy { model.scanStartup() }
        }
        .onChange(of: model.startupIncludeSystem) { _, _ in selection=nil; model.scanStartup() }
        .onChange(of: model.startupLoading) { _, loading in if loading { selection=nil } }
        .sheet(isPresented: $showCoverage) { coverage }
        .toolbar {
            ToolbarItemGroup {
                PageInfoButton(title: model.t("Startup Items"), message: model.t("Review background-task definitions and manage login items in macOS Settings.") + "\n\n" + model.t("This list shows launchd definitions. Login Items, background registrations and embedded helpers are available in System Settings. A definition does not prove a task is enabled or running."))
                Button { openSettings() } label: { Label(model.t("Open Login Items Settings"), systemImage: "arrow.up.forward.app") }
                    .labelStyle(.iconOnly).help(model.t("Open Login Items Settings")).accessibilityIdentifier("startup.settings")
            }
        }
        .confirmationDialog(
            model.t(pendingControl?.action == .enable ? "Enable startup definition?" : "Disable startup definition?"),
            isPresented: Binding(get: { pendingControl != nil }, set: { if !$0 { pendingControl=nil } }),
            titleVisibility: .visible
        ) {
            if let pendingControl {
                Button(model.t(pendingControl.action == .enable ? "Enable" : "Disable")) {
                    let request=pendingControl; self.pendingControl=nil
                    model.controlStartup(request.definition, action: request.action)
                }
                Button(model.t("Cancel"), role: .cancel) { self.pendingControl=nil }
            }
        } message: {
            if let pendingControl {
                Text(String(format: model.t("This changes the current user's launchd override for %@. Existing processes are not terminated."), pendingControl.definition.label))
            }
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField(model.t("Search startup names or paths"), text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("startup.search")
                Toggle(model.t("Include Apple system definitions"), isOn: $model.startupIncludeSystem)
                    .toggleStyle(.checkbox).disabled(model.busy).accessibilityIdentifier("startup.includeSystem")
                if model.startupLoading {
                    Button(model.t(model.stopRequested ? "Stopping…" : "Stop")) { model.cancel() }.disabled(model.stopRequested).accessibilityIdentifier("startup.stop")
                } else {
                    Button { model.scanStartup() } label: { Label(model.t("Check Again"), systemImage: "arrow.clockwise") }
                        .disabled(model.busy).accessibilityIdentifier("startup.refresh")
                }
            }
            if model.startupLoading {
                OperationProgressView(title: model.t("Reading startup definitions…"), symbol: "power",
                    countText: model.t("Discovering startup items…"), stopRequested: model.stopRequested,
                    stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: model.cancel)
            } else if let report=model.startupInventory {
                HStack {
                    Text(String(format: model.t("%lld definitions found"), locale: model.language.locale, report.items.count))
                    if !search.isEmpty { Text(String(format: model.t("%lld matches"), locale: model.language.locale, items.count)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(model.date(report.checkedAt)).foregroundStyle(.secondary)
                    Button(model.t("View Coverage…")) { showCoverage=true }.accessibilityIdentifier("startup.coverage")
                }.font(.caption)
                if report.status == "partial" {
                    Label(model.t("Some startup definitions could not be inspected."), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Table(items, selection: $selection) {
                    TableColumn(model.t("Name")) { item in
                        Label(item.label, systemImage: "gearshape.2").lineLimit(1).help(item.label)
                    }.width(min: 180, ideal: 300)
                    TableColumn(model.t("Source")) { item in Text(sourceTitle(item.sourceId)).foregroundStyle(.secondary) }.width(min: 130, ideal: 170)
                    TableColumn(model.t("Definition")) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            if item.disabledByDefinition {
                                Text(model.t("Disabled in definition"))
                            }
                            let states=observedStates(item)
                            if states.isEmpty {
                                Text(model.t("System state not checked"))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(states).foregroundStyle(.secondary)
                            }
                        }
                    }.width(min: 130, ideal: 180)
                }.frame(minHeight: 0, maxHeight: .infinity)
                    .accessibilityIdentifier("startup.definitions")
                    .overlay {
                        if items.isEmpty {
                            ContentUnavailableView(model.t(search.isEmpty ? "No definitions found in the inspected sources" : "No matching startup definitions"), systemImage: "power.circle")
                        }
                    }
                if let selected { details(selected) }
                else { Text(model.t("Select a definition to inspect its source and executable path.")).font(.caption).foregroundStyle(.secondary) }
            } else {
                ContentUnavailableView(model.t("Check startup definitions"), systemImage: "power.circle",
                    description: Text(model.t("Checking is read-only. No startup setting or file is changed.")))
            }
        }.padding(16)
    }

    private func details(_ item: StartupDefinition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.label).font(.headline).textSelection(.enabled)
                Spacer()
                if item.controlCapability == "launchctl_user_agent" {
                    Button { pendingControl=StartupControlRequest(definition: item, action: .enable) } label: {
                        Label(model.t("Enable"), systemImage: "play.circle")
                    }.disabled(model.busy).accessibilityIdentifier("startup.enable")
                    Button { pendingControl=StartupControlRequest(definition: item, action: .disable) } label: {
                        Label(model.t("Disable"), systemImage: "stop.circle")
                    }.disabled(model.busy).accessibilityIdentifier("startup.disable")
                }
                Button(model.t("Reveal Definition in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    .accessibilityIdentifier("startup.reveal")
                Button(model.t("Copy Path")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.path, forType: .string)
                }.accessibilityIdentifier("startup.copyPath")
            }
            Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            LabeledContent(model.t("Executable"), value: item.programPath ?? model.t("Not resolved"))
                .font(.caption.monospaced()).textSelection(.enabled)
            LabeledContent(model.t("Trigger clues"), value: item.triggers.isEmpty ? model.t("Not specified") : item.triggers.map { model.t(triggerTitle($0)) }.joined(separator: " · "))
                .font(.caption)
            if item.controlCapability == "launchctl_user_agent" {
                Text(model.t("Direct control is limited to this user's LaunchAgents. The definition hint and launchd override can differ; recheck after changing it."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let states=observedStates(item)
            if !states.isEmpty { Text(states).font(.caption.monospaced()) }
            Text(model.t(states.isEmpty ? "Configured and runtime states are unknown. A Disabled key is a definition hint; launchd overrides may differ." : "Observed startup state is best effort; launchd can change after this read."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private func observedStates(_ item: StartupDefinition) -> String {
        [item.configuredState, item.runtimeState]
            .filter { $0 != "unknown" }
            .map(stateTitle)
            .joined(separator: " · ")
    }
    private func stateTitle(_ state: String) -> String {
        switch state {
        case "enabled": return model.t("Enabled")
        case "disabled": return model.t("Disabled")
        case "running": return model.t("Running")
        case "loaded": return model.t("Loaded")
        case "not_loaded": return model.t("Not loaded")
        default: return model.t("State unavailable")
        }
    }
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Startup Discovery Coverage")).font(.title2.bold())
            Text(model.t("Checking is read-only. No startup setting or file is changed.")).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.startupInventory?.sources ?? []) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(sourceTitle(source.id)).bold(); Spacer(); Text(model.t(coverageTitle(source.status))) }
                            Text(source.location.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(Array((model.startupInventory?.issues.filter { $0.sourceId == source.id } ?? []).enumerated()), id: \.offset) { _, issue in
                                Text(model.t(issueTitle(issue.code)) + "\n" + issue.path).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                    }
                    Divider()
                    Text(model.t("Outside this discovery scope")).font(.headline)
                    Text(model.t("Login Items, background-task registrations and helpers embedded in applications require System Settings. Apple system definitions are included only when requested. Permission and read-budget gaps remain visible."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack { Button(model.t("Open Login Items Settings")) { openSettings() }; Spacer(); Button(model.t("Close")) { showCoverage=false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 720, height: 600)
    }
    private func sourceTitle(_ id: String) -> String {
        let location=model.startupInventory?.sources.first { $0.id == id }?.location
        if location?.systemOwned == true { return model.t(location?.kind == "daemon" ? "Apple system daemons" : "Apple system agents") }
        return model.t(location?.scope == "user" ? "Current user agents" : location?.kind == "daemon" ? "All-user daemons" : "All-user agents")
    }
    private func coverageTitle(_ status: String) -> String {
        switch status { case "complete": "Inspected"; case "missing": "Not present"; case "partial": "Partial"; case "not_scanned": "Not inspected"; default: "Unavailable" }
    }
    private func triggerTitle(_ trigger: String) -> String {
        switch trigger {
        case "run_at_load": "At load"
        case "keep_alive": "Keep alive"
        case "conditional_keep_alive": "Conditional keep alive"
        case "scheduled": "Scheduled"
        case "watched_paths": "Watched paths"
        case "queued_directories": "Queued directories"
        case "socket_activation": "Socket activation"
        default: "Service activation"
        }
    }
    private func issueTitle(_ code: String) -> String {
        switch code {
        case "resource_limit": "Read budget reached"
        case "permission_denied": "Permission denied"
        case "linked_definition": "Linked definition was not followed"
        case "definition_too_large": "Definition exceeds the read limit"
        case "definition_changed": "Definition changed while reading"
        case "unsupported_definition": "Definition is not a regular file"
        case "invalid_definition", "invalid_filename": "Definition could not be interpreted"
        default: "Source could not be read"
        }
    }
    private func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
