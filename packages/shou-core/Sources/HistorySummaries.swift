import Foundation

public struct HistoryPage: Codable, Sendable {
    public let receipts: [ExecutionReceipt]
    public let totalCount: Int
    public let nextOffset: Int?
}

private struct ReceiptSummary: Codable {
    let revision: String
    let receipt: ExecutionReceipt
}

enum HistorySummaries {
    static func save(_ receipt: ExecutionReceipt, store: any RecordStore, revision: String? = nil) {
        // Summaries are disposable. A failed summary write must never turn a
        // committed deletion into a journal failure; stale summaries are rejected.
        guard let revision=revision ?? (try? store.recordMetadata("history", id: receipt.id)?.revision) else { return }
        var summary=receipt
        for index in summary.items.indices { summary.items[index].manifest=[] }
        if let data=try? Codec.encode(ReceiptSummary(revision: revision, receipt: summary)) {
            try? store.write("history-summaries", id: receipt.id, data: data)
        }
    }
}

extension ShouEngine {
    public func historySummaries(offset: Int = 0, limit: Int = 50) throws -> HistoryPage {
        guard offset >= 0, offset <= 1_000_000, (1...500).contains(limit) else { throw ShouError("invalid_argument", "Invalid history page.") }
        let records=try store.records("history").sorted { a,b in
            a.modifiedAt == b.modifiedAt ? a.id > b.id : a.modifiedAt > b.modifiedAt
        }
        var receipts=[ExecutionReceipt]()
        for record in records.dropFirst(offset).prefix(limit) {
            if Task.isCancelled { throw ShouError("cancelled", "History loading cancelled.") }
            if let data=try? store.read("history-summaries", id: record.id),
               let cached=try? Codec.decode(ReceiptSummary.self, from: data), cached.revision == record.revision,
               cached.receipt.id == record.id {
                receipts.append(cached.receipt)
            } else {
                let full=try ReceiptJournal.load(record.id, store: store, includeManifests: false)
                HistorySummaries.save(full, store: store, revision: record.revision)
                var summary=full
                for index in summary.items.indices { summary.items[index].manifest=[] }
                receipts.append(summary)
            }
        }
        let end=offset + receipts.count
        return .init(receipts: receipts, totalCount: records.count, nextOffset: end < records.count ? end : nil)
    }
}
