using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsAIWorkspace : IAIWorkspaceInspector
{
    private readonly string home;
    private readonly string roaming;
    public WindowsAIWorkspace()
    { home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile); roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData); }
    public Task<AIWorkspaceSnapshot> InspectAsync(string toolId, CancellationToken cancellationToken) => Task.Run(() =>
    {
        (string Kind, string Path, string Format)[] definitions = toolId switch
        {
            "claude-code" => [("configuration", H(".claude/settings.json"), "json"), ("mcp", H(".claude.json"), "json"), ("instructions", H(".claude/CLAUDE.md"), "text"), ("skills", H(".claude/skills"), "directory")],
            "claude-desktop" => [("mcp", System.IO.Path.Combine(roaming, "Claude", "claude_desktop_config.json"), "json")],
            "codex" => [("configuration", H(".codex/config.toml"), "toml"), ("mcp", H(".codex/config.toml"), "toml"), ("instructions", H(".codex/AGENTS.md"), "text"), ("skills", H(".codex/skills"), "directory"), ("skills", H(".agents/skills"), "directory")],
            "gemini" => [("configuration", H(".gemini/settings.json"), "json"), ("mcp", H(".gemini/settings.json"), "json"), ("instructions", H(".gemini/GEMINI.md"), "text"), ("skills", H(".gemini/skills"), "directory")],
            "opencode" => [("configuration", H(".config/opencode/opencode.json"), "json"), ("mcp", H(".config/opencode/opencode.json"), "json"), ("instructions", H(".config/opencode/AGENTS.md"), "text"), ("skills", H(".config/opencode/skills"), "directory")],
            _ => []
        };
        var rows = ImmutableArray.CreateBuilder<AIWorkspaceResource>();
        for (var index = 0; index < definitions.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var (kind, absolute, format) = definitions[index];
            var path = WindowsPath.Parse(absolute);
            try
            {
                ImmutableArray<string> names = [];
                if (format == "directory")
                {
                    using var pinned = WindowsFileSystem.PinPath(path);
                    var root = WindowsFileSystem.ReadEntry(path, pinned.Final);
                    if (root.Kind != EntryKind.Directory) throw new ShouException("unsafe_path", "The AI skills location is not a local directory.");
                    var found = NativeFileHandles.Names(pinned.Final, root.IsCaseSensitive, 256, cancellationToken.ThrowIfCancellationRequested);
                    var skills = new List<string>();
                    foreach (var name in found)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        try
                        {
                            var childPath = path.Append(name);
                            using var child = NativeFileHandles.OpenChild(pinned.Final, childPath, root.IsCaseSensitive);
                            var childEntry = WindowsFileSystem.ReadEntry(childPath, child);
                            if (childEntry.Kind != EntryKind.Directory) continue;
                            var definition = childPath.Append("SKILL.md");
                            using var skill = NativeFileHandles.OpenChild(child, definition, childEntry.IsCaseSensitive);
                            if (WindowsFileSystem.ReadEntry(definition, skill).Kind == EntryKind.File) skills.Add(name);
                        }
                        catch (ShouException) { }
                    }
                    names = skills.Order(StringComparer.Ordinal).ToImmutableArray();
                }
                else
                {
                    var data = WindowsFileSystem.ReadMetadataFile(path, 262_144, false, cancellationToken);
                    if (format != "text") names = AIWorkspaceSummary.Names(data, format, kind);
                }
                rows.Add(new(index.ToString(System.Globalization.CultureInfo.InvariantCulture), kind, absolute, "present", names));
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                var missing = error is ShouException { Code: "not_found" };
                rows.Add(new(index.ToString(System.Globalization.CultureInfo.InvariantCulture), kind, absolute, missing ? "missing" : "unavailable", []));
            }
        }
        return new AIWorkspaceSnapshot(toolId, rows.ToImmutable());
    }, cancellationToken);
    private string H(string relative) => System.IO.Path.Combine(home, relative.Replace('/', System.IO.Path.DirectorySeparatorChar));
}
