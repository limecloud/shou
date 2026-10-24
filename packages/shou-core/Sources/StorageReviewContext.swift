import Foundation

/// Request-local evidence, never a reusable authorization cache. Callers hold
/// the mutation lease when using it for plan preparation or execution.
struct StorageReviewContext {
    private struct Exclusion {
        let prefix: String
        let patterns: [PathPattern.Compiled]
    }
    let owner: UInt32
    let catalog: StorageCatalog?
    private let inline: [String: FileEntry]
    private let root: String
    private let caseSensitive: Bool
    private let exclusions: [Exclusion]
    private struct Excluded: Error {}

    init(scan: StorageScan, catalog: StorageCatalog?, configuration: Configuration, owner: UInt32) {
        self.catalog=catalog; self.owner=owner
        inline=catalog == nil ? Dictionary(scan.tree.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        root=scan.rootPath == "/System/Volumes/Data" ? "/" : StorageRemovalPolicy.canonical(scan.rootPath)
        caseSensitive=scan.tree.caseSensitive
        exclusions=configuration.workspaces.compactMap { workspace in
            let patterns=(configuration.globalExclusions ?? []) + workspace.exclusions
            guard !patterns.isEmpty else { return nil }
            return Exclusion(prefix: StorageRemovalPolicy.canonical(workspace.path) + "/",
                patterns: patterns.map { PathPattern.Compiled($0, caseSensitive: scan.tree.caseSensitive) })
        }
    }

    func entry(_ path: String) throws -> FileEntry? {
        if let catalog { return try catalog.entry(at: path)?.entry }
        return inline[path]
    }

    func excludes(_ path: String) -> Bool {
        guard !exclusions.isEmpty else { return false }
        let full=StorageRemovalPolicy.absolute(root: root, relative: path)
        for exclusion in exclusions where full.hasPrefix(exclusion.prefix) {
            let relative=String(full.dropFirst(exclusion.prefix.count))
            let parts=(caseSensitive ? relative : relative.lowercased()).split(separator: "/").map(String.init)
            if exclusion.patterns.contains(where: { $0.matches(parts) }) { return true }
        }
        return false
    }

    func containsExclusion(path: String, manifest: [FileEntry]) -> Bool {
        guard !exclusions.isEmpty else { return false }
        return manifest.contains { excludes($0.path == "." ? path : path + "/" + $0.path) }
    }

    func containsExclusion(under path: String) throws -> Bool {
        guard !exclusions.isEmpty else { return false }
        let full=StorageRemovalPolicy.absolute(root: root, relative: path)
        guard exclusions.contains(where: { full.hasPrefix($0.prefix) || $0.prefix.hasPrefix(full + "/") }) else { return false }
        if let catalog {
            do {
                try catalog.forEachEntry(under: path) { if excludes($0.path) { throw Excluded() } }
                return false
            } catch is Excluded { return true }
        }
        return inline.values.contains { ($0.path == path || $0.path.hasPrefix(path + "/")) && excludes($0.path) }
    }
}
