import Foundation

public struct StorageBrowsePage: Codable, Sendable {
    public let directory: StorageDirectoryPage
    public let removalReasons: [String: String]
}

public struct StorageSelectionSummary: Codable, Sendable {
    public let paths: [String]
    public let allocatedBytes: Int64
}

extension ShouEngine {
    /// Read-only presentation of the published scan and current protection rules.
    /// Execution still builds and validates a new complete removal manifest.
    public func storageBrowsePage(scanId: String, path: String = ".", offset: Int = 0) throws -> StorageBrowsePage {
        let page=try storageDirectoryPage(scanId: scanId, path: path, offset: offset, limit: 200)
        let scan=try storageScan(scanId)
        var reasons=[String: String]()
        for item in page.children {
            try Task.checkCancellation()
            if let reason=storageRemovalReason(scan: scan, path: item.node.path) { reasons[item.node.path]=reason }
        }
        return StorageBrowsePage(directory: page, removalReasons: reasons)
    }

    /// Reuse the same literal, disjoint selection semantics as the macOS client.
    /// Only ancestry needed to uncheck a covered child is expanded from disk.
    public func storageSelection(scanId: String, paths: [String], targets: [String], selected: Bool) throws -> StorageSelectionSummary {
        guard paths.count <= 5000, targets.count <= 5000,
              Set(paths).count == paths.count, Set(targets).count == targets.count,
              (paths + targets).allSatisfy(StorageRemovalPolicy.validRelative) else {
            throw ShouError("invalid_argument", "Select at most 5,000 exact, distinct analysis paths.")
        }
        let scan=try storageScan(scanId), catalog=try catalog(for: scan), existing=Set(paths)
        let inline=catalog == nil ? StorageIndex(tree: scan.tree) : nil
        func node(_ path: String) throws -> StorageNode? {
            if let catalog { return try catalog.entry(at: path)?.node }
            return inline?.nodes[path]
        }
        for path in paths + targets {
            try Task.checkCancellation()
            guard try node(path) != nil else { throw ShouError("invalid_argument", "Item is absent from this analysis.") }
        }
        var nodes=[String: StorageNode]()
        if !selected {
            var ancestry=Set<String>()
            for target in targets where StorageSelection.contains(target, in: existing) {
                var parent=StorageIndex.parent(target)
                while parent != "." {
                    if StorageSelection.contains(parent, in: existing) { ancestry.insert(parent) }
                    parent=StorageIndex.parent(parent)
                }
            }
            for parent in ancestry {
                var offset=0
                repeat {
                    try Task.checkCancellation()
                    let page: StorageDirectoryPage
                    if let catalog { page=try catalog.directoryPage(path: parent, offset: offset, limit: 200) }
                    else { page=try storageDirectoryPage(scanId: scanId, path: parent, offset: offset, limit: 200) }
                    // The public selection and removal contracts allow 5,000
                    // roots. Reject expansion before publishing a partial set.
                    guard page.totalCount <= 5001, nodes.count + page.children.count <= 50_000 else {
                        throw ShouError("resource_limit", "This folder expands beyond the selection limit. Clear it and select a smaller scope.")
                    }
                    for child in page.children { nodes[child.node.path]=child.node }
                    guard let next=page.nextOffset else { break }
                    offset=next
                } while true
            }
        }
        let result=StorageSelection.setting(Set(targets), selected: selected, in: StorageSelection.normalized(existing), index: StorageIndex(nodes: Array(nodes.values)))
        guard result.count <= 5000 else { throw ShouError("resource_limit", "Select at most 5,000 distinct analysis paths.") }
        var bytes: Int64=0
        for path in result {
            try Task.checkCancellation()
            guard let item=try node(path) else { throw ShouError("invalid_argument", "Item is absent from this analysis.") }
            if let reason=storageRemovalReason(scan: scan, path: path) { throw ShouError("permission_denied", reason) }
            bytes += item.allocatedBytes
        }
        return StorageSelectionSummary(paths: result.sorted(), allocatedBytes: bytes)
    }
}
