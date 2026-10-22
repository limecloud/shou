#if os(Windows)
import Foundation
import ShouCore
import CShouWindows

extension NativeFileSystem {
    public var supportsStorageCatalog: Bool { true }

    /// Measurement has no deletion-manifest entry cap. Directory cursors stream
    /// names into SQLite and retain the complete Windows identity for later reads.
    public func measureStorage(_ path: String, catalog: URL, cancelled: @Sendable () -> Bool,
                               progress: @Sendable (ScanProgress) -> Void) throws -> StorageMeasurement {
        func checkCancellation() throws {
            if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Space analysis stopped.") }
        }
        try checkCancellation()
        let path=try normalizedPath(path), identity=try analysisRootIdentity(path)
        let rootPrefix=path.hasSuffix("/") ? path : path + "/"
        let database=try StorageCatalog(url: catalog, create: true, prepareNewFile: {
            try checkCancellation()
            try WindowsNative.check(shou_win_create_private_catalog(catalog.path), path: catalog.path)
        })
        let first=try database.append(identity, name: ".", parentID: 0)
        let deadline=ContinuousClock.now.advanced(by: .seconds(3600))
        var count=1, issueCount=0, issues=[String](), issueBytes=0
        var lastReport=ContinuousClock.now
        func issue(_ value: String) {
            issueCount += 1
            if issues.count < 256, issueBytes + value.utf8.count <= 262_144 {
                issues.append(value); issueBytes += value.utf8.count
            }
        }
        func visit(_ entry: FileEntry, _ initial: StorageNode, _ id: Int64, _ depth: Int) throws -> StorageNode {
            try checkCancellation()
            var total=initial
            let initialIssues=issueCount
            guard depth <= 128, ContinuousClock.now < deadline else {
                issue("resource_limit: " + entry.path)
                total.isComplete=false; try database.setTotals(total, id: id); return total
            }
            let absolute=entry.path == "." ? path : rootPrefix + entry.path
            var cursor: OpaquePointer?, expected=try WindowsNative.savedInfo(entry)
            let opened=shou_win_directory_open(absolute, &expected, &cursor)
            guard opened == 0, let cursor else {
                issue("unreadable_directory: " + entry.path + " (" + String(opened) + ")")
                total.isComplete=false; try database.setTotals(total, id: id); return total
            }
            defer { shou_win_directory_close(cursor) }
            while true {
                try checkCancellation()
                guard ContinuousClock.now < deadline else { issue("resource_limit: " + entry.path); break }
                var pointer: UnsafeMutablePointer<CChar>?
                let code=shou_win_directory_next(cursor, &pointer)
                defer { shou_win_free(pointer) }
                if code == 18 { break } // ERROR_NO_MORE_FILES
                guard code == 0, let pointer, let name=String(validatingCString: pointer),
                      !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
                    issue("unreadable_directory_entry: " + entry.path + " (" + String(code) + ")"); break
                }
                let relative=entry.path == "." ? name : entry.path + "/" + name
                let item: FileEntry
                do {
                    item=WindowsNative.entry(try WindowsNative.metadata(absolute + (absolute.hasSuffix("/") ? "" : "/") + name), path: relative)
                } catch {
                    issue("unreadable: " + relative); continue
                }
                guard item.device == identity.device else { issue("cross_filesystem: " + relative); continue }
                let row=try database.append(item, name: name, parentID: id)
                count += 1
                total.logicalBytes += row.node.logicalBytes; total.allocatedBytes += row.node.allocatedBytes
                total.fileCount += row.node.fileCount
                total.newestModifiedNanoseconds=max(total.newestModifiedNanoseconds, row.node.newestModifiedNanoseconds)
                if count % 128 == 0, lastReport.duration(to: .now) >= .milliseconds(250) {
                    progress(ScanProgress(stage: "scanning", entryCount: count, currentPath: rootPrefix + relative)); lastReport = .now
                }
            }
            // Index immediate siblings before descending so a large early project
            // does not erase the remaining directories from partial coverage.
            try database.forEachChildDirectory(parentID: id) { childID, child in
                let node=child.node
                let measured=try visit(child.entry, node, childID, depth + 1)
                total.logicalBytes += measured.logicalBytes - node.logicalBytes
                total.allocatedBytes += measured.allocatedBytes - node.allocatedBytes
                total.fileCount += measured.fileCount - node.fileCount
                total.newestModifiedNanoseconds=max(total.newestModifiedNanoseconds, measured.newestModifiedNanoseconds)
            }
            if shou_win_directory_verify(cursor, &expected) != 0 { issue("changed_directory: " + entry.path) }
            total.isComplete=initialIssues == issueCount
            try database.setTotals(total, id: id)
            return total
        }
        progress(ScanProgress(stage: "scanning", entryCount: count, currentPath: path))
        let total=try visit(identity, first.node, first.id, 0)
        try checkCancellation()
        progress(ScanProgress(stage: "analysis", entryCount: count, currentPath: path))
        try database.seal(progress: { completed, steps in
            progress(ScanProgress(stage: "analysis", entryCount: count, currentPath: path,
                completedUnitCount: completed, totalUnitCount: steps))
        }, checkpoint: checkCancellation)
        if issueCount > issues.count { issues.append("additional_coverage_issues: " + String(issueCount - issues.count)) }
        return StorageMeasurement(tree: TreeSnapshot(entries: [identity], complete: total.isComplete == true,
            issues: issues, caseSensitive: false, completedPaths: total.isComplete == true ? ["."] : [],
            discoveryComplete: total.isComplete == true), entryCount: count)
    }
}
#endif
