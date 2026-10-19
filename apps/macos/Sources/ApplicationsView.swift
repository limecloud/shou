import AppKit
import SwiftUI
import ShouCore

struct ApplicationsView: View {
    @Bindable var model: AppModel
    @State private var search=""
    @State private var selection: String?
    @State private var showCoverage=false
    private var items: [ApplicationDefinition] {
        (model.applicationCatalog?.items ?? []).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
    private var selected: ApplicationDefinition? { items.first { $0.id == selection } }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let review=model.applicationReview { ApplicationUninstallReviewView(model: model, review: review).id(review.id) }
                else { catalog }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .task(id: model.initializing) {
            if !model.initializing && model.applicationCatalog == nil && !model.busy { model.scanApplications() }
        }
        .onChange(of: model.applicationsIncludeSystem) { _, _ in selection=nil; model.scanApplications() }
        .sheet(isPresented: $showCoverage) { coverage }
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("Applications")).font(.largeTitle.bold())
                    Text(model.t("Review an app and its associated files before moving them to Trash."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.applicationsLoading ? model.cancel() : model.scanApplications() } label: {
                    Label(model.t(model.applicationsLoading ? "Stop" : "Check Again"), systemImage: model.applicationsLoading ? "stop.fill" : "arrow.clockwise")
                }.disabled(model.busy && !model.applicationsLoading).accessibilityIdentifier("applications.refresh")
            }
            HStack {
                TextField(model.t("Search app names, identifiers or paths"), text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("applications.search")
                Toggle(model.t("Include protected system apps"), isOn: $model.applicationsIncludeSystem)
                    .toggleStyle(.checkbox).disabled(model.busy).accessibilityIdentifier("applications.includeSystem")
            }
            if model.applicationsLoading {
                ActivityIndicator(title: model.t("Reading installed applications…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report=model.applicationCatalog {
                HStack {
                    Text(String(format: model.t("%lld applications found"), locale: model.language.locale, report.items.count))
                    if !search.isEmpty { Text(String(format: model.t("Matches: %lld"), locale: model.language.locale, items.count)).foregroundStyle(.secondary) }
                    Spacer()
                    Button(model.t("View Coverage…")) { showCoverage=true }.accessibilityIdentifier("applications.coverage")
                }.font(.caption)
                if report.status == "partial" {
                    Label(model.t("Some applications could not be fully inspected. Review ownership notices before selecting associated files."), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Table(items, selection: $selection) {
                    TableColumn(model.t("Name")) { item in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.bundleIdentifier ?? model.t("Identifier unavailable")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 3).help(item.path)
                    }.width(min: 180, ideal: 260)
                    TableColumn(model.t("Version")) { item in Text(item.version ?? "—").foregroundStyle(.secondary) }.width(min: 65, ideal: 80)
                    TableColumn(model.t("Location")) { item in Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.path) }.width(min: 150, ideal: 290)
                }.frame(minHeight: 0, maxHeight: .infinity).accessibilityIdentifier("applications.list")
                    .overlay {
                        if items.isEmpty { ContentUnavailableView(model.t(search.isEmpty ? "No applications found in these directories" : "No matching applications"), systemImage: "app.dashed") }
                    }
                    .onTapGesture(count: 2) { if let selected, !model.busy { model.inspectApplication(selected) } }
                HStack {
                    Text(model.t("Scanning is read-only. Uninstalling requires a component review and confirmation.")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.t("Review Uninstall…")) { if let selected { model.inspectApplication(selected) } }
                        .buttonStyle(.borderedProminent).disabled(selected == nil || model.busy)
                        .accessibilityIdentifier("applications.inspect")
                }
            } else {
                ContentUnavailableView(model.t("Check installed applications"), systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24)
    }
    private var coverage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Application Discovery Coverage")).font(.title2.bold())
            Text(model.t("Only the listed application directories and two levels of folders are checked. Embedded apps, package receipts and custom installation locations are not enumerated."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.applicationCatalog?.sources ?? []) { source in
                        HStack { Text(source.source.path).textSelection(.enabled); Spacer(); Text(model.t(source.status)).foregroundStyle(.secondary) }.font(.callout)
                    }
                    ForEach(Array((model.applicationCatalog?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading) { Text(issue.path).textSelection(.enabled); Text(model.t(issue.code)).foregroundStyle(.secondary) }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(model.t("Done")) { showCoverage=false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 660, height: 480)
    }
}

private struct ApplicationUninstallReviewView: View {
    @Bindable var model: AppModel
    let review: ApplicationUninstallReview
    @State private var selection=Set<String>()
    @State private var includeUserData=false
    @State private var focused: String?
    @State private var showLimits=false
    private var components: [UninstallComponent] { review.components.filter { $0.status != "missing" } }
    private var selected: [UninstallComponent] { components.filter { selection.contains($0.id) && selectable($0) } }
    private func selectable(_ component: UninstallComponent) -> Bool { component.eligible && (!component.requiresUserDataConsent || includeUserData) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: review.application.path)).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.application.name).font(.title.bold())
                    Text(review.application.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { model.inspectApplication(review.application) } label: {
                    Label(model.t("Review Again"), systemImage: "arrow.clockwise")
                }.labelStyle(.iconOnly).help(model.t("Review Again")).disabled(model.busy).accessibilityIdentifier("uninstall.refresh")
                Button(model.t("Back to Applications")) { model.applicationReview=nil }.disabled(model.busy).accessibilityIdentifier("applications.back")
            }
            Text(model.t("Choose the app components to move to Trash. Personal data is retained unless you enable it separately."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if components.contains(where: { !$0.warnings.isEmpty }) {
                Label(model.t("Application discovery has gaps. Associated components require individual selection; an exact identifier does not prove exclusive ownership."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(model.t("Allow selecting personal app data"), isOn: $includeUserData).toggleStyle(.checkbox)
                .disabled(model.busy).accessibilityIdentifier("uninstall.personalData")
            if includeUserData {
                Label(model.t("Preferences, databases, sessions and container files may contain work or sign-in data. Select each item deliberately."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Table(components, selection: $focused) {
                TableColumn("") { component in
                    SelectionCheckbox(state: selection.contains(component.id) ? .on : .off, enabled: selectable(component) && !model.busy,
                        label: model.t("Select") + " " + componentTitle(component.kind), identifier: "uninstall.select." + component.kind.rawValue) {
                        if selection.contains(component.id) { selection.remove(component.id) } else { selection.insert(component.id) }
                    }.frame(width: 20, height: 22)
                }.width(26)
                TableColumn(model.t("Component")) { component in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(componentTitle(component.kind))
                        if component.requiresUserDataConsent { Text(model.t("Personal data")).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }.width(min: 110, ideal: 145)
                TableColumn(model.t("Location")) { component in Text(component.path).font(.caption).lineLimit(1).truncationMode(.middle).help(component.path) }.width(min: 160, ideal: 310)
                TableColumn(model.t("Size")) { component in Text(model.bytes(component.allocatedBytesEstimate)).monospacedDigit() }.width(min: 65, ideal: 80)
                TableColumn(model.t("Status")) { component in
                    Text(model.t(component.eligible ? component.requiresUserDataConsent && !includeUserData ? "Retained" : "Reviewable" : "Protected"))
                        .font(.caption).foregroundStyle(component.eligible ? Color.secondary : Color.orange)
                }.width(min: 70, ideal: 85)
            }.frame(minHeight: 0, maxHeight: .infinity).accessibilityIdentifier("uninstall.components")
            if let component=components.first(where: { $0.id == focused }) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(component.path).font(.caption.monospaced()).textSelection(.enabled)
                    Text(model.t(component.kind == .application ? "The selected application bundle itself." : component.kind == .groupContainer ? "Shared data is included only when native container metadata identifies this application." : "Associated by an exact bundle identifier. Similar names are never sufficient ownership evidence."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(component.reasons, id: \.self) { Text(model.t($0)).font(.caption).foregroundStyle(.orange) }
                    ForEach(component.warnings, id: \.self) { Text(model.t($0)).font(.caption).foregroundStyle(.orange) }
                }.accessibilityIdentifier("uninstall.componentDetails")
            }
            DisclosureGroup(model.t("Scope and retained items"), isExpanded: $showLimits) {
                Text(model.t("Verified group containers may be included; unverified shared data, package receipts and external helpers remain protected. Custom locations and other accounts are not searched. Process checks cover the current account. Missing associations are not added to the plan."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: model.t("%lld components selected"), locale: model.language.locale, selected.count))
                    Text(model.bytes(selected.reduce(0) { $0 + $1.allocatedBytesEstimate }) + " · " + model.t("Moving to Trash does not free disk space.")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.t("Preview Uninstall…")) { model.previewUninstall(review, componentIds: selected.map(\.id), includeUserData: includeUserData) }
                    .buttonStyle(.borderedProminent).disabled(model.busy || !selected.contains(where: { $0.kind == .application }))
                    .accessibilityIdentifier("uninstall.preview")
            }
        }.padding(24)
        .onAppear { selection=Set(components.filter { $0.eligible && !$0.requiresUserDataConsent && $0.warnings.isEmpty }.map(\.id)) }
        .onChange(of: includeUserData) { _, value in if !value { selection.subtract(components.filter(\.requiresUserDataConsent).map(\.id)) } }
    }
    private func componentTitle(_ kind: UninstallComponentKind) -> String {
        switch kind {
        case .application: model.t("Application bundle")
        case .caches: model.t("App caches")
        case .logs: model.t("App logs")
        case .preferences: model.t("Preferences")
        case .applicationSupport: model.t("App support data")
        case .savedState: model.t("Saved state")
        case .container: model.t("App container")
        case .groupContainer: model.t("Shared group container")
        case .webKit: model.t("WebKit data")
        case .httpStorage: model.t("HTTP storage")
        }
    }
}
