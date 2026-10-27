import SwiftUI
import AppKit
import ShouCore

/// Native outline rows keep disclosure, keyboard focus, column resizing and
/// alternating backgrounds consistent with the rest of macOS.
struct CleanupOutlineTable: NSViewRepresentable {
    var model: AppModel
    let language: AppLanguage
    let snapshotID: String?
    let selection: Set<String>
    let busy: Bool
    let storageReady: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table=OutlineView()
        table.headerView=NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors=true
        table.rowHeight=28
        table.intercellSpacing=NSSize(width: 8, height: 0)
        table.selectionHighlightStyle = .regular
        table.indentationPerLevel=18
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .fullWidth
        table.allowsEmptySelection=true
        table.allowsMultipleSelection=false
        for (id,width) in [("name",560.0),("size",100.0),("files",75.0),("modified",100.0)] {
            let column=NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width=width; column.minWidth=id == "name" ? 260 : 65
            column.headerCell.font = .systemFont(ofSize: ShouDesign.captionFontSize,weight:.medium)
            column.headerCell.alignment=id == "name" ? .left : .right
            column.sortDescriptorPrototype=NSSortDescriptor(key:id,ascending:id == "name")
            table.addTableColumn(column)
            if id == "name" { table.outlineTableColumn=column }
        }
        table.sortDescriptors=[NSSortDescriptor(key:"size",ascending:false)]
        table.dataSource=context.coordinator; table.delegate=context.coordinator
        table.toggleFocusedSelection={ [weak coordinator=context.coordinator] in coordinator?.toggleFocusedItem() }
        table.setAccessibilityIdentifier("cleanup.candidates")
        let menu=NSMenu(); menu.autoenablesItems=false; menu.delegate=context.coordinator
        table.menu=menu
        let scroll=NSScrollView()
        scroll.documentView=table; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=false
        scroll.drawsBackground=false
        context.coordinator.table=table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(model, content: (snapshotID ?? "empty") + language.rawValue, selection: selection.sorted().joined(separator: ":") + String(busy) + String(storageReady))
    }

    @MainActor final class Item: NSObject {
        let group: CleanupCategory
        let candidate: Candidate?
        var children: [Item]=[]
        var key: String { candidate?.id ?? group.id }
        init(group: CleanupCategory, candidate: Candidate? = nil) { self.group=group; self.candidate=candidate }
        var bytes: Int64 { candidate?.allocatedBytesEstimate ?? group.allocatedBytesEstimate }
        var newest: Date { candidate?.newestModifiedAt ?? group.candidates.map(\.newestModifiedAt).max() ?? .distantPast }
    }
    @MainActor final class Checkbox: NSButton { var item: Item? }

    @MainActor final class OutlineView: NSOutlineView {
        var toggleFocusedSelection: (() -> Void)?
        var contextMenuRow: Int?

        override func keyDown(with event: NSEvent) {
            let modifiers=event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
                if !event.isARepeat { toggleFocusedSelection?() }
                return
            }
            if event.specialKey == .f10, modifiers == .shift, selectedRow >= 0, let menu {
                contextMenuRow=selectedRow
                // Populate lazy menus before AppKit checks whether there are items to show.
                menu.delegate?.menuNeedsUpdate?(menu)
                let bounds=rect(ofRow: selectedRow)
                guard let window, let contextEvent=NSEvent.mouseEvent(with: .rightMouseDown,
                    location: convert(NSPoint(x: bounds.minX + 28, y: bounds.maxY), to: nil),
                    modifierFlags: [], timestamp: event.timestamp, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
                NSMenu.popUpContextMenu(menu, with: contextEvent, for: self)
                return
            }
            super.keyDown(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                contextMenuRow=row(at: convert(event.locationInWindow, from: nil))
            default:
                contextMenuRow=selectedRow
            }
            return super.menu(for: event)
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: AppModel
        weak var table: OutlineView?
        var roots: [Item]=[]
        private var contentSignature=""
        private var selectionSignature=""
        private var updating=false
        init(model: AppModel) { self.model=model }
        func update(_ model: AppModel, content: String, selection: String) {
            self.model=model
            guard let table else { return }
            updating=true; defer { updating=false }
            if content != contentSignature {
                let expanded=Set(roots.filter { table.isItemExpanded($0) }.map(\.key))
                let selectedKey=(table.item(atRow: table.selectedRow) as? Item)?.key
                contentSignature=content
                roots=model.categories.map { group in
                    let item=Item(group: group)
                    item.children=group.candidates.map { Item(group: group, candidate: $0) }
                    return item
                }
                sortRows()
                for column in table.tableColumns {
                    let titles=["name":"Name","size":"Size","files":"Files","modified":"Modified"]
                    column.title=model.t(titles[column.identifier.rawValue] ?? "Name")
                }
                table.setAccessibilityLabel(model.t("Cleanup candidates"))
                table.setAccessibilityHelp(model.t("Use the arrow keys to browse and expand groups. Press Space to change the focused selection, or Shift-F10 for path actions."))
                reloadRows(expanded: expanded, selectedKey: selectedKey)
                selectionSignature=selection
            } else if selection != selectionSignature {
                selectionSignature=selection
                let expanded=Set(roots.filter { table.isItemExpanded($0) }.map(\.key))
                let selectedKey=(table.item(atRow: table.selectedRow) as? Item)?.key
                // A row-index reload materializes offscreen views in large outlines.
                // Reload the data so AppKit creates only the visible cells.
                reloadRows(expanded: expanded, selectedKey: selectedKey)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Item)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Item)?.children[index] ?? roots[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.children.isEmpty == false }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item=item as? Item else { return nil }
            let column=tableColumn?.identifier.rawValue ?? "name"
            if column == "name" { return nameCell(item) }
            let text: String
            if column == "size" { text=model.bytes(item.bytes) }
            else if column == "files" {
                let candidates=item.candidate.map { [$0] } ?? item.group.candidates
                text=String(candidates.reduce(0) { $0 + (model.storage.nodes[$1.relativePath]?.fileCount ?? 0) })
            } else {
                let formatter=RelativeDateTimeFormatter(); formatter.locale=model.language.locale; formatter.unitsStyle = .short
                text=formatter.localizedString(for:item.newest,relativeTo:Date())
            }
            let field=NSTextField(labelWithString:text)
            field.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); field.textColor = .secondaryLabelColor; field.alignment = .right
            field.lineBreakMode = .byTruncatingTail
            let cell=NSTableCellView(); field.translatesAutoresizingMaskIntoConstraints=false; cell.addSubview(field)
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo:cell.leadingAnchor),field.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-6),field.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            return cell
        }
        private func nameCell(_ item: Item) -> NSView {
            let candidates=item.candidate.map { [$0] } ?? item.group.candidates
            let eligible=candidates.filter(\.eligible), selected=eligible.filter { model.selection.contains($0.id) }
            let box=Checkbox(checkboxWithTitle:"",target:self,action:#selector(toggle(_:)))
            box.item=item; box.allowsMixedState=true; box.controlSize = .small
            box.state=selected.isEmpty ? .off : selected.count == eligible.count ? .on : .mixed
            box.isEnabled = !model.busy && !eligible.isEmpty
            box.setAccessibilityLabel(model.t("Select") + " " + (item.candidate?.relativePath ?? categoryTitle(item.group.id,model:model)))
            box.setAccessibilityIdentifier("cleanup.select." + item.key)
            let symbol=item.candidate?.eligible == false ? "lock.fill" : categorySymbol(item.group.id)
            let image=NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil) ?? NSImage())
            image.setAccessibilityElement(false)
            image.contentTintColor=NSColor(categoryColor(item.group.id)); image.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:12,weight:.regular)
            image.translatesAutoresizingMaskIntoConstraints=false; image.widthAnchor.constraint(equalToConstant:16).isActive=true
            let title=NSTextField(labelWithString:item.candidate?.relativePath ?? categoryTitle(item.group.id,model:model))
            title.font = .systemFont(ofSize:12,weight:item.candidate == nil ? .semibold : .regular)
            title.lineBreakMode = .byTruncatingMiddle
            let explanation: String
            if let candidate=item.candidate {
                if let activityReason=candidate.reasons.first(where: { ["application_running", "application_activity_unavailable", "build_process_running", "tracked_artifact_content", "artifact_evidence_unavailable", "artifact_layout_unverified", "artifact_restore_unavailable", "cargo_source_modified"].contains($0) }) {
                    explanation=model.t(activityReason)
                } else {
                    explanation = candidate.eligible ? model.t(candidate.rebuildNotes.first ?? "Review") : model.t(candidate.reasons.contains("incomplete_scan") ? "Incomplete scan" : "Protected content or exclusions prevent cleanup")
                }
            } else { explanation=model.t(categoryExplanation(item.group.id)) }
            box.setAccessibilityHelp((item.candidate?.risk == "high" ? model.t("High risk") + ". " : "") + explanation)
            let subtitle=NSTextField(labelWithString:explanation)
            subtitle.font = .systemFont(ofSize: ShouDesign.captionFontSize); subtitle.textColor=item.candidate?.risk == "high" ? .systemOrange : .tertiaryLabelColor
            subtitle.lineBreakMode = .byTruncatingTail
            subtitle.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            title.setContentCompressionResistancePriority(.defaultHigh,for:.horizontal)
            let stack=NSStackView(views:[box,image,title,subtitle]); stack.orientation = .horizontal; stack.spacing=8; stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints=false
            let cell=NSTableCellView(); cell.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:cell.leadingAnchor),stack.trailingAnchor.constraint(lessThanOrEqualTo:cell.trailingAnchor,constant:-4),stack.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            cell.toolTip=(item.candidate?.relativePath ?? categoryTitle(item.group.id,model:model)) + "\n" + explanation
            return cell
        }
        @objc private func toggle(_ sender: Checkbox) {
            guard let item=sender.item else { return }
            toggleItem(item)
        }
        func toggleFocusedItem() {
            guard let table, let item=table.item(atRow: table.selectedRow) as? Item else { return }
            toggleItem(item)
        }
        private func toggleItem(_ item: Item) {
            guard !model.busy else { return }
            let candidates=(item.candidate.map { [$0] } ?? item.group.candidates).filter(\.eligible)
            let shouldSelect = !candidates.allSatisfy { model.selection.contains($0.id) }
            if item.candidate == nil { model.selectOverviewCandidates(candidates, selected: shouldSelect) }
            else if let candidate=item.candidate { model.toggleCandidate(candidate, selected: shouldSelect) }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row=table.contextMenuRow ?? table.selectedRow
            guard row >= 0, let candidate=(table.item(atRow: row) as? Item)?.candidate else { return }
            for (index, title) in ["Reveal in Finder", "Copy Path", "Show in Space Analysis", "Exclude Directory"].enumerated() {
                let item=NSMenuItem(title: model.t(title), action: #selector(performPathAction(_:)), keyEquivalent: "")
                item.target=self; item.tag=index; item.representedObject=candidate.id
                item.isEnabled=index != 3 || !model.busy
                menu.addItem(item)
            }
        }
        @objc private func performPathAction(_ sender: NSMenuItem) {
            guard let id=sender.representedObject as? String,
                  let candidate=model.snapshot?.candidates.first(where: { $0.id == id }) else { return }
            switch sender.tag {
            case 0: model.revealPath(candidate.relativePath)
            case 1: model.copyPath(candidate.relativePath)
            case 2: model.showInSpaceAnalysis(candidate.relativePath)
            case 3: model.exclude(candidate)
            default: break
            }
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, table.selectedRow >= 0, let item=table.item(atRow:table.selectedRow) as? Item else { return }
            model.focusedPath=item.candidate?.relativePath
        }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let expanded=Set(roots.filter { outlineView.isItemExpanded($0) }.map(\.key))
            let selectedKey=(outlineView.item(atRow: outlineView.selectedRow) as? Item)?.key
            updating=true; defer { updating=false }
            sortRows()
            reloadRows(expanded: expanded, selectedKey: selectedKey, revealSelection: true)
        }
        private func reloadRows(expanded: Set<String>, selectedKey: String?, revealSelection: Bool = false) {
            guard let table else { return }
            table.reloadData()
            for root in roots where expanded.contains(root.key) { table.expandItem(root) }
            if let selectedKey, let row=(0..<table.numberOfRows).first(where: { (table.item(atRow: $0) as? Item)?.key == selectedKey }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if revealSelection { table.scrollRowToVisible(row) }
            }
        }
        private func sortRows() {
            let descriptor=table?.sortDescriptors.first
            func before(_ lhs: Item,_ rhs: Item) -> Bool {
                let ascending=descriptor?.ascending ?? false
                switch descriptor?.key {
                case "name":
                    let a=lhs.candidate?.relativePath ?? lhs.group.id, b=rhs.candidate?.relativePath ?? rhs.group.id
                    return ascending ? a < b : a > b
                case "modified": return ascending ? lhs.newest < rhs.newest : lhs.newest > rhs.newest
                case "files":
                    let a=count(lhs), b=count(rhs); return ascending ? a < b : a > b
                default: return ascending ? lhs.bytes < rhs.bytes : lhs.bytes > rhs.bytes
                }
            }
            roots.sort(by:before)
            for item in roots { item.children.sort(by:before) }
        }
        private func count(_ item: Item) -> Int { (item.candidate.map { [$0] } ?? item.group.candidates).reduce(0) { $0 + (model.storage.nodes[$1.relativePath]?.fileCount ?? 0) } }
    }
}

private func categoryExplanation(_ category: String) -> String {
    ["build":"Build tools recreate outputs when needed", "dependencies":"Reinstall to use these projects again", "cache":"Tools recreate caches when needed", "packages":"Packages will be downloaded again", "personal":"Your own reviewed cleanup rules"][category] ?? "Review"
}
