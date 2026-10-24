using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class StorageAnalysisTests
{
    private static readonly WindowsPath Root = WindowsPath.Parse("C:/Generated");
    private static MeasuredEntry Entry(string name, long allocated, EntryKind kind = EntryKind.File, long? attributed = null) =>
        new(new(Root.Append(name), new(1, Guid.NewGuid().ToString("N"), "S-1-5-21-1000"), kind, allocated, allocated,
            DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch), attributed ?? allocated);
    private static ScanSnapshot Snapshot(params MeasuredEntry[] rows) => new("scan_fixture", Root,
        new(1, new string('a', 32), "S-1-5-21-1000"), DateTimeOffset.UnixEpoch, ScanState.Complete,
        new[] { new MeasuredEntry(new(Root, new(1, new string('b', 32), "S-1-5-21-1000"), EntryKind.Directory, 0, 0, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch), 0) }.Concat(rows).ToImmutableArray(), [], [Root]);

    [Fact]
    public void ExtensionTotalsUseAttributedBytesAndCurrentDirectory()
    {
        var snapshot = Snapshot(Entry("a.JSON", 40), Entry("linked.json", 40, attributed: 0),
            Entry("nested", 0, EntryKind.Directory), Entry("nested/b.json", 60), Entry("nested/no-extension", 20));
        var analysis = new StorageAnalysis(snapshot);
        var types = analysis.Extensions(Root);
        Assert.Equal(100, types.Single(row => row.Extension == ".json").AllocatedBytes);
        Assert.Equal(3, types.Single(row => row.Extension == ".json").Count);
        Assert.Equal(80, analysis.Extensions(Root.Append("nested")).Sum(row => row.AllocatedBytes));
        Assert.Equal(120, analysis.Directory(Root).Sum(row => row.AllocatedBytes));
    }

    [Theory]
    [InlineData(".env", "")]
    [InlineData("ending.", "")]
    [InlineData("a.tar.GZ", ".gz")]
    [InlineData("file", "")]
    public void ExtensionNamesDoNotTreatDotFilesAsSuffixes(string name, string expected) =>
        Assert.Equal(expected, StorageAnalysis.Extension(name));

    [Fact]
    public void LargeFilesPreserveCoverageAndStableOrderingWithoutDirectories()
    {
        var snapshot = Snapshot(Entry("folder", 100, EntryKind.Directory), Entry("b.bin", 20), Entry("a.bin", 20)) with
        { State = ScanState.Partial, Issues = [new(Root.Append("a.bin"), "permission_denied")] };
        var rows = new StorageAnalysis(snapshot).LargeFiles(".BIN");
        Assert.Equal(new[] { "a.bin", "b.bin" }, rows.Select(row => row.Name));
        Assert.True(rows[0].IsPartial); Assert.False(rows[1].IsPartial);
    }

    [Fact]
    public void DirectoryProjectionRetainsAllPages()
    {
        var analysis = new StorageAnalysis(Snapshot(Enumerable.Range(0, 1100).Select(index => Entry($"file-{index:d4}", index)).ToArray()));
        Assert.Equal(1100, analysis.Directory(Root).Length);
        Assert.Equal(1099, analysis.Directory(Root)[0].AllocatedBytes);
    }

    [Fact]
    public void MapAggregationConservesBytesAndProvidesExplicitOtherGroup()
    {
        var rows = Enumerable.Range(1, 300).Select(index => new StorageRow(Root.Append("f" + index), "f" + index, false, index, index, false));
        var map = StorageAnalysis.MapItems(rows, 16);
        Assert.Equal(16, map.Length); Assert.Null(map[^1].Path);
        Assert.Equal(45150, map.Sum(row => row.Bytes));
    }

    [Theory]
    [InlineData(800, 300)]
    [InlineData(300, 800)]
    public void MapTilesFillBoundsProportionallyWithoutOverlap(double width, double height)
    {
        var items = Enumerable.Range(1, 100).Select(index => new StorageMapItem(Root.Append("f" + index), "f", index)).ToImmutableArray();
        var tiles = StorageAnalysis.Layout(items, width, height);
        Assert.Equal(items.Length, tiles.Length);
        foreach (var tile in tiles)
        {
            Assert.True(tile.X >= 0 && tile.Y >= 0 && tile.X + tile.Width <= width + 1e-8 && tile.Y + tile.Height <= height + 1e-8);
            Assert.Equal(tile.Item.Bytes / 5050d, tile.Width * tile.Height / (width * height), 8);
        }
        for (var a = 0; a < tiles.Length; a++)
            for (var b = a + 1; b < tiles.Length; b++)
                Assert.True(Math.Min(tiles[a].X + tiles[a].Width, tiles[b].X + tiles[b].Width) - Math.Max(tiles[a].X, tiles[b].X) < 1e-8 ||
                    Math.Min(tiles[a].Y + tiles[a].Height, tiles[b].Y + tiles[b].Height) - Math.Max(tiles[a].Y, tiles[b].Y) < 1e-8);
    }

    [Fact]
    public void InvalidMapBoundsAndZeroMeasurementsDoNotProduceTiles()
    {
        Assert.Empty(StorageAnalysis.Layout([new(null, "empty", 0)], 100, 100));
        Assert.Empty(StorageAnalysis.Layout([new(null, "measured", 10)], double.NaN, 100));
    }

    [Fact]
    public void NestedMapKeepsDescendantsInsideTheirMeasuredParent()
    {
        var analysis = new StorageAnalysis(Snapshot(Entry("folder", 0, EntryKind.Directory), Entry("folder/a.json", 60), Entry("folder/b.bin", 40), Entry("outside.bin", 100)));
        var tiles = analysis.NestedMap(analysis.Directory(Root), 800, 300);
        var parent = tiles.Single(value => value.Row?.Path == Root.Append("folder")).Tile;
        Assert.Equal(2, tiles.Count(value => value.Depth == 0));
        Assert.Equal(2, tiles.Count(value => value.Depth == 1));
        foreach (var child in tiles.Where(value => value.Depth == 1).Select(value => value.Tile))
        {
            Assert.True(child.X >= parent.X && child.Y >= parent.Y + 18);
            Assert.True(child.X + child.Width <= parent.X + parent.Width && child.Y + child.Height <= parent.Y + parent.Height);
        }
        Assert.Equal(800 * 300, tiles.Where(value => value.Depth == 0).Sum(value => value.Tile.Width * value.Tile.Height), 6);
    }
}
