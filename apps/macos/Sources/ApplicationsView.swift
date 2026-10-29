import AppKit
import SwiftUI
import ShouCore

private enum ApplicationFilter: String, CaseIterable {
    case all, ready, running, administrator, protected
    var title: String {
        switch self {
        case .all: "All Applications"
        case .ready: "Ready to Uninstall"
        case .running: "Running"
        case .administrator: "Authentication Required"
        case .protected: "Cannot Uninstall"
        }
    }
    func matches(_ item: ApplicationSummary) -> Bool {
        switch self {
        case .all: true
        case .ready: ["ready", "admin-required", "trash-required", "shortcut"].contains(item.status)
        case .running: item.status == "running"
        case .administrator: item.status == "admin-required"
        case .protected: ["protected", "unavailable"].contains(item.status)
        }
    }
}
private enum ApplicationSort { case name, status, size, lastUsed }

struct ApplicationsView: View {
    @Bindable var model: AppModel
    @Bindable var session: ApplicationsSession
    @State private var search=""
    @State private var filter=ApplicationFilter.all
    @State private var sort=ApplicationSort.size
    @State private var ascending=false
    @State private var showCoverage=false
    @State private var showCoverageAfterOrphans=false
    @FocusState private var searchFocused: Bool
    @FocusState private var browsingFocused: Bool

    private var items: [ApplicationSummary] {
        session.items.filter { item in
            let app=item.application
            return filter.matches(item) && (search.isEmpty || [app.name, app.path, app.bundleIdentifier ?? "", app.version ?? ""].contains { $0.localizedStandardContains(search) })
        }.sorted { a, b in
            let order: ComparisonResult
            switch sort {
            case .name: order=a.application.name.localizedStandardCompare(b.application.name)
            case .status: order=a.status.compare(b.status)
            case .size:
                if a.allocatedBytesEstimate == nil || b.allocatedBytesEstimate == nil {
                    if a.allocatedBytesEstimate == nil && b.allocatedBytesEstimate != nil { return false }
                    if b.allocatedBytesEstimate == nil && a.allocatedBytesEstimate != nil { return true }
                }
                order=compare(a.allocatedBytesEstimate ?? 0, b.allocatedBytesEstimate ?? 0)
            case .lastUsed:
                if a.lastUsed == nil || b.lastUsed == nil {
                    if a.lastUsed == nil && b.lastUsed != nil { return false }
                    if b.lastUsed == nil && a.lastUsed != nil { return true }
                }
                order=(a.lastUsed ?? .distantPast).compare(b.lastUsed ?? .distantPast)
            }
            if order == .orderedSame {
                let names=a.application.name.localizedStandardCompare(b.application.name)
                return names == .orderedSame ? a.application.path.utf8.lexicographicallyPrecedes(b.application.path.utf8) : names == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
    private func compare(_ a: Int64, _ b: Int64) -> ComparisonResult { a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending }
    private var eligible: [ApplicationSummary] { items.filter(session.selectable) }
    private var selectedVisible: Int { eligible.filter { session.isSelected($0.application.id) }.count }

    var body: some View {
        Group {
            if session.catalog == nil && session.items.isEmpty && !session.scanning {
                WorkspaceStartPage(eyebrow: model.t("Applications"), title: model.t("Keep the apps you love."),
                    subtitle: model.t("Review applications and their related files in one place."), kind: .applications,
                    footnote: model.t("Scanning only reads application information. Review components before uninstalling.")) {
                    Button { session.scan(app: model) } label: { Label(model.t("Scan Applications"), systemImage: "magnifyingglass") }
                        .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(model.busy).accessibilityIdentifier("applications.start")
                }.accessibilityIdentifier("applications.welcome")
            } else {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !session.scanning { ScanAccessBanner(model: model) }
                    summary
                    ShouDivider()
                    filters
                    ShouDivider()
                    columns(compact: geometry.size.width < 840)
                    ShouDivider()
                    if session.scanning && session.items.isEmpty {
                        VStack(spacing: 14) {
                            OperationActivityArtwork(symbol: "app.dashed", stopped: session.stopRequested)
                                .scaleEffect(0.7).frame(width: ShouDesign.cleanupArtworkWidth, height: 138)
                            Text(model.t("Measuring application sizes…")).foregroundStyle(ShouPalette.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items, id: \.application.id) { item in
                                    ApplicationUninstallRow(model: model, session: session, summary: item, compact: geometry.size.width < 840)
                                    ShouDivider().padding(.leading, 54)
                                }
                            }.padding(.horizontal, 10)
                        }
                        .focusable().focused($browsingFocused).focusEffectDisabled()
                        .onKeyPress(keys: [.escape, "a"]) { key in
                            guard !searchFocused, !model.busy else { return .ignored }
                            if key.key == .escape { session.clear(app: model); return .handled }
                            if key.key == "a", key.modifiers.contains(.command) { session.selectVisible(items, app: model); return .handled }
                            return .ignored
                        }
                        .overlay {
                            if items.isEmpty {
                                WorkspaceEmptyState(title: model.t(search.isEmpty ? "No applications in this category" : "No matching applications"), kind: .applications)
                            }
                        }
                    }
                }
                .modifier(WorkspaceSurface())
                .padding(.horizontal, ShouDesign.workspaceInset)
                .padding(.bottom, 10)
                footer
            }
        }
            }
        }
        .onChange(of: session.includeSystem) { _, _ in session.scan(app: model) }
        .sheet(isPresented: $showCoverage) { coverage }
        .sheet(isPresented: $model.showApplicationOrphans, onDismiss: {
            if showCoverageAfterOrphans { showCoverageAfterOrphans=false; showCoverage=true }
        }) {
            ApplicationOrphansView(model: model, onReviewCoverage: { showCoverageAfterOrphans=true })
        }
        .toolbar { ToolbarItemGroup { header } }
    }

    private var header: some View {
        HStack {
            Button(model.t("Application Leftovers")) { model.orphanRetryPaths=[]; model.showApplicationOrphans=true }
                .disabled(model.busy).accessibilityLabel(model.t("Application Leftovers"))
                .accessibilityIdentifier("applications.leftovers")
            Menu {
                Toggle(model.t("Include protected system apps"), isOn: $session.includeSystem)
                Button(model.t("View Coverage…")) { showCoverage=true }
                Button(model.t("Review Disk Access…")) { model.scanAccess.showingSetup=true }
                Button(model.t("Authorize Administrator Access…")) { model.scanAccess.authorizeAdministrator { session.scan(app: model) } }
                    .disabled(model.scanAccess.authorizingAdministrator)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                .accessibilityLabel(model.t("Application Options"))
            Button {
                if session.scanning || session.preparing { session.stop() }
                else { session.scan(app: model) }
            } label: { Label(model.t(session.stopRequested && (session.scanning || session.preparing) ? "Stopping…" : session.scanning || session.preparing ? "Stop" : "Scan Again"), systemImage: session.scanning || session.preparing ? "stop.fill" : "arrow.clockwise") }
                .disabled((session.stopRequested && (session.scanning || session.preparing)) || (model.busy && !session.scanning && !session.preparing))
                .labelStyle(.iconOnly).help(model.t(session.scanning || session.preparing ? "Stop" : "Scan Again"))
                .accessibilityIdentifier("applications.refresh")
        }
    }
    private var summary: some View {
        HStack(spacing: 10) {
            Text(String(format: model.t("%lld applications found"), locale: model.language.locale, session.items.count)).font(ShouType.body.weight(.medium))
            Text(model.t("Estimated Size")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Text(model.bytes(session.items.reduce(0) { $0 + ($1.allocatedBytesEstimate ?? 0) })).font(ShouType.body.weight(.semibold)).foregroundStyle(ShouPalette.accent).monospacedDigit()
            Spacer()
            if session.scanning {
                VStack(alignment: .leading, spacing: 5) {
                    OperationProgressMeter(fraction: session.applicationCount > 0 ? Double(session.processedCount) / Double(session.applicationCount) : nil,
                        label: session.stopRequested ? model.t("Stopping…") : session.applicationCount > 0 ? String(format: model.t("%lld of %lld applications checked"), locale: model.language.locale, session.processedCount, session.applicationCount) : model.t("Reviewing application components…"), compact: true)
                    Text(session.currentPath).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary)
                        .lineLimit(1).truncationMode(.middle).help(session.currentPath)
                        .transaction { $0.animation=nil }
                }.frame(width: 270)
            } else if session.hasChanges {
                Button(model.t("Scan again to update sizes and status")) { session.scan(app: model) }.buttonStyle(.link).font(ShouType.caption)
            }
        }.padding(20)
    }
    private var filters: some View {
        HStack(spacing: 5) {
            ForEach(ApplicationFilter.allCases, id: \.self) { item in
                Button { filter=item } label: {
                    HStack(spacing: 5) {
                        Text(model.t(item.title))
                        Text(String(session.items.filter(item.matches).count)).monospacedDigit().foregroundStyle(ShouPalette.secondary)
                    }.font(ShouType.caption).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(filter == item ? ShouPalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(filter == item ? ShouPalette.accent : ShouPalette.text)
                }.buttonStyle(.plain).accessibilityIdentifier("applications.filter." + item.rawValue)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
            Spacer(minLength: 8)
            TextField(model.t("Search applications or paths"), text: $search).textFieldStyle(.roundedBorder)
                .frame(minWidth: 130, maxWidth: 260).focused($searchFocused).accessibilityIdentifier("applications.search")
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }
    private func columns(compact: Bool) -> some View {
        HStack(spacing: 12) {
            SelectionCheckbox(state: selectedVisible == 0 ? .off : selectedVisible == eligible.count ? .on : .mixed,
                enabled: !model.busy && session.canChangeSelection && !eligible.isEmpty, label: model.t("Select applications in this view"), identifier: "applications.selectAll") {
                session.selectVisible(items, app: model)
            }.frame(width: 20, height: 20)
            Color.clear.frame(width: 32, height: 1)
            sortButton("Application Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Status", .status).frame(width: 112, alignment: .leading)
            sortButton("Estimated Size", .size).frame(width: 88, alignment: .trailing)
            if !compact { sortButton("Last Used", .lastUsed).frame(width: 135, alignment: .trailing) }
            Color.clear.frame(width: 22, height: 1)
        }.font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 7)
    }
    private func sortButton(_ label: String, _ value: ApplicationSort) -> some View {
        Button {
            if sort == value { ascending.toggle() } else { sort=value; ascending=value == .name }
        } label: {
            HStack(spacing: 4) {
                Text(model.t(label))
                if sort == value { Image(systemName: ascending ? "arrow.up" : "arrow.down").font(ShouType.caption) }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("applications.sort." + label)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
        if !session.runningSelectionIDs.isEmpty {
            Text(model.t("Save your work before quitting. Apps that remain open must be closed manually."))
                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
        }
        HStack(spacing: 12) {
            Text(String(format: model.t("%lld items selected"), session.selectedAppIDs.count)).font(ShouType.body)
            ShouDivider(vertical: true).frame(height: 18)
            Text(model.t("Estimated Removal")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Text(model.bytes(session.selectedBytes)).font(ShouType.body.weight(.semibold)).monospacedDigit()
            Spacer()
            if session.preparing {
                Text(model.t("Selection is being checked…")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if !session.selectedAppIDs.isEmpty {
                Button(model.t("Clear Selection")) { session.clear(app: model) }.disabled(model.busy).accessibilityIdentifier("applications.clear")
            }
            if !session.runningSelectionIDs.isEmpty {
                Button(model.t("Quit Selected Apps and Check Again")) { session.closeSelected(app: model) }
                    .buttonStyle(.borderedProminent).disabled(model.busy || session.preparing)
                    .accessibilityIdentifier("applications.quitSelected")
            } else if session.selectionHasShortcuts {
                Button(role: .destructive) { session.removeSelected(app: model, action: "permanent") } label: {
                    Label(model.t("Delete Permanently"), systemImage: "trash").font(ShouType.body.weight(.semibold))
                        .frame(minWidth: ShouDesign.primaryActionMinWidth, minHeight: ShouDesign.primaryActionContentMinHeight)
                }.buttonStyle(.borderedProminent).tint(ShouPalette.danger).controlSize(.large)
                    .disabled(model.busy || session.preparing || session.selectionRequiresTrash || session.hasChanges)
                    .help(model.t(session.selectionRequiresTrash ? "Select broken shortcuts separately from apps that require Trash." : "Permanent deletion cannot be undone."))
                    .accessibilityIdentifier("applications.uninstall")
            } else if session.selectionRequiresTrash {
                Button(role: .destructive) { session.removeSelected(app: model, action: "trash") } label: {
                    Label(model.t("Move to Trash"), systemImage: "trash")
                        .font(ShouType.body.weight(.semibold))
                        .frame(minWidth: ShouDesign.primaryActionMinWidth, minHeight: ShouDesign.primaryActionContentMinHeight)
                }.buttonStyle(.borderedProminent).tint(ShouPalette.danger).controlSize(.large)
                    .disabled(model.busy || session.preparing || session.selectedAppIDs.isEmpty || session.hasChanges)
                    .accessibilityIdentifier("applications.uninstall")
            } else {
            CleanupActionButton(model: model, enabled: !model.busy && !session.preparing && !session.selectedAppIDs.isEmpty && !session.hasChanges,
                clean: { session.removeSelected(app: model, action: "permanent") },
                trash: { session.removeSelected(app: model, action: "trash") }, identifier: "applications.uninstall")
            }
        }
        }.padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 12).background(.bar)
    }
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Application Discovery Coverage")).font(ShouType.title.bold())
            Text(model.t("Application sizes describe the app bundle. Associated files are measured when you expand or select an application. System usage records can be unavailable."))
                .foregroundStyle(ShouPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.t("macOS requests an administrator password when needed. Authorization is reused during this session. Only the selected application bundle is removed; associated data is kept."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.catalog?.sources ?? []) { source in
                        HStack { Text(source.source.path).textSelection(.enabled); Spacer(); Text(model.t(source.status)).foregroundStyle(ShouPalette.secondary) }.font(ShouType.body)
                    }
                    ForEach(Array((session.catalog?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading) { Text(issue.path).textSelection(.enabled); Text(model.t(issue.code)).foregroundStyle(ShouPalette.secondary) }.font(ShouType.caption)
                    }
                    ForEach(session.items.filter { !$0.issues.isEmpty }) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.application.name).font(ShouType.body.weight(.medium))
                            ForEach(item.issues, id: \.self) { issue in
                                Text(model.t(issue)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.t("Verified group containers may be included; unverified shared data, package receipts and external helpers remain protected. Custom locations and other accounts are not searched. Process checks cover the current account. Missing associations are not added to the plan."))
                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            HStack { Spacer(); Button(model.t("Done")) { showCoverage=false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 660, height: 480)
    }
}

private struct ApplicationUninstallRow: View {
    var model: AppModel
    @Bindable var session: ApplicationsSession
    let summary: ApplicationSummary
    let compact: Bool
    @State private var hovering=false
    private var app: ApplicationDefinition { summary.application }
    private var expanded: Bool { session.expandedID == app.id }
    private var components: [UninstallComponent] { session.reviews[app.id]?.components.filter { $0.status != "missing" } ?? [] }
    private var chosen: Set<String> { session.selection[app.id] ?? [] }
    private var selectionState: NSControl.StateValue {
        if session.pendingSelectionIDs.contains(app.id) || session.runningSelectionIDs.contains(app.id) { return .on }
        if chosen.isEmpty { return .off }
        return components.filter { session.componentSelectable($0, appID: app.id) }
            .allSatisfy { chosen.contains($0.id) } ? .on : .mixed
    }
    private var identitySubtitle: String {
        if summary.issues.contains("application_link_target_missing") { return model.t("Target application is missing") }
        let identifier=app.bundleIdentifier ?? model.t("Identifier unavailable")
        let version=app.version.map { ", " + model.t("Version") + " " + $0 } ?? ""
        return identifier + version
    }
    private var sizeLabel: String {
        guard let bytes=summary.allocatedBytesEstimate else { return "—" }
        return (summary.sizeIsLowerBound ? "≥ " : "") + model.bytes(bytes)
    }
    private var rowColor: Color {
        if session.isSelected(app.id) { return ShouPalette.accent.opacity(0.08) }
        return hovering ? ShouPalette.text.opacity(0.035) : .clear
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow
            if expanded { details }
        }.accessibilityElement(children: .contain)
    }
    private var summaryRow: some View {
        HStack(spacing: 12) {
            SelectionCheckbox(state: selectionState,
                enabled: !model.busy && session.canChangeSelection && (session.selectable(summary) || session.isSelected(app.id)), label: model.t("Select") + " " + app.name, identifier: "applications.select." + app.id) {
                session.toggle(summary, app: model)
            }.frame(width: 20, height: 24)
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: ShouDesign.workspaceIconSize, height: ShouDesign.workspaceIconSize).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: ShouDesign.bodyFontSize, weight: .medium)).lineLimit(1)
                Text(identitySubtitle)
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading).help(app.path)
            status.frame(width: 112, alignment: .leading)
            Text(sizeLabel).monospacedDigit().font(ShouType.body).frame(width: 88, alignment: .trailing)
            if !compact {
                Text(summary.lastUsed.map(model.date) ?? model.t("No usage record")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(1).frame(width: 135, alignment: .trailing)
            }
            Button { session.expand(summary, app: model) } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                .buttonStyle(.plain).frame(width: 22, height: 28).disabled(model.busy)
                .accessibilityLabel(model.t(expanded ? "Hide components" : "Show components") + " " + app.name)
                .accessibilityIdentifier("applications.expand." + app.id)
        }.padding(.horizontal, 14).padding(.vertical, ShouDesign.workspaceRowPadding)
            .background(rowColor, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering=$0 }.contentShape(Rectangle())
            .contextMenu {
                Button(model.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                Button(model.t("Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.path, forType: .string) }
            }
    }
    @ViewBuilder private var status: some View {
        if session.reviewingID == app.id {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(model.t(model.scanAccess.authorizingAdministrator ? "Authenticating…" : "Reviewing…"))
            }.font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                .accessibilityIdentifier("applications.reviewing." + app.id)
        } else if session.pendingSelectionIDs.contains(app.id) {
            Text(model.t("Queued for review")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
        } else if summary.status == "admin-required" {
            Group {
                if model.scanAccess.administratorState == .authorized {
                    authorizationLabel
                } else {
                    Button { session.authorize(summary, app: model) } label: { authorizationLabel }
                        .buttonStyle(.plain).disabled(model.busy || session.hasChanges)
                }
            }
                .help(model.t("Selecting this application requests administrator access when needed."))
                .accessibilityIdentifier("applications.authentication." + app.id)
        } else {
            statusLabel
        }
    }
    private var authorizationLabel: some View {
        Label(model.t(model.scanAccess.administratorState == .authorized ? "Authorized for this session" : "Authentication Required"),
              systemImage: model.scanAccess.administratorState == .authorized ? "lock.open" : "lock.fill")
            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
    }
    private var statusLabel: some View {
        let title: String=switch summary.status {
        case "ready": "Ready to Uninstall"
        case "running": "Quit Application First"
        case "trash-required": "Move to Trash"
        case "shortcut": "Broken Shortcut"
        case "protected": "Protected"
        default: summary.issues.contains("application_link_target_missing") ? "Broken Shortcut" : summary.issues.contains("linked_application") ? "Application Shortcut" : summary.issues.contains("application_activity_unavailable") ? "Status Unverified" : "Cannot Uninstall"
        }
        return Text(model.t(title)).font(ShouType.caption).foregroundStyle(summary.status == "ready" ? ShouPalette.secondary : ShouPalette.warning)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(summary.status == "ready" ? .clear : ShouPalette.warning.opacity(0.09), in: Capsule())
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(app.path).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).accessibilityLabel(model.t("Reveal in Finder"))
            }
            ApplicationUpdateRow(model: model, application: app)
            ShouDivider()
            if summary.issues.contains("application_link_target_missing") {
                Text(model.t("Only this broken shortcut is removed. Its target and associated data are kept."))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if let error=session.reviewErrors[app.id] {
                HStack(alignment: .top) {
                    Text(error).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                    Spacer()
                    Button(model.t("Check Again")) { session.recheck(summary, app: model) }.disabled(model.busy || session.preparing)
                }
            }
            if summary.status == "protected" {
                Text(model.t(app.isSystemApplication ? "macOS protects this system application from uninstalling." : "Shou cannot uninstall itself while it is running."))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if !summary.issues.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.issues, id: \.self) { issue in
                            if issue != "application_link_target_missing" || !session.selectable(summary) {
                                Text(model.t(issue)).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                            }
                        }
                    }
                    Spacer()
                    if summary.issues.contains("application_activity_unavailable") {
                        Button(model.t("Check Again")) { session.recheck(summary, app: model) }.disabled(model.busy || session.preparing)
                            .accessibilityIdentifier("applications.recheck." + app.id)
                    }
                }
            }
            if needsDiskAccess {
                HStack(alignment: .top, spacing: 12) {
                    Text(model.t("Allow Shou in Full Disk Access, then check this application again. File permissions may also restrict access."))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    Spacer()
                    Button(model.t("Review Disk Access…")) { model.scanAccess.showingSetup=true }.disabled(model.busy)
                        .accessibilityIdentifier("applications.access." + app.id)
                    Button(model.t("Check Again")) { session.recheck(summary, app: model) }.disabled(model.busy || session.preparing)
                    Button(model.t("Authorize…")) { session.authorize(summary, app: model) }
                        .disabled(model.busy || model.scanAccess.authorizingAdministrator)
                }
            }
            if summary.status == "running" {
                HStack {
                    Text(model.t("Quit the application and its helpers before uninstalling.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                    Spacer()
                    Button(model.t("Request Quit")) { session.quit(summary, app: model) }.disabled(model.busy || session.preparing)
                    Button(model.t("Check Again")) { session.recheck(summary, app: model) }.disabled(model.busy || session.preparing)
                }
            }
            if summary.status == "admin-required" {
                HStack(spacing: ShouDesign.itemSpacing) {
                    Label(model.t("Administrator Access"), systemImage: "lock.fill")
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    Spacer(minLength: 12)
                    if model.scanAccess.administratorState == .authorized {
                        Text(model.t("Authorized for this session")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    } else {
                        Button(model.t("Authorize…")) { session.authorize(summary, app: model) }
                            .disabled(model.busy || model.scanAccess.authorizingAdministrator)
                            .accessibilityIdentifier("applications.authorize." + app.id)
                    }
                    Button(model.t(session.isSelected(app.id) ? "Deselect" : "Select for Removal")) { session.toggle(summary, app: model) }
                        .disabled(model.busy || session.hasChanges).accessibilityIdentifier("applications.selectForRemoval." + app.id)
                }
                if let error=model.scanAccess.administratorError {
                    Text(model.t(error)).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                }
            }
            if session.reviewingID == app.id {
                HStack { ProgressView().controlSize(.small); Text(model.t("Reviewing application components…")).font(ShouType.caption) }.padding(.vertical, 12)
            } else {
                if session.reviews[app.id]?.keepsAssociatedData != true && components.contains(where: \.requiresUserDataConsent) {
                    Text(model.t("Personal app data selected; work and sign-in information may be lost.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                    Toggle(model.t("Allow selecting personal app data"), isOn: Binding(get: { session.personalDataConsent.contains(app.id) }, set: { session.allowPersonalData(app.id, allowed: $0, app: model) }))
                        .toggleStyle(.checkbox).font(ShouType.caption).disabled(model.busy).accessibilityIdentifier("applications.personalData." + app.id)
                }
                ForEach(components.filter { session.reviews[app.id]?.keepsAssociatedData != true || $0.kind == .application }) { component in componentRow(component) }
                if components.isEmpty {
                    Text(model.t("No verified components available. Scan again or review access notices.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
            }
        }.padding(.leading, 54).padding(.trailing, 12).padding(.vertical, 12)
    }
    private var needsDiskAccess: Bool {
        let reasons=summary.issues + components.flatMap(\.reasons)
        return reasons.contains { ["permission_denied", "permission_or_type_unavailable", "unreadable_directory", "unreadable_entry", "privacy_permission_required"].contains($0) }
    }
    private func componentRow(_ component: UninstallComponent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SelectionCheckbox(state: chosen.contains(component.id) ? .on : .off, enabled: !model.busy && session.componentSelectable(component, appID: app.id),
                label: model.t("Select") + " " + component.path, identifier: "applications.component." + app.id + "." + component.kind.rawValue) {
                session.toggleComponent(component, appID: app.id, app: model)
            }.frame(width: 20, height: 22)
            Image(systemName: component.kind == .application ? "app" : component.kind == .preferences ? "slider.horizontal.3" : "folder")
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary).frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t(componentTitle(component.kind))).font(ShouType.body)
                Text(component.path).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                ForEach(component.reasons + component.warnings, id: \.self) { Text(model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(model.t(component.kind == .shortcut ? "Only this shortcut" : component.kind == .application ? "Required for uninstall" : component.requiresUserDataConsent ? "Personal data" : component.eligible ? "Optional" : "Unavailable"))
                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(.horizontal, 7).padding(.vertical, 4).background(ShouPalette.inset, in: Capsule())
            Text((component.status == "partial" ? "≥ " : "") + model.bytes(component.allocatedBytesEstimate)).font(ShouType.caption).monospacedDigit().frame(width: 88, alignment: .trailing)
        }.padding(.vertical, 7)
    }
    private func componentTitle(_ kind: UninstallComponentKind) -> String {
        switch kind {
        case .application: "Application bundle"
        case .shortcut: "Broken Shortcut"
        case .caches: "App caches"
        case .logs: "App logs"
        case .preferences: "Preferences"
        case .applicationSupport: "App support data"
        case .savedState: "Saved state"
        case .container: "App container"
        case .groupContainer: "Shared group container"
        case .webKit: "WebKit data"
        case .httpStorage: "HTTP storage"
        }
    }
}
