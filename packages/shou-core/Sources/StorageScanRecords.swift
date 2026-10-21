import Foundation

/// Large analyses are published only after every bounded entry page is durable.
/// Existing single-record analyses remain readable without migration.
enum StorageScanRecords {
    private static let pageSize=10_000
    private struct Page: Codable {
        let id: String
        let count: Int
        let digest: String
    }
    private struct Record: Codable {
        let formatVersion: Int
        let scan: StorageScan
        let entryCount: Int
        let pages: [Page]
    }
    static func save(_ scan: StorageScan, store: any RecordStore, progress: (Int, Int) -> Void = { _, _ in }, checkpoint: () throws -> Void) throws {
        try checkpoint()
        let total=scan.tree.entries.count > pageSize ? (scan.tree.entries.count + pageSize - 1) / pageSize + 1 : 1
        progress(0, total)
        guard scan.tree.entries.count > pageSize else {
            let data=try Codec.encode(scan)
            try checkpoint()
            try store.write("storage-scans", id: scan.id, data: data)
            progress(1, total)
            return
        }
        var pages=[Page]()
        for offset in stride(from: 0, to: scan.tree.entries.count, by: pageSize) {
            try checkpoint()
            let end=min(offset + pageSize, scan.tree.entries.count)
            let data=try Codec.encode(Array(scan.tree.entries[offset..<end]))
            try checkpoint()
            let id=scan.id + "_p" + String(pages.count)
            try store.write("storage-scan-entries", id: id, data: data)
            pages.append(Page(id: id, count: end - offset, digest: Digest.sha256(data)))
            progress(pages.count, total)
        }
        var metadata=scan
        metadata.tree.entries=[]
        let record=Record(formatVersion: 1, scan: metadata, entryCount: scan.tree.entries.count, pages: pages)
        let data=try Codec.encode(record)
        try checkpoint()
        try store.write("storage-scans", id: scan.id, data: data)
        progress(total, total)
    }
    static func load(_ id: String, store: any RecordStore) throws -> StorageScan {
        guard let data=try store.read("storage-scans", id: id) else { throw ShouError("invalid_argument", "Unknown space analysis.") }
        guard let record=try? Codec.decode(Record.self, from: data) else { return try Codec.decode(StorageScan.self, from: data) }
        guard record.formatVersion == 1, record.scan.id == id, record.scan.tree.entries.isEmpty,
              (pageSize + 1...1_000_000).contains(record.entryCount),
              record.pages.count == (record.entryCount + pageSize - 1) / pageSize else { throw invalidRecord() }
        var scan=record.scan
        scan.tree.entries.reserveCapacity(record.entryCount)
        var previous: String?
        for (index, page) in record.pages.enumerated() {
            if Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            guard page.id == id + "_p" + String(index),
                  page.count == min(pageSize, record.entryCount - index * pageSize),
                  let data=try store.read("storage-scan-entries", id: page.id), Digest.sha256(data) == page.digest else { throw invalidRecord() }
            let entries=try Codec.decode([FileEntry].self, from: data)
            guard entries.count == page.count else { throw invalidRecord() }
            for entry in entries {
                guard previous.map({ $0 < entry.path }) ?? true else { throw invalidRecord() }
                previous=entry.path
            }
            scan.tree.entries.append(contentsOf: entries)
        }
        guard scan.tree.entries.first?.path == ".", scan.tree.entries.first?.sameObject(as: scan.identity) == true else { throw invalidRecord() }
        return scan
    }
    private static func invalidRecord() -> ShouError { ShouError("store_corrupt", "Space analysis entry pages are missing or inconsistent.") }
}
