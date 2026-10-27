import Foundation

/// Only names and file facts cross this boundary. Configuration values, command
/// arguments, environment variables and credentials never become UI/diagnostic data.
public struct AIWorkspaceResource: Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let path: String
    public let state: String
    public let names: [String]
    public init(id: String, kind: String, path: String, state: String, names: [String] = []) {
        self.id=id; self.kind=kind; self.path=path; self.state=state; self.names=names
    }
}
public struct AIWorkspaceSnapshot: Sendable {
    public let toolID: String
    public let resources: [AIWorkspaceResource]
    public init(toolID: String, resources: [AIWorkspaceResource]) { self.toolID=toolID; self.resources=resources }
}
public protocol AIWorkspaceInspecting: Sendable {
    func inspect(toolID: String) throws -> AIWorkspaceSnapshot
}
public enum AIWorkspaceSummary {
    public static let supportedTools: Set<String> = ["claude-code", "claude-desktop", "codex", "gemini", "opencode"]
    public static func names(data: Data, format: String, kind: String) throws -> [String] {
        guard data.count <= 262_144 else { throw invalid() }
        let names: [String]
        if format == "json" {
            guard let root=try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw invalid() }
            let keys = kind == "mcp" ? ["mcpServers", "mcp"] : ["provider", "providers"]
            names=keys.flatMap { (root[$0] as? [String:Any]).map { Array($0.keys) } ?? [] }
        } else if format == "toml" {
            guard let text=String(data: data, encoding: .utf8) else { throw invalid() }
            guard !text.contains("\"\"\""), !text.contains("'''") else { throw invalid() }
            // A bounded declaration summary, not a TOML editor. Unsupported table
            // syntax remains unclaimed, and no values are extracted.
            let section=kind == "mcp" ? "mcp_servers" : "model_providers"
            let expression=try NSRegularExpression(pattern: "(?m)^\\s*\\[" + section + "\\.([A-Za-z0-9_-]{1,128})\\]\\s*(?:#[^\\r\\n]*)?$" )
            let value=text as NSString
            names=expression.matches(in: text, range: NSRange(location: 0, length: value.length)).map { value.substring(with: $0.range(at: 1)) }
        } else { throw invalid() }
        guard names.count <= 256 else { throw invalid() }
        return Array(Set(names.filter { !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } })).sorted()
    }
    private static func invalid() -> ShouError { ShouError("unsupported_schema", "AI tool configuration could not be summarized.") }
}
