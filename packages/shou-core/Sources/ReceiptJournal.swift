import Foundation

/// Large manifests are immutable journal dependencies. State transitions publish
/// a small receipt only after its referenced manifests are durable.
struct ReceiptJournal {
    private struct Reference: Codable {
        let itemId: String
        let id: String
        let count: Int
        let digest: String
    }
    private struct Record: Codable {
        let formatVersion: Int
        var receipt: ExecutionReceipt
        let manifests: [Reference]
    }
    private var saved: [String: (entries: [FileEntry], reference: Reference)]=[:]

    mutating func save(_ receipt: ExecutionReceipt, store: any RecordStore) throws {
        var compact=receipt, references=[Reference]()
        for index in receipt.items.indices {
            let item=receipt.items[index]
            guard item.manifest.count > 1024 else { continue }
            let reference: Reference
            if let previous=saved[item.id], previous.entries == item.manifest { reference=previous.reference }
            else {
                let data=try Codec.encode(item.manifest), digest=Digest.sha256(data)
                let id=receipt.id + "_" + String(index) + "_" + digest.dropFirst(7).prefix(24)
                reference=Reference(itemId: item.id, id: id, count: item.manifest.count, digest: digest)
                try store.write("history-manifests", id: id, data: data)
                saved[item.id]=(item.manifest, reference)
            }
            compact.items[index].manifest=[]; references.append(reference)
        }
        let data=try references.isEmpty ? Codec.encode(receipt) : Codec.encode(Record(formatVersion: 1, receipt: compact, manifests: references))
        try store.write("history", id: receipt.id, data: data)
    }

    static func load(_ id: String, store: any RecordStore, includeManifests: Bool = true) throws -> ExecutionReceipt {
        guard let data=try store.read("history", id: id) else { throw ShouError("invalid_argument", "Record does not exist.", details: ["id": id]) }
        // Legacy inline receipts remain readable. A malformed new envelope must
        // fail closed rather than being mistaken for an empty old receipt.
        guard let record=try? Codec.decode(Record.self, from: data) else {
            do { return try Codec.decode(ExecutionReceipt.self, from: data) }
            catch { throw corrupt() }
        }
        var receipt=record.receipt
        guard record.formatVersion == 1, receipt.id == id, !record.manifests.isEmpty,
              Set(receipt.items.map(\.id)).count == receipt.items.count,
              Set(record.manifests.map(\.itemId)).count == record.manifests.count else { throw corrupt() }
        for reference in record.manifests {
            guard let index=receipt.items.firstIndex(where: { $0.id == reference.itemId }),
                  receipt.items[index].manifest.isEmpty, reference.count > 1024, reference.count <= 1_000_001,
                  reference.digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil,
                  reference.id == id + "_" + String(index) + "_" + reference.digest.dropFirst(7).prefix(24) else { throw corrupt() }
            if includeManifests {
                guard let bytes=try store.read("history-manifests", id: reference.id), Digest.sha256(bytes) == reference.digest,
                      let entries=try? Codec.decode([FileEntry].self, from: bytes), entries.count == reference.count,
                      entries.first?.path == "." else { throw corrupt() }
                receipt.items[index].manifest=entries
            }
        }
        if !includeManifests { for index in receipt.items.indices { receipt.items[index].manifest=[] } }
        return receipt
    }

    private static func corrupt() -> ShouError { ShouError("store_corrupt", "Execution journal manifests are missing or inconsistent.") }
}
