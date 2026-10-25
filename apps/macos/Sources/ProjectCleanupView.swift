import SwiftUI
import ShouCore
import AppKit

struct ProjectCleanupView: View {
    @Bindable var model: AppModel
    @State private var projects: [CleanupProjectGroup]=[]
    @State private var query=""
    private var visible: [CleanupProjectGroup] { projects.filter { query.isEmpty || $0.path.localizedStandardContains(query) } }
    private var projectSources: [CleanupSource] { projects.flatMap(\.sources) }
    private var selected: [CleanupSource] { projectSources.filter { model.commonSelection.contains($0.id) && $0.selectable } }
    private var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }

    var body: some View {
        VStack(spacing: 0) {
            if model.systemResult != nil && !model.scanning {
                WorkspaceHeading(title: model.t("Developer Projects"), subtitle: model.t("Review build outputs and dependencies from local and cloned projects. Source files are kept."), artwork: .projects)
            }
            if model.scanning {
                ScanActivity(model: model).frame(maxHeight: .infinity)
            } else if model.systemResult == nil {
                WorkspaceStartPage(eyebrow: model.t("Developer Projects"), title: model.t("More room to build."),
                    subtitle: model.t("Review build outputs and dependencies from local and cloned projects. Source files are kept."), kind: .projects,
                    footnote: model.t("Built-in and enabled personal rules share the same scan and selection.")) {
                    HStack(spacing: 18) {
                        Button { model.scanCommonLocations() } label: { Label(model.t("Start Scan"), systemImage: "magnifyingglass") }
                            .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(model.busy).accessibilityIdentifier("projects.start")
                        Button(model.t("Include Folder…")) { model.addWorkspace() }.buttonStyle(.link).disabled(model.busy)
                    }
                }.accessibilityIdentifier("projects.welcome")
            } else {
                HStack(spacing: 16) {
                    TextField(model.t("Search projects or paths"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                        .accessibilityIdentifier("projects.search")
                    Spacer()
                    Button(model.t("Include Folder…")) { model.addWorkspace() }.disabled(model.busy)
                    Button { model.scanCommonLocations() } label: { Label(model.t("Scan Again"), systemImage: "arrow.clockwise") }.disabled(model.busy)
                }.padding(.horizontal, ShouDesign.workspaceInset).padding(.bottom, 18)
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(visible) { project in ProjectCleanupRow(model: model, project: project) }
                    }.padding(.horizontal, ShouDesign.workspaceInset).padding(.bottom, 24)
                }
                .overlay {
                    if visible.isEmpty { WorkspaceEmptyState(title: model.t("No matching project outputs"), kind: .projects) }
                }
                Divider()
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: model.t("%lld locations selected"), locale: model.language.locale, selected.count)).font(.caption).foregroundStyle(.secondary)
                        Text(model.bytes(selectedBytes)).font(.system(size: ShouDesign.summaryFigureSize, weight: .medium)).monospacedDigit()
                    }
                    Spacer()
                    Button(model.t("Clear Selection")) { model.selectCommon(projectSources, selected: false) }.disabled(model.busy || selected.isEmpty)
                    CleanupActionButton(model: model, enabled: !model.busy && !selected.isEmpty,
                        clean: { model.previewCommonCleanup(sourceIds: Set(projectSources.map(\.id))) },
                        trash: { model.previewCommonCleanup(permanent: false, sourceIds: Set(projectSources.map(\.id))) })
                }.padding(ShouDesign.workspaceInset).background(.bar)
            }
        }
        .task(id: model.systemResult?.snapshots.map(\.id)) {
            let review=model.commonReview
            let snapshots=model.systemResult?.snapshots ?? []
            let locations=model.systemResult?.locations ?? []
            let result=await Task.detached(priority: .userInitiated) { review.projects(snapshots: snapshots, locations: locations) }.value
            guard !Task.isCancelled else { return }
            projects=result
        }
    }
}

private struct ProjectCleanupRow: View {
    @Bindable var model: AppModel
    let project: CleanupProjectGroup
    @State private var expanded=false
    @State private var visibleCount=20
    private var selectable: [CleanupSource] { project.sources.filter(\.selectable) }
    private var selected: [CleanupSource] { selectable.filter { model.commonSelection.contains($0.id) } }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 12) {
                Divider()
                ForEach(project.sources.prefix(visibleCount)) { source in CleanupSourceRow(model: model, source: source) }
                if visibleCount < project.sources.count {
                    Button(model.t("Show More")) { visibleCount += 50 }.buttonStyle(.link)
                }
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 16) {
                SelectionCheckbox(state: selected.isEmpty ? .off : selected.count == selectable.count ? .on : .mixed,
                    enabled: !model.busy && !selectable.isEmpty, label: model.t("Select") + " " + project.path,
                    identifier: "projects.select." + project.path) {
                    model.selectCommon(selectable, selected: selected.count != selectable.count)
                }.frame(width: 22, height: 24)
                Image(systemName: project.identifiedProject ? "chevron.left.forwardslash.chevron.right" : "folder")
                    .font(.title2).foregroundStyle(Color.accentColor).frame(width: ShouDesign.workspaceIconSize)
                VStack(alignment: .leading, spacing: 6) {
                    Text(URL(fileURLWithPath: project.path).lastPathComponent).font(.system(size: ShouDesign.bodyFontSize, weight: .medium))
                    Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(project.path)
                    if !project.identifiedProject { Text(model.t("Grouped by scan location")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(model.bytes(project.bytes)).font(.system(size: 16, weight: .medium)).monospacedDigit()
                    Text(model.t("Matched cleanup items")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }
        .padding(18).modifier(WorkspaceSurface())
    }
}
