using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

/// <summary>Layout evidence only. Current Git ownership and activity are checked independently before each mutation.</summary>
internal static class RustArtifactPolicy
{
    internal const string RuleId = "shou.builtin.rust-target";
    private static readonly HashSet<string> SourceExtensions = new(StringComparer.OrdinalIgnoreCase)
    { ".rs", ".c", ".cc", ".cpp", ".h", ".hpp" };

    internal static bool IsGeneratedSource(FileEntry target, FileEntry source, IReadOnlyDictionary<WindowsPath, FileEntry> entries)
    {
        if (source.Kind != EntryKind.File || target.Path.Name != "target" || target.Path.Parent is not { } project ||
            !SourceExtensions.Contains(PathExtension(source.Path.Name)) ||
            !Is(project.Append("Cargo.toml"), EntryKind.File) || !Is(target.Path.Append("CACHEDIR.TAG"), EntryKind.File) ||
            !Is(target.Path.Append(".rustc_info.json"), EntryKind.File)) return false;
        var parts = source.Path.RelativeTo(target.Path, caseSensitive: true).Split('/');
        var offset = parts[0] is "debug" or "release" ? 0 : 1;
        if (parts.Length <= offset + 4 || parts[offset] is not ("debug" or "release") || parts[offset + 1] != "build" ||
            parts[offset + 3] != "out" ||
            !Regex.IsMatch(parts[offset + 2], "^[A-Za-z0-9_-]+-[0-9a-fA-F]{8,64}$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)) return false;
        return Is(target.Path.Append(string.Join('/', parts.Take(offset + 1)) + "/.fingerprint"), EntryKind.Directory);

        bool Is(WindowsPath path, EntryKind kind) => entries.TryGetValue(path, out var entry) && entry.Kind == kind;
    }

    private static string PathExtension(string name) => name.LastIndexOf('.') is var index && index >= 0 ? name[index..] : "";
}
