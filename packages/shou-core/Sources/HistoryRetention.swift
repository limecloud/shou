import Foundation

public struct HistoryCleanupPreview: Codable, Sendable {
    public let executionIds: [String]
    public let retainedCount: Int
    public let recordBytes: Int
}

extension ShouEngine {
    public func historyCleanupPreview(executionIds: [String]? = nil, includeRecoverable: Bool = false) throws -> HistoryCleanupPreview {
        let requested=executionIds.map(Set.init), followups=try followUps()
        let receipts=try history().filter { requested == nil || requested!.contains($0.id) }
        var ids=[String](), bytes=0
        let manifests=try store.records("history-manifests")
        for receipt in receipts {
            let related=followups.filter { $0.executionId == receipt.id }
            guard receipt.state != "executing", !related.contains(where: { $0.state == "pending" }),
                  !receipt.items.contains(where: { ["moving", "purging"].contains($0.state) }) else { continue }
            let unresolved=receipt.items.contains { item in
                if item.state == "unknown" || (item.state == "pending" && receipt.state != "cancelled") { return true }
                return item.state == "trashed" && !related.contains { $0.itemId == item.id && $0.state == "completed" }
            }
            guard includeRecoverable || !unresolved else { continue }
            ids.append(receipt.id)
            bytes += try store.read("history", id: receipt.id)?.count ?? 0
            bytes += manifests.filter { $0.id.hasPrefix(receipt.id + "_") }.reduce(0) { $0 + Int($1.byteCount) }
            for followup in related { bytes += try store.read("followups", id: followup.id)?.count ?? 0 }
        }
        return HistoryCleanupPreview(executionIds: ids, retainedCount: receipts.count - ids.count, recordBytes: bytes)
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
            for manifest in manifests where manifest.hasPrefix(id + "_") { try store.removeHistoryRecord("history-manifests", id: manifest) }
            for followup in followups where followup.executionId == id { try store.removeHistoryRecord("followups", id: followup.id) }
        }
        return preview
    }
}
