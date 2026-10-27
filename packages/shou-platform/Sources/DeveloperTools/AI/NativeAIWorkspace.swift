import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativeAIWorkspace: AIWorkspaceInspecting {
    private let home: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { home=homeDirectory }
    public func inspect(toolID: String) throws -> AIWorkspaceSnapshot {
        #if os(macOS)
        let definitions: [(String,String,String)]
        switch toolID {
        case "claude-code": definitions=[("configuration", ".claude/settings.json", "json"), ("mcp", ".claude.json", "json"), ("instructions", ".claude/CLAUDE.md", "text"), ("skills", ".claude/skills", "directory")]
        case "claude-desktop": definitions=[("mcp", "Library/Application Support/Claude/claude_desktop_config.json", "json")]
        case "codex": definitions=[("configuration", ".codex/config.toml", "toml"), ("mcp", ".codex/config.toml", "toml"), ("instructions", ".codex/AGENTS.md", "text"), ("skills", ".codex/skills", "directory"), ("skills", ".agents/skills", "directory")]
        case "gemini": definitions=[("configuration", ".gemini/settings.json", "json"), ("mcp", ".gemini/settings.json", "json"), ("instructions", ".gemini/GEMINI.md", "text"), ("skills", ".gemini/skills", "directory")]
        case "opencode": definitions=[("configuration", ".config/opencode/opencode.json", "json"), ("mcp", ".config/opencode/opencode.json", "json"), ("instructions", ".config/opencode/AGENTS.md", "text"), ("skills", ".config/opencode/skills", "directory")]
        default: return .init(toolID: toolID, resources: [])
        }
        var rows=[AIWorkspaceResource]()
        for (index,definition) in definitions.enumerated() {
            try Task.checkCancellation()
            let (kind,relative,format)=definition, url=home.appendingPathComponent(relative)
            var metadata=stat()
            if lstat(url.path, &metadata) != 0 {
                rows.append(.init(id: String(index), kind: kind, path: url.path, state: errno == ENOENT ? "missing" : "unavailable")); continue
            }
            do {
                if format == "directory" {
                    let descriptor=try SecurePaths.directory(url.path); defer { close(descriptor) }
                    let items=try NativeDefinitionFiles.names(descriptor, limit: 256, deadline: .now.advanced(by: .seconds(3)))
                    var names=[String]()
                    for name in items.names {
                        let child=openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { continue }; defer { close(child) }
                        var entry=stat()
                        if fstatat(child, "SKILL.md", &entry, AT_SYMLINK_NOFOLLOW) == 0, entry.st_mode & S_IFMT == S_IFREG { names.append(name) }
                    }
                    rows.append(.init(id: String(index), kind: kind, path: url.path, state: items.truncated ? "partial" : "present", names: names))
                } else {
                    let (parent,name)=try SecurePaths.parent(url.path); defer { close(parent) }
                    let data=try NativeDefinitionFiles.bytes(directory: parent, name: name, path: url.path, deadline: .now.advanced(by: .seconds(3)))
                    let names = format == "text" ? [] : try AIWorkspaceSummary.names(data: data, format: format, kind: kind)
                    rows.append(.init(id: String(index), kind: kind, path: url.path, state: "present", names: names))
                }
            } catch { rows.append(.init(id: String(index), kind: kind, path: url.path, state: "unavailable")) }
        }
        return .init(toolID: toolID, resources: rows)
        #else
        throw ShouError("unsupported_capability", "AI workspace discovery requires macOS.")
        #endif
    }
}
