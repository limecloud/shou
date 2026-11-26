import Foundation

public struct HistoryCleanupPreview: Codable, Sendable {
    public let executionIds: [String]
    public let retainedCount: Int
    public let recordBytes: Int
    public var records: [StoredRecord] = []
}

extension ShouEngine {
    public func historyCleanupPreview(executionIds: [String]? = nil, includeRecoverable: Bool = false) throws -> HistoryCleanupPreview {
        let requested=executionIds.map(Set.init), followups=try followUps()
        let receiptIds=try store.ids("history").filter { requested == nil || requested!.contains($0) }
        let relatedFollowups=Dictionary(grouping: followups, by: \.executionId)
        var ids=[String](), records=[StoredRecord]()
        let manifests=try store.records("history-manifests")
        for id in receiptIds {
            try Task.checkCancellation()
            guard let metadata=try store.recordMetadata("history", id: id) else { throw ShouError("plan_stale", "History changed. Review the current records again.") }
            let receipt=try ReceiptJournal.load(id, store: store, includeManifests: false)
            guard receipt.id == id else { throw ShouError("store_corrupt", "History record identity is inconsistent.") }
            let related=relatedFollowups[receipt.id] ?? []
            guard ["completed", "partial", "cancelled"].contains(receipt.state), !related.contains(where: { !["completed", "failed"].contains($0.state) }),
                  !receipt.items.contains(where: { ["moving", "purging"].contains($0.state) }) else { continue }
            let unresolved=receipt.items.contains { item in
                if item.state == "pending" { return receipt.state != "cancelled" }
                if !["purged", "trashed", "failed", "skipped"].contains(item.state) { return true }
                return item.state == "trashed" && !related.contains { $0.itemId == item.id && $0.state == "completed" }
            }
            guard includeRecoverable || !unresolved else { continue }
            guard try store.recordMetadata("history", id: id) == metadata else { throw ShouError("plan_stale", "History changed. Review the current records again.") }
            ids.append(receipt.id)
            records.append(metadata)
            records.append(contentsOf: manifests.filter { $0.id.hasPrefix(receipt.id + "_") })
            if let summary=try store.recordMetadata("history-summaries", id: receipt.id) { records.append(summary) }
            for followup in related {
                if let metadata=try store.recordMetadata("followups", id: followup.id) { records.append(metadata) }
            }
        }
        return HistoryCleanupPreview(executionIds: ids, retainedCount: receiptIds.count - ids.count,
            recordBytes: records.reduce(0) { $0 + Int($1.byteCount) }, records: records)
    }
    /// Only removes Shou receipts. The referenced files, Trash items and executed
    /// plans remain untouched; a forgotten execution cannot be replayed.
    public func clearHistory(executionIds: [String], includeRecoverable: Bool = false) throws -> HistoryCleanupPreview {
        guard !executionIds.isEmpty, executionIds.count <= 10_000 else { throw ShouError("invalid_argument", "Select history records to remove.") }
        let lease=try store.lock(); defer { lease.release() }
        let preview=try historyCleanupPreview(executionIds: executionIds, includeRecoverable: includeRecoverable)
        guard Set(preview.executionIds) == Set(executionIds) else { throw ShouError("confirmation_required", "Active or recoverable records were preserved. Review the history selection.") }
        let followups=try followUps().filter { preview.executionIds.contains($0.executionId) }
        let manifests=try store.ids("history-manifests")
        for id in preview.executionIds {
            // Remove the parent first. Interruption may leave inert orphan follow-ups,
            // but must never make a completed restoration look available again.
            try store.removeHistoryRecord("history", id: id)
            if let summary=try store.recordMetadata("history-summaries", id: id) { try store.removeDerivedRecord(summary) }
            for manifest in manifests where manifest.hasPrefix(id + "_") { try store.removeHistoryRecord("history-manifests", id: manifest) }
            for followup in followups where followup.executionId == id { try store.removeHistoryRecord("followups", id: followup.id) }
        }
        return preview
    }
}
