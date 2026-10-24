import Foundation

struct FileManifestPage: Codable, Sendable {
    let id: String
    let count: Int
    let digest: String
}

/// Immutable, content-addressed pages shared by plans and execution journals.
/// Publishing metadata is always the final write; partial pages grant no authority.
enum FileManifestRecords {
    static let pageSize=4096

    static func pages(_ entries: [FileEntry], prefix: String,
                      checkpoint: () throws -> Void = {},
                      consume: (FileManifestPage, Data) throws -> Void = { _, _ in }) throws -> [FileManifestPage] {
        var pages=[FileManifestPage]()
        for offset in stride(from: 0, to: entries.count, by: pageSize) {
            try checkpoint()
            let end=min(offset + pageSize, entries.count)
            let data=try Codec.encode(Array(entries[offset..<end]))
            let digest=Digest.sha256(data)
            let page=FileManifestPage(id: prefix + "_p" + String(pages.count) + "_" + digest.dropFirst(7).prefix(24), count: end - offset, digest: digest)
            try consume(page, data)
            pages.append(page)
        }
        return pages
    }

    static func load(_ pages: [FileManifestPage], count: Int, prefix: String,
                     collection: String, store: any RecordStore, checkpoint: () throws -> Void = {}) throws -> [FileEntry] {
        guard (1...1_000_001).contains(count), pages.count == (count + pageSize - 1) / pageSize else { throw corrupt() }
        var entries=[FileEntry]()
        entries.reserveCapacity(count)
        for (index, page) in pages.enumerated() {
            try checkpoint()
            guard page.count == min(pageSize, count - index * pageSize),
                  page.id == prefix + "_p" + String(index) + "_" + page.digest.dropFirst(7).prefix(24),
                  let data=try store.read(collection, id: page.id), Digest.sha256(data) == page.digest else { throw corrupt() }
            let values=try Codec.decode([FileEntry].self, from: data)
            guard values.count == page.count else { throw corrupt() }
            for value in values {
                guard value.path == "." || StorageRemovalPolicy.validRelative(value.path),
                      entries.last.map({ $0.path < value.path }) ?? true else { throw corrupt() }
                entries.append(value)
            }
        }
        guard entries.first?.path == "." else { throw corrupt() }
        return entries
    }

    static func corrupt() -> ShouError { ShouError("store_corrupt", "File manifest pages are missing or inconsistent.") }
}
