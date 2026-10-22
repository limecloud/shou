import SwiftUI
import ShouCore
import AppKit
import QuickLook

@MainActor private func measuredSize(_ node: StorageNode?, model: AppModel) -> String {
    if node?.isComplete == false && node?.allocatedBytes == 0 && node?.fileCount == 0 { return model.t("Not measured") }
    return (node?.isComplete == false ? "≥ " : "") + model.bytes(node?.allocatedBytes ?? 0)
}

struct StorageBrowser: View {
    @Bindable var model: AppModel
    let inspector: Bool
    var body: some View {
        StorageAnalysisView(model: model, session: model.space, inspector: inspector)
    }
}

private enum StorageKeyboardArea: Hashable { case list, map }
private struct StorageAgentContext: Identifiable {
    let path: String
    var id: String { path }
}

private struct StorageAnalysisView: View {
    @Bindable var model: AppModel
    @Bindable var session: StorageSession
    let inspector: Bool
    @State private var agentContext: StorageAgentContext?
    @State private var previewURL: URL?
    @State private var showingCoverage=false
    @FocusState private var keyboardArea: StorageKeyboardArea?
    var body: some View {
        VStack(spacing: 0) {
            if !session.scanning && session.scan == nil { ScanAccessBanner(model: model) }
            if session.scanning { scanning }
            else if session.scan == nil { entry }
            else { results }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: $model.ai.showingInspector) {
            AIInvestigationInspector(model: model, session: model.ai)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .onChange(of: session.scan?.id) { _, _ in model.ai.stop() }
        .onChange(of: session.hasChanges) { _, changed in if changed { model.ai.stop() } }
        .task { session.loadLocations() }
        .task(id: "\(session.scan?.id ?? ""):\(session.path):\(session.detailed)") { session.loadPresentation(app: model) }
        .sheet(item: $session.plan) { plan in StorageRemovalConfirmation(model: model, session: session, plan: plan) }
        .sheet(item: $agentContext) { AgentRuleSetupView(model: model, contextPath: $0.path) }
        .quickLookPreview($previewURL)
    }
    private var entry: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "internaldrive.fill").font(.system(size: 76, weight: .light))
                .foregroundStyle(Color.accentColor.gradient).symbolRenderingMode(.hierarchical)
            VStack(spacing: 10) {
                Text(model.t("Space Analysis")).font(.system(size: 30, weight: .semibold))
                Text(model.t("Find what takes up space. Keep what matters."))
                    .font(.title3).foregroundStyle(.secondary)
            }
            VStack(spacing: 16) {
                Picker(model.t("Scan Location"), selection: $session.location) {
                    ForEach(session.locations) { item in Label(item.name, systemImage: item.symbol).tag(item.path) }
                }.labelsHidden().frame(width: 290).controlSize(.large)
                    .accessibilityLabel(model.t("Scan Location"))
                Button(model.t("Choose Folder…")) { session.chooseFolder(app: model) }.buttonStyle(.link)
            }.padding(.vertical, 8)
            Button { session.start(app: model) } label: {
                Text(model.t("Start Scan")).font(.headline).frame(width: 165).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("storage.start")
            Text(model.t("Scanning reads file sizes. Nothing is selected or deleted automatically."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Spacer().frame(height: 20)
        }.padding(30)
    }
    private var scanning: some View { StorageScanProgressView(model: model, session: session) }
    private var results: some View {
        VStack(spacing: 0) {
            navigation
            Divider()
            if let suffix=session.extensionFilter {
                HStack { Text(model.t("Highlighted extension") + ": " + (suffix.isEmpty ? model.t("No Extension") : "." + suffix)); Button(model.t("Clear")) { session.extensionFilter=nil }; Spacer() }.font(.caption).padding(6)
            }
            if session.detailed {
                StorageDetailedView(session: session, model: model)
            } else {
            HSplitView {
                directoryList.frame(minWidth: 320, idealWidth: 380, maxWidth: 510)
                    .overlay { if session.loadingDirectory { ProgressView().controlSize(.large) } }
                chart.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            Divider()
            selectionBar
        }
    }
    private var coverageDescription: String {
        model.t(session.actionableCoverage.isEmpty ? "System-managed locations are excluded from analysis." : "Some locations in this folder need attention.")
    }
    private var investigationPath: String {
        if session.selected.count == 1, let path=session.selected.first, session.index.nodes[path]?.kind == "directory" { return path }
        if let path=session.focus, session.index.nodes[path]?.kind == "directory" { return path }
        return session.path
    }
    private var navigation: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }.disabled(session.back.isEmpty)
                    .help(model.t("Back")).accessibilityLabel(model.t("Back"))
                Button { session.goForward() } label: { Image(systemName: "chevron.right") }.disabled(session.forward.isEmpty)
                    .help(model.t("Forward")).accessibilityLabel(model.t("Forward"))
                Button { session.navigate(StorageIndex.parent(session.path)) } label: { Image(systemName: "arrow.up") }.disabled(session.path == ".")
                    .help(model.t("Up One Level")).accessibilityLabel(model.t("Up One Level"))
            }.controlSize(.small).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Button { session.navigate(".") } label: {
                        Label(session.locations.first { $0.path == session.location }?.name ?? session.location, systemImage: "internaldrive")
                    }
                    let parts=session.path == "." ? [] : session.path.split(separator: "/").map(String.init)
                    ForEach(parts.indices, id: \.self) { i in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(parts[i]) { session.navigate(parts[...i].joined(separator: "/")) }
                    }
                }.buttonStyle(.borderless).font(.callout).fixedSize(horizontal: true, vertical: false)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker(model.t("View"), selection: $session.detailed) {
                Text(model.t("Simple")).tag(false)
                Text(model.t("Detailed")).tag(true)
            }.pickerStyle(.segmented).frame(width: 130).accessibilityIdentifier("storage.view-mode")
            Button { model.ai.requestLaunch(app: model, path: absolute(investigationPath)) } label: {
                Label(model.t("Investigate"), systemImage: "sparkles")
            }.disabled(session.loadingDirectory || model.busy).help(model.t("Investigate this folder with your model"))
                .accessibilityIdentifier("storage.investigate")
            Menu {
                Button(model.t(session.copyingAnalysis ? "Preparing…" : session.analysisCopied ? "Copied" : "Copy for AI")) { session.copyAnalysis(app: model) }
                    .disabled(session.copyingAnalysis || session.loadingDirectory || model.busy).accessibilityIdentifier("storage.copy-analysis")
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                .help(model.t("External AI Tools")).accessibilityLabel(model.t("External AI Tools"))
            if session.analysisHandoffStarted {
                Button(model.t("Review AI Rules…")) {
                    Task { await model.refreshExternalChanges(); model.reviewPersonalRules=true; model.section="rules"; model.externalRulesChanged=false }
                }.disabled(model.busy).accessibilityIdentifier("storage.review-ai-rules")
            }
            if session.currentFolderIncomplete {
                Button { showingCoverage=true } label: {
                    Label(model.t("Scan Coverage"), systemImage: session.actionableCoverage.isEmpty ? "info.circle" : "exclamationmark.triangle")
                }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    .foregroundStyle(session.actionableCoverage.isEmpty ? Color.secondary : Color.orange)
                    .help(coverageDescription).accessibilityLabel(model.t("Scan Coverage") + ": " + coverageDescription)
                    .accessibilityIdentifier("storage.coverage")
                    .popover(isPresented: $showingCoverage) {
                        StorageCoverageView(model: model, session: session, dismiss: { showingCoverage=false })
                    }
            }
            Button { session.start(app: model, retainPath: true) } label: {
                Label(model.t("Refresh"), systemImage: "arrow.clockwise")
            }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(model.busy)
                .help(model.t(session.hasChanges ? "Selected items processed. Refresh to measure current disk usage." : "Refresh"))
                .accessibilityIdentifier("storage.refresh")
            Button(model.t("Start Over")) { session.restart(app: model) }.buttonStyle(.borderless).disabled(model.busy).fixedSize()
        }.padding(.horizontal, 16).frame(height: 42).background(.bar)
    }
    private var directoryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.t("Filter this folder"), text: $session.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("storage.filter")
                if !session.query.isEmpty { Button { session.query="" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7)).padding(10)
            HStack {
                let eligible=session.eligibleChildren
                let count=eligible.filter { session.isSelected($0.path) }.count
                SelectionCheckbox(state: count == 0 ? .off : count == eligible.count ? .on : .mixed,
                    enabled: !eligible.isEmpty && !model.busy, label: model.t("Select All in This Folder"),
                    identifier: "storage.select-all") { session.selectVisible(app: model) }
                    .frame(width: 18, height: 18).help(model.t("Select All in This Folder"))
                Text(model.t("Name")).font(.caption.weight(.medium))
                Spacer()
                Picker(model.t("Sort"), selection: $session.sort) {
                    Text(model.t("Size")).tag("size")
                    Text(model.t("Name")).tag("name")
                    Text(model.t("Files")).tag("count")
                }.labelsHidden().frame(width: 105).controlSize(.small).accessibilityLabel(model.t("Sort"))
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(session.children) { node in row(node).id(node.path) }
                    }.padding(.vertical, 4)
                }
                .focusable().focusEffectDisabled().focused($keyboardArea, equals: .list)
                .onKeyPress(keys: [.space, .escape, "a"], action: handleKeyPress)
                .onChange(of: session.focus) { _, path in if let path { withAnimation { proxy.scrollTo(path, anchor: .center) } } }
            }
            if session.children.isEmpty {
                Text(model.t(session.query.isEmpty ? "This folder is empty." : "No matching items.")).font(.callout).foregroundStyle(.secondary).padding()
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private func row(_ node: StorageNode) -> some View {
        let reason=session.reason(node), checked=session.isSelected(node.path)
        let mixed = !checked && session.selected.contains { $0.hasPrefix(node.path + "/") }
        let emphasized=session.focus == node.path || session.hovered == node.path
        return HStack(spacing: 10) {
            SelectionCheckbox(state: checked ? .on : mixed ? .mixed : .off,
                enabled: reason == nil && !model.busy, label: model.t("Select Item") + " " + node.name,
                identifier: "storage.select." + node.path) { session.toggle(node, app: model) }
                .frame(width: 18, height: 18)
                .help(reason.map(model.t) ?? model.t("Select Item"))
            Image(nsImage: NSWorkspace.shared.icon(forFile: absolute(node.path))).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(node.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if node.isComplete == false {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            .help(model.t("Incomplete measurement. The displayed size is a lower bound."))
                    }
                    Spacer(minLength: 4)
                    Text(measuredSize(node, model: model)).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule().fill(color(node.path).opacity(0.65)).frame(width: max(2, geo.size.width * min(1, Double(node.allocatedBytes) / Double(max(1, session.index.nodes[session.path]?.allocatedBytes ?? 1)))))
                }.frame(height: 3)
                if node.kind == "directory" {
                    Text(String(format: model.t("%lld files"), node.fileCount)).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if node.kind == "directory" {
                Button { session.navigate(node.path) } label: { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).frame(width: 20, height: 32) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(model.t("Open Directory")).accessibilityLabel(model.t("Open Directory") + " " + node.name)
            } else { Color.clear.frame(width: 20) }
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .background(emphasized ? Color.accentColor.opacity(0.12) : checked ? Color.accentColor.opacity(0.045) : .clear)
            .contentShape(Rectangle()).onTapGesture(count: 2) { if node.kind == "directory" { session.navigate(node.path) } }
            .onTapGesture { session.focus=node.path; keyboardArea = .list }
            .contextMenu { actions(node) }
    }
    private var chart: some View {
        VStack(alignment: .leading, spacing: 14) {
            let node=session.index.nodes[session.hovered ?? session.focus ?? session.path]
            HStack(alignment: .firstTextBaseline) {
                Text(node?.path == "." ? model.t("Measured Space") : node?.name ?? model.t("Measured Space")).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(measuredSize(node, model: model)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            StorageTreemap(session: session, model: model, color: color,
                focus: { session.focus=$0; keyboardArea = .map },
                customize: { model.ai.requestLaunch(app: model, path: absolute($0)) },
                preview: { previewURL=URL(fileURLWithPath: absolute($0)) })
                .focusable().focusEffectDisabled().focused($keyboardArea, equals: .map)
                .onKeyPress(keys: [.space, .escape, "a"], action: handleKeyPress)
            HStack {
                Image(systemName: "cursorarrow").foregroundStyle(.tertiary)
                Text(model.t("Click to inspect. Double-click a folder to open it.")).font(.caption).foregroundStyle(.secondary)
            }
            if inspector, let path=session.focus, let node=session.index.nodes[path] {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(absolute(path)).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                        Text(model.bytes(node.allocatedBytes) + " · " + String(format: model.t("%lld files"), node.fileCount)).font(.caption).foregroundStyle(.secondary)
                        if let reason=session.reason(node) { Text(model.t(reason)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Menu { actions(node) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 25)
                }.frame(minHeight: 65, alignment: .top)
            }
        }.padding(20)
    }
    private var selectionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle").foregroundStyle(session.selected.isEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.selected.isEmpty ? model.t("Select files or folders to remove") : String(format: model.t("%lld items selected"), session.selected.count)).font(.callout)
                if !session.selected.isEmpty { Text(model.bytes(session.selectedBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if !session.selected.isEmpty { Button(model.t("Clear Selection")) { session.selected=[] }.buttonStyle(.borderless).disabled(model.busy) }
            Spacer()
            if session.reviewing {
                ProgressView().controlSize(.small)
                Button(model.t("Stop")) { session.stop() }
            } else {
                Menu {
                    Button(model.t("Delete Permanently…"), role: .destructive) { session.review(app: model, action: "permanent") }
                    Button(model.t("Move to Trash…")) { session.review(app: model, action: "trash") }
                } label: { Label(model.t("Delete Permanently…"), systemImage: "trash") }
                    primaryAction: { session.review(app: model, action: "permanent") }
                    .menuStyle(.borderlessButton).fixedSize().buttonStyle(.borderedProminent).controlSize(.regular)
                    .disabled(session.selected.isEmpty || model.busy).accessibilityIdentifier("storage.delete")
            }
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
    }
    @ViewBuilder private func actions(_ node: StorageNode) -> some View {
        Button(model.t("Reveal in Finder")) { session.reveal(node.path) }
        Button(model.t("Copy Path")) { session.copy(node.path) }
        if node.kind == "directory" { Button(model.t("Open Directory")) { session.navigate(node.path) } }
        Divider()
        Button(model.t(session.isSelected(node.path) ? "Deselect Item" : "Select Item")) { session.toggle(node, app: model) }.disabled(session.reason(node) != nil || model.busy)
        Button(model.t("Select All in This Folder")) { session.selectVisible(app: model) }.disabled(model.busy)
        if node.kind == "directory" {
            Divider()
            Button(model.t("Investigate This Folder")) { model.ai.requestLaunch(app: model, path: absolute(node.path)) }.disabled(model.busy)
        }
        Button(model.t("Quick Look")) { previewURL=URL(fileURLWithPath: absolute(node.path)) }
    }
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard keyboardArea != nil, !model.busy else { return .ignored }
        if press.key == "a", press.modifiers == .command {
            session.selectVisible(app: model, toggle: false)
            return .handled
        }
        if press.key == .escape { session.selected=[]; return .handled }
        if press.key == .space, press.modifiers.isEmpty, let path=session.focus {
            previewURL=URL(fileURLWithPath: absolute(path)); return .handled
        }
        return .ignored
    }
    private func absolute(_ path: String) -> String { StorageRemovalPolicy.absolute(root: session.scan?.rootPath ?? session.location, relative: path) }
    private func color(_ path: String) -> Color {
        let palette=[Color(red: 0.25, green: 0.55, blue: 0.72), Color(red: 0.42, green: 0.61, blue: 0.37), Color(red: 0.56, green: 0.44, blue: 0.65), Color(red: 0.85, green: 0.53, blue: 0.3), Color(red: 0.32, green: 0.63, blue: 0.59), Color(red: 0.72, green: 0.43, blue: 0.5)]
        let hash=path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct StorageCoverageView: View {
    var model: AppModel
    var session: StorageSession
    var dismiss: () -> Void
    @State private var copied: String?
    @State private var showingSystem=false
    private var notes: [StorageCoverageNote] { session.coverageNotes.filter { showingSystem || !$0.systemManaged } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Scan Coverage")).font(.headline)
            Text(model.t("Only measured space is included. Complete folders remain available even when another location cannot be read."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(notes.prefix(50).enumerated()), id: \.offset) { _, note in
                        noteRow(note)
                    }
                }.padding(.trailing, 8)
            }.frame(maxHeight: 280)
            if notes.isEmpty { Text(model.t("No access changes are needed for system-managed locations.")).font(.callout).foregroundStyle(.secondary) }
            if notes.count > 50 {
                Text(model.t("Showing the first 50 scan notes.")).font(.caption).foregroundStyle(.secondary)
            }
            if session.coverageNotes.contains(where: \.systemManaged) {
                Toggle(model.t("Show system-managed locations"), isOn: $showingSystem).font(.caption)
            }
            Divider()
            HStack {
                if model.scanAccess.needsAccess {
                    Button(model.t("Finish Setup…")) {
                        dismiss()
                        Task { @MainActor in await Task.yield(); model.scanAccess.showingSetup=true }
                    }
                }
                Spacer()
                Button(model.t("Rescan This Folder")) { dismiss(); session.rescanCurrentFolder(app: model) }.disabled(model.busy)
            }
        }.padding(20).frame(width: 460)
    }
    private func noteRow(_ note: StorageCoverageNote) -> some View {
        let issue=note.code + ": " + note.path
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t(note.systemManaged ? "Managed by the system; no action is needed." : reason(note.code)))
                    .font(.callout.weight(.medium))
                if !note.path.isEmpty {
                    Text(ProgressPresentation.shortPath(note.path)).font(.caption)
                        .foregroundStyle(.secondary).textSelection(.enabled).help(note.path)
                }
                if !note.systemManaged && ["authorization_required", "unreadable", "unreadable_directory"].contains(note.code) {
                    HStack {
                        Button(model.t("Finish Setup…")) { dismiss(); model.scanAccess.showingSetup=true }
                        Button(model.t("Reveal in Finder")) { session.reveal(note.path) }
                    }.font(.caption).buttonStyle(.link)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !note.path.isEmpty {
                Button {
                    let path=StorageRemovalPolicy.absolute(root: session.scan?.rootPath ?? "/", relative: note.path)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
                    copied=issue
                } label: { Image(systemName: copied == issue ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).help(model.t("Copy Path"))
                    .accessibilityLabel(model.t("Copy Path"))
            }
        }
    }
    private func reason(_ code: String) -> String {
        switch code {
        case "authorization_required": "Disk access is required for this location."
        case "unreadable", "unreadable_directory": "This location could not be read."
        case "changed_during_scan", "changed_directory": "This location changed during scanning."
        case "cloud_placeholder": "Cloud-only content was not downloaded."
        case "cross_filesystem": "This location belongs to another volume."
        case "resource_limit": "This location exceeded a scan resource boundary."
        case "additional_coverage_issues": "Additional scan notes are summarized here."
        default: "This location could not be fully measured."
        }
    }
}

private struct StorageTreemap: View {
    @Bindable var session: StorageSession
    var model: AppModel
    var color: (String) -> Color
    var focus: (String) -> Void
    var customize: (String) -> Void
    var preview: (String) -> Void
    private var nodes: [StorageNode] {
        let all=session.measuredChildren
        guard all.count > 160 else { return all }
        let remaining=all.dropFirst(160)
        return Array(all.prefix(160)) + [StorageNode(path: "", kind: "remainder", logicalBytes: remaining.reduce(0) { $0 + $1.logicalBytes }, allocatedBytes: remaining.reduce(0) { $0 + $1.allocatedBytes }, fileCount: remaining.reduce(0) { $0 + $1.fileCount }, newestModifiedNanoseconds: 0)]
    }
    var body: some View {
        GeometryReader { geometry in
            let nodes=nodes, lookup=Dictionary(uniqueKeysWithValues: nodes.map { ($0.path,$0) })
            let tiles=SpaceMap.layout(nodes, width: geometry.size.width, height: geometry.size.height)
            ZStack(alignment: .topLeading) {
                if tiles.isEmpty {
                    ContentUnavailableView(model.t(session.index.nodes[session.path]?.isComplete == false ? "This folder could not be fully measured" : "No allocated data in this folder"), systemImage: "folder")
                }
                ForEach(tiles) { tile in
                    if let node=lookup[tile.id] {
                        let selected=session.isSelected(node.path), focused=session.focus == node.path || session.hovered == node.path
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 5).fill(color(node.path).gradient)
                            if tile.width > 65 && tile.height > 42 {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(node.kind == "remainder" ? model.t("Other Entries") : node.name).font(.system(size: tile.width > 200 ? 15 : 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                                    Text(measuredSize(node, model: model)).font(.system(size: 11, design: .rounded)).monospacedDigit().opacity(0.85)
                                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).foregroundStyle(.white)
                            }
                            if tile.width > 45 && tile.height > 40, session.reason(node) == nil {
                                Button { session.toggle(node, app: model) } label: {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 19)).foregroundStyle(.white).shadow(radius: 2)
                                }.buttonStyle(.plain).padding(8).disabled(model.busy)
                                    .accessibilityLabel(model.t("Select Item") + " " + node.name)
                            }
                        }
                        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(selected || focused ? 0.95 : 0.15), lineWidth: selected || focused ? 3 : 1) }
                        .frame(width: max(0, tile.width-3), height: max(0, tile.height-3))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if node.kind == "directory" { session.navigate(node.path) } }
                        .onTapGesture { if node.kind != "remainder" { focus(node.path) } }
                        .onHover { session.hovered=$0 ? node.path : nil }
                        .position(x: tile.x+tile.width/2, y: tile.y+tile.height/2)
                        .help(node.path + " · " + model.bytes(node.allocatedBytes))
                        .accessibilityLabel(node.name + " " + model.bytes(node.allocatedBytes))
                        .contextMenu {
                            if node.kind != "remainder" {
                                Button(model.t("Reveal in Finder")) { session.reveal(node.path) }
                                Button(model.t("Copy Path")) { session.copy(node.path) }
                                Button(model.t("Quick Look")) { preview(node.path) }
                                Button(model.t(session.isSelected(node.path) ? "Deselect Item" : "Select Item")) { session.toggle(node, app: model) }.disabled(session.reason(node) != nil || model.busy)
                                if node.kind == "directory" {
                                    Button(model.t("Open Directory")) { session.navigate(node.path) }
                                    Button(model.t("Investigate This Folder")) { customize(node.path) }.disabled(model.busy)
                                }
                            }
                        }
                    }
                }
            }
        }.frame(minHeight: 220).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
