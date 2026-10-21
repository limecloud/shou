import SwiftUI
import ShouCore

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var removal: HistoryCleanupPreview?
    @State private var includeRecoverable=false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.t("History")).font(.title2.weight(.semibold))
                Spacer()
                Button(model.t("Clear Finished Records…")) { prepareRemoval() }
                    .disabled(model.busy || model.history.isEmpty).accessibilityIdentifier("history.clear-finished")
            }.padding(24)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.history) { receipt in
                    HistoryReceiptView(model: model, receipt: receipt,
                        followups: model.followups.filter { $0.executionId == receipt.id },
                        remove: { prepareRemoval(ids: [receipt.id], allowRecoveryLoss: true) })
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.overlay {
            if model.history.isEmpty { ContentUnavailableView(model.t("No cleanup history"), systemImage: "clock") }
        }
        }
        .alert(model.t("Clear history records?"), isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal=nil } })) {
            Button(model.t("Cancel"), role: .cancel) { removal=nil }
            Button(model.t("Clear Records"), role: .destructive) {
                if let removal { model.clearHistory(removal.executionIds, includeRecoverable: includeRecoverable) }
                removal=nil
            }.disabled(removal?.executionIds.isEmpty != false)
        } message: {
            if let removal {
                Text(String(format: model.t("%lld records · %@ of local data"), locale: model.language.locale, removal.executionIds.count, model.bytes(Int64(removal.recordBytes))) + "\n" +
                     model.t(includeRecoverable ? "Only records are removed. Files stay in place, but Shou can no longer restore or verify these records." : "Only finished records are removed. Files stay in place; recoverable and unfinished records are kept."))
            }
        }
    }
    private func prepareRemoval(ids: [String]? = nil, allowRecoveryLoss: Bool = false) {
        guard let engine=model.engine, !model.busy else { return }
        Task {
            do { removal=try await engine.historyCleanupPreview(executionIds: ids, includeRecoverable: allowRecoveryLoss); includeRecoverable=allowRecoveryLoss }
            catch { model.error=error.localizedDescription }
        }
    }
}

private struct HistoryReceiptView: View {
    var model: AppModel
    let receipt: ExecutionReceipt
    let followups: [FollowUpReceipt]
    let remove: () -> Void
    @State private var selection=Set<String>()
    @State private var expanded=false

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
                Image(systemName: receipt.state == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(receipt.state == "completed" ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(receipt.items.first.map { URL(fileURLWithPath: $0.originalPath).lastPathComponent } ?? model.t("Cleanup"))
                        .font(.headline).lineLimit(1)
                    Text(model.date(receipt.createdAt) + " · " + model.t(receipt.state == "executing" ? "Unfinished cleanup" : receipt.state))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.bytes(receipt.items.reduce(0) { $0 + (["purged", "trashed"].contains($1.state) ? $1.allocatedBytesEstimate : 0) }))
                    .monospacedDigit().foregroundStyle(.secondary)
                Button(model.t(expanded ? "Hide Details" : "Details")) { expanded.toggle() }.buttonStyle(.borderless)
                    .accessibilityIdentifier("history.details." + receipt.id)
                Menu { Button(model.t("Remove Record…"), role: .destructive, action: remove) }
                    label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                    .disabled(model.busy || receipt.state == "executing")
            }
            if expanded {
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
                    Button(model.t("View Results")) { model.completion=CleanupCompletion(receipts: [receipt], sourceSection: "history") }
                        .accessibilityIdentifier("history.results." + receipt.id)
                    Spacer(minLength: 8)
                    Button(model.t("Restore…")) { model.review(receipt, items: selected, action: "restore") }
                        .disabled(selected.isEmpty).accessibilityIdentifier("history.restore." + receipt.id)
                    if !receipt.items.contains(where: { $0.uninstallOrigin != nil }) {
                        Button(model.t("Permanently Remove…"), role: .destructive) { model.review(receipt, items: selected, action: "purge") }
                            .disabled(selected.isEmpty).accessibilityIdentifier("history.remove." + receipt.id)
                    }
                }.buttonStyle(.bordered).disabled(model.busy).padding(.horizontal, 12).padding(.bottom, 12)
                Divider()
                ForEach(receipt.items) { item in
                    itemRow(item, followups: itemHistory[item.id] ?? [], selectable: availableIDs.contains(item.id))
                    Divider()
                }
                Text(model.t(receipt.items.contains { $0.state == "purged" } ? "Permanently removed items cannot be restored." : "Moved to Trash; this is not freed space."))
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: availableIDs) { _, ids in selection.formIntersection(ids) }
    }

    private func itemRow(_ item: ItemReceipt, followups: [FollowUpReceipt], selectable: Bool) -> some View {
        let completed=followups.first { $0.state == "completed" }
        let pending=followups.contains { $0.state == "pending" }
        let latest=followups.max { $0.createdAt < $1.createdAt }
        let state=receipt.state != "executing" && item.state == "pending" ? "Skipped" :
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
