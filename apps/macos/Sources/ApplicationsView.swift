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
        case .administrator: "Administrator Required"
        case .protected: "Unavailable"
        }
    }
    func matches(_ item: ApplicationSummary) -> Bool {
        switch self {
        case .all: true
        case .ready: item.status == "ready"
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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                VStack(spacing: 0) {
                    summary
                    Divider()
                    filters
                    Divider()
                    columns(compact: geometry.size.width < 840)
                    Divider()
                    if session.scanning && session.items.isEmpty {
                        VStack(spacing: 14) {
                            ProgressView().controlSize(.large)
                            Text(model.t("Measuring application sizes…")).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items, id: \.application.id) { item in
                                    ApplicationUninstallRow(model: model, session: session, summary: item, compact: geometry.size.width < 840)
                                    Divider().padding(.leading, 54)
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
                                ContentUnavailableView(model.t(search.isEmpty ? "No applications in this category" : "No matching applications"), systemImage: "app.dashed")
                            }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.55)))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                footer
            }
        }
        .task(id: model.initializing) { if !model.initializing && session.catalog == nil && !model.busy { session.scan(app: model) } }
        .onChange(of: session.includeSystem) { _, _ in session.scan(app: model) }
        .sheet(isPresented: $showCoverage) { coverage }
        .sheet(item: $session.plan) { plan in ApplicationBatchConfirmation(model: model, session: session, plan: plan) }
    }

    private var header: some View {
        HStack {
            Text(model.t("Application Uninstall")).font(.title2.weight(.semibold))
            Spacer()
            Menu {
                Toggle(model.t("Include protected system apps"), isOn: $session.includeSystem)
                Button(model.t("View Coverage…")) { showCoverage=true }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                .accessibilityLabel(model.t("Application Options"))
            Button {
                if session.scanning || session.preparing { session.stop() }
                else { session.scan(app: model) }
            } label: { Label(model.t(session.scanning || session.preparing ? "Stop" : "Scan Again"), systemImage: session.scanning || session.preparing ? "stop.fill" : "arrow.clockwise") }
                .disabled(model.busy && !session.scanning && !session.preparing)
                .accessibilityIdentifier("applications.refresh")
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }
    private var summary: some View {
        HStack(spacing: 10) {
            Text(String(format: model.t("%lld applications found"), locale: model.language.locale, session.items.count)).font(.callout.weight(.medium))
            Text(model.t("Estimated Size")).font(.caption).foregroundStyle(.secondary)
            Text(model.bytes(session.items.reduce(0) { $0 + ($1.allocatedBytesEstimate ?? 0) })).font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor).monospacedDigit()
            Spacer()
            if session.scanning || session.preparing {
                ProgressView().controlSize(.small)
                Text(session.scanning ? String(format: model.t("%lld of %lld applications checked"), session.processedCount, session.applicationCount) : model.t("Reviewing application components…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.hasChanges {
                Button(model.t("Scan again to update sizes and status")) { session.scan(app: model) }.buttonStyle(.link).font(.caption)
            } else if session.catalog?.status == "partial" {
                Button { showCoverage=true } label: { Label(model.t("Partial Coverage"), systemImage: "exclamationmark.triangle") }.buttonStyle(.link).font(.caption)
            }
        }.padding(14)
    }
    private var filters: some View {
        HStack(spacing: 5) {
            ForEach(ApplicationFilter.allCases, id: \.self) { item in
                Button { filter=item } label: {
                    HStack(spacing: 5) {
                        Text(model.t(item.title))
                        Text(String(session.items.filter(item.matches).count)).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(filter == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(filter == item ? Color.accentColor : .primary)
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
                enabled: !model.busy && !eligible.isEmpty, label: model.t("Select applications in this view"), identifier: "applications.selectAll") {
                session.selectVisible(items, app: model)
            }.frame(width: 20, height: 20)
            Color.clear.frame(width: 32, height: 1)
            sortButton("Application Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Status", .status).frame(width: 112, alignment: .leading)
            sortButton("Estimated Size", .size).frame(width: 88, alignment: .trailing)
            if !compact { sortButton("Last Used", .lastUsed).frame(width: 135, alignment: .trailing) }
            Color.clear.frame(width: 22, height: 1)
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 7)
    }
    private func sortButton(_ label: String, _ value: ApplicationSort) -> some View {
        Button {
            if sort == value { ascending.toggle() } else { sort=value; ascending=value == .name }
        } label: {
            HStack(spacing: 4) {
                Text(model.t(label))
                if sort == value { Image(systemName: ascending ? "arrow.up" : "arrow.down").font(.caption2) }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("applications.sort." + label)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(format: model.t("%lld applications selected"), session.selectedAppIDs.count)).font(.callout)
            Divider().frame(height: 18)
            Text(model.t("Estimated Removal")).font(.caption).foregroundStyle(.secondary)
            Text(model.bytes(session.selectedBytes)).font(.title3.weight(.semibold)).monospacedDigit()
            Spacer()
            if !session.selectedAppIDs.isEmpty {
                Button(model.t("Clear Selection")) { session.clear(app: model) }.disabled(model.busy).accessibilityIdentifier("applications.clear")
            }
            Menu {
                Button(model.t("Move Selected to Trash…")) { session.prepare(app: model, action: "trash") }
                Button(model.t("Permanently Uninstall Selected…"), role: .destructive) { session.prepare(app: model, action: "permanent") }
            } label: { Label(model.t("Uninstall Selected…"), systemImage: "shippingbox") }
                primaryAction: { session.prepare(app: model, action: "permanent") }
                .fixedSize().buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.busy || session.selectedAppIDs.isEmpty || session.hasChanges).accessibilityIdentifier("applications.uninstall")
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Application Discovery Coverage")).font(.title2.bold())
            Text(model.t("Application sizes describe the app bundle. Associated files are measured when you expand or select an application. System usage records can be unavailable."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.t("Administrator access is not requested automatically. Applications requiring elevated access remain unavailable for removal."))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.catalog?.sources ?? []) { source in
                        HStack { Text(source.source.path).textSelection(.enabled); Spacer(); Text(model.t(source.status)).foregroundStyle(.secondary) }.font(.callout)
                    }
                    ForEach(Array((session.catalog?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading) { Text(issue.path).textSelection(.enabled); Text(model.t(issue.code)).foregroundStyle(.secondary) }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.t("Verified group containers may be included; unverified shared data, package receipts and external helpers remain protected. Custom locations and other accounts are not searched. Process checks cover the current account. Missing associations are not added to the plan."))
                .font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectionCheckbox(state: chosen.isEmpty ? .off : components.filter { session.componentSelectable($0, appID: app.id) }.allSatisfy({ chosen.contains($0.id) }) ? .on : .mixed,
                    enabled: !model.busy && (session.selectable(summary) || session.isSelected(app.id)), label: model.t("Select") + " " + app.name, identifier: "applications.select." + app.id) {
                    session.toggle(summary, app: model)
                }.frame(width: 20, height: 24)
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text((app.bundleIdentifier ?? model.t("Identifier unavailable")) + (app.version.map { " · " + model.t("Version") + " " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading).help(app.path)
                status.frame(width: 112, alignment: .leading)
                Text(summary.allocatedBytesEstimate.map { (summary.issues.isEmpty ? "" : "≥ ") + model.bytes($0) } ?? "—").monospacedDigit().font(.callout).frame(width: 88, alignment: .trailing)
                if !compact {
                    Text(summary.lastUsed.map(model.date) ?? model.t("No usage record")).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 135, alignment: .trailing)
                }
                Button { session.expand(summary, app: model) } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain).frame(width: 22, height: 28).disabled(model.busy)
                    .accessibilityLabel(model.t(expanded ? "Hide components" : "Show components") + " " + app.name)
                    .accessibilityIdentifier("applications.expand." + app.id)
            }.padding(.horizontal, 10).padding(.vertical, 12)
                .background(session.isSelected(app.id) ? Color.accentColor.opacity(0.08) : hovering ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering=$0 }.contentShape(Rectangle())
                .contextMenu {
                    Button(model.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                    Button(model.t("Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(app.path, forType: .string) }
                }
            if expanded { details }
        }.accessibilityElement(children: .contain)
    }
    private var status: some View {
        let title: String=switch summary.status {
        case "ready": "Ready to Uninstall"
        case "running": "Quit Application First"
        case "admin-required": "Administrator Required"
        case "protected": "Protected"
        default: "Unavailable"
        }
        return Text(model.t(title)).font(.caption).foregroundStyle(summary.status == "ready" ? Color.secondary : Color.orange)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(summary.status == "ready" ? .clear : Color.orange.opacity(0.09), in: Capsule())
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(app.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).accessibilityLabel(model.t("Reveal in Finder"))
            }
            if summary.status == "running" {
                HStack {
                    Text(model.t("Quit the application and its helpers before uninstalling.")).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(model.t("Request Quit")) { session.quit(summary, app: model) }.disabled(model.busy)
                }
            }
            if summary.status == "admin-required" {
                Text(model.t("This application requires elevated access. Automatic administrator removal is not supported.")).font(.caption).foregroundStyle(.orange)
            }
            if session.reviewingID == app.id {
                HStack { ProgressView().controlSize(.small); Text(model.t("Reviewing application components…")).font(.caption) }.padding(.vertical, 12)
            } else {
                if components.contains(where: \.requiresUserDataConsent) {
                    Toggle(model.t("Allow selecting personal app data"), isOn: Binding(get: { session.personalDataConsent.contains(app.id) }, set: { session.allowPersonalData(app.id, allowed: $0, app: model) }))
                        .toggleStyle(.checkbox).font(.caption).disabled(model.busy).accessibilityIdentifier("applications.personalData." + app.id)
                }
                ForEach(components) { component in componentRow(component) }
                if components.isEmpty {
                    Text(model.t("No verified components available. Scan again or review access notices.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.leading, 54).padding(.trailing, 12).padding(.vertical, 12)
            .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1).padding(.leading, 32).padding(.vertical, 10) }
    }
    private func componentRow(_ component: UninstallComponent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SelectionCheckbox(state: chosen.contains(component.id) ? .on : .off, enabled: !model.busy && session.componentSelectable(component, appID: app.id),
                label: model.t("Select") + " " + component.path, identifier: "applications.component." + app.id + "." + component.kind.rawValue) {
                session.toggleComponent(component, appID: app.id, app: model)
            }.frame(width: 20, height: 22)
            Image(systemName: component.kind == .application ? "app" : component.kind == .preferences ? "slider.horizontal.3" : "folder")
                .font(.callout).foregroundStyle(.secondary).frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t(componentTitle(component.kind))).font(.callout)
                Text(component.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                ForEach(component.reasons + component.warnings, id: \.self) { Text(model.t($0)).font(.caption2).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(model.t(component.kind == .application ? "Required for uninstall" : component.requiresUserDataConsent ? "Personal data" : component.eligible ? "Optional" : "Unavailable"))
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule())
            Text((component.status == "partial" ? "≥ " : "") + model.bytes(component.allocatedBytesEstimate)).font(.caption).monospacedDigit().frame(width: 88, alignment: .trailing)
        }.padding(.vertical, 7)
    }
    private func componentTitle(_ kind: UninstallComponentKind) -> String {
        switch kind {
        case .application: "Application bundle"
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

private struct ApplicationBatchConfirmation: View {
    var model: AppModel
    @Bindable var session: ApplicationsSession
    let plan: ApplicationUninstallBatchPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.t(plan.action == "permanent" ? "Permanently uninstall these applications?" : "Move these applications to Trash?"), systemImage: "shippingbox")
                .font(.title2.weight(.semibold))
            Text(String(format: model.t("%lld applications selected"), plan.plans.count) + " · " + model.bytes(plan.allocatedBytesEstimate)).foregroundStyle(.secondary)
            Text(model.t(plan.action == "permanent" ? "The selected applications and components will be permanently removed. This action cannot be undone." : "You can restore these items from History. Moving to Trash does not free disk space."))
                .font(.callout).foregroundStyle(plan.action == "permanent" ? Color.red : Color.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plan.plans) { application in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(application.application.name).font(.headline)
                            ForEach(application.components) { component in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(component.path).font(.caption.monospaced()).textSelection(.enabled)
                                        if component.requiresUserDataConsent { Text(model.t("Personal app data selected; work and sign-in information may be lost.")).font(.caption).foregroundStyle(.orange) }
                                    }
                                    Spacer()
                                    Text(model.bytes(component.allocatedBytesEstimate)).font(.caption).monospacedDigit()
                                }
                            }
                        }
                    }
                }.padding(14)
            }.frame(minHeight: 100, maxHeight: 300).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(model.t("Cancel")) { session.plan=nil }.keyboardShortcut(.cancelAction)
                Button(model.t(plan.action == "permanent" ? "Uninstall Permanently" : "Move to Trash"), role: .destructive) { session.execute(plan, app: model) }
                    .buttonStyle(.borderedProminent).tint(plan.action == "permanent" ? .red : .accentColor).accessibilityIdentifier("applications.confirm")
            }
        }.padding(26).frame(width: 660)
    }
}
