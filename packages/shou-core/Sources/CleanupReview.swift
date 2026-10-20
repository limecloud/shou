import Foundation

/// A presentation projection of immutable scan evidence. It grants no execution authority.
public struct CleanupSource: Sendable, Identifiable {
    public let snapshotId: String
    public let workspace: Workspace
    public let candidate: Candidate
    public let fileCount: Int
    public let selectable: Bool
    public var id: String { snapshotId + ":" + candidate.id }
    public var path: String { workspace.path + "/" + candidate.relativePath }
    /// Distinguishes maintained rules from explicitly enabled personal rules.
    public var isBuiltIn: Bool { candidate.ruleIds.allSatisfy { $0.hasPrefix(BuiltinCatalog.prefix) } && !candidate.ruleIds.isEmpty }
}

public struct CleanupRuleGroup: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: String
    public let applicationBundleIdentifiers: [String]
    public let sources: [CleanupSource]
    public var bytes: Int64 { sources.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }
}

public struct CleanupReviewCategory: Sendable, Identifiable {
    public let id: String
    public let groups: [CleanupRuleGroup]
    public var sources: [CleanupSource] { groups.flatMap(\.sources) }
    public var bytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }
}

public struct CleanupReview: Sendable {
    public let categories: [CleanupReviewCategory]
    public var sources: [CleanupSource] { categories.flatMap(\.sources) }
    public var bytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    /// Scans contain enabled rules only. Draft previews and incomplete or
    /// blocked candidates remain ineligible for the repeated one-click path.
    public var recommendedSources: [CleanupSource] { sources.filter(\.selectable) }

    public init() { categories=[] }

    public init(snapshots: [ScanSnapshot], locations: [KnownLocation] = []) throws {
        let templates=try BuiltinCatalog.templates()
        let byId=Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
        var grouped: [String: [CleanupSource]]=[:]
        var definitions: [String: (String, String, [String])]=[:]
        var claimed=Set<String>()
        // Resolve overlapping registered roots before grouping or calculating capacity.
        let ordered=snapshots.flatMap { snapshot in
            CleanupOverview.candidates(snapshot.candidates).map { (snapshot, $0) }
        }.sorted {
            let a=$0.0.workspace.path + "/" + $0.1.relativePath, b=$1.0.workspace.path + "/" + $1.1.relativePath
            return a == b ? $0.0.id < $1.0.id : a < b
        }
        var indexes: [String: StorageIndex]=[:]
        for (snapshot, candidate) in ordered {
            let path=snapshot.workspace.path + "/" + candidate.relativePath
            let identity=snapshot.caseSensitive ? path : path.lowercased()
            guard !claimed.contains(identity) else { continue }
            var parent=StorageIndex.parent(identity), overlaps=false
            while parent != "." && !parent.isEmpty && parent != "/" {
                if claimed.contains(parent) { overlaps=true; break }
                let next=StorageIndex.parent(parent)
                if next == parent { break }
                parent=next
            }
            guard !overlaps else { continue }
            claimed.insert(identity)
            let template=candidate.ruleIds.sorted().compactMap { byId[$0] }.first
            let key=template?.id ?? candidate.ruleIds.sorted().joined(separator: ",")
            let location=locations.first { $0.path == snapshot.workspace.path }
            let category: String
            if template == nil { category="personal" }
            else if template?.location == "projects" { category=template?.category == "build" || template?.category == "dependencies" ? "build" : "developer" }
            else if template?.category == "build" || template?.category == "packages" { category="developer" }
            else if location?.category == "browser" || locations.contains(where: { $0.category == "browser" && !Set($0.applicationBundleIdentifiers).isDisjoint(with: template?.applicationBundleIdentifiers ?? []) }) { category="browser" }
            else if location?.category == "developer" { category="developer" }
            else { category="application" }
            if indexes[snapshot.id] == nil { indexes[snapshot.id]=StorageIndex(entries: snapshot.entries) }
            grouped[key, default: []].append(CleanupSource(snapshotId: snapshot.id, workspace: snapshot.workspace, candidate: candidate,
                fileCount: indexes[snapshot.id]?.nodes[candidate.relativePath]?.fileCount ?? 0,
                selectable: candidate.eligible && !snapshot.previewOnly && TreeSnapshot(entries: [], complete: snapshot.treeComplete ?? (snapshot.status == "complete"), issues: [], caseSensitive: snapshot.caseSensitive, completedPaths: snapshot.completedPaths).isComplete(at: candidate.relativePath)))
            definitions[key]=(template?.name ?? "Personal Rules", category, template?.applicationBundleIdentifiers ?? [])
        }
        let rules=grouped.map { key, sources in
            let definition=definitions[key]!
            return CleanupRuleGroup(id: key, title: definition.0, category: definition.1, applicationBundleIdentifiers: definition.2,
                sources: sources.sorted { $0.candidate.allocatedBytesEstimate > $1.candidate.allocatedBytesEstimate })
        }
        let order=["application", "browser", "developer", "build", "personal"]
        categories=Dictionary(grouping: rules, by: \.category).map { category, rules in
            CleanupReviewCategory(id: category, groups: rules.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes })
        }.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }
}
