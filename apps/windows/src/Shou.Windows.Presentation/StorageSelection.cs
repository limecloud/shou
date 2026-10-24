using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

/// <summary>Measured review selection only. This object cannot prepare or execute removal.</summary>
public sealed class StorageSelection(WindowsPath root)
{
    private readonly Dictionary<WindowsPath, StorageRow> selected = [];
    public ImmutableArray<StorageRow> Items => selected.Values.OrderBy(row => row.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    public int Count => selected.Count;
    public long AllocatedBytes => selected.Values.Sum(row => row.AllocatedBytes);
    public bool Contains(WindowsPath path) => selected.Keys.Any(parent => path.IsWithin(parent, caseSensitive: true));
    public bool HasDescendant(WindowsPath path) => selected.Keys.Any(child => child != path && child.IsWithin(path, caseSensitive: true));
    public bool CanSelect(StorageRow row) => !row.IsPartial && row.Path != root && row.Path.IsWithin(root, caseSensitive: true);
    public void Set(StorageRow row, bool value)
    {
        if (value && !CanSelect(row)) return;
        foreach (var path in selected.Keys.Where(path => path.IsWithin(row.Path, caseSensitive: true) || row.Path.IsWithin(path, caseSensitive: true)).ToArray())
            selected.Remove(path);
        if (value) selected[row.Path] = row;
    }
    public void Clear() => selected.Clear();
}
