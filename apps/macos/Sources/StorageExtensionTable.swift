import AppKit
import SwiftUI
import ShouCore

@MainActor final class StorageShareCell: NSTableCellView {
    private let label=NSTextField(labelWithString: "")
    var fraction=0.0 { didSet { needsDisplay=true; label.stringValue=fraction.formatted(.percent.precision(.fractionLength(1))) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .monospacedDigitSystemFont(ofSize: ShouDesign.captionFontSize, weight: .regular); label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints=false; addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemBlue.withAlphaComponent(0.22).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * min(1,max(0,fraction)), height: bounds.height).fill()
    }
}

/// The same compact AppKit row metrics as the adjacent directory outline.
struct StorageExtensionTable: NSViewRepresentable {
    var session: StorageSession
    var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table=NSTableView(); table.rowHeight=19; table.intercellSpacing=NSSize(width: 4, height: 0)
        table.style = .fullWidth; table.usesAlternatingRowBackgroundColors=true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, width) in [("type",100.0),("share",52.0),("allocated",84.0),("files",72.0),("logical",84.0)] {
            let col=NSTableColumn(identifier: .init(id)); col.width=width; col.minWidth=id == "type" ? 85 : width
            table.addTableColumn(col)
        }
        table.delegate=context.coordinator; table.dataSource=context.coordinator
        table.setAccessibilityIdentifier("storage.extension-table")
        let scroll=NSScrollView(); scroll.documentView=table; scroll.hasVerticalScroller=true; scroll.hasHorizontalScroller=true
        context.coordinator.table=table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: StorageExtensionTable
        weak var table: NSTableView?
        var rows=[StorageExtensionStat](), signature="", updating=false
        init(_ parent: StorageExtensionTable) { self.parent=parent }
        func update(_ value: StorageExtensionTable) {
            parent=value
            guard let table else { return }
            updating=true
            let key="\(value.session.scan?.id ?? ""):\(value.session.path):\(value.session.presentation?.items.count ?? 0):\(value.model.language):\(value.session.hasChanges)"
            if key != signature {
                signature=key; rows=value.session.presentation?.extensions.items ?? []
                let labels=["type":"Type","share":"% of Scope","allocated":"Allocated","files":"Files","logical":"Logical Size"]
                for col in table.tableColumns { col.title=value.model.t(labels[col.identifier.rawValue] ?? "") }
                table.reloadData()
            }
            if let filter=value.session.extensionFilter, let row=rows.firstIndex(where: { $0.suffix == filter }) {
                if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
            updating=false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.session.extensionFilter=rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].suffix : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column=tableColumn else { return nil }
            let item=rows[row], id=column.identifier
            let field=(tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
            field.identifier=id; field.font = .monospacedDigitSystemFont(ofSize: ShouDesign.captionFontSize, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle; field.alignment = .right
            switch id.rawValue {
            case "type":
                let stack=(tableView.makeView(withIdentifier: .init("legend"), owner: self) as? NSStackView) ?? NSStackView()
                stack.identifier = .init("legend"); stack.orientation = .horizontal; stack.spacing=5
                if stack.arrangedSubviews.isEmpty {
                    let swatch=NSView(); swatch.wantsLayer=true
                    swatch.widthAnchor.constraint(equalToConstant: 8).isActive=true; swatch.heightAnchor.constraint(equalToConstant: 8).isActive=true
                    stack.addArrangedSubview(swatch)
                    let text=NSTextField(labelWithString: ""); text.font = .systemFont(ofSize: ShouDesign.captionFontSize); text.lineBreakMode = .byTruncatingMiddle
                    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); stack.addArrangedSubview(text)
                }
                stack.arrangedSubviews[0].layer?.backgroundColor=NSColor(storageExtensionColor(item.suffix)).cgColor
                (stack.arrangedSubviews[1] as? NSTextField)?.stringValue=item.suffix.isEmpty ? parent.model.t("No Extension") : "." + item.suffix
                stack.setAccessibilityLabel(item.suffix.isEmpty ? parent.model.t("No Extension") : "." + item.suffix)
                return stack
            case "share":
                let total=parent.session.presentation?.scope.node.allocatedBytes ?? 0
                let share=(tableView.makeView(withIdentifier: .init("share-bar"), owner: self) as? StorageShareCell) ?? StorageShareCell()
                share.identifier = .init("share-bar"); share.fraction=Double(item.allocatedBytes)/Double(max(1,total))
                return share
            case "allocated": field.stringValue=parent.model.bytes(item.allocatedBytes)
            case "logical": field.stringValue=parent.model.bytes(item.logicalBytes)
            default: field.stringValue=item.fileCount.formatted()
            }
            return field
        }
    }
}
