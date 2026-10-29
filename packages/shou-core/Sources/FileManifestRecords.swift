import Foundation

struct FileManifestPage: Codable, Sendable {
    let id: String
    let count: Int
    let digest: String
}

/// An operation-local source whose pages and decoded entries were verified together.
/// Journals copy the bytes into their own retention scope, never depend on a plan's lifetime.
struct FileManifestSource {
    let entries: [FileEntry]
    let pages: [FileManifestPage]
    let prefix: String
    let collection: String
}

/// Immutable, content-addressed pages shared by plans and execution journals.
/// Publishing metadata is always the final write; partial pages grant no authority.
enum FileManifestRecords {
    static let pageSize=4096

    static func pages(_ entries: [FileEntry], prefix: String,
                      checkpoint: () throws -> Void = {},
                      consume: (FileManifestPage, Data) throws -> Void = { _, _ in }) throws -> [FileManifestPage] {
        var pages=[FileManifestPage]()
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys, .withoutEscapingSlashes]
        for offset in stride(from: 0, to: entries.count, by: pageSize) {
            try checkpoint()
            let end=min(offset + pageSize, entries.count)
            let data=try encoder.encode(FileManifestEntries(entries: entries[offset..<end]))
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

    static func copy(_ source: FileManifestSource, prefix: String, store: any RecordStore,
                     consume: (FileManifestPage, Data) throws -> Void) throws -> [FileManifestPage] {
        let count=source.entries.count
        guard (1...1_000_001).contains(count), source.pages.count == (count + pageSize - 1) / pageSize else { throw corrupt() }
        var pages=[FileManifestPage]()
        for (index, page) in source.pages.enumerated() {
            guard page.count == min(pageSize, count - index * pageSize),
                  page.id == source.prefix + "_p" + String(index) + "_" + page.digest.dropFirst(7).prefix(24),
                  let data=try store.read(source.collection, id: page.id), Digest.sha256(data) == page.digest else { throw corrupt() }
            let copy=FileManifestPage(id: prefix + "_p" + String(index) + "_" + page.digest.dropFirst(7).prefix(24), count: page.count, digest: page.digest)
            try consume(copy, data)
            pages.append(copy)
        }
        return pages
    }

    static func corrupt() -> ShouError { ShouError("store_corrupt", "File manifest pages are missing or inconsistent.") }
}

/// Preserve the existing page bytes without converting the same fixed keys for every entry.
/// Other records and legacy decoding continue to use Codec.
private struct FileManifestEntries: Encodable {
    let entries: ArraySlice<FileEntry>
    func encode(to encoder: any Encoder) throws {
        var container=encoder.unkeyedContainer()
        for entry in entries { try container.encode(FileManifestEntry(entry: entry)) }
    }
}

private struct FileManifestEntry: Encodable {
    let entry: FileEntry
    enum CodingKeys: String, CodingKey {
        case path, kind, device, inode, mode, owner, links
        case logicalBytes="logical_bytes", allocatedBytes="allocated_bytes"
        case modifiedNanoseconds="modified_nanoseconds", changedNanoseconds="changed_nanoseconds"
        case contentDigest="content_digest"
    }
    func encode(to encoder: any Encoder) throws {
        var c=encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entry.path, forKey: .path); try c.encode(entry.kind, forKey: .kind)
        try c.encode(entry.device, forKey: .device); try c.encode(entry.inode, forKey: .inode)
        try c.encode(entry.logicalBytes, forKey: .logicalBytes); try c.encode(entry.allocatedBytes, forKey: .allocatedBytes)
        try c.encode(entry.modifiedNanoseconds, forKey: .modifiedNanoseconds); try c.encode(entry.changedNanoseconds, forKey: .changedNanoseconds)
        try c.encode(entry.mode, forKey: .mode); try c.encode(entry.owner, forKey: .owner); try c.encode(entry.links, forKey: .links)
        try c.encodeIfPresent(entry.contentDigest, forKey: .contentDigest)
    }
}
