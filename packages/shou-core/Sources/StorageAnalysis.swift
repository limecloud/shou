import Foundation

public struct StorageNode: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: String
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var newestModifiedNanoseconds: Int64
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
            let unique=entry.kind != "symlink" && charged.insert("\(entry.device):\(entry.inode)").inserted
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
