import Foundation

public struct BuiltinTemplate: Codable, Sendable, Identifiable {
    public let id: String
    public let version: String?
    public let name: String
    public let category: String
    public let patterns: [String]
    public let marker: String?
    public let risk: String
    public let rebuildNote: String
    public let limitation: String
    public let location: String
    public let applicationBundleIdentifiers: [String]?

    public func rule(rootRef: String) throws -> CleanupRule {
        let rule=CleanupRule(schemaVersion: "1.0", id: id, version: version ?? "1.0.0", name: name, description: rebuildNote,
            platforms: ["macos", "windows"], scope: .init(rootRef: rootRef, maxDepth: 24, followSymlinks: false, crossFilesystems: false),
            match: .init(kind: "directory", relativePatterns: patterns, projectMarkers: marker.map { .init(location: "parent", allOf: [$0]) }),
            conditions: .init(minAllocatedBytes: 0, newestDescendantModifiedDaysAtLeast: nil), exclude: .init(relativePatterns: []),
            risk: .init(declaredLevel: risk, rebuildNote: rebuildNote, limitations: [limitation]), action: .init(type: "trash"))
        return try CleanupRule.parse(Codec.encode(rule))
    }
}

public enum BuiltinCatalog {
    public static let prefix="shou.builtin."
    private static let catalog: Result<[BuiltinTemplate], Error> = Result {
        guard let url=CoreResources.bundle.url(forResource: "builtin-rules", withExtension: "json") else { throw ShouError("io_error", "Built-in rule catalog is unavailable.") }
        let templates=try JSONDecoder().decode([BuiltinTemplate].self, from: Data(contentsOf: url))
        guard Set(templates.map(\.id)).count == templates.count else { throw ShouError("invalid_rule", "Built-in rule identifiers must be unique.") }
        for template in templates {
            guard template.id.hasPrefix(prefix), (template.applicationBundleIdentifiers ?? []).allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z0-9.-]+$", options: .regularExpression) != nil }) else {
                throw ShouError("invalid_rule", "Built-in rule metadata is invalid.")
            }
            _ = try template.rule(rootRef: "catalog-validation")
        }
        return templates
    }
    public static func templates() throws -> [BuiltinTemplate] {
        try catalog.get()
    }
    public static func rules(for workspace: Workspace, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, platform: String = KnownLocations.currentPlatform) throws -> [CleanupRule] {
        let locations=try KnownLocations.catalog(homeDirectory: homeDirectory, platform: platform)
        let scopedLocations=Set(locations.filter { $0.path == workspace.path }.map(\.id))
        return try templates().filter { template in
            template.location == "projects" ? scopedLocations.isEmpty : scopedLocations.contains(template.location)
        }.map { try $0.rule(rootRef: workspace.rootRef) }
    }
    public static func category(ruleIds: [String]) -> String {
        let known=(try? templates()) ?? []
        return known.first { ruleIds.contains($0.id) }?.category ?? "personal"
    }
}
