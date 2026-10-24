using System.Collections.Immutable;

namespace Shou.Windows.Core;

/// <summary>One observation, indexed once per request. This is not an authorization cache.</summary>
internal sealed class FileTreeIndex
{
    internal Dictionary<WindowsPath, FileEntry> Entries { get; }
    internal Dictionary<WindowsPath, FileEntry[]> Children { get; }
    internal HashSet<FileIdentity> DuplicateFiles { get; }
    internal HashSet<WindowsPath> CompletedDirectories { get; }

    internal FileTreeIndex(ScanSnapshot scan)
    {
        Entries = scan.Entries.ToDictionary(item => item.Entry.Path, item => item.Entry);
        Children = Entries.Values.Where(entry => entry.Path != scan.Root).GroupBy(entry => entry.Path.Parent!)
            .ToDictionary(group => group.Key, group => group.OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).ToArray());
        DuplicateFiles = Entries.Values.Where(entry => entry.Kind == EntryKind.File).GroupBy(entry => entry.Identity)
            .Where(group => group.Count() > 1).Select(group => group.Key).ToHashSet();
        CompletedDirectories = scan.CompletedDirectories.ToHashSet();
    }

    internal ImmutableArray<FileEntry> Manifest(WindowsPath path)
    {
        var result = ImmutableArray.CreateBuilder<FileEntry>();
        var pending = new Stack<WindowsPath>();
        pending.Push(path);
        while (pending.TryPop(out var current))
        {
            if (!Entries.TryGetValue(current, out var entry)) throw new ShouException("invalid_snapshot", "Directory case evidence is missing.");
            result.Add(entry);
            if (Children.TryGetValue(current, out var children))
                for (var index = children.Length - 1; index >= 0; index--) pending.Push(children[index].Path);
        }
        // Ordinal path order differs from depth-first order for names containing punctuation.
        return result.OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    }
}
