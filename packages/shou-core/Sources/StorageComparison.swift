import Foundation

private struct ComparisonScanHeader: Decodable {
    struct Tree: Decodable {
        let complete: Bool
        let issues: [String]
        let caseSensitive: Bool
    }
    let id: String
    let rootPath: String
    let identity: FileEntry
    let createdAt: Date
    let tree: Tree
    let catalogId: String?
    let measuredEntryCount: Int?
    var scan: StorageScan {
        StorageScan(id: id, rootPath: rootPath, identity: identity, createdAt: createdAt,
            tree: TreeSnapshot(entries: [identity], complete: tree.complete, issues: tree.issues, caseSensitive: tree.caseSensitive),
            catalogId: catalogId, measuredEntryCount: measuredEntryCount)
    }
}

public struct StorageAnalysisReference: Codable, Sendable, Identifiable {
    public let id: String
    public let rootPath: String
    public let createdAt: Date
    public let status: String
    public let entryCount: Int
    init(_ scan: StorageScan) {
        id=scan.id; rootPath=scan.rootPath; createdAt=scan.createdAt; status=scan.status; entryCount=scan.entryCount
    }
}

public struct StorageComparisonHistory: Codable, Sendable {
    public let current: StorageAnalysisReference
    public let candidates: [StorageAnalysisReference]
    public let examinedRecordCount: Int
    public let status: String
    public let issues: [String]
}

public struct StorageChange: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: String
    /// Observations of absent/replaced objects never claim a creation/deletion.
    public let state: String
    public let beforeBytes: Int64?
    public let afterBytes: Int64?
    public let deltaBytes: Int64?
    public let beforeComplete: Bool?
    public let afterComplete: Bool?
    fileprivate var magnitude: Int64 { deltaBytes.map { $0 < 0 ? -$0 : $0 } ?? max(beforeBytes ?? 0, afterBytes ?? 0) }
}

public struct StorageComparison: Codable, Sendable {
    public let baseline: StorageAnalysisReference
    public let current: StorageAnalysisReference
    public let path: String
    public let metric: String
    public let status: String
    public let beforeBytes: Int64
    public let afterBytes: Int64
    public let deltaBytes: Int64?
    public let examinedEntryCount: Int
    public let changedEntryCount: Int
    public let changes: [StorageChange]
    public let issues: [String]
}

private final class ComparisonChildren {
    let catalog: StorageCatalog
    let path: String
    private var after=""
    private var rows=[StorageCatalogItem]()
    private var offset=0
    private var finished=false
    init(catalog: StorageCatalog, path: String) { self.catalog=catalog; self.path=path }
    func peek() throws -> StorageCatalogItem? {
        if offset == rows.count && !finished {
            rows=try catalog.namedChildren(of: path, after: after)
            offset=0; finished=rows.count < 256
            if let last=rows.last { after=last.node.name }
        }
        return offset < rows.count ? rows[offset] : nil
    }
    func advance() { offset += 1 }
}

extension ShouEngine {
    /// Only small disk-index metadata is eligible; paged legacy manifests are
    /// deliberately not expanded to populate a history picker or comparison.
    private func comparisonScan(_ id: String, expectedRecord: StoredRecord? = nil) throws -> StorageScan {
        if Task.isCancelled { throw ShouError("cancelled", "Analysis comparison stopped.") }
        func unavailable(_ reason: String) -> ShouError {
            ShouError("comparison_unavailable", "This analysis cannot be compared. Run two new space analyses of the same folder.", details: ["reason": reason])
        }
        guard let metadata=try expectedRecord ?? store.recordMetadata("storage-scans", id: id), (1...4_194_304).contains(metadata.byteCount),
              let data=try store.read("storage-scans", id: id), data.count == metadata.byteCount,
              try store.recordMetadata("storage-scans", id: id) == metadata else { throw unavailable("metadata_unavailable") }
        guard let header=try? Codec.decode(ComparisonScanHeader.self, from: data), header.id == id,
              header.identity.path == ".", header.identity.kind == "directory" else { throw unavailable("invalid_record") }
        guard header.catalogId != nil else { throw unavailable("legacy_format") }
        guard header.catalogId == id else { throw unavailable("invalid_record") }
        return header.scan
    }

    public func storageComparisonHistory(scanId: String) throws -> StorageComparisonHistory {
        let currentRecord=try store.recordMetadata("storage-scans", id: scanId)
        let current=try comparisonScan(scanId, expectedRecord: currentRecord)
        _ = try catalog(for: current)
        let listing=try store.boundedRecords("storage-scans", limit: 127)
        let records=listing.records.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt
        }
        var candidates=[StorageAnalysisReference](), examined=0, bytes: Int64=currentRecord?.byteCount ?? 4_194_304, issues=[String]()
        for record in records where record.id != scanId {
            if Task.isCancelled { throw ShouError("cancelled", "Analysis comparison stopped.") }
            examined += 1
            guard record.byteCount > 0, record.byteCount <= 4_194_304, bytes + record.byteCount <= 8_388_608 else {
                if !issues.contains("history_read_limit") { issues.append("history_read_limit") }; continue
            }
            bytes += record.byteCount
            do {
                let scan=try comparisonScan(record.id, expectedRecord: record)
                guard scan.createdAt < current.createdAt,
                      StorageRemovalPolicy.canonical(scan.rootPath) == StorageRemovalPolicy.canonical(current.rootPath),
                      scan.identity.sameObject(as: current.identity), scan.identity.hasSameOwner(as: current.identity) else { continue }
                guard try store.recordMetadata("storage-catalogs", id: scan.id) != nil else {
                    if !issues.contains("history_index_cleared") { issues.append("history_index_cleared") }; continue
                }
                candidates.append(StorageAnalysisReference(scan))
            } catch let error as ShouError where error.code == "cancelled" { throw error }
            catch let error as ShouError where error.details["reason"] == "legacy_format" {
                if !issues.contains("history_legacy_format") { issues.append("history_legacy_format") }
            }
            catch { if !issues.contains("history_record_unavailable") { issues.append("history_record_unavailable") } }
        }
        if listing.truncated { issues.append("history_record_limit") }
        return StorageComparisonHistory(current: StorageAnalysisReference(current),
            candidates: candidates.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt },
            examinedRecordCount: examined, status: issues.isEmpty ? "complete" : "partial", issues: issues)
    }

    /// Read-only, bounded merge of one directory's immediate children. Ranking
    /// covers the examined scope only; snapshots never confer removal authority.
    public func compareStorage(baselineId: String, scanId: String, path: String = ".", limit: Int = 50,
                               maxEntries: Int = 100_000, maxSeconds: Double = 10) throws -> StorageComparison {
        guard baselineId != scanId, (1...100).contains(limit), (1...100_000).contains(maxEntries),
              maxSeconds.isFinite, (1...30).contains(maxSeconds), path == "." || StorageRemovalPolicy.validRelative(path) else {
            throw ShouError("invalid_argument", "Use distinct analyses, an exact relative directory, limit 1–100, max-entries 1–100000 and max-seconds 1–30.")
        }
        let clock=ContinuousClock(), started=clock.now
        let before=try comparisonScan(baselineId), after=try comparisonScan(scanId)
        guard before.createdAt < after.createdAt,
              before.tree.caseSensitive == after.tree.caseSensitive,
              StorageRemovalPolicy.canonical(before.rootPath) == StorageRemovalPolicy.canonical(after.rootPath),
              before.identity.sameObject(as: after.identity), before.identity.hasSameOwner(as: after.identity),
              let oldCatalog=try catalog(for: before), let newCatalog=try catalog(for: after),
              let old=try oldCatalog.entry(at: path), let new=try newCatalog.entry(at: path),
              old.entry.kind == "directory", old.entry.sameObject(as: new.entry), old.entry.hasSameOwner(as: new.entry) else {
            throw ShouError("comparison_unavailable", "Choose an earlier analysis of the same directory identity. Replaced folders cannot be compared.")
        }
        let covered=before.tree.complete && after.tree.complete && old.node.isComplete == true && new.node.isComplete == true
        var issues=[String](), changes=[StorageChange](), examined=0, changed=0
        if !covered { issues.append("incomplete_coverage") }
        let oldRows=ComparisonChildren(catalog: oldCatalog, path: path), newRows=ComparisonChildren(catalog: newCatalog, path: path)
        func comesFirst(_ lhs: StorageChange, _ rhs: StorageChange) -> Bool {
            lhs.magnitude == rhs.magnitude ? lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8) : lhs.magnitude > rhs.magnitude
        }
        while true {
            if Task.isCancelled { throw ShouError("cancelled", "Analysis comparison stopped.") }
            let a=try oldRows.peek(), b=try newRows.peek()
            if a == nil && b == nil { break }
            if examined >= maxEntries || started.duration(to: clock.now) >= .seconds(maxSeconds) {
                issues.append("comparison_budget_reached"); break
            }
            let left: StorageCatalogItem?, right: StorageCatalogItem?
            if let a, let b, a.node.name.utf8.elementsEqual(b.node.name.utf8) {
                left=a; right=b; oldRows.advance(); newRows.advance()
            } else if let a, b == nil || a.node.name.utf8.lexicographicallyPrecedes(b!.node.name.utf8) {
                left=a; right=nil; oldRows.advance()
            } else { left=nil; right=b; newRows.advance() }
            examined += 1
            let state: String, delta: Int64?
            if let left, let right {
                if !left.entry.sameObject(as: right.entry) || !left.entry.hasSameOwner(as: right.entry) { state="replaced"; delta=nil }
                else if !covered || left.node.isComplete != true || right.node.isComplete != true { state="not_comparable"; delta=nil }
                else {
                    let difference=right.node.allocatedBytes - left.node.allocatedBytes
                    if difference == 0 { continue }
                    state=difference > 0 ? "increased" : "decreased"; delta=difference
                }
            } else { state=left == nil ? "only_current" : "only_baseline"; delta=nil }
            let row=StorageChange(path: (right ?? left!).node.path, kind: (right ?? left!).entry.kind, state: state,
                beforeBytes: left?.node.allocatedBytes, afterBytes: right?.node.allocatedBytes, deltaBytes: delta,
                beforeComplete: left?.node.isComplete, afterComplete: right?.node.isComplete)
            changed += 1
            if changes.count < limit || comesFirst(row, changes.last!) {
                changes.append(row); changes.sort(by: comesFirst)
                if changes.count > limit { changes.removeLast() }
            }
        }
        return StorageComparison(baseline: StorageAnalysisReference(before), current: StorageAnalysisReference(after), path: path,
            metric: "allocated_bytes_estimate", status: issues.isEmpty ? "complete" : "partial",
            beforeBytes: old.node.allocatedBytes, afterBytes: new.node.allocatedBytes,
            deltaBytes: covered ? new.node.allocatedBytes - old.node.allocatedBytes : nil,
            examinedEntryCount: examined, changedEntryCount: changed, changes: changes, issues: issues)
    }
}
