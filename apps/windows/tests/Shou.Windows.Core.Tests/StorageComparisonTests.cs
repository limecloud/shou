using System.Collections.Immutable;

namespace Shou.Windows.Core.Tests;

public sealed class StorageComparisonTests
{
    private static readonly WindowsPath Root = WindowsPath.Parse("C:/Work");
    private static async Task<ScanSnapshot> Scan(MemoryFileSystem fs, int time) =>
        (await new StorageScanner(fs).ScanAsync(Root, new(), null, default)) with { StartedUtc = DateTimeOffset.UnixEpoch.AddMinutes(time) };
    private static MemoryFileSystem Fixture()
    {
        var fs = new MemoryFileSystem(); fs.Add(Root.Value, EntryKind.Directory); fs.Add("C:/Work/data", EntryKind.Directory);
        fs.Add("C:/Work/data/file.bin", allocated: 4096); return fs;
    }

    [Fact]
    public async Task PersistsAndComparesExactIdentityWithoutRescanningOrRewritingRecords()
    {
        var fs = Fixture(); var store = new MemoryRecordStore(); var service = new StorageComparisonService(store);
        var before = await Scan(fs, 0); var file = WindowsPath.Parse("C:/Work/data/file.bin");
        fs.Entries[file.Value] = fs.Entries[file.Value] with { AllocatedBytes = 8192 };
        var after = await Scan(fs, 1); await service.SaveAsync(before, default); await service.SaveAsync(after, default);
        var writes = store.Writes;
        var history = await service.HistoryAsync(after.Id, default); Assert.Equal(before.Id, Assert.Single(history.Candidates).Id);
        var result = await service.CompareAsync(before.Id, after.Id);
        Assert.Equal(4096, result.DeltaBytes); Assert.Equal("increased", Assert.Single(result.Changes).State);
        Assert.Equal(4096, (await service.CompareAsync(before.Id, after.Id, "data")).DeltaBytes);
        Assert.Equal(writes, store.Writes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingOrReplacedObjectsNeverClaimCreationOrDeletion(bool replace)
    {
        var fs = Fixture(); var store = new MemoryRecordStore(); var service = new StorageComparisonService(store); var before = await Scan(fs, 0);
        var path = WindowsPath.Parse("C:/Work/data/file.bin"); var original = fs.Entries[path.Value]; fs.Entries.Remove(path.Value);
        if (replace) fs.Add(path.Value, identity: new(1, new string('F', 32), original.Identity.OwnerSid));
        var after = await Scan(fs, 1); await service.SaveAsync(before, default); await service.SaveAsync(after, default);
        var result = await service.CompareAsync(before.Id, after.Id, "data"); var row = Assert.Single(result.Changes);
        Assert.Equal(replace ? "replaced" : "only_baseline", row.State); Assert.Null(row.DeltaBytes);
    }

    [Fact]
    public async Task IncompleteAndTamperedPagesRemainUnavailableOrWithoutNumericGrowth()
    {
        var fs = Fixture(); var store = new MemoryRecordStore(); var service = new StorageComparisonService(store); var before = await Scan(fs, 0);
        fs.Denied.Add(WindowsPath.Parse("C:/Work/data").Value); var after = await Scan(fs, 1);
        await service.SaveAsync(before, default); await service.SaveAsync(after, default);
        var result = await service.CompareAsync(before.Id, after.Id); Assert.Equal("partial", result.Status); Assert.Null(result.DeltaBytes);
        var page = store.Records.Keys.First(key => key.Contains("_p0_", StringComparison.Ordinal)); store.Records[page][0] ^= 1;
        Assert.Equal("store_corrupt", (await Assert.ThrowsAsync<ShouException>(() => service.CompareAsync(before.Id, after.Id))).Code);
    }

    [Fact]
    public async Task DifferentRootsOrderAndCancellationAreRejected()
    {
        var fs = Fixture(); var store = new MemoryRecordStore(); var service = new StorageComparisonService(store); var before = await Scan(fs, 0);
        var after = await Scan(fs, 1); await service.SaveAsync(before, default); await service.SaveAsync(after, default);
        Assert.Equal("comparison_unavailable", (await Assert.ThrowsAsync<ShouException>(() => service.CompareAsync(after.Id, before.Id))).Code);
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.CompareAsync(before.Id, after.Id, cancellationToken: cancel.Token));
        Assert.Equal("invalid_argument", (await Assert.ThrowsAsync<ShouException>(() => service.CompareAsync(before.Id, before.Id))).Code);
    }
}
