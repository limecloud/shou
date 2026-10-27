using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

// Configuration values, arguments, environment variables and credentials are never exposed.
public sealed record AIWorkspaceResource(string Id, string Kind, string Path, string State, ImmutableArray<string> Names);
public sealed record AIWorkspaceSnapshot(string ToolId, ImmutableArray<AIWorkspaceResource> Resources);
public interface IAIWorkspaceInspector
{
    Task<AIWorkspaceSnapshot> InspectAsync(string toolId, CancellationToken cancellationToken);
}
public static class AIWorkspaceSummary
{
    public static bool Supports(string id) => id is "claude-code" or "claude-desktop" or "codex" or "gemini" or "opencode";
    public static ImmutableArray<string> Names(ReadOnlyMemory<byte> data, string format, string kind)
    {
        if (data.Length > 262_144) throw Invalid();
        IEnumerable<string> names;
        if (format == "json")
        {
            using var json = JsonDocument.Parse(data, new JsonDocumentOptions { MaxDepth = 64 });
            if (json.RootElement.ValueKind != JsonValueKind.Object) throw Invalid();
            var keys = kind == "mcp" ? new[] { "mcpServers", "mcp" } : ["provider", "providers"];
            names = keys.SelectMany(key => json.RootElement.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Object ? value.EnumerateObject().Select(p => p.Name).ToArray() : []).ToArray();
        }
        else if (format == "toml")
        {
            var value = new UTF8Encoding(false, true).GetString(data.Span);
            if (value.Contains("\"\"\"", StringComparison.Ordinal) || value.Contains("'''", StringComparison.Ordinal)) throw Invalid();
            var section = kind == "mcp" ? "mcp_servers" : "model_providers";
            names = Regex.Matches(value, @"(?m)^\s*\[" + section + @"\.([A-Za-z0-9_-]{1,128})\]\s*(?:#[^\r\n]*)?$", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)).Select(m => m.Groups[1].Value).ToArray();
        }
        else throw Invalid();
        var result = names.ToArray();
        if (result.Length > 256) throw Invalid();
        return result.Where(n => n.Length > 0 && Encoding.UTF8.GetByteCount(n) <= 128 && !n.Any(char.IsControl)).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray();
    }
    private static ShouException Invalid() => new("unsupported_schema", "AI tool configuration could not be summarized.");
}
