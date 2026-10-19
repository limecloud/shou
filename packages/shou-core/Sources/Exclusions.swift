import Foundation

public struct ExclusionSettings: Codable, Sendable {
    public let globalPatterns: [String]
    public let workspaceId: String?
    public let workspacePatterns: [String]
    public let effectivePatterns: [String]

    public init(globalPatterns: [String], workspaceId: String?, workspacePatterns: [String]) {
        self.globalPatterns=globalPatterns; self.workspaceId=workspaceId; self.workspacePatterns=workspacePatterns
        var seen=Set<String>()
        effectivePatterns=(workspacePatterns + globalPatterns).filter { seen.insert($0).inserted }
    }
}

public enum ExclusionPattern {
    public static func scopedToProject(_ project: String, pattern: String) throws -> String {
        try PathPattern.validate(project)
        guard !project.contains("*"), !project.contains("?") else {
            throw ShouError("invalid_argument", "Project directory must be a literal relative path without wildcards.")
        }
        try PathPattern.validate(pattern)
        let scoped=project + "/" + pattern
        try PathPattern.validate(scoped)
        return scoped
    }
}
