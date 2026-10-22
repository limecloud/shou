import SwiftUI
import ShouCore
import AppKit

struct SmartScanView: View {
    @Bindable var model: AppModel
    @ReduceMotion private var reduceMotion
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
                resultBrowser
                selectionBar
            } else {
                locationBrowser
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.scanning)
        .onChange(of: model.systemResult?.snapshots.count) { _, _ in
            if !model.commonReview.categories.contains(where: { $0.id == category }) {
                category=model.commonReview.categories.first?.id ?? "all"
            }
        }
        .sheet(isPresented: $scanLocations) { ScanLocationsView(model: model) }
        .sheet(isPresented: $agentSetup, onDismiss: { Task { await model.refresh() } }) { AgentRuleSetupView(model: model) }
        .toolbar {
            ToolbarItemGroup {
                if !model.scanning && model.systemResult != nil {
                    Button { model.ai.requestLaunch(app: model) } label: { Label(model.t("Investigate Other Space…"), systemImage: "sparkles") }
                        .disabled(model.busy).accessibilityIdentifier("smart.ai.other-space")
                    if model.commonReview.sources.contains(where: { $0.candidate.reasons.contains("application_running") }) {
                        CleanupApplicationCloseButton(model: model)
                    }
                    Button { scanLocations=true } label: { Label(model.t("Scan Locations…"), systemImage: "folder.badge.gearshape") }
                        .labelStyle(.iconOnly).help(model.t("Scan Locations…")).disabled(model.busy)
                }
                DiskCapacityView(model: model)
            }
        }
    }

    private var resultBrowser: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HSplitView {
                    List(selection: $category) {
                        categoryRow(id: "all", bytes: model.commonReview.bytes, sources: model.commonReview.sources, count: allGroups.count).tag("all")
                        ForEach(model.commonReview.categories) { item in
                            categoryRow(id: item.id, bytes: item.bytes, sources: item.sources, count: item.groups.count).tag(item.id)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 205, idealWidth: 225, maxWidth: 270)
                    ruleList
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Picker(model.t("Category"), selection: $category) {
                            Text(model.t("All Items")).tag("all")
                            ForEach(model.commonReview.categories) { Text(title($0.id)).tag($0.id) }
                        }.frame(maxWidth: 260)
                        Spacer()
                    }.padding(12)
                    Divider()
                    ruleList
                }
            }
        }
    }

    private var resultSummary: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(format: model.t("%lld cleanup items found"), locale: model.language.locale, allGroups.count)).font(.headline)
                Text(model.t("Found (estimate)") + " " + model.bytes(model.commonReview.bytes))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if let result=model.systemResult, !result.issues.isEmpty {
                    Button { showIssues.toggle() } label: { Label(model.t("Some locations need attention"), systemImage: "exclamationmark.triangle") }
                        .buttonStyle(.link).font(.caption).popover(isPresented: $showIssues) { issues(result) }
                }
            }
            Spacer()
            Label(model.t(model.systemResult?.status == "complete" ? "Scan Complete" : "Partial Scan"),
                systemImage: model.systemResult?.status == "complete" ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
            Button { model.scanCommonLocations() } label: { Label(model.t("Scan Again"), systemImage: "arrow.clockwise") }
                .disabled(model.busy).accessibilityIdentifier("smart.rescan")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            ruleHeader
            Divider()
            List {
                ForEach(groups) { group in CommonRuleRow(model: model, group: group) }
                if query.isEmpty && (category == "all" || category == "developer") { ToolCleanupPanel(model: model) }
            }.listStyle(.inset)
                .overlay {
                    if groups.isEmpty && (!query.isEmpty || (category != "all" && category != "developer")) {
                        ContentUnavailableView(model.t(query.isEmpty ? "No matching cleanup items" : "No search results"), systemImage: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                            description: Text(model.t(query.isEmpty ? "Nothing eligible was found. Use AI to cover your own tools and folders." : "Try another rule name or path.")))
                    }
                }
        }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ruleHeader: some View {
        let sources=groups.flatMap(\.sources)
        let eligible=sources.filter(\.selectable)
        let selected=eligible.filter { model.commonSelection.contains($0.id) }
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(title(category)).font(.headline)
                Text(String(format: model.t("%lld items"), locale: model.language.locale, groups.count)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(model.bytes(selected.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate }) + " / " + model.bytes(sources.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate }))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                SelectionCheckbox(state: selected.isEmpty ? .off : selected.count == eligible.count ? .on : .mixed,
                    enabled: !model.busy && !eligible.isEmpty, label: model.t("Select All"), identifier: "smart.select-visible") {
                    model.selectCommon(eligible, selected: selected.count != eligible.count)
                }.frame(width: 18, height: 18)
            }
            HStack {
                TextField(model.t("Search rules or paths"), text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    .accessibilityLabel(model.t("Search rules or paths"))
                    .accessibilityIdentifier("smart.search")
                Spacer(minLength: 0)
            }
        }.padding(14)
    }

    private func categoryRow(id: String, bytes: Int64, sources: [CleanupSource], count: Int) -> some View {
        let eligible=sources.filter(\.selectable)
        let selectedSources=eligible.filter { model.commonSelection.contains($0.id) }
        let selected=selectedSources.reduce(Int64(0)) { $0 + $1.candidate.allocatedBytesEstimate }
        return HStack(spacing: 9) {
            SelectionCheckbox(state: selectedSources.isEmpty ? .off : selectedSources.count == eligible.count ? .on : .mixed,
                enabled: !eligible.isEmpty && !model.busy, label: model.t("Select") + " " + title(id), identifier: "smart.category." + id) {
                model.selectCommon(eligible, selected: selectedSources.count != eligible.count)
            }.frame(width: 18, height: 18)
            Image(systemName: symbol(id)).font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(id)).font(.callout)
                Text(model.bytes(bytes) + " · " + String(format: model.t("%lld items"), locale: model.language.locale, count))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if !selectedSources.isEmpty {
                    Text(model.t("Selected") + " " + model.bytes(selected)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }.padding(.vertical, 7).accessibilityElement(children: .contain)
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: model.t("%lld items selected"), locale: model.language.locale, selectedGroupCount))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.t("Estimated Space to Free") + " " + model.bytes(model.commonSelectedBytes)).font(.title3.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.commonSelectedBytes)))
                }
                Spacer()
                Menu(model.t("Select Items")) {
                    Button(model.t("Use Recommended Selection")) { model.commonSelection=Set(model.commonRecommended.map(\.id)) }
                    Button(model.t("Select Reviewable Items")) { model.commonSelection=[]; model.selectCommon(allGroups.flatMap(\.sources).filter { $0.candidate.risk != "high" }, selected: true) }
                    Button(model.t("Select All Eligible Items, Including High Risk")) { model.commonSelection=[]; model.selectCommon(allGroups.flatMap(\.sources), selected: true) }
                    Divider()
                    Button(model.t("Clear Selection")) { model.commonSelection=[] }
                }.fixedSize().disabled(model.busy)
                Menu {
                    Button(model.t("Move Selected to Trash…")) { model.previewCommonCleanup(permanent: false) }
                    Button(model.t("Permanently Clean Selected…"), role: .destructive) { model.previewCommonCleanup(permanent: true) }
                } label: {
                    Text(model.t("Clean & Free Space"))
                } primaryAction: { model.previewCommonCleanup() }
                    .menuStyle(.borderlessButton).fixedSize().buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy || model.commonSelected.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(.bar)
    }

    private var locationBrowser: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(model.t("Find what is ready to tidy up")).font(.system(size: 26, weight: .semibold))
                Text(model.t("Scan app caches, developer build outputs, and your personal cleanup rules together."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            Menu {
                Button(model.t("Scan Common Locations")) { model.scanCommonLocations() }
                Button(model.t("Scan & Free Space")) { model.quickCleanCommon() }
                Divider()
                Button(model.t("Scan Locations…")) { scanLocations=true }
            } label: {
                Label(model.t("Start Scan"), systemImage: "sparkle.magnifyingglass").padding(.horizontal, 18).padding(.vertical, 7)
            } primaryAction: { model.scanCommonLocations() }
                .buttonStyle(.borderedProminent).controlSize(.large).fixedSize().disabled(model.busy)
                .accessibilityIdentifier("smart.start")
            Text(model.t("Common locations are found automatically. No project setup needed."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 20) {
                Button(model.t("Investigate a Folder with AI…")) { model.ai.requestLaunch(app: model) }.accessibilityIdentifier("smart.ai.investigate")
                Button(model.t("External AI Tools…")) { agentSetup=true }.accessibilityIdentifier("smart.agent.setup")
                Button(model.t("Scan Locations…")) { scanLocations=true }.accessibilityIdentifier("smart.locations")
            }.buttonStyle(.link).disabled(model.busy)
            Spacer()
        }.padding(30).frame(maxWidth: .infinity)
    }

    private func issues(_ result: SystemScanResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.t("Some locations need attention")).font(.headline)
                ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.t(result.locations.first { $0.id == issue.locationId }?.title ?? issue.locationId)).font(.callout.weight(.medium))
                        Text(model.t(issue.message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
            else { Image(systemName: fallback).resizable().scaledToFit().padding(3).foregroundStyle(.secondary) }
        }.frame(width: 28, height: 28).accessibilityHidden(true)
    }
}

private struct CommonRuleRow: View {
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
                ForEach(Array(Set(group.sources.flatMap { $0.candidate.rebuildNotes })).sorted(), id: \.self) { Text(model.t($0)).font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(Set(group.sources.flatMap { $0.candidate.limitations })).sorted(), id: \.self) { Label(model.t($0), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                ForEach(group.sources.prefix(visibleCount)) { source in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { model.commonSelection.contains(source.id) }, set: { model.selectCommon([source], selected: $0) })) { EmptyView() }
                            .toggleStyle(.checkbox).labelsHidden().disabled(!source.selectable || model.busy).padding(.top, 2)
                            .accessibilityLabel(model.t("Select") + " " + source.path)
                            .accessibilityIdentifier("smart.source." + source.path)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(source.path)
                            Text(String(format: model.t("%lld files"), locale: model.language.locale, source.fileCount) + " · " + model.date(source.candidate.newestModifiedAt))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(source.candidate.reasons, id: \.self) { Text(model.t($0)).font(.caption).foregroundStyle(.orange) }
                            if source.candidate.reasons.contains("incomplete_scan") {
                                Button(model.t("Continue Scanning This Directory")) { model.continueCleanupScan(source) }
                                    .buttonStyle(.link).font(.caption).disabled(model.busy)
                                    .accessibilityIdentifier("smart.continue." + source.path)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(model.bytes(source.candidate.allocatedBytesEstimate)).font(.callout).monospacedDigit()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) } label: {
                            Image(systemName: "folder")
                        }.buttonStyle(.borderless).help(model.t("Reveal in Finder"))
                            .accessibilityLabel(model.t("Reveal in Finder") + " " + source.path)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain).contextMenu {
                        if source.candidate.reasons.contains("incomplete_scan") {
                            Button(model.t("Continue Scanning This Directory")) { model.continueCleanupScan(source) }.disabled(model.busy)
                        }
                        Button(model.t("Investigate This Folder")) { model.ai.requestLaunch(app: model, path: source.path) }.disabled(model.busy)
                        Button(model.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                        Button(model.t("Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.path, forType: .string) }
                    }
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
                    Text(model.t(group.title)).font(.callout.weight(.medium))
                    Text(String(format: model.t("%lld locations"), locale: model.language.locale, group.sources.count))
                        .font(.caption).foregroundStyle(.secondary)
                    if selectable.isEmpty { Text(model.t("Review required")).font(.caption).foregroundStyle(.secondary) }
                    else if group.sources.contains(where: { $0.candidate.risk == "high" }) { Text(model.t("High risk")).font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength: 5)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.bytes(group.bytes)).font(.callout).monospacedDigit()
                    if selectedBytes > 0 { Text(model.t("Selected") + " " + model.bytes(selectedBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
            }.padding(.vertical, 8).accessibilityElement(children: .contain)
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
