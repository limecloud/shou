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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.scanning {
                VStack(alignment: .leading, spacing: 0) {
                    CapacityDots(segments: [], scanning: true).frame(height: 86).padding(.horizontal, 24).padding(.top, 20)
                    if let location=model.scanningLocation {
                        Text(model.t(location.title)).font(.headline).padding(.horizontal, 24).padding(.top, 20)
                    }
                    ScanActivity(model: model)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.systemResult != nil {
                resultBrowser
                selectionBar
            } else {
                locationBrowser
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.scanning)
        .onChange(of: model.systemResult?.snapshots.count) { _, _ in category="all" }
        .sheet(isPresented: $scanLocations) { ScanLocationsView(model: model) }
        .sheet(isPresented: $agentSetup, onDismiss: { Task { await model.refresh() } }) { AgentRuleSetupView(model: model) }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: AppIdentity.icon).resizable().interpolation(.high)
                .frame(width: 56, height: 56).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.systemResult == nil ? model.displayTitle : model.t("Smart Cleanup"))
                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(model.t("Tidy up. That's it.")).font(.callout).foregroundStyle(.secondary)
                if model.systemResult != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(model.t("Found (estimate)")).font(.caption).foregroundStyle(.secondary)
                        Text(model.bytes(model.commonReview.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                if model.scanning {
                    Button { model.cancel() } label: {
                        Label(model.t("Stop"), systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                } else if model.systemResult == nil {
                    HStack(spacing: 8) {
                        Button { model.quickCleanCommon() } label: {
                            Label(model.t("Scan & Free Space"), systemImage: "sparkles")
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button { model.scanCommonLocations() } label: {
                            Text(model.t("Scan Only"))
                        }.buttonStyle(.bordered).controlSize(.large)
                    }.disabled(model.busy)
                } else {
                    HStack(spacing: 8) {
                        Button { model.quickCleanCommon() } label: {
                            Label(model.t("Clean & Free Space"), systemImage: "sparkles")
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.commonRecommended.isEmpty || model.busy)
                        Menu {
                            Button(model.t("Move Recommended to Trash…")) { model.quickCleanCommon(permanent: false) }
                            Button(model.t("Permanently Clean Recommended…"), role: .destructive) { model.quickCleanCommon(permanent: true) }
                        } label: {
                            Image(systemName: "chevron.down")
                        }.menuStyle(.borderlessButton).frame(width: 24).disabled(model.commonRecommended.isEmpty || model.busy)
                        Button { model.scanCommonLocations() } label: {
                            Label(model.t("Scan Again"), systemImage: "arrow.clockwise")
                        }.buttonStyle(.bordered).controlSize(.large).disabled(model.busy)
                    }
                }
                if let result=model.systemResult, !result.issues.isEmpty {
                    Button { showIssues.toggle() } label: { Label(model.t("Some locations need attention"), systemImage: "exclamationmark.triangle") }
                        .buttonStyle(.link).font(.caption).popover(isPresented: $showIssues) { issues(result) }
                } else if !model.scanning {
                    Text(model.t(model.systemResult == nil ? "Scan is read-only. Clean Recommended opens one confirmation." : "Built-in and enabled personal rules are ready to clean.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var resultBrowser: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HSplitView {
                    List(selection: $category) {
                        categoryRow(id: "all", bytes: model.commonReview.bytes, sources: model.commonReview.sources).tag("all")
                        ForEach(model.commonReview.categories) { item in
                            categoryRow(id: item.id, bytes: item.bytes, sources: item.sources).tag(item.id)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
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

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title(category)).font(.headline)
                Spacer()
                TextField(model.t("Search rules or paths"), text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .accessibilityLabel(model.t("Search rules or paths"))
            }.padding(14)
            Divider()
            List {
                ForEach(groups) { group in CommonRuleRow(model: model, group: group) }
            }.listStyle(.inset)
                .overlay {
                    if groups.isEmpty {
                        ContentUnavailableView(model.t(query.isEmpty ? "No matching cleanup items" : "No search results"), systemImage: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                            description: Text(model.t(query.isEmpty ? "Nothing eligible was found. Use AI to cover your own tools and folders." : "Try another rule name or path.")))
                    }
                }
        }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categoryRow(id: String, bytes: Int64, sources: [CleanupSource]) -> some View {
        let selected=sources.filter { model.commonSelection.contains($0.id) }.reduce(Int64(0)) { $0 + $1.candidate.allocatedBytesEstimate }
        return HStack(spacing: 9) {
            Image(systemName: symbol(id)).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(id)).font(.callout)
                Text(model.bytes(selected) + " / " + model.bytes(bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: model.t("%lld items selected"), locale: model.language.locale, model.commonSelected.count))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.bytes(model.commonSelectedBytes)).font(.title3.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.commonSelectedBytes)))
                }
                Spacer()
                Menu(model.t("Select Items")) {
                    Button(model.t("Use Recommended Selection")) { model.commonSelection=Set(model.commonRecommended.map(\.id)) }
                    Button(model.t("Select Reviewable Items")) { model.commonSelection=[]; model.selectCommon(groups.flatMap(\.sources).filter { $0.candidate.risk != "high" }, selected: true) }
                    Button(model.t("Select All Eligible Items, Including High Risk")) { model.commonSelection=[]; model.selectCommon(groups.flatMap(\.sources), selected: true) }
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
        ScrollView {
            VStack(spacing: 28) {
                Spacer().frame(height: 24)
                Image(systemName: "sparkles").font(.system(size: 58, weight: .light))
                    .foregroundStyle(Color.accentColor.gradient).accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text(model.t("One scan. A tidier Mac.")).font(.system(size: 28, weight: .semibold))
                    Text(model.t("App caches, project build outputs, and your enabled rules — together in one cleanup."))
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 540)
                }
                HStack(spacing: 16) {
                    discoveryCard("Application Caches", symbol: "app.badge", count: model.knownLocations.filter(\.exists).count)
                    discoveryCard("Project Folders", symbol: "hammer", count: model.projectLocations.filter(\.exists).count)
                    discoveryCard("Personal Rules", symbol: "sparkles", count: Set(model.configuration.bindings.filter { $0.enabled && !$0.ruleId.hasPrefix(BuiltinCatalog.prefix) }.map(\.ruleId)).count)
                }.frame(maxWidth: 650)
                VStack(spacing: 14) {
                    Text(model.t("Common locations are found automatically. No project setup needed."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 20) {
                        Button(model.t("Customize with AI…")) { agentSetup=true }
                            .accessibilityIdentifier("smart.agent.setup")
                        Button(model.t("Scan Locations…")) { scanLocations=true }
                            .accessibilityIdentifier("smart.locations")
                    }.buttonStyle(.link).disabled(model.busy)
                }
                Spacer().frame(height: 24)
            }.padding(28).frame(maxWidth: .infinity)
        }
    }

    private func discoveryCard(_ title: String, symbol: String, count: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            Text(count.formatted()).font(.title.weight(.semibold)).monospacedDigit()
            Text(model.t(title)).font(.callout).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
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
        model.t(["all":"All Items", "application":"Application Caches", "browser":"Browser Caches", "developer":"Developer Tools", "build":"Project Build Outputs", "personal":"Personal Rules", "system":"System Caches"][id] ?? "Other")
    }
    private func symbol(_ id: String) -> String {
        ["all":"tray.full", "application":"square.grid.2x2", "browser":"globe", "developer":"terminal", "build":"hammer", "personal":"slider.horizontal.3", "system":"internaldrive"][id] ?? "archivebox"
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
    private var selectable: [CleanupSource] { group.sources.filter(\.selectable) }
    private var selected: [CleanupSource] { selectable.filter { model.commonSelection.contains($0.id) } }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                let candidate=group.sources.first?.candidate
                ForEach(Array(Set(candidate?.rebuildNotes ?? [])).sorted(), id: \.self) { Text(model.t($0)).font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(Set(candidate?.limitations ?? [])).sorted(), id: \.self) { Label(model.t($0), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                ForEach(group.sources) { source in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { model.commonSelection.contains(source.id) }, set: { model.selectCommon([source], selected: $0) })) { EmptyView() }
                            .toggleStyle(.checkbox).labelsHidden().disabled(!source.selectable || model.busy).padding(.top, 2)
                            .accessibilityLabel(model.t("Select") + " " + source.path)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(source.path)
                            Text(String(format: model.t("%lld files"), locale: model.language.locale, source.fileCount) + " · " + model.date(source.candidate.newestModifiedAt))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(source.candidate.reasons, id: \.self) { Text(model.t($0)).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer(minLength: 6)
                        Text(model.bytes(source.candidate.allocatedBytesEstimate)).font(.callout).monospacedDigit()
                    }.padding(.vertical, 5).contextMenu {
                        Button(model.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                        Button(model.t("Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.path, forType: .string) }
                    }
                }
            }.padding(.leading, 18).padding(.vertical, 12)
        } label: {
            HStack(spacing: 12) {
                SelectionCheckbox(state: selected.isEmpty ? .off : selected.count == selectable.count ? .on : .mixed,
                    enabled: !model.busy && !selectable.isEmpty, label: model.t("Select") + " " + model.t(group.title)) {
                    model.selectCommon(group.sources, selected: selected.count != selectable.count)
                }.frame(width: 18, height: 20)
                SoftwareIcon(identifiers: group.applicationBundleIdentifiers, fallback: group.category == "developer" ? "terminal" : "archivebox")
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t(group.title)).font(.callout.weight(.medium))
                    if selectable.isEmpty { Text(model.t("Review required")).font(.caption).foregroundStyle(.secondary) }
                    else if group.sources.contains(where: { $0.candidate.risk == "high" }) { Text(model.t("High risk — reinstall required")).font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength: 5)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.bytes(group.bytes)).font(.callout).monospacedDigit()
                    if selectedBytes > 0 { Text(model.t("Selected") + " " + model.bytes(selectedBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
            }.padding(.vertical, 8)
        }
    }
}
