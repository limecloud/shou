import SwiftUI
import ShouCore
import AppKit

struct StorageBrowser: View {
    @Bindable var model: AppModel
    @Binding var ruleEditor: Bool
    let inspector: Bool
    @State private var sortOrder=[KeyPathComparator(\StorageNode.allocatedBytes, order: .reverse)]
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(model: model, title: "Space Analysis", symbol: "square.grid.2x2")
            if model.workspace == nil { LocationPicker(model: model) }
            else if model.snapshot?.scope == .cleanup {
                ContentUnavailableView {
                    Label(model.t("Measure the whole workspace"), systemImage: "square.grid.2x2")
                } description: {
                    Text(model.t("Cleanup scans measure rule targets. Run space analysis to include other files."))
                } actions: {
                    Button(model.t("Run Space Analysis")) { model.startScan() }.buttonStyle(.borderedProminent).disabled(model.busy)
                }
            } else if let snapshot=model.snapshot {
                breadcrumb
                if snapshot.status != "complete" { Text(model.t("Partial measurements — inaccessible or changing content is not included.")).font(.caption).foregroundStyle(.orange).padding(10) }
                Divider()
                HSplitView {
                    directoryList.frame(minWidth: 260, idealWidth: 330, maxWidth: 430)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.t("Space by Directory")).font(.headline)
                            Spacer()
                            Text(model.bytes(model.storage.nodes[model.browsingPath]?.allocatedBytes ?? 0)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        StorageTreemap(model: model)
                        Text(model.t("Area represents allocated space. Click a folder to look inside; use the list to inspect an item.")).font(.caption).foregroundStyle(.secondary)
                        if inspector { storageInspector }
                    }.padding(20).frame(minWidth: 300)
                }
            } else { ScanPlaceholder(model: model) }
        }
    }
    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button { navigate(".") } label: { Image(systemName: "house") }.help(model.t("Workspace"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let parts=model.browsingPath == "." ? [] : model.browsingPath.split(separator: "/").map(String.init)
                    ForEach(parts.indices, id: \.self) { index in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(parts[index]) { navigate(parts[...index].joined(separator: "/")) }.lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { navigate(StorageIndex.parent(model.browsingPath)) } label: { Label(model.t("Up One Level"), systemImage: "arrow.up") }.disabled(model.browsingPath == ".")
        }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.bottom, 16)
    }
    private var directoryList: some View {
        Table(model.storage.children(of: model.browsingPath).sorted(using: sortOrder), selection: $model.focusedPath, sortOrder: $sortOrder) {
            TableColumn(model.t("Name"), value: \.name) { node in
                HStack(spacing: 8) {
                    Image(systemName: node.kind == "directory" ? "folder.fill" : node.kind == "symlink" ? "link" : "doc").foregroundStyle(node.kind == "directory" ? Color.accentColor : .secondary)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if node.kind == "directory" { Button { navigate(node.path) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).help(model.t("Open Directory")) }
                }
            }.width(min: 120, ideal: 220)
            TableColumn(model.t("Disk Usage"), value: \.allocatedBytes) { node in Text(model.bytes(node.allocatedBytes)).monospacedDigit() }.width(95)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if let path=paths.first { PathActions(model: model, path: path) }
        } primaryAction: { paths in
            if let path=paths.first, model.storage.nodes[path]?.kind == "directory" { navigate(path) }
        }
    }
    private var storageInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let path=model.focusedPath, let node=model.storage.nodes[path] {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(node.name).font(.headline)
                        Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(model.bytes(node.allocatedBytes) + " · " + String(node.fileCount) + " " + model.t("files")).font(.caption)
                    }
                    Spacer()
                    Menu { PathActions(model: model, path: path) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                }
                if let candidate=model.snapshot?.candidates.first(where: { $0.relativePath == path }), candidate.eligible {
                    Text(model.t(candidate.rebuildNotes.first ?? "Review")).font(.callout).foregroundStyle(.secondary)
                    Button(model.t("Review This Item")) { model.toggleCandidate(candidate, selected: true); model.section="overview" }.buttonStyle(.borderedProminent).disabled(model.busy)
                } else if node.kind == "directory" {
                    Text(model.t("Space usage does not mean this folder is disposable. Add a reviewed rule if you know how its contents can be rebuilt.")).font(.callout).foregroundStyle(.secondary)
                    Button(model.t("Create Rule for This Folder…")) { model.ruleDraftPattern=path; ruleEditor=true }.disabled(model.busy)
                }
            } else {
                Label(model.t("Select an item to see its details and available actions."), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 125, alignment: .top)
    }
    private func navigate(_ path: String) { model.browsingPath=path; model.focusedPath=nil }
}

struct StorageTreemap: View {
    var model: AppModel
    @State private var hovered: String?
    private var chartNodes: [StorageNode] {
        let nodes=model.storage.children(of: model.browsingPath)
        guard nodes.count > 60 else { return nodes }
        let rest=nodes.dropFirst(60)
        return Array(nodes.prefix(60)) + [StorageNode(path: "", kind: "remainder", logicalBytes: rest.reduce(0) { $0 + $1.logicalBytes }, allocatedBytes: rest.reduce(0) { $0 + $1.allocatedBytes }, fileCount: rest.reduce(0) { $0 + $1.fileCount }, newestModifiedNanoseconds: 0)]
    }
    var body: some View {
        GeometryReader { geometry in
            let nodes=chartNodes
            let byPath=Dictionary(uniqueKeysWithValues: nodes.map { ($0.path,$0) })
            let tiles=SpaceMap.layout(nodes, width: geometry.size.width, height: geometry.size.height)
            ZStack(alignment: .topLeading) {
                if tiles.isEmpty { ContentUnavailableView(model.t("No allocated data in this folder"), systemImage: "folder") }
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    if let node=byPath[tile.id] {
                        let selected=model.focusedPath == node.path || hovered == node.path
                        let color=tileColor(index)
                        Button {
                            if node.kind == "directory" { model.browsingPath=node.path; model.focusedPath=nil }
                            else { model.focusedPath=node.path }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7).fill(color.opacity(selected ? 0.95 : 0.78))
                                if tile.width > 65 && tile.height > 50 {
                                    VStack(spacing: 6) {
                                        if tile.height > 100 { Image(systemName: node.kind == "directory" ? "folder.fill" : "doc.fill").font(.system(size: min(32,tile.height/5))).foregroundStyle(.white.opacity(0.8)) }
                                        Text(node.kind == "remainder" ? model.t("Other Entries") : node.name).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                                        Text(model.bytes(node.allocatedBytes)).font(.system(size: 11, design: .rounded)).monospacedDigit().opacity(0.9)
                                    }.padding(8).foregroundStyle(.white)
                                }
                            }.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(selected ? 0.8 : 0.1), lineWidth: selected ? 2 : 1) }
                        }.buttonStyle(.plain)
                            .frame(width: max(0,tile.width-3), height: max(0,tile.height-3))
                            .position(x: tile.x+tile.width/2, y: tile.y+tile.height/2)
                            .help((node.kind == "remainder" ? model.t("Other entries are available in the directory list.") : node.path) + " · " + model.bytes(node.allocatedBytes))
                            .accessibilityLabel((node.kind == "remainder" ? model.t("Other Entries") : node.name) + " " + model.bytes(node.allocatedBytes))
                            .disabled(node.kind == "remainder")
                            .onHover { hovered=$0 ? node.path : nil }
                            .contextMenu { if node.kind != "remainder" { PathActions(model: model, path: node.path) } }
                    }
                }
            }
        }.frame(minHeight: 230).padding(4).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func tileColor(_ index: Int) -> Color { [Color.blue, .teal, .indigo, .cyan, .purple, .mint][index % 6] }
}
