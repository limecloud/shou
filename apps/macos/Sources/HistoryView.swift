import SwiftUI
import ShouCore

struct HistoryView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(model.history) { receipt in
                    HistoryReceiptView(model: model, receipt: receipt,
                        followups: model.followups.filter { $0.executionId == receipt.id })
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.overlay {
            if model.history.isEmpty { ContentUnavailableView(model.t("No cleanup history"), systemImage: "clock") }
        }
    }
}

private struct HistoryReceiptView: View {
    var model: AppModel
    let receipt: ExecutionReceipt
    let followups: [FollowUpReceipt]
    @State private var selection=Set<String>()

    private var availableItems: [ItemReceipt] {
        let blocked=Set(followups.filter { ["completed", "pending"].contains($0.state) }.map(\.itemId))
        return receipt.items.filter { $0.state == "trashed" && $0.trashPath != nil && !blocked.contains($0.id) }
    }

    var body: some View {
        let available=availableItems
        let availableIDs=Set(available.map(\.id))
        let selected=available.filter { selection.contains($0.id) }
        let itemHistory=Dictionary(grouping: followups, by: \.itemId)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.date(receipt.createdAt))
                Text(model.t(receipt.state == "executing" ? "Unfinished cleanup" : receipt.state))
                Text(model.t(receipt.entryPoint == "desktop" ? "Desktop" : "CLI"))
                if receipt.operation == "application_uninstall" { Text(model.t("Application uninstall")).foregroundStyle(.secondary) }
                Spacer()
            }
            Text(receipt.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    SelectionCheckbox(state: selected.isEmpty ? .off : selected.count == available.count ? .on : .mixed,
                        enabled: !model.busy && !available.isEmpty, label: model.t("Select available items in this cleanup"),
                        identifier: "history.selectAll." + receipt.id) {
                        selection=selected.count == available.count ? [] : availableIDs
                    }.frame(width: 18, height: 20)
                    Text(model.t("Select available items in this cleanup")).font(.callout)
                    Spacer()
                    Text(String(format: model.t("%lld items selected"), locale: model.language.locale, selected.count))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button(model.t("Clear Selection")) { selection=[] }.disabled(model.busy || selected.isEmpty)
                }.padding(12)
                HStack(spacing: 8) {
                    Button(model.t("Verify Locations…")) { model.historyInspection=HistoryInspectionRequest(id: receipt.id) }
                        .accessibilityIdentifier("history.inspect." + receipt.id)
                    Button(model.t("View Results")) { model.completion=CleanupCompletion(receipts: [receipt]) }
                        .accessibilityIdentifier("history.results." + receipt.id)
                    Spacer(minLength: 8)
                    Button(model.t("Restore…")) { model.review(receipt, items: selected, action: "restore") }
                        .disabled(selected.isEmpty).accessibilityIdentifier("history.restore." + receipt.id)
                    if receipt.operation != "application_uninstall" {
                        Button(model.t("Permanently Remove…"), role: .destructive) { model.review(receipt, items: selected, action: "purge") }
                            .disabled(selected.isEmpty).accessibilityIdentifier("history.remove." + receipt.id)
                    }
                }.buttonStyle(.bordered).disabled(model.busy).padding(.horizontal, 12).padding(.bottom, 12)
                Divider()
                ForEach(receipt.items) { item in
                    itemRow(item, followups: itemHistory[item.id] ?? [], selectable: availableIDs.contains(item.id))
                    Divider()
                }
                Text(model.t("Moved to Trash; this is not freed space."))
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }.onChange(of: availableIDs) { _, ids in selection.formIntersection(ids) }
    }

    private func itemRow(_ item: ItemReceipt, followups: [FollowUpReceipt], selectable: Bool) -> some View {
        let completed=followups.first { $0.state == "completed" }
        let pending=followups.contains { $0.state == "pending" }
        let latest=followups.max { $0.createdAt < $1.createdAt }
        let state=receipt.state == "cancelled" && item.state == "pending" ? "Skipped" :
            ["moving", "pending"].contains(item.state) ? "Needs verification" : item.state
        return HStack {
            Toggle(isOn: Binding(get: { selection.contains(item.id) }, set: {
                if $0 { selection.insert(item.id) } else { selection.remove(item.id) }
            })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.relativePath).font(.body.monospaced())
                    if item.uninstallOrigin != nil { Text(item.originalPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(model.diagnostic(pending ? "Follow-up needs verification" : item.error ?? completed?.action ?? state))
                        .font(.caption).foregroundStyle(.secondary)
                    if latest?.state == "failed", let error=latest?.error {
                        Text(model.diagnostic(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }.toggleStyle(.checkbox).disabled(model.busy || !selectable)
                .accessibilityIdentifier("history.select." + receipt.id + "." + item.id)
            Spacer()
            Text(model.bytes(item.allocatedBytesEstimate)).monospacedDigit()
        }.padding(12)
    }
}
