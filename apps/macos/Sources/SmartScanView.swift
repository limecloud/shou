import SwiftUI
import ShouCore
import AppKit

struct SmartScanView: View {
    @Bindable var model: AppModel
    @State private var category="all"
    @State private var query=""
    @State private var showIssues=false
    @State private var scanLocations=false
    @State private var agentSetup=false

    private var groups: [CleanupRuleGroup] {
        model.commonReview.categories.filter { category == "all" || $0.id == category }.flatMap(\.groups).filter {
            query.isEmpty || model.t($0.title).localizedStandardContains(query) || $0.sources.contains { $0.path.localizedStandardContains(query) }
        }
    }
    private var allGroups: [CleanupRuleGroup] { model.commonReview.categories.flatMap(\.groups) }
    private var selectedGroupCount: Int {
        allGroups.filter { $0.sources.contains { $0.selectable && model.commonSelection.contains($0.id) } }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.scanning { ScanAccessBanner(model: model) }
            if model.scanning {
                VStack(alignment: .leading, spacing: 0) {
                    ScanActivity(model: model)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.systemResult != nil {
                resultSummary
                if model.commonReview.sources.contains(where: { $0.candidate.reasons.contains("application_running") }) {
                    CleanupApplicationClosePanel(model: model)
                }
                resultBrowser
                selectionBar
            } else {
                locationBrowser
            }
        }
        .onChange(of: model.systemResult?.snapshots.count) { _, _ in
            if !model.commonReview.categories.contains(where: { $0.id == category }) {
                category="all"
            }
        }
        .sheet(isPresented: $scanLocations) { ScanLocationsView(model: model) }
        .sheet(isPresented: $agentSetup, onDismiss: { Task { await model.refresh() } }) { AgentRuleSetupView(model: model) }
        .toolbar {
            ToolbarItemGroup {
                if !model.scanning && model.systemResult != nil {
                }
                DiskCapacityView(model: model)
            }
        }
    }

    private var resultBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(model.t("Search rules or paths"), text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    .accessibilityIdentifier("smart.search")
                Spacer()
                Picker(model.t("Category"), selection: $category) {
                    Text(model.t("All Items")).tag("all")
                    ForEach(model.commonReview.categories) { Text(title($0.id)).tag($0.id) }
                }.frame(maxWidth: 230)
                CleanupOptionsMenu(model: model, showLocations: { scanLocations=true }, showAgentSetup: { agentSetup=true })
            }.padding(.horizontal, ShouDesign.workspaceInset).padding(.bottom, 18)
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.commonReview.categories.filter { category == "all" || $0.id == category }) { item in
                        let visible=item.groups.filter { group in groups.contains { $0.id == group.id } }
                        if !visible.isEmpty {
                            CleanupCategorySection(model: model, category: item, groups: visible, title: title(item.id), symbol: symbol(item.id), searching: !query.isEmpty)
                        }
                    }
                    if query.isEmpty && (category == "all" || category == "developer") { ToolCleanupPanel(model: model) }
                }.padding(.horizontal, ShouDesign.workspaceInset).padding(.bottom, 24)
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView(model.t("No matching cleanup items"), systemImage: "magnifyingglass")
                }
            }
        }
    }

    private var resultSummary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.t("Ready to clean")).font(.system(size: ShouDesign.workspaceTitleSize, weight: .medium))
                HStack(spacing: 10) {
                    Text(String(format: model.t("%lld cleanup items found"), locale: model.language.locale, allGroups.count))
                    Text(model.t(model.systemResult?.status == "complete" ? "Scan Complete" : "Partial Scan"))
                    if let result=model.systemResult, !result.issues.isEmpty {
                        Button { showIssues.toggle() } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).accessibilityLabel(model.t("Some locations need attention"))
                            .popover(isPresented: $showIssues) { issues(result) }
                    }
                }.font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(model.bytes(model.commonReview.bytes)).font(.system(size: ShouDesign.workspaceTitleSize, weight: .medium)).monospacedDigit()
                Text(model.t("Found (estimate)")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            CleanupScanButton(model: model, rescan: true)
        }.padding(ShouDesign.workspaceInset)
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: model.t("%lld items selected"), locale: model.language.locale, selectedGroupCount))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    Text(model.t("Estimated Space to Free") + " " + model.bytes(model.commonSelectedBytes)).font(.system(size: ShouDesign.summaryFigureSize, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.commonSelectedBytes)))
                }
                Spacer()
                Menu(model.t("Select Items")) {
                    Button(model.t("Use Recommended Selection")) { model.commonSelection=Set(model.commonRecommended.map(\.id)) }
                    Button(model.t("Select Reviewable Items")) { model.commonSelection=[]; model.selectCommon(allGroups.flatMap(\.sources).filter { !$0.requiresManualReview && $0.candidate.risk != "high" }, selected: true) }
                    Button(model.t("Select All Eligible Items, Including High Risk")) { model.commonSelection=[]; model.selectCommon(allGroups.flatMap(\.sources).filter { !$0.requiresManualReview }, selected: true) }
                    Divider()
                    Button(model.t("Clear Selection")) { model.commonSelection=[] }
                }.fixedSize().disabled(model.busy)
                CleanupActionButton(model: model, enabled: !model.busy && !model.commonSelected.isEmpty,
                    clean: { model.executeCommonCleanup() }, trash: { model.executeCommonCleanup(permanent: false) })
            }.padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 18)
        }.background(.bar)
    }

    private var locationBrowser: some View {
        CleanupWelcomeView(model: model, showLocations: { scanLocations=true }, showAgentSetup: { agentSetup=true })
    }

    private func issues(_ result: SystemScanResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.t("Some locations need attention")).font(ShouType.body.weight(.semibold))
                ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.t(result.locations.first { $0.id == issue.locationId }?.title ?? issue.locationId)).font(ShouType.body.weight(.medium))
                        Text(model.t(issue.message)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    }
                }
            }.padding(20)
        }.frame(width: 380, height: 320)
    }

    private func title(_ id: String) -> String {
        model.t(["all":"All Items", "userCache":"User Cache Files", "application":"Application Caches", "browser":"Browser Data", "developer":"Developer Tools", "build":"Project Build Outputs", "personal":"Personal Rules", "system":"System Caches"][id] ?? "Other")
    }
    private func symbol(_ id: String) -> String {
        ["all":"tray.full", "userCache":"internaldrive", "application":"square.grid.2x2", "browser":"globe", "developer":"terminal", "build":"hammer", "personal":"slider.horizontal.3", "system":"internaldrive"][id] ?? "archivebox"
    }
}

private struct SoftwareIcon: View {
    let identifiers: [String]
    let fallback: String
    var body: some View {
        Group {
            if let icon=AppIdentity.applicationIcon(identifiers) { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: fallback).resizable().scaledToFit().padding(3).foregroundStyle(ShouPalette.secondary) }
        }.frame(width: ShouDesign.workspaceIconSize, height: ShouDesign.workspaceIconSize).accessibilityHidden(true)
    }
}

struct CommonRuleRow: View {
    @Bindable var model: AppModel
    let group: CleanupRuleGroup
    @State private var expanded=false
    @State private var visibleCount=10
    private var selectable: [CleanupSource] { group.sources.filter(\.selectable) }
    private var selected: [CleanupSource] { selectable.filter { model.commonSelection.contains($0.id) } }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Set(group.sources.flatMap { $0.candidate.rebuildNotes })).sorted(), id: \.self) { Text(model.t($0)).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
                ForEach(Array(Set(group.sources.flatMap { $0.candidate.limitations })).sorted(), id: \.self) { Label(model.t($0), systemImage: "info.circle").font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                ForEach(group.sources.prefix(visibleCount)) { source in
                    CleanupSourceRow(model: model, source: source)
                }
                if visibleCount < group.sources.count {
                    Button(String(format: model.t("Show More (%lld remaining)"), locale: model.language.locale, group.sources.count - visibleCount)) {
                        visibleCount += 50
                    }.buttonStyle(.link).accessibilityIdentifier("smart.more." + group.id)
                }
            }.padding(.leading, 18).padding(.vertical, 12).accessibilityElement(children: .contain)
        } label: {
            HStack(spacing: 12) {
                SelectionCheckbox(state: selected.isEmpty ? .off : selected.count == selectable.count ? .on : .mixed,
                    enabled: !model.busy && !selectable.isEmpty, label: model.t("Select") + " " + model.t(group.title)) {
                    model.selectCommon(group.sources, selected: selected.count != selectable.count)
                }.frame(width: 18, height: 20).accessibilityIdentifier("smart.rule." + group.id)
                SoftwareIcon(identifiers: group.applicationBundleIdentifiers, fallback: group.category == "build" ? "hammer" : group.category == "developer" ? "terminal" : "archivebox")
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t(group.title)).font(.system(size: ShouDesign.bodyFontSize, weight: .medium))
                    Text(String(format: model.t("%lld locations"), locale: model.language.locale, group.sources.count))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    if group.sources.contains(where: { $0.candidate.reasons.contains("application_running") }) {
                        Label(model.t("App is running"), systemImage: "app.badge").font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                    }
                    if selectable.isEmpty || group.sources.contains(where: \.requiresManualReview) { Text(model.t("Review required")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                    else if group.sources.contains(where: { $0.candidate.risk == "high" }) { Text(model.t("High risk")).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
                }
                Spacer(minLength: 5)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.bytes(group.bytes)).font(ShouType.body).monospacedDigit()
                    if selectedBytes > 0 { Text(model.t("Selected") + " " + model.bytes(selectedBytes)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).monospacedDigit() }
                }
            }.padding(.vertical, ShouDesign.workspaceRowPadding).accessibilityElement(children: .contain)
        }
        .accessibilityActions {
            if !model.busy && !selectable.isEmpty {
                Button(model.t(selected.count == selectable.count ? "Clear Selection" : "Select") + " " + model.t(group.title)) {
                    model.selectCommon(group.sources, selected: selected.count != selectable.count)
                }
            }
        }
    }
}
