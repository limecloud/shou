import Foundation

public struct StorageNode: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: String
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var newestModifiedNanoseconds: Int64
    public var isComplete: Bool? = nil
    public var name: String { path == "." ? path : String(path.split(separator: "/").last ?? "") }
    public init(path: String, kind: String, logicalBytes: Int64, allocatedBytes: Int64, fileCount: Int, newestModifiedNanoseconds: Int64) {
        self.path=path; self.kind=kind; self.logicalBytes=logicalBytes; self.allocatedBytes=allocatedBytes
        self.fileCount=fileCount; self.newestModifiedNanoseconds=newestModifiedNanoseconds
    }
}

/// A single accounting tree shared by the desktop and CLI. Hard links are charged
/// to the first lexical path, so sibling totals never count the same object twice.
public struct StorageIndex: Sendable {
    public let nodes: [String: StorageNode]
    private let childPaths: [String: [String]]
    /// Catalog nodes already contain subtree totals. Never aggregate them again.
    public init(nodes: [StorageNode]) {
        self.nodes=Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        self.childPaths=Dictionary(grouping: nodes.filter { $0.path != "." }.map(\.path), by: Self.parent)
    }
    public init(tree: TreeSnapshot) {
        self.init(entries: tree.entries)
        guard !tree.complete else { return }
        var updated=nodes
        let complete=Set(tree.completedPaths ?? [])
        for path in nodes.keys where nodes[path]?.kind == "directory" {
            var current=path, measured=complete.contains(".")
            while !measured {
                measured=complete.contains(current)
                if current == "." { break }
                current=Self.parent(current)
            }
            updated[path]?.isComplete=measured
        }
        self=StorageIndex(nodes: Array(updated.values))
    }
    public init(entries: [FileEntry]) {
        self.init(entries: entries, checkpoint: {})
    }
    public init(entries: [FileEntry], checkpoint: () throws -> Void) rethrows {
        try checkpoint()
        var nodes: [String: StorageNode]=[:], children: [String: [String]]=[:]
        var charged=Set<String>()
        var sorted=true
        for index in entries.indices.dropFirst() {
            if index % 4096 == 0 { try checkpoint() }
            if entries[index - 1].path > entries[index].path { sorted=false; break }
        }
        let ordered=sorted ? entries : entries.sorted(by: { $0.path < $1.path })
        for (index, entry) in ordered.enumerated() {
            if index % 4096 == 0 { try checkpoint() }
            let unique=entry.kind != "symlink" && charged.insert(entry.objectIdentityKey).inserted
            nodes[entry.path]=StorageNode(path: entry.path, kind: entry.kind,
                logicalBytes: unique ? max(0, entry.logicalBytes) : 0,
                allocatedBytes: unique ? max(0, entry.allocatedBytes) : 0,
                fileCount: entry.kind == "file" ? 1 : 0, newestModifiedNanoseconds: entry.modifiedNanoseconds)
            if entry.path != "." { children[Self.parent(entry.path), default: []].append(entry.path) }
        }
        // A parent path sorts before all of its descendants. Reverse lexical
        // order gives postorder without splitting paths in a second sort.
        for (index, entry) in ordered.reversed().enumerated() where entry.path != "." {
            if index % 4096 == 0 { try checkpoint() }
            let path=entry.path
            guard let child=nodes[path] else { continue }
            let parent=Self.parent(path)
            nodes[parent]?.logicalBytes += child.logicalBytes
            nodes[parent]?.allocatedBytes += child.allocatedBytes
            nodes[parent]?.fileCount += child.fileCount
            if let current=nodes[parent]?.newestModifiedNanoseconds {
                nodes[parent]?.newestModifiedNanoseconds=max(current, child.newestModifiedNanoseconds)
            }
        }
        try checkpoint()
        self.nodes=nodes; self.childPaths=children
    }
    public static func parent(_ path: String) -> String {
        guard let slash=path.lastIndex(of: "/") else { return "." }
        return String(path[..<slash])
    }
    public func children(of path: String = ".") -> [StorageNode] {
        (childPaths[path] ?? []).compactMap { nodes[$0] }.sorted {
            $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
        }
    }
}

/// Filename-extension groups only; no file contents are opened or inferred.
public enum StorageFileType: String, Codable, CaseIterable, Hashable, Sendable {
    case all, video, audio, image, archive, document
    case aiModel = "ai-model"
    case other
    private static let extensions: [Self: Set<String>] = [
        .video: ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "webm", "flv", "mpeg", "mpg", "3gp", "ts"],
        .audio: ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "alac"],
        .image: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "ico", "avif", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2"],
        .archive: ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "tgz"],
        .document: ["pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "csv", "epub", "pages", "numbers", "key"],
        .aiModel: ["safetensors", "gguf", "ggml", "onnx", "ort", "tflite", "mlmodel", "keras", "pt", "pth", "ckpt"]
    ]
    public static func classify(name: String) -> Self {
        let start=name.lastIndex(of: "/").map { name.index(after: $0) } ?? name.startIndex
        let basename=name[start...]
        guard let dot=basename.lastIndex(of: "."), dot != basename.startIndex else { return .other }
        let suffix=basename[basename.index(after: dot)...].lowercased()
        return extensions.first(where: { $0.value.contains(suffix) })?.key ?? .other
    }
}

public struct StorageLargeFilePage: Codable, Sendable {
    public let items: [StorageCatalogItem]
    public let totalCount: Int
    public let totalAllocatedBytes: Int64
    public let nextCursor: String?
}

struct StorageLargeFileQuery {
    private struct Filter: Codable { let scanId: String; let minimumBytes: Int64; let type: StorageFileType }
    struct Cursor: Codable {
        let version: Int
        let filterId: String
        let allocatedBytes: Int64
        let path: String
    }
    let minimumBytes: Int64
    let type: StorageFileType
    let limit: Int
    let after: Cursor?
    private let filterId: String
    init(scanId: String, minimumBytes: Int64, type: StorageFileType, limit: Int, cursor: String?) throws {
        guard minimumBytes >= 0, (1...500).contains(limit) else {
            throw ShouError("invalid_argument", "Minimum bytes must be nonnegative and limit must be between 1 and 500.")
        }
        self.minimumBytes=minimumBytes; self.type=type; self.limit=limit
        filterId=try Digest.of(Filter(scanId: scanId, minimumBytes: minimumBytes, type: type))
        if let cursor {
            guard cursor.utf8.count <= 32_768, let data=Data(base64Encoded: cursor),
                  let value=try? Codec.decode(Cursor.self, from: data), value.version == 1, value.filterId == filterId,
                  value.allocatedBytes >= minimumBytes, StorageRemovalPolicy.validRelative(value.path) else {
                throw ShouError("invalid_argument", "Cursor does not belong to this scan and large-file filter.")
            }
            after=value
        } else { after=nil }
    }
    static func checkpoint() throws {
        if Task.isCancelled { throw ShouError("cancelled", "Large-file loading stopped.") }
    }
    static func precedes(_ left: StorageCatalogItem, _ right: StorageCatalogItem) -> Bool {
        left.node.allocatedBytes != right.node.allocatedBytes ? left.node.allocatedBytes > right.node.allocatedBytes :
            left.entry.path.utf8.lexicographicallyPrecedes(right.entry.path.utf8)
    }
    func followsCursor(_ item: StorageCatalogItem) -> Bool {
        guard let after else { return true }
        return item.node.allocatedBytes < after.allocatedBytes || (item.node.allocatedBytes == after.allocatedBytes &&
            after.path.utf8.lexicographicallyPrecedes(item.entry.path.utf8))
    }
    func page(_ ordered: [StorageCatalogItem], totalCount: Int, totalAllocatedBytes: Int64) throws -> StorageLargeFilePage {
        let items=Array(ordered.prefix(limit))
        var next: String?
        if ordered.count > limit, let last=items.last {
            next=try Codec.encode(Cursor(version: 1, filterId: filterId, allocatedBytes: last.node.allocatedBytes, path: last.entry.path)).base64EncodedString()
        }
        return StorageLargeFilePage(items: items, totalCount: totalCount, totalAllocatedBytes: totalAllocatedBytes, nextCursor: next)
    }
    func legacyPage(_ entries: [FileEntry]) throws -> StorageLargeFilePage {
        // Legacy manifests already reside in memory. Only multiply-linked files
        // need extra identity state; result retention stays at limit + one.
        var firstLinks=[String: String]()
        for (index, entry) in entries.enumerated() {
            if index % 4096 == 0 { try Self.checkpoint() }
            guard entry.kind == "file", entry.links > 1 else { continue }
            let object=entry.objectIdentityKey
            if firstLinks[object].map({ entry.path < $0 }) ?? true { firstLinks[object]=entry.path }
        }
        var heap=[StorageCatalogItem](), totalCount=0, totalAllocatedBytes: Int64=0
        for (index, entry) in entries.enumerated() {
            if index % 4096 == 0 { try Self.checkpoint() }
            guard entry.kind == "file" else { continue }
            let charged=entry.links <= 1 || firstLinks[entry.objectIdentityKey]?.utf8.elementsEqual(entry.path.utf8) == true
            let allocated=charged ? max(0, entry.allocatedBytes) : 0
            guard allocated >= minimumBytes, type == .all || StorageFileType.classify(name: entry.path) == type else { continue }
            totalCount += 1
            let (sum, overflow)=totalAllocatedBytes.addingReportingOverflow(allocated)
            guard !overflow else { throw ShouError("store_corrupt", "Large-file allocation total exceeds supported limits.") }
            totalAllocatedBytes=sum
            var node=StorageNode(path: entry.path, kind: "file", logicalBytes: charged ? max(0, entry.logicalBytes) : 0,
                allocatedBytes: allocated, fileCount: 1, newestModifiedNanoseconds: entry.modifiedNanoseconds)
            node.isComplete=true
            let item=StorageCatalogItem(entry: entry, node: node)
            guard followsCursor(item) else { continue }
            if heap.count < limit + 1 {
                heap.append(item)
                var child=heap.count - 1
                while child > 0 {
                    let parent=(child - 1) / 2
                    guard Self.precedes(heap[parent], heap[child]) else { break }
                    heap.swapAt(parent, child); child=parent
                }
            } else if Self.precedes(item, heap[0]) {
                heap[0]=item
                var parent=0
                while parent * 2 + 1 < heap.count {
                    var child=parent * 2 + 1
                    if child + 1 < heap.count, Self.precedes(heap[child], heap[child + 1]) { child += 1 }
                    guard Self.precedes(heap[parent], heap[child]) else { break }
                    heap.swapAt(parent, child); parent=child
                }
            }
        }
        try Self.checkpoint()
        return try page(heap.sorted(by: Self.precedes), totalCount: totalCount, totalAllocatedBytes: totalAllocatedBytes)
    }
}

extension ShouEngine {
    /// A read of saved evidence. Threshold and type changes never rescan files.
    public func storageLargeFiles(scanId: String, minimumBytes: Int64 = 50 * 1024 * 1024,
                                  type: StorageFileType = .all, limit: Int = 100, cursor: String? = nil) throws -> StorageLargeFilePage {
        let query=try StorageLargeFileQuery(scanId: scanId, minimumBytes: minimumBytes, type: type, limit: limit, cursor: cursor)
        try StorageLargeFileQuery.checkpoint()
        let scan=try storageScan(scanId)
        if let catalog=try catalog(for: scan) { return try catalog.largeFiles(query: query) }
        return try query.legacyPage(scan.tree.entries)
    }
}

public struct CleanupCategory: Codable, Sendable, Identifiable {
    public let id: String
    public var candidates: [Candidate]
    public var allocatedBytesEstimate: Int64 { candidates.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    public var eligibleBytesEstimate: Int64 { candidates.filter(\.eligible).reduce(0) { $0 + $1.allocatedBytesEstimate } }
}

public enum CleanupOverview {
    /// Present outermost matched directories, avoiding parent/child double counting.
    public static func candidates(_ candidates: [Candidate]) -> [Candidate] {
        var kept=Set<String>()
        let ordered=candidates.filter { !$0.ruleIds.isEmpty }.sorted {
            let a=$0.relativePath.split(separator: "/").count, b=$1.relativePath.split(separator: "/").count
            return a == b ? $0.relativePath < $1.relativePath : a < b
        }
        return ordered.filter { candidate in
            var parent=StorageIndex.parent(candidate.relativePath)
            while parent != "." {
                if kept.contains(parent) { return false }
                parent=StorageIndex.parent(parent)
            }
            kept.insert(candidate.relativePath); return true
        }.sorted { $0.allocatedBytesEstimate > $1.allocatedBytesEstimate }
    }
    public static func categories(_ candidates: [Candidate]) -> [CleanupCategory] {
        let grouped=Dictionary(grouping: self.candidates(candidates), by: { BuiltinCatalog.category(ruleIds: $0.ruleIds) })
        return grouped.map { CleanupCategory(id: $0.key, candidates: $0.value) }.sorted {
            $0.allocatedBytesEstimate == $1.allocatedBytesEstimate ? $0.id < $1.id : $0.allocatedBytesEstimate > $1.allocatedBytesEstimate
        }
    }
}
