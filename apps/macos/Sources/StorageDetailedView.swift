import SwiftUI
import AppKit
import ShouCore

struct StorageDetailedView: View {
    @Bindable var session: StorageSession
    var model: AppModel
    var body: some View {
        StorageAnalysisSplit {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(model.t("Filter this folder"), text: $session.query).textFieldStyle(.plain)
                            Picker(model.t("Sort"), selection: $session.sort) {
                                Text(model.t("Size")).tag("size")
                                Text(model.t("Name")).tag("name")
                                Text(model.t("Files")).tag("count")
                            }.labelsHidden().frame(width: 70)
                            Button(model.t("Select All in This Folder")) { session.selectVisible(app: model) }.disabled(model.busy)
                        }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 8).frame(height: 29).background(.bar)
                        StorageDirectoryOutline(session: session, model: model)
                    }.frame(minWidth: 340, maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(model.t("File Extensions")).font(.system(size: 11, weight: .semibold))
                            Spacer()
                            if session.extensionFilter != nil { Button(model.t("Clear")) { session.extensionFilter=nil }.buttonStyle(.borderless) }
                        }.padding(.horizontal, 8).frame(height: 29).background(.bar)
                        StorageExtensionTable(session: session, model: model)
                        if session.hasChanges {
                            Text(model.t("Refresh to update extension totals after cleanup.")).font(.caption2).foregroundStyle(.secondary).padding(4)
                        }
                    }.frame(minWidth: 285, idealWidth: 360, maxWidth: 520)
                }.frame(minHeight: 160)
        } lower: {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(session.focus.flatMap { session.index.nodes[$0]?.name } ?? model.t("Measured Space")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(model.bytes(session.index.nodes[session.focus ?? session.path]?.allocatedBytes ?? 0)).monospacedDigit()
                    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 22).background(.bar)
                    StorageNestedMap(session: session, model: model)
                    HStack {
                        Text(model.t("Click to inspect. Double-click a folder to open it."))
                        Spacer()
                        Text(model.t("Colors indicate extensions, not cleanup eligibility."))
                    }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 20)
                }.frame(minHeight: 160, maxHeight: .infinity)
        }.overlay { if session.loadingPresentation { ProgressView().controlSize(.large).allowsHitTesting(false) } }
    }
}

func storageExtensionColor(_ suffix: String, brightness: Double = 1) -> Color {
    let hex=StorageMapPalette.hex(forExtension: suffix)
    let rgb=UInt32(hex.dropFirst(), radix: 16) ?? 0
    return Color(red: min(1, Double((rgb >> 16) & 255)/255 * brightness),
                 green: min(1, Double((rgb >> 8) & 255)/255 * brightness),
                 blue: min(1, Double(rgb & 255)/255 * brightness))
}

private struct StorageNestedMap: View {
    @Bindable var session: StorageSession
    var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let nodes=session.presentation?.items.compactMap { session.index.nodes[$0.node.path] } ?? []
            let lookup=Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
            let scope=session.index.nodes[session.path]
            let tiles=scope.map { SpaceMap.nested(nodes, scope: $0, width: geometry.size.width, height: geometry.size.height, aggregates: session.presentationAggregates) } ?? []
            Canvas { context, _ in
                for item in tiles {
                    let tile=item.tile, node=lookup[tile.id]
                    let rect=CGRect(x: tile.x + 0.35, y: tile.y + 0.35, width: max(0,tile.width - 0.7), height: max(0,tile.height - 0.7))
                    guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
                    let directory=node?.kind == "directory", suffix=item.aggregate?.suffix ?? StorageExtensionStat.suffix(node?.name ?? "")
                    let matching=(node?.kind == "file" || item.aggregate != nil) && suffix == session.extensionFilter
                    let shape=Path(rect)
                    if directory || item.remainder {
                        let level=0.19 + Double(item.depth % 4) * 0.025
                        context.fill(shape, with: .color(Color(white: level)))
                    } else {
                        var surface=context
                        surface.opacity=session.extensionFilter == nil || matching ? 1 : 0.25
                        surface.fill(shape, with: .linearGradient(Gradient(stops: [
                            .init(color: storageExtensionColor(suffix, brightness: 0.45), location: 0),
                            .init(color: storageExtensionColor(suffix, brightness: 1.15), location: 0.48),
                            .init(color: storageExtensionColor(suffix, brightness: 0.42), location: 1)
                        ]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                        surface.fill(shape, with: .linearGradient(Gradient(stops: [
                            .init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.5), .init(color: .black.opacity(0.45), location: 1)
                        ]), startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
                    }
                    if rect.width > 64, rect.height > 15 {
                        var labelContext=context; labelContext.clip(to: shape)
                        let title=item.remainder ? model.t("Other Entries") : item.aggregate.map { ($0.suffix.isEmpty ? model.t("No Extension") : "." + $0.suffix) + " × " + $0.fileCount.formatted() } ?? node?.name ?? ""
                        let size=model.bytes(item.aggregate?.allocatedBytes ?? node?.allocatedBytes ?? 0)
                        let label=Text(directory ? title + " (" + size + ")" : title).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(directory ? 0.9 : 1))
                        labelContext.draw(labelContext.resolve(label), in: CGRect(x: rect.minX + 3, y: rect.minY, width: rect.width - 6, height: 12))
                        if !directory && rect.height > 34 {
                            labelContext.draw(labelContext.resolve(Text(size).font(.system(size: 9)).foregroundColor(.white.opacity(0.8))), at: CGPoint(x: rect.minX+3,y:rect.minY+13), anchor: .topLeading)
                        }
                    }
                }
                // Draw linked highlights last so nested surfaces never cover them.
                for item in tiles where !item.remainder {
                    let path=item.id, node=lookup[path]
                    let matching=session.extensionFilter != nil && (node?.kind == "file" || item.aggregate != nil) && (item.aggregate?.suffix ?? StorageExtensionStat.suffix(node?.name ?? "")) == session.extensionFilter
                    if session.focus == path || session.isSelected(path) || matching || session.hovered == path {
                        let tile=item.tile
                        let rect=CGRect(x:tile.x+1,y:tile.y+1,width:max(0,tile.width-2),height:max(0,tile.height-2))
                        let color: Color=session.isSelected(path) ? .cyan : session.focus == path ? .white : matching ? Color(red:1,green:0.24,blue:0.22) : .white.opacity(0.7)
                        context.stroke(Path(rect),with:.color(color),lineWidth:session.isSelected(path) || session.focus == path ? 2 : 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { event in
                if let hit=hit(event.location, tiles), lookup[hit]?.kind == "directory" { session.navigate(hit) }
            }.exclusively(before: SpatialTapGesture().onEnded { event in session.focus=hit(event.location, tiles) }))
            .onContinuousHover { phase in
                switch phase { case .active(let point): session.hovered=hit(point, tiles); case .ended: session.hovered=nil }
            }
            .contextMenu {
                if let path=session.focus, let node=session.index.nodes[path] {
                    Button(model.t("Copy Path")) { session.copy(path) }
                    Button(model.t("Reveal in Finder")) { session.reveal(path) }
                    Button(model.t(session.isSelected(path) ? "Deselect Item" : "Select Item")) { session.toggle(node, app: model) }.disabled(model.busy || session.reason(node) != nil)
                    if node.kind == "directory" { Button(model.t("Open Directory")) { session.navigate(path) } }
                }
            }
            .accessibilityLabel(model.t("Space Map"))
            .accessibilityHint(model.t("Browse the directory tree for keyboard access to map items."))
        }.background(Color(white: 0.10))
    }
    private func hit(_ point: CGPoint, _ tiles: [NestedSpaceTile]) -> String? {
        guard let tile=tiles.last(where: { !$0.remainder && CGRect(x: $0.tile.x, y: $0.tile.y, width: $0.tile.width, height: $0.tile.height).contains(point) }) else { return nil }
        return tile.aggregate?.parentPath ?? tile.id
    }
}

private struct StorageDirectoryOutline: NSViewRepresentable {
    var session: StorageSession
    var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table=Outline(); table.style = .fullWidth; table.rowHeight=19; table.intercellSpacing=NSSize(width: 4, height: 0)
        table.usesAlternatingRowBackgroundColors=true; table.indentationPerLevel=12
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, width) in [("name",190.0),("share",58.0),("size",84.0),("logical",84.0),("files",72.0),("modified",125.0)] {
            let col=NSTableColumn(identifier: .init(id)); col.width=width; col.minWidth=id == "name" ? 155 : width; table.addTableColumn(col)
            if id == "name" { table.outlineTableColumn=col }
        }
        table.selectAllItems={ session.selectVisible(app: model, toggle: false) }
        table.clearItems={ session.selected=[] }
        table.toggleItem={ if let path=session.focus, let node=session.index.nodes[path] { session.toggle(node, app: model) } }
        table.delegate=context.coordinator; table.dataSource=context.coordinator
        table.target=context.coordinator; table.doubleAction=#selector(Coordinator.open)
        let scroll=NSScrollView(); scroll.documentView=table; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=true
        context.coordinator.table=table; table.setAccessibilityIdentifier("storage.directory-tree")
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }
    @MainActor final class Outline: NSOutlineView {
        var selectAllItems: (() -> Void)?
        var clearItems: (() -> Void)?
        var toggleItem: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
            if modifiers == .command && event.charactersIgnoringModifiers == "a" { selectAllItems?(); return }
            if modifiers.isEmpty && event.keyCode == 53 { clearItems?(); return }
            if modifiers.isEmpty && event.charactersIgnoringModifiers == " " { if !event.isARepeat { toggleItem?() }; return }
            super.keyDown(with:event)
        }
    }
    @MainActor final class Item: NSObject {
        let path: String
        let more: Bool
        init(_ path: String, more: Bool = false) { self.path=path; self.more=more }
    }
    @MainActor final class Check: NSButton { var path="" }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: StorageDirectoryOutline
        weak var table: NSOutlineView?
        var objects=[String: Item](), children=[String: [Item]]()
        var signature="", lastScope="", lastFocus: String?, updating=false
        init(_ parent: StorageDirectoryOutline) { self.parent=parent }
        func update(_ value: StorageDirectoryOutline) {
            parent=value
            guard let table else { return }
            let session=value.session
            let key="\(session.scan?.id ?? ""):\(session.path):\(session.index.nodes.count):\(session.selected.sorted()):\(session.query):\(session.sort):\(session.directoryOffsets):\(session.hasChanges):\(value.model.busy):\(value.model.language)"
            if key != signature {
                signature=key; updating=true
                let expanded=objects.values.filter { table.isItemExpanded($0) }
                let grouped=Dictionary(grouping: session.index.nodes.values.filter { $0.path != "." }, by: { StorageIndex.parent($0.path) })
                children=grouped.mapValues { nodes in nodes.sorted {
                    if session.sort == "name" { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    if session.sort == "count" { return $0.fileCount == $1.fileCount ? $0.path < $1.path : $0.fileCount > $1.fileCount }
                    return $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
                }.filter {
                    session.query.isEmpty || $0.kind == "directory" || $0.name.localizedCaseInsensitiveContains(session.query)
                }.map { node in
                    if let existing=objects[node.path] { return existing }
                    let item=Item(node.path); objects[node.path]=item; return item
                } }
                for (path,total) in session.directoryTotals where (session.directoryOffsets[path] ?? 0) < total {
                    children[path, default: []].append(Item(path, more: true))
                }
                let labels=["name":"Name","share":"% of Parent","size":"Allocated","logical":"Logical Size","files":"Files","modified":"Modified"]
                for col in table.tableColumns { col.title=value.model.t(labels[col.identifier.rawValue] ?? "") }
                table.reloadData()
                for item in expanded { table.expandItem(item) }
                let scope="\(session.scan?.id ?? ""):\(session.path)"
                if lastScope != scope, session.presentation != nil {
                    lastScope=scope
                    var path=session.path
                    for _ in 0..<8 {
                        guard let item=children[path]?.first, let node=session.index.nodes[item.path], node.kind == "directory",
                              Double(node.allocatedBytes)/Double(max(1,session.index.nodes[path]?.allocatedBytes ?? 0)) > 0.65 else { break }
                        table.expandItem(item); path=item.path
                    }
                }
                updating=false
            }
            if lastFocus != session.focus {
                lastFocus=session.focus; updating=true
                if let focus=session.focus, let item=objects[focus] {
                    var path=StorageIndex.parent(focus), ancestors=[Item]()
                    while path != session.path && path != "." { if let ancestor=objects[path] { ancestors.append(ancestor) }; path=StorageIndex.parent(path) }
                    for ancestor in ancestors.reversed() { table.expandItem(ancestor) }
                    let row=table.row(forItem: item)
                    if row >= 0 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
                }
                updating=false
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children[(item as? Item)?.path ?? parent.session.path]?.count ?? 0 }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children[(item as? Item)?.path ?? parent.session.path]![index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item=item as? Item, !item.more else { return false }
            return parent.session.index.nodes[item.path]?.kind == "directory"
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !updating, let item=notification.userInfo?["NSObject"] as? Item else { return }
            Task { await parent.session.expandDirectory(item.path, app: parent.model) }
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, let item=table.item(atRow: table.selectedRow) as? Item else { return }
            if item.more { Task { await parent.session.expandDirectory(item.path, app: parent.model, more: true) } }
            else { parent.session.focus=item.path }
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item=item as? Item else { return nil }
            if item.more { return NSTextField(labelWithString: tableColumn?.identifier.rawValue == "name" ? parent.model.t("Load More") : "") }
            guard let node=parent.session.index.nodes[item.path] else { return nil }
            switch tableColumn?.identifier.rawValue {
            case "name":
                let check=Check(checkboxWithTitle: "", target: self, action: #selector(toggle(_:))); check.controlSize = .mini
                check.path=node.path; check.allowsMixedState=true
                check.state=parent.session.isSelected(node.path) ? .on : parent.session.selected.contains(where: { $0.hasPrefix(node.path + "/") }) ? .mixed : .off
                check.isEnabled = !parent.model.busy && parent.session.reason(node) == nil
                check.setAccessibilityLabel(parent.model.t("Select Item") + " " + node.name)
                let text=NSTextField(labelWithString: node.name); text.font = .systemFont(ofSize: 11); text.lineBreakMode = .byTruncatingMiddle; text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let icon=NSImageView(image: NSImage(systemSymbolName: node.kind == "directory" ? "folder.fill" : "doc", accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor=node.kind == "directory" ? .systemBlue : .secondaryLabelColor
                icon.widthAnchor.constraint(equalToConstant: 13).isActive=true; icon.heightAnchor.constraint(equalToConstant: 13).isActive=true
                let stack=NSStackView(views: [check, icon, text]); stack.spacing=3; stack.orientation = .horizontal; stack.toolTip=StorageRemovalPolicy.absolute(root: parent.session.scan?.rootPath ?? "", relative: node.path); return stack
            default:
                let id=tableColumn?.identifier ?? .init("size")
                let field=(outlineView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
                field.identifier=id; field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); field.alignment = .right
                switch id.rawValue {
                case "size": field.stringValue=(node.isComplete == false ? "≥ " : "") + parent.model.bytes(node.allocatedBytes)
                case "logical": field.stringValue=parent.model.bytes(node.logicalBytes)
                case "share":
                    let total=parent.session.index.nodes[StorageIndex.parent(node.path)]?.allocatedBytes ?? 0
                    let share=(outlineView.makeView(withIdentifier: .init("share-bar"), owner: self) as? StorageShareCell) ?? StorageShareCell()
                    share.identifier = .init("share-bar"); share.fraction=Double(node.allocatedBytes)/Double(max(1,total))
                    return share
                case "modified": field.stringValue=Date(timeIntervalSince1970: Double(parent.session.entries[node.path]?.modifiedNanoseconds ?? 0)/1e9).formatted(date: .numeric, time: .shortened)
                default: field.stringValue=node.fileCount.formatted()
                }
                return field
            }
        }
        @objc func toggle(_ sender: Check) { if let node=parent.session.index.nodes[sender.path] { parent.session.toggle(node, app: parent.model) } }
        @objc func open() { guard let table, let item=table.item(atRow: table.clickedRow) as? Item, !item.more, parent.session.index.nodes[item.path]?.kind == "directory" else { return }; parent.session.navigate(item.path) }
    }
}
