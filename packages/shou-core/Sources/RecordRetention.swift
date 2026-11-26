import Foundation

public struct StoredRecord: Codable, Sendable, Equatable {
    public let collection: String
    public let id: String
    public let byteCount: Int64
    public let modifiedAt: Date
    public let revision: String
    public init(collection: String, id: String, byteCount: Int64, modifiedAt: Date, revision: String) {
        self.collection=collection; self.id=id; self.byteCount=byteCount; self.modifiedAt=modifiedAt; self.revision=revision
    }
}

public struct RecordRetentionPolicy: Codable, Sendable {
    public var maxAgeSeconds: Double
    public var maxBytes: Int64
    public var graceSeconds: Double
    public var keepLatestScans: Bool
    public init(maxAgeSeconds: Double = 7 * 86400, maxBytes: Int64 = 256 * 1024 * 1024, graceSeconds: Double = 1800, keepLatestScans: Bool = true) {
        self.maxAgeSeconds=maxAgeSeconds; self.maxBytes=maxBytes; self.graceSeconds=graceSeconds
        self.keepLatestScans=keepLatestScans
    }
}

public struct RecordCollectionUsage: Codable, Sendable, Identifiable {
    public var id: String { collection }
    public let collection: String
    public let totalBytes: Int64
    public let removableBytes: Int64
    public let retainedCount: Int
}

/// Reasons may overlap. Their byte counts must not be added together.
public struct RecordRetentionReason: Codable, Sendable, Identifiable {
    public var id: String { reason }
    public let reason: String
    public let byteCount: Int64
    public let recordCount: Int
}

public struct RecordRetentionPreview: Codable, Sendable {
    public let records: [StoredRecord]
    public let totalBytes: Int64
    public let removableBytes: Int64
    public let retainedCount: Int
    public let issues: [String]
    public var collections: [RecordCollectionUsage] = []
    public var retentionReasons: [RecordRetentionReason] = []
    public var quotaBytes: Int64 = 0
    public var quotaExcessBytes: Int64 = 0
}

/// Reproducible evidence and detached journal dependencies. Manifest files with
/// a live history parent are always protected, including unfinished operations.
public enum DerivedRecords {
    public static let collections=["scans", "plans", "storage-scans", "storage-scan-entries", "storage-plans", "storage-plan-manifests", "storage-catalogs", "history-summaries", "history-manifests", "application-close-plans", "tool-scans", "tool-plans", "orphan-reviews", "orphan-plans", "docker-storage-scans", "docker-storage-plans"]
}

extension ShouEngine {
    func maintainDerivedRecordsIfNeeded() {
        let timestamp=now()
        guard lastRecordMaintenance.map({ timestamp.timeIntervalSince($0) >= 3600 }) ?? true else { return }
        // Explicit preview exposes maintenance issues. Best-effort maintenance
        // must not prevent a normal scan when another process holds the lease.
        if (try? collectRecords()) != nil { lastRecordMaintenance=timestamp }
    }
    public func recordRetentionPreview(policy: RecordRetentionPolicy = .init(), includeFinishedHistory: Bool = false) throws -> RecordRetentionPreview {
        guard policy.maxAgeSeconds.isFinite, policy.graceSeconds.isFinite,
              policy.maxAgeSeconds >= 0, policy.maxBytes >= 0, policy.graceSeconds >= 0 else {
            throw ShouError("invalid_argument", "Record retention limits must be finite and nonnegative.")
        }
        struct PlanReference: Decodable { let scanId: String; let expiresAt: Date; let state: String }
        struct PlanEnvelope: Decodable {
            struct Manifest: Decodable { struct Page: Decodable { let id: String }; let pages: [Page] }
            let formatVersion: Int
            let plan: PlanReference
            let manifests: [Manifest]
        }
        struct ToolPlanReference: Decodable { let expiresAt: Date; let state: String }
        struct DockerPlanReference: Decodable { struct Scan: Decodable { let id: String }; let scan: Scan; let expiresAt: Date }
        struct StorageReference: Decodable {
            struct Scan: Decodable { let catalogId: String? }
            struct Page: Decodable { let id: String }
            let catalogId: String?
            let scan: Scan?
            let pages: [Page]?
        }
        let collections=DerivedRecords.collections + (includeFinishedHistory ? ["history", "followups"] : [])
        let records=try collections.flatMap { try store.records($0) }
        let finishedHistory=includeFinishedHistory ? try historyCleanupPreview() : nil
        if let finishedHistory {
            let inventory=Dictionary(uniqueKeysWithValues: records.map { ($0.collection + "/" + $0.id, $0) })
            guard finishedHistory.records.allSatisfy({ inventory[$0.collection + "/" + $0.id] == $0 }) else {
                throw ShouError("plan_stale", "History changed. Review the current records again.")
            }
        }
        let timestamp=now(), grace=timestamp.addingTimeInterval(-policy.graceSeconds)
        var protected=Set<String>(), issues=[String]()
        var reasons=[String: Set<String>]()
        var parents=[String: String]()
        func key(_ collection: String, _ id: String) -> String { collection + "/" + id }
        func protect(_ value: String, _ reason: String) {
            protected.insert(value); reasons[value, default: []].insert(reason)
        }
        for collection in ["plans", "storage-plans"] {
            for record in records where record.collection == collection {
                guard let data=try store.read(collection, id: record.id) else {
                    issues.append("unreadable_plan:" + collection + "/" + record.id); continue
                }
                let plan: PlanReference
                if let inline=try? Codec.decode(PlanReference.self, from: data) { plan=inline }
                else if collection == "storage-plans", let envelope=try? Codec.decode(PlanEnvelope.self, from: data), envelope.formatVersion == 1 {
                    plan=envelope.plan
                    for manifest in envelope.manifests {
                        for page in manifest.pages { parents[key("storage-plan-manifests", page.id)]=key(collection, record.id) }
                    }
                } else { issues.append("unreadable_plan:" + collection + "/" + record.id); continue }
                if plan.state == "executing" || (plan.state == "ready" && plan.expiresAt > timestamp) {
                    protect(key(collection, record.id), "active_plan")
                    protect(key(collection == "plans" ? "scans" : "storage-scans", plan.scanId), "active_plan")
                }
            }
        }
        for record in records where ["tool-plans", "orphan-plans"].contains(record.collection) {
            guard let data=try store.read(record.collection, id: record.id), let plan=try? Codec.decode(ToolPlanReference.self, from: data) else {
                issues.append("unreadable_tool_plan:" + record.id); continue
            }
            if plan.state == "executing" || (plan.state == "ready" && plan.expiresAt > timestamp) { protect(key(record.collection,record.id), "active_plan") }
        }
        for record in records where record.collection == "docker-storage-plans" {
            guard let data=try store.read(record.collection, id: record.id), let plan=try? Codec.decode(DockerPlanReference.self, from: data) else {
                issues.append("unreadable_docker_plan:" + record.id); continue
            }
            if plan.expiresAt > timestamp {
                protect(key(record.collection, record.id), "active_plan")
                protect(key("docker-storage-scans", plan.scan.id), "active_plan")
            }
        }
        // Recent scans can still be in a desktop selection or an unpublished worker.
        for record in records where record.modifiedAt >= grace { protect(key(record.collection, record.id), "grace_period") }
        // Keep the latest result in each scan family for later inspection.
        for collection in ["scans", "storage-scans", "tool-scans", "docker-storage-scans"] where policy.keepLatestScans {
            if let latest=records.filter({ $0.collection == collection }).max(by: { $0.modifiedAt < $1.modifiedAt }) {
                protect(key(collection, latest.id), "latest_scan")
            }
        }
        for record in records where record.collection == "storage-scans" {
            guard let data=try store.read(record.collection, id: record.id), let scan=try? Codec.decode(StorageReference.self, from: data) else {
                issues.append("unreadable_storage_scan:" + record.id); continue
            }
            let parent=key(record.collection, record.id)
            parents[key("storage-catalogs", scan.catalogId ?? scan.scan?.catalogId ?? record.id)]=parent
            for page in scan.pages ?? [] { parents[key("storage-scan-entries", page.id)]=parent }
        }
        let historyIDs=Set(try store.ids("history"))
        for record in records where ["history", "followups"].contains(record.collection) {
            protect(key(record.collection, record.id), "recovery_dependency")
        }
        for record in records where record.collection == "history-summaries" && historyIDs.contains(record.id) {
            protect(key(record.collection, record.id), "history_dependency")
        }
        for record in records where record.collection == "history-manifests" && historyIDs.contains(where: { record.id.hasPrefix($0 + "_") }) {
            protect(key(record.collection, record.id), "recovery_dependency")
        }
        let total=records.reduce(Int64(0)) { $0 + $1.byteCount }
        // Unknown plan references must not be guessed away. Recovery journals are
        // never candidates, even with an explicitly zero retention quota.
        func result(_ removal: [StoredRecord], _ retainedReasons: [String: Set<String>]) -> RecordRetentionPreview {
            let removed=Set(removal.map { key($0.collection,$0.id) })
            let removable=removal.reduce(Int64(0)) { $0 + $1.byteCount }
            var preview=RecordRetentionPreview(records: removal, totalBytes: total, removableBytes: removable, retainedCount: records.count-removal.count, issues: issues)
            preview.quotaBytes=policy.maxBytes
            preview.quotaExcessBytes=max(0,total-removable-policy.maxBytes)
            preview.collections=Dictionary(grouping: records, by: \.collection).map { collection, values in
                let eligible=values.filter { removed.contains(key($0.collection,$0.id)) }
                return RecordCollectionUsage(collection: collection, totalBytes: values.reduce(0) { $0+$1.byteCount }, removableBytes: eligible.reduce(0) { $0+$1.byteCount }, retainedCount: values.count-eligible.count)
            }.sorted { $0.totalBytes == $1.totalBytes ? $0.collection < $1.collection : $0.totalBytes > $1.totalBytes }
            var byReason=[String: [StoredRecord]]()
            for record in records where !removed.contains(key(record.collection,record.id)) {
                for reason in retainedReasons[key(record.collection,record.id)] ?? ["within_policy"] { byReason[reason,default: []].append(record) }
            }
            preview.retentionReasons=byReason.map { reason, values in
                RecordRetentionReason(reason: reason, byteCount: values.reduce(0) { $0+$1.byteCount }, recordCount: values.count)
            }.sorted { $0.reason < $1.reason }
            return preview
        }
        guard issues.isEmpty else {
            return result([], Dictionary(uniqueKeysWithValues: records.map { (key($0.collection,$0.id),Set(["verification_required"])) }))
        }
        var remaining=total, removal=[StoredRecord]()
        let groups=Dictionary(grouping: records) { record in parents[key(record.collection, record.id)] ?? key(record.collection, record.id) }
        // Explicitly giving up published scans also gives up their grace period.
        // Unpublished worker catalogs still need grace, and active plans keep
        // their parent/dependency protection independently of this choice.
        if !policy.keepLatestScans {
            for group in groups.values where group.contains(where: { ["scans", "storage-scans", "tool-scans", "docker-storage-scans"].contains($0.collection) }) {
                for record in group {
                    let value=key(record.collection, record.id)
                    reasons[value]?.remove("grace_period")
                    if reasons[value]?.isEmpty == true { protected.remove(value); reasons.removeValue(forKey: value) }
                }
            }
        }
        let ordered=groups.values.sorted { a,b in
            let left=a.map(\.modifiedAt).max()!, right=b.map(\.modifiedAt).max()!
            return left == right ? key(a[0].collection,a[0].id) < key(b[0].collection,b[0].id) : left < right
        }
        // A protected parent protects every page/catalog in its publication.
        // Preserve the reason as well as the bytes so callers can explain quotas.
        for group in ordered {
            let inherited=group.reduce(into: Set<String>()) { $0.formUnion(reasons[key($1.collection,$1.id)] ?? []) }
            if !inherited.isEmpty {
                for record in group { reasons[key(record.collection,record.id),default: []].formUnion(inherited) }
            }
        }
        for group in ordered where !group.contains(where: { protected.contains(key($0.collection,$0.id)) }) {
            let explicitlyDiscardedScan = !policy.keepLatestScans && group.contains { ["scans", "storage-scans", "tool-scans", "docker-storage-scans"].contains($0.collection) }
            if explicitlyDiscardedScan || group.allSatisfy({ timestamp.timeIntervalSince($0.modifiedAt) >= policy.maxAgeSeconds }) || remaining > policy.maxBytes {
                // Unpublish a scan before its dependent pages/catalog. An
                // interrupted collection can leave only inert orphan data.
                let sorted=group.sorted { (["storage-scans", "storage-plans"].contains($0.collection) ? 0 : 1) < (["storage-scans", "storage-plans"].contains($1.collection) ? 0 : 1) }
                removal.append(contentsOf: sorted); remaining -= group.reduce(0) { $0 + $1.byteCount }
            }
        }
        if let finishedHistory {
            // Explicit history cleanup releases terminal journals and their own
            // dependencies, even when they are recent. Active, uncertain and
            // recoverable journals never enter this default history preview.
            let selected=Set(removal.map { key($0.collection, $0.id) })
            removal.append(contentsOf: finishedHistory.records.filter { !selected.contains(key($0.collection, $0.id)) })
            // Unpublish every history parent before removing any dependent page.
            removal.sort { ($0.collection == "history" ? 0 : 1) < ($1.collection == "history" ? 0 : 1) }
        }
        return result(removal,reasons)
    }

    /// Default maintenance collects only derived records. Explicit reviewed
    /// history cleanup reuses terminal-journal eligibility under the same lease.
    public func collectRecords(policy: RecordRetentionPolicy = .init(), reviewedRecords: [StoredRecord]? = nil, includeFinishedHistory: Bool = false) throws -> RecordRetentionPreview {
        guard !includeFinishedHistory || reviewedRecords != nil else { throw ShouError("confirmation_required", "Review finished history records before removing them.") }
        let lease=try store.lock(); defer { lease.release() }
        let preview=try recordRetentionPreview(policy: policy, includeFinishedHistory: includeFinishedHistory)
        if let reviewedRecords {
            guard Set(reviewedRecords.map { $0.collection + "/" + $0.id }).count == reviewedRecords.count,
                  Set(reviewedRecords.map { $0.collection + "/" + $0.id }) == Set(preview.records.map { $0.collection + "/" + $0.id }),
                  Dictionary(uniqueKeysWithValues: reviewedRecords.map { ($0.collection + "/" + $0.id,$0) }) == Dictionary(uniqueKeysWithValues: preview.records.map { ($0.collection + "/" + $0.id,$0) }) else {
                throw ShouError("plan_stale", "Record cleanup changed. Review the current records again.")
            }
        }
        for record in preview.records {
            if Task.isCancelled { throw ShouError("cancelled", "Record cleanup cancelled.") }
            if ["history", "followups"].contains(record.collection) {
                guard try store.recordMetadata(record.collection, id: record.id) == record else { throw ShouError("plan_stale", "History changed. Review the current records again.") }
                try store.removeHistoryRecord(record.collection, id: record.id)
            } else { try store.removeDerivedRecord(record) }
        }
        return preview
    }
}
