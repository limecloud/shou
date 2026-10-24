using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public sealed record StorageExtension(string Extension, long AllocatedBytes, int Count, long LogicalBytes = 0)
{
    public string DisplaySize => StorageRow.FormatBytes(AllocatedBytes);
}
public sealed record StorageMapItem(WindowsPath? Path, string Name, long Bytes);
public sealed record StorageMapTile(StorageMapItem Item, double X, double Y, double Width, double Height);
public sealed record StorageNestedTile(StorageMapTile Tile, StorageRow? Row, int Depth);

/// <summary>Read-only projections of measured data; map areas never imply cleanup eligibility.</summary>
public sealed class StorageAnalysis(ScanSnapshot snapshot)
{
    private readonly StorageBrowser browser = new(snapshot);
    public ImmutableArray<StorageRow> Directory(WindowsPath path)
    {
        var first = browser.GetPage(path, limit: 500);
        var rows = first.Items.ToBuilder();
        while (rows.Count < first.Total) rows.AddRange(browser.GetPage(path, rows.Count, 500).Items);
        return rows.ToImmutable();
    }
    public ImmutableArray<StorageRow> LargeFiles(string query = "") => snapshot.Entries.Where(item => item.Entry.Kind == EntryKind.File &&
            item.Entry.Path.Name.Contains(query, StringComparison.OrdinalIgnoreCase))
        .Select(item => new StorageRow(item.Entry.Path, item.Entry.Path.Name, false, item.AttributedAllocatedBytes, item.Entry.LogicalBytes,
            snapshot.Issues.Any(issue => item.Entry.Path.IsWithin(issue.Path, caseSensitive: true)), 1, item.Entry.LastWriteUtc))
        .OrderByDescending(row => row.AllocatedBytes).ThenBy(row => row.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    public ImmutableArray<StorageExtension> Extensions(WindowsPath path) => snapshot.Entries.Where(item => item.Entry.Kind == EntryKind.File && item.Entry.Path.IsWithin(path, caseSensitive: true))
        .GroupBy(item => Extension(item.Entry.Path.Name), StringComparer.OrdinalIgnoreCase)
        .Select(group => new StorageExtension(group.Key, group.Sum(item => item.AttributedAllocatedBytes), group.Count(), group.Sum(item => item.Entry.LogicalBytes)))
        .OrderByDescending(row => row.AllocatedBytes).ThenBy(row => row.Extension, StringComparer.Ordinal).ToImmutableArray();
    public static string Extension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? "" : name[dot..].ToLowerInvariant();
    }
    public static ImmutableArray<StorageMapItem> MapItems(IEnumerable<StorageRow> rows, int maximum = 128)
    {
        if (maximum < 2) throw new ArgumentOutOfRangeException(nameof(maximum));
        var measured = rows.Where(row => row.AllocatedBytes > 0).OrderByDescending(row => row.AllocatedBytes).ToArray();
        var result = measured.Take(maximum - 1).Select(row => new StorageMapItem(row.Path, row.Name, row.AllocatedBytes)).ToList();
        var remainder = measured.Skip(maximum - 1).Sum(row => row.AllocatedBytes);
        if (remainder > 0) result.Add(new(null, "Other Entries", remainder));
        return result.ToImmutableArray();
    }
    public static ImmutableArray<StorageMapTile> Layout(ImmutableArray<StorageMapItem> items, double width, double height)
    {
        if (!double.IsFinite(width) || !double.IsFinite(height) || width <= 0 || height <= 0) return [];
        var values = items.Where(item => item.Bytes > 0).ToArray();
        var tiles = ImmutableArray.CreateBuilder<StorageMapTile>();
        Split(0, values.Length, 0, 0, width, height);
        return tiles.ToImmutable();

        void Split(int start, int count, double x, double y, double w, double h)
        {
            if (count == 0) return;
            if (count == 1) { tiles.Add(new(values[start], x, y, w, h)); return; }
            var total = values.Skip(start).Take(count).Sum(item => (double)item.Bytes);
            var half = 0d;
            var left = 0;
            while (left < count - 1 && (left == 0 || half < total / 2)) half += values[start + left++].Bytes;
            var fraction = half / total;
            if (w >= h) { Split(start, left, x, y, w * fraction, h); Split(start + left, count - left, x + w * fraction, y, w * (1 - fraction), h); }
            else { Split(start, left, x, y, w, h * fraction); Split(start + left, count - left, x, y + h * fraction, w, h * (1 - fraction)); }
        }
    }

    public ImmutableArray<StorageNestedTile> NestedMap(IEnumerable<StorageRow> rows, double width, double height)
    {
        const int maximumTiles = 512;
        var result = ImmutableArray.CreateBuilder<StorageNestedTile>();
        Draw(rows.ToImmutableArray(), 0, 0, width, height, 0, 0);
        return result.ToImmutable();

        void Draw(ImmutableArray<StorageRow> children, double x, double y, double w, double h, int depth, int reserved)
        {
            var tiles = Layout(MapItems(children, 32), w, h);
            var remaining = tiles.Length;
            foreach (var tile in tiles)
            {
                remaining--;
                var row = children.FirstOrDefault(value => value.Path == tile.Item.Path);
                var positioned = tile with { X = x + tile.X, Y = y + tile.Y };
                result.Add(new(positioned, row, depth));
                // The parent remains visible if its descendants exceed the visual budget.
                if (row?.IsDirectory == true && depth < 5 && tile.Width >= 80 && tile.Height >= 50 && result.Count + reserved + remaining + 32 <= maximumTiles)
                    Draw(Directory(row.Path), positioned.X + 2, positioned.Y + 18, tile.Width - 4, tile.Height - 20, depth + 1, reserved + remaining);
            }
        }
    }
}
