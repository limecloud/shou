using System.Collections.Immutable;
using System.Globalization;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public sealed record StorageRow(WindowsPath Path, string Name, bool IsDirectory,
    long AllocatedBytes, long LogicalBytes, bool IsPartial, long FileCount = 0, DateTimeOffset? ModifiedUtc = null)
{
    public string DisplaySize => FormatBytes(AllocatedBytes);
    public static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
        var value = (double)bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1) { value /= 1024; unit++; }
        return value.ToString(unit == 0 ? "0" : "0.##", CultureInfo.CurrentCulture) + " " + units[unit];
    }
}

public sealed record StoragePage(WindowsPath Directory, int Offset, int Total,
    ImmutableArray<StorageRow> Items)
{
    public bool HasPrevious => Offset > 0;
    public bool HasNext => Offset + Items.Length < Total;
}

public sealed class StorageBrowser
{
    private readonly ScanSnapshot snapshot;
    private readonly Dictionary<WindowsPath, ImmutableArray<StorageRow>> directories = [];
    private readonly ILookup<WindowsPath?, MeasuredEntry> children;
    private readonly HashSet<WindowsPath> knownDirectories;
    private readonly Dictionary<string, (long Allocated, long Logical, long Files)> totals = new(StringComparer.Ordinal);

    public StorageBrowser(ScanSnapshot snapshot)
    {
        this.snapshot = snapshot;
        children = snapshot.Entries.ToLookup(item => item.Entry.Path.Parent);
        knownDirectories = snapshot.Entries.Where(item => item.Entry.Kind == EntryKind.Directory).Select(item => item.Entry.Path).ToHashSet();
        foreach (var item in snapshot.Entries)
        {
            for (WindowsPath? path = item.Entry.Path; path is not null && path.IsWithin(snapshot.Root, caseSensitive: true); path = path.Parent)
            {
                totals.TryGetValue(path.Value, out var existing);
                totals[path.Value] = (checked(existing.Allocated + item.AttributedAllocatedBytes), checked(existing.Logical + item.Entry.LogicalBytes),
                    checked(existing.Files + (item.Entry.Kind == EntryKind.File ? 1 : 0)));
                if (path == snapshot.Root) break;
            }
        }
    }

    public StoragePage GetPage(WindowsPath directory, int offset = 0, int limit = 200)
    {
        if (limit is < 1 or > 500 || offset < 0) throw new ShouException("invalid_argument", "Invalid directory page bounds.");
        if (!knownDirectories.Contains(directory))
            throw new ShouException("not_found", "The directory is not present in this scan.");
        if (!directories.TryGetValue(directory, out var rows))
        {
        rows = children[directory].Select(item =>
        {
            totals.TryGetValue(item.Entry.Path.Value, out var size);
            var partial = snapshot.Issues.Any(issue => issue.Path.IsWithin(item.Entry.Path, caseSensitive: true) ||
                item.Entry.Path.IsWithin(issue.Path, caseSensitive: true));
            return new StorageRow(item.Entry.Path, item.Entry.Path.Name, item.Entry.Kind == EntryKind.Directory,
                size.Allocated, size.Logical, partial, size.Files, item.Entry.LastWriteUtc);
        }).OrderByDescending(row => row.AllocatedBytes).ThenBy(row => row.Path.Value, StringComparer.Ordinal).ToImmutableArray();
        directories[directory] = rows;
        }
        if (offset > rows.Length) throw new ShouException("invalid_argument", "The page offset exceeds the available results.");
        return new(directory, offset, rows.Length, rows.Skip(offset).Take(limit).ToImmutableArray());
    }
}
