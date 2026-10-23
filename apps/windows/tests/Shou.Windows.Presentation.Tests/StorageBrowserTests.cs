using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class StorageBrowserTests
{
    private static readonly WindowsPath Root = WindowsPath.Parse(@"C:\Work");

    private static MeasuredEntry Entry(string path, EntryKind kind, long size) => new(new(WindowsPath.Parse(path),
        new(1, Guid.NewGuid().ToString("N"), "S-1-5-21-1000"), kind, size, size,
        DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch), size);

    private static ScanSnapshot Snapshot(params MeasuredEntry[] entries) => new("scan_fixture", Root,
        new(1, new string('F', 32), "S-1-5-21-1000"), DateTimeOffset.UnixEpoch, ScanState.Complete,
        entries.ToImmutableArray(), ImmutableArray<ScanIssue>.Empty, [Root]);

    [Fact]
    public void AggregatesNestedStorageAndSortsByAllocatedSize()
    {
        var snapshot = Snapshot(Entry(Root.Value, EntryKind.Directory, 0),
            Entry(@"C:\Work\small.bin", EntryKind.File, 10),
            Entry(@"C:\Work\项目", EntryKind.Directory, 0),
            Entry(@"C:\Work\项目\large.bin", EntryKind.File, 2048));
        var browser = new StorageBrowser(snapshot);
        var page = browser.GetPage(Root);
        Assert.Equal(2, page.Total);
        Assert.Equal("项目", page.Items[0].Name);
        Assert.Equal(2048, page.Items[0].AllocatedBytes);
        Assert.Equal("2 KiB", page.Items[0].DisplaySize);
        Assert.Single(browser.GetPage(WindowsPath.Parse(@"C:\Work\项目")).Items);
        Assert.False(page.HasPrevious);
        Assert.False(page.HasNext);
    }

    [Fact]
    public void PaginationHasStableTieBreaksAndBounds()
    {
        var snapshot = Snapshot(Entry(Root.Value, EntryKind.Directory, 0),
            Entry(@"C:\Work\b.bin", EntryKind.File, 10), Entry(@"C:\Work\a.bin", EntryKind.File, 10));
        var browser = new StorageBrowser(snapshot);
        var first = browser.GetPage(Root, limit: 1);
        var second = browser.GetPage(Root, offset: 1, limit: 1);
        Assert.Equal("a.bin", first.Items[0].Name);
        Assert.True(first.HasNext);
        Assert.Equal("b.bin", second.Items[0].Name);
        Assert.True(second.HasPrevious);
        Assert.False(second.HasNext);
        Assert.Throws<ShouException>(() => browser.GetPage(Root, offset: 3));
        Assert.Throws<ShouException>(() => browser.GetPage(Root, limit: 501));
        Assert.Throws<ShouException>(() => browser.GetPage(WindowsPath.Parse(@"C:\Elsewhere")));
    }

    [Fact]
    public void CoverageIsNeverInferredFromSize()
    {
        var snapshot = Snapshot(Entry(Root.Value, EntryKind.Directory, 0), Entry(@"C:\Work\denied", EntryKind.Directory, 0)) with
        {
            State = ScanState.Partial,
            Issues = [new(WindowsPath.Parse(@"C:\Work\denied"), "permission_denied")]
        };
        var row = new StorageBrowser(snapshot).GetPage(Root).Items[0];
        Assert.True(row.IsPartial);
        Assert.Equal(0, row.AllocatedBytes);
    }
}
