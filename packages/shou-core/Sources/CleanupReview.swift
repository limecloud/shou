import Foundation

/// A presentation projection of immutable scan evidence. It grants no execution authority.
public struct CleanupSource: Sendable, Identifiable {
    public let snapshotId: String
    public let workspace: Workspace
    public let candidate: Candidate
    public let fileCount: Int
    public let selectable: Bool
    public let requiresManualReview: Bool
    public let recommendationEligible: Bool
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

/// Groups existing candidates by observed project markers for presentation only.
/// A repository or marker never proves its contents can be removed.
public struct CleanupProjectGroup: Sendable, Identifiable {
    public let path: String
    public let identifiedProject: Bool
    public let sources: [CleanupSource]
    public var id: String { path }
    public var bytes: Int64 { sources.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }
}

/// Selects newer evidence for one displayed directory without changing saved snapshots.
public struct CleanupTargetRefinement: Sendable {
    public let originalSnapshotId: String
    public let candidateId: String
    public let snapshotId: String
    public init(originalSnapshotId: String, candidateId: String, snapshotId: String) {
        self.originalSnapshotId=originalSnapshotId; self.candidateId=candidateId; self.snapshotId=snapshotId
    }
}

public struct CleanupReview: Sendable {
    public let categories: [CleanupReviewCategory]
    public var sources: [CleanupSource] { categories.flatMap(\.sources) }
    public var bytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    /// Scans contain enabled rules only. Draft previews and incomplete or
    /// blocked candidates remain ineligible for the repeated one-click path.
    public var recommendedSources: [CleanupSource] { sources.filter { $0.selectable && !$0.requiresManualReview && $0.recommendationEligible && $0.candidate.risk != "high" } }

    public init() { categories=[] }

    public func projects(snapshots: [ScanSnapshot], locations: [KnownLocation]) -> [CleanupProjectGroup] {
        let projectRoots=Set(locations.filter { $0.category == "build" }.map(\.path))
        let markers=Set(((try? BuiltinCatalog.templates()) ?? []).filter { $0.location == "projects" }.compactMap(\.marker))
            .union(["Package.swift", "go.mod"])
        var rootsBySnapshot: [String: [String]]=[:]
        for snapshot in snapshots {
            rootsBySnapshot[snapshot.id]=Set(snapshot.entries.compactMap { entry -> String? in
                guard entry.kind == "file", markers.contains((entry.path as NSString).lastPathComponent) else { return nil }
                let parent=StorageIndex.parent(entry.path)
                return parent == "." ? snapshot.workspace.path : snapshot.workspace.path + "/" + parent
            }).sorted { $0.count > $1.count }
        }
        let projectSources=categories.flatMap { category -> [CleanupSource] in
            if category.id == "build" { return category.sources }
            if category.id == "personal" { return category.sources.filter { projectRoots.contains($0.workspace.path) } }
            return []
        }
        var grouped: [String: [CleanupSource]]=[:]
        var identified=Set<String>()
        for source in projectSources {
            let root=rootsBySnapshot[source.snapshotId]?.first { source.path.hasPrefix($0 + "/") }
            let path=root ?? source.workspace.path
            if root != nil { identified.insert(path) }
            grouped[path, default: []].append(source)
        }
        return grouped.map { path, sources in
            CleanupProjectGroup(path: path, identifiedProject: identified.contains(path), sources: sources.sorted { $0.path < $1.path })
        }.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
    }

    public init(snapshots: [ScanSnapshot], locations: [KnownLocation] = [], refinements: [CleanupTargetRefinement] = []) throws {
        let templates=try BuiltinCatalog.templates()
        let byId=Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
        var grouped: [String: [CleanupSource]]=[:]
        var definitions: [String: (String, String, [String])]=[:]
        var claimed=Set<String>()
        // Resolve overlapping registered roots before grouping or calculating capacity.
        let refinedIds=Set(refinements.map(\.snapshotId))
        var evidence=snapshots.filter { !refinedIds.contains($0.id) }.flatMap { snapshot in
            CleanupOverview.candidates(snapshot.candidates).map { (snapshot, $0) }
        }
        for refinement in refinements {
            guard let original=snapshots.first(where: { $0.id == refinement.originalSnapshotId }),
                  let target=original.candidates.first(where: { $0.id == refinement.candidateId }),
                  let updated=snapshots.first(where: { $0.id == refinement.snapshotId }),
                  target.reasons.contains("incomplete_scan"), !original.previewOnly, !updated.previewOnly,
                  original.scope == .cleanup, updated.scope == .cleanup,
                  original.configurationDigest == updated.configurationDigest,
                  original.caseSensitive == updated.caseSensitive,
                  original.workspace.id == updated.workspace.id, original.workspace.path == updated.workspace.path,
                  original.workspace.rootRef == updated.workspace.rootRef,
                  original.workspace.identity.sameObject(as: updated.workspace.identity) else {
                throw ShouError("plan_stale", "Scan evidence changed. Scan again before continuing.")
            }
            let targetPath=original.workspace.path + "/" + target.relativePath
            func contains(_ path: String) -> Bool {
                let root=original.caseSensitive ? targetPath : targetPath.lowercased()
                let value=original.caseSensitive ? path : path.lowercased()
                return value == root || value.hasPrefix(root + "/")
            }
            evidence.removeAll { contains($0.0.workspace.path + "/" + $0.1.relativePath) }
            evidence += CleanupOverview.candidates(updated.candidates.filter {
                contains(updated.workspace.path + "/" + $0.relativePath)
            }).map { (updated, $0) }
        }
        let ordered=evidence.sorted {
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
            let installedCache=snapshot.installedApplicationCaches?.first { candidate.ruleIds.contains($0.ruleId) }
            let toolTitle=template?.id == "shou.builtin.tool-caches" ? [
                "Homebrew":"Homebrew download caches", "node-gyp":"Node.js toolchain caches", "org.swift.swiftpm":"Swift Package Manager caches"
            ][candidate.relativePath] : nil
            let key=(template?.id ?? installedCache?.ruleId ?? candidate.ruleIds.sorted().joined(separator: ",")) + (toolTitle == nil ? "" : ":" + candidate.relativePath)
            let location=locations.first { $0.path == snapshot.workspace.path }
            let category: String
            if template == nil && installedCache == nil { category="personal" }
            else if installedCache != nil && template == nil { category="application" }
            else if template?.location == "projects" { category="build" }
            else if template?.location == "caches" { category="userCache" }
            else if template?.category == "build" || template?.category == "packages" { category="developer" }
            else if location?.category == "browser" || locations.contains(where: { $0.category == "browser" && !Set($0.applicationBundleIdentifiers).isDisjoint(with: template?.applicationBundleIdentifiers ?? []) }) { category="browser" }
            else if location?.category == "developer" { category="developer" }
            else { category="application" }
            if indexes[snapshot.id] == nil { indexes[snapshot.id]=StorageIndex(entries: snapshot.entries) }
            let complete=TreeSnapshot(entries: [], complete: snapshot.treeComplete ?? (snapshot.status == "complete"), issues: [], caseSensitive: snapshot.caseSensitive, completedPaths: snapshot.completedPaths).isComplete(at: candidate.relativePath)
            grouped[key, default: []].append(CleanupSource(snapshotId: snapshot.id, workspace: snapshot.workspace, candidate: candidate,
                fileCount: indexes[snapshot.id]?.nodes[candidate.relativePath]?.fileCount ?? 0,
                selectable: !snapshot.previewOnly && !candidate.reasons.contains("excluded_descendant") && !candidate.reasons.contains("application_running") &&
                    !(snapshot.workspace.protectedRelativePaths ?? []).contains { protected in
                        protected == "." || candidate.relativePath == protected || candidate.relativePath.hasPrefix(protected + "/") || protected.hasPrefix(candidate.relativePath + "/")
                    },
                requiresManualReview: !candidate.eligible || !complete,
                recommendationEligible: !(snapshot.installedApplicationCaches ?? []).contains { candidate.ruleIds.contains($0.ruleId) && $0.ownershipCoverageIncomplete == true }))
            definitions[key]=(toolTitle ?? template?.name ?? installedCache?.application.name ?? "Personal Rules", category,
                template?.applicationBundleIdentifiers ?? installedCache?.application.bundleIdentifier.map { [$0] } ?? [])
        }
        let rules=grouped.map { key, sources in
            let definition=definitions[key]!
            return CleanupRuleGroup(id: key, title: definition.0, category: definition.1, applicationBundleIdentifiers: definition.2,
                sources: sources.sorted { $0.candidate.allocatedBytesEstimate > $1.candidate.allocatedBytesEstimate })
        }
        let order=["userCache", "application", "browser", "developer", "build", "personal"]
        categories=Dictionary(grouping: rules, by: \.category).map { category, rules in
            CleanupReviewCategory(id: category, groups: rules.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes })
        }.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }
}
