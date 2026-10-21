import Foundation

/// Authoring convenience only. The closed rule parser remains the authority.
public struct PersonalRuleDraft: Sendable, Equatable {
    public var name: String
    public var relativePatterns: [String]
    public var projectMarkers: [String]
    public var exclusions: [String]
    public var maxDepth: Int
    public var minimumAllocatedBytes: Int64
    public var minimumAgeDays: Int?
    public var rebuildNote: String
    public var limitations: [String]
    public var highRisk: Bool

    public init(name: String, relativePatterns: [String], projectMarkers: [String] = [], exclusions: [String] = [], maxDepth: Int = 8,
                minimumAllocatedBytes: Int64 = 0, minimumAgeDays: Int? = nil, rebuildNote: String, limitations: [String], highRisk: Bool = false) {
        self.name=name; self.relativePatterns=relativePatterns; self.projectMarkers=projectMarkers; self.exclusions=exclusions
        self.maxDepth=maxDepth; self.minimumAllocatedBytes=minimumAllocatedBytes; self.minimumAgeDays=minimumAgeDays
        self.rebuildNote=rebuildNote; self.limitations=limitations; self.highRisk=highRisk
    }

    public func rule(id: String, rootRef: String, platform: String) throws -> CleanupRule {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        var match: [String: JSONValue] = ["kind": .string("directory"), "relative_patterns": .array(relativePatterns.map { .string(clean($0)) })]
        if !projectMarkers.isEmpty {
            match["project_markers"] = .object(["location": .string("parent"), "all_of": .array(projectMarkers.map { .string(clean($0)) })])
        }
        var conditions: [String: JSONValue] = ["min_allocated_bytes": .integer(minimumAllocatedBytes)]
        if let minimumAgeDays { conditions["newest_descendant_modified_days_at_least"] = .integer(Int64(minimumAgeDays)) }
        let value: JSONValue = .object([
            "schema_version": .string("1.0"), "id": .string(id), "version": .string("0.1.0"),
            "name": .string(clean(name)), "description": .string(clean(rebuildNote)), "platforms": .array([.string(platform)]),
            "scope": .object(["root_ref": .string(rootRef), "max_depth": .integer(Int64(maxDepth)), "follow_symlinks": .bool(false), "cross_filesystems": .bool(false)]),
            "match": .object(match), "conditions": .object(conditions),
            "exclude": .object(["relative_patterns": .array(exclusions.map { .string(clean($0)) })]),
            "risk": .object(["declared_level": .string(highRisk ? "high" : "review"), "rebuild_note": .string(clean(rebuildNote)), "limitations": .array(limitations.map { .string(clean($0)) })]),
            "action": .object(["type": .string("trash")])
        ])
        return try CleanupRule.parse(Codec.encode(value))
    }

    /// Do not resolve or broaden a selection. Filesystem access is rechecked by scanning.
    public static func exactRelativePath(selection: String, workspacePath: String) throws -> String {
        let root=workspacePath.hasSuffix("/") ? String(workspacePath.dropLast()) : workspacePath
        guard root.hasPrefix("/"), selection.hasPrefix(root + "/") else {
            throw ShouError("invalid_rule", "Choose a folder inside the selected workspace, not the workspace itself.")
        }
        let relative=String(selection.dropFirst(root.count + 1))
        guard !relative.contains("*"), !relative.contains("?") else {
            throw ShouError("invalid_rule", "This folder name contains wildcard characters and cannot be represented as an exact rule.")
        }
        try PathPattern.validate(relative, target: true)
        return relative
    }
}

/// Shared by candidate matching and draft explanations, including precise age boundaries.
enum RuleConditions {
    static func failures(_ rule: CleanupRule, allocatedBytes: Int64, newestModifiedAt: Date, now: Date, missingMarkers: Bool) -> [String] {
        var reasons: [String]=[]
        if allocatedBytes < rule.conditions.minAllocatedBytes { reasons.append("rule_minimum_size") }
        if missingMarkers { reasons.append("rule_missing_markers") }
        if let days=rule.conditions.newestDescendantModifiedDaysAtLeast,
           now.timeIntervalSince1970 - newestModifiedAt.timeIntervalSince1970 < Double(days) * 86_400 { reasons.append("rule_recent_modification") }
        return reasons
    }
}

public struct PersonalRulePreviewRow: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let allocatedBytes: Int64
    public let newestModifiedAt: Date
    public let status: String
    public let reasons: [String]
}

public enum PersonalRulePreview {
    /// A presentation of measured evidence; it never grants plan or execution permission.
    public static func rows(snapshot: ScanSnapshot, rule: CleanupRule) throws -> [PersonalRulePreviewRow] {
        try Task.checkCancellation()
        let storage=StorageIndex(entries: snapshot.entries)
        let entries=Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.path, $0.kind) })
        let patterns=rule.match.relativePatterns.map { PathPattern.Compiled($0, caseSensitive: snapshot.caseSensitive) }
        return try snapshot.candidates.compactMap { candidate in
            try Task.checkCancellation()
            let path=candidate.relativePath, parts=path.split(separator: "/").map(String.init)
            let normalized=snapshot.caseSensitive ? parts : parts.map { $0.lowercased() }
            guard patterns.contains(where: { $0.matches(normalized) }), let measured=storage.nodes[path] else { return nil }
            let parent=StorageIndex.parent(path)
            let missing=(rule.match.projectMarkers?.allOf ?? []).contains { marker in
                entries[parent == "." ? marker : parent + "/" + marker] != "file"
            }
            let newest=Date(timeIntervalSince1970: Double(measured.newestModifiedNanoseconds) / 1_000_000_000)
            var reasons=RuleConditions.failures(rule, allocatedBytes: measured.allocatedBytes, newestModifiedAt: newest, now: snapshot.createdAt, missingMarkers: missing)
            if parts.count > rule.scope.maxDepth { reasons.append("rule_maximum_depth") }
            let matched=candidate.ruleIds.contains(rule.id)
            if matched { reasons=candidate.reasons }
            else if reasons.isEmpty { reasons.append("unclassified") }
            return PersonalRulePreviewRow(path: path, allocatedBytes: candidate.allocatedBytesEstimate, newestModifiedAt: newest,
                                          status: matched ? (candidate.eligible ? "matched" : "blocked") : "not_matched", reasons: reasons)
        }.sorted { $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes }
    }
}
