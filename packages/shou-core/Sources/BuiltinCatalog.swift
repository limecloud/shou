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
    public let platforms: [String]?

    public var supportedPlatforms: [String] {
        platforms ?? (location == "projects" ? ["macos", "windows"] : ["macos"])
    }

    public func rule(rootRef: String) throws -> CleanupRule {
        let rule=CleanupRule(schemaVersion: "1.0", id: id, version: version ?? "1.0.0", name: name, description: rebuildNote,
            platforms: supportedPlatforms, scope: .init(rootRef: rootRef, maxDepth: 24, followSymlinks: false, crossFilesystems: false),
            match: .init(kind: "directory", relativePatterns: patterns, projectMarkers: marker.map { .init(location: "parent", allOf: [$0]) }),
            conditions: .init(minAllocatedBytes: 0, newestDescendantModifiedDaysAtLeast: nil), exclude: .init(relativePatterns: []),
            risk: .init(declaredLevel: risk, rebuildNote: rebuildNote, limitations: [limitation]), action: .init(type: "trash"))
        return try CleanupRule.parse(Codec.encode(rule))
    }
}

public enum BuiltinCatalog {
    public static let prefix="shou.builtin."
    private struct ValidatedTemplate: Sendable {
        let template: BuiltinTemplate
        let rule: CleanupRule
    }
    private static let catalog: Result<[ValidatedTemplate], Error> = Result {
        guard let url=CoreResources.bundle.url(forResource: "builtin-rules", withExtension: "json") else { throw ShouError("io_error", "Built-in rule catalog is unavailable.") }
        let templates=try JSONDecoder().decode([BuiltinTemplate].self, from: Data(contentsOf: url))
        guard Set(templates.map(\.id)).count == templates.count else { throw ShouError("invalid_rule", "Built-in rule identifiers must be unique.") }
        return try templates.map { template in
            guard template.id.hasPrefix(prefix),
                  template.location.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
                  Set(template.applicationBundleIdentifiers ?? []).count == (template.applicationBundleIdentifiers ?? []).count,
                  (template.applicationBundleIdentifiers ?? []).allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z0-9.-]+$", options: .regularExpression) != nil }) else {
                throw ShouError("invalid_rule", "Built-in rule metadata is invalid.")
            }
            return ValidatedTemplate(template: template, rule: try template.rule(rootRef: "catalog-validation"))
        }
    }
    public static func templates() throws -> [BuiltinTemplate] {
        try catalog.get().map(\.template)
    }
    /// Source exceptions require the complete bundled definition. Reuse the
    /// validated catalog instead of parsing its JSON for each candidate.
    static func trustedTemplates(matching rules: [CleanupRule]) throws -> [BuiltinTemplate] {
        try catalog.get().compactMap { item in
            guard let rule=rules.first(where: { $0.id == item.template.id }),
                  try item.rule.rebindingRootReference(rule.scope.rootRef) == rule else { return nil }
            return item.template
        }
    }
    public static func rules(for workspace: Workspace, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, platform: String = KnownLocations.currentPlatform) throws -> [CleanupRule] {
        let locations=try KnownLocations.catalog(homeDirectory: homeDirectory, platform: platform)
        let key=KnownLocations.pathKey(workspace.path, platform: platform)
        let scopedLocations=Set(locations.filter { KnownLocations.pathKey($0.path, platform: platform) == key }.map(\.id))
        return try catalog.get().filter { item in
            let template=item.template
            return template.supportedPlatforms.contains(platform) && (template.location == "projects" ? scopedLocations.isEmpty : scopedLocations.contains(template.location))
        }.map { try $0.rule.rebindingRootReference(workspace.rootRef) }
    }
    public static func category(ruleIds: [String]) -> String {
        let known=(try? templates()) ?? []
        return known.first { ruleIds.contains($0.id) }?.category ?? "personal"
    }
}
