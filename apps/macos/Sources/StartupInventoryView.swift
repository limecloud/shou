import SwiftUI
import AppKit
import ServiceManagement
import ShouCore

private struct StartupControlRequest: Identifiable {
    let id=UUID()
    let definitions: [StartupDefinition]
    let action: StartupControlAction
}

struct StartupInventoryView: View {
    @Bindable var model: AppModel
    @State private var search=""
    @State private var filter=StartupFilter.all
    @State private var expandedID: String?
    @State private var showCoverage=false
    @State private var pendingControl: StartupControlRequest?

    private var groups: [StartupApplicationGroup] { StartupPresentation.groups(model.startupInventory?.items ?? []) }
    private var visibleGroups: [StartupApplicationGroup] { groups.filter { filter.matches($0) && $0.matches(query: search) } }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if model.startupLoading && model.startupInventory == nil {
                    OperationProgressView(title: model.t("Reading startup definitions…"), symbol: "power", stopRequested: model.stopRequested,
                        stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: model.cancel)
                } else {
                    workspace(compact: geometry.size.width < 760)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
        .task(id: model.initializing) {
            if !model.initializing && model.startupInventory == nil && !model.busy { model.scanStartup() }
        }
        .onChange(of: model.startupIncludeSystem) { _, _ in expandedID=nil; model.scanStartup() }
        .sheet(isPresented: $showCoverage) { coverage }
        .sheet(item: $pendingControl) { request in confirmation(request) }
        .toolbar { ToolbarItemGroup { header } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                Toggle(model.t("Include Apple system definitions"), isOn: $model.startupIncludeSystem)
                Button(model.t("View Coverage…")) { showCoverage=true }
                Button(model.t("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                .accessibilityLabel(model.t("Startup Options")).accessibilityIdentifier("startup.options")
            Button {
                if model.startupLoading { model.cancel() } else { model.scanStartup() }
            } label: {
                Label(model.t(model.startupLoading ? model.stopRequested ? "Stopping…" : "Stop" : "Scan Again"),
                    systemImage: model.startupLoading ? "stop.fill" : "arrow.clockwise")
            }
            .disabled((model.busy && !model.startupLoading) || (model.startupLoading && model.stopRequested))
            .accessibilityIdentifier("startup.refresh")
        }
    }

    private func workspace(compact: Bool) -> some View {
        VStack(spacing: 0) {
            summary
            Divider()
            if compact {
                VStack(spacing: 8) { filters; searchField }.padding(10)
            } else {
                HStack(spacing: 12) { filters; Spacer(minLength: 12); searchField.frame(maxWidth: 280) }.padding(10)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleGroups) { group in
                        StartupInventoryRow(model: model, group: group, expanded: expandedID == group.id,
                            toggleExpanded: { expandedID=expandedID == group.id ? nil : group.id },
                            requestControl: requestControl)
                    }
                }.padding(8)
            }
            .accessibilityIdentifier("startup.definitions")
            .overlay {
                if visibleGroups.isEmpty {
                    ContentUnavailableView(model.t(groups.isEmpty ? "No startup items found" : "No matching startup items"),
                        systemImage: search.isEmpty ? "power.circle" : "magnifyingglass",
                        description: Text(model.t(groups.isEmpty ? "Scan again or review discovery coverage." : "Try another search or startup category.")))
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55)))
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Text(String(format: model.t("%lld startup programs"), locale: model.language.locale, groups.count))
                .font(.callout.weight(.medium))
            Text(model.t("Startup Enabled")).font(.caption).foregroundStyle(.secondary)
            Text(String(groups.filter(StartupFilter.enabled.matches).count))
                .font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor).monospacedDigit()
            Spacer(minLength: 4)
            if model.startupLoading || model.startupControlLoading { ProgressView().controlSize(.small) }
            if model.startupInventory?.status == "partial" {
                Button { showCoverage=true } label: { Label(model.t("Partial Coverage"), systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.link).font(.caption).accessibilityIdentifier("startup.coverage")
            }
        }.padding(14)
    }

    private var filters: some View {
        HStack(spacing: 3) {
            ForEach(StartupFilter.allCases, id: \.self) { item in
                Button { filter=item } label: {
                    HStack(spacing: 5) {
                        Text(model.t(filterTitle(item)))
                        Text(String(groups.filter(item.matches).count)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(filter == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(filter == item ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain).accessibilityIdentifier("startup.filter." + item.rawValue)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(model.t("Search programs or publishers"), text: $search).textFieldStyle(.plain)
                .accessibilityIdentifier("startup.search")
            if !search.isEmpty {
                Button { search="" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(model.t("Clear search"))
            }
        }
        .font(.callout).padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.65)))
    }

    private func requestControl(_ definitions: [StartupDefinition], _ action: StartupControlAction) {
        guard !model.busy, !definitions.isEmpty else { return }
        pendingControl=StartupControlRequest(definitions: definitions, action: action)
    }

    private func confirmation(_ request: StartupControlRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t(request.action == .remove ? "Remove startup items?" : request.action == .enable ? "Enable startup items?" : "Disable startup items?"))
                .font(.title2.bold())
            Text(model.t(request.action == .remove
                ? "Selected definitions will be moved to Trash. Applications and their data are kept. Running processes are not terminated."
                : "This changes startup configuration for the selected items. Running processes are not terminated."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if request.definitions.contains(where: { $0.controlCapability == "launchctl_system_daemon" }) {
                Label(model.t("macOS will request administrator approval for system background items."), systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.definitions) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayName ?? item.label).font(.headline)
                            Text(model.t(startupSourceTitle(item.sourceId))).font(.caption).foregroundStyle(.secondary)
                            Text(item.path.hasPrefix("/") ? item.path : item.applicationPath ?? item.label)
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 220)
            HStack {
                Button(model.t("Cancel")) { pendingControl=nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.t(request.action == .remove ? "Move to Trash" : request.action == .enable ? "Enable" : "Disable"),
                    role: request.action == .remove ? .destructive : nil) {
                    pendingControl=nil
                    model.controlStartup(request.definitions, action: request.action)
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("startup.confirm")
            }
        }.padding(24).frame(width: 560)
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Startup Discovery Coverage")).font(.title2.bold())
            Text(model.t("Checking is read-only. No startup setting or file is changed.")).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.startupInventory?.sources ?? []) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(model.t(startupSourceTitle(source.id))).bold(); Spacer(); Text(model.t(coverageTitle(source.status))) }
                            Text(source.location.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(Array((model.startupInventory?.issues.filter { $0.sourceId == source.id } ?? []).enumerated()), id: \.offset) { _, issue in
                                Text(model.t(issueTitle(issue.code)) + "\n" + issue.path).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                    }
                    if let unavailable=model.startupInventory?.unavailableSources, !unavailable.isEmpty {
                        Divider()
                        Text(model.t("Outside this discovery scope")).font(.headline)
                        Text(model.t("Some login items and embedded helpers may require System Settings. Permission and read-budget gaps remain visible."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(model.t("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                Spacer()
                Button(model.t("Close")) { showCoverage=false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 720, height: 600)
    }

    private func filterTitle(_ filter: StartupFilter) -> String {
        switch filter { case .all: "Startup All"; case .enabled: "Startup Enabled"; case .disabled: "Startup Disabled"; case .leftover: "Startup Leftovers" }
    }
    private func coverageTitle(_ status: String) -> String {
        switch status { case "complete": "Inspected"; case "missing": "Not present"; case "partial": "Partial"; case "not_scanned": "Not inspected"; default: "Unavailable" }
    }
    private func issueTitle(_ code: String) -> String {
        switch code {
        case "resource_limit": "Read budget reached"
        case "permission_denied": "Permission denied"
        case "state_unavailable": "Startup state could not be verified."
        case "linked_definition": "Linked definition was not followed"
        case "definition_too_large": "Definition exceeds the read limit"
        case "definition_changed": "Definition changed while reading"
        case "unsupported_definition": "Definition is not a regular file"
        case "invalid_definition", "invalid_filename": "Definition could not be interpreted"
        default: "Source could not be read"
        }
    }
}
