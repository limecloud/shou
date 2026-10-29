using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class StorageScannerTests
{
    private sealed class ProgressClock : TimeProvider
    {
        public long Timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Timestamp;
    }
    private sealed class ScanObserver(Action<ScanProgress> action) : IProgress<ScanProgress>
    {
        public void Report(ScanProgress value) => action(value);
    }
    private static readonly WindowsPath Root = WindowsPath.Parse(@"C:\Work");
    private static MemoryFileSystem Fixture(bool caseSensitive = false)
    {
        var fs = new MemoryFileSystem();
        fs.Add(Root.Value, EntryKind.Directory, caseSensitive: caseSensitive);
        return fs;
    }

    [Fact]
    public async Task MeasuresUnicodeAndDeduplicatesHardLinkAllocation()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\项目", EntryKind.Directory);
        var file = fs.Add(@"C:\Work\项目\a.bin", bytes: 12);
        fs.Add(@"C:\Work\b.bin", bytes: 12, identity: file.Identity);
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.Equal(ScanState.Complete, result.State);
        Assert.Equal(4, result.Entries.Length);
        Assert.Equal(24, result.LogicalBytes);
        Assert.Equal(4096, result.AllocatedBytes);
        Assert.Empty(result.Issues);
    }

    [Fact]
    public async Task DoesNotTraverseReparsePointsOrCrossVolumes()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\junction", EntryKind.ReparsePoint);
        fs.Add(@"C:\Work\junction\secret.bin");
        fs.Add(@"C:\Work\mount", EntryKind.Directory, identity: new(2, new string('F', 32), "S-1-5-21-1000"));
        fs.Add(@"C:\Work\mount\secret.bin");
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Equal([Root.Value], fs.Enumerated);
        Assert.DoesNotContain(result.Entries, item => item.Entry.Path.Name == "secret.bin");
        Assert.Contains(result.Issues, issue => issue.Code == "unsupported_entry");
        Assert.Contains(result.Issues, issue => issue.Code == "unsupported_metadata");
    }

    [Fact]
    public async Task PermissionFailureRetainsMeasuredSiblingsAsPartial()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\denied", EntryKind.Directory);
        fs.Denied.Add(@"C:\Work\denied");
        fs.Add(@"C:\Work\retained.bin");
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.False(result.IsComplete);
        Assert.Contains(result.Issues, issue => issue.Code == "permission_denied");
        Assert.Contains(result.Entries, item => item.Entry.Path.Name == "retained.bin");
    }

    [Fact]
    public async Task PartialSiblingsDoNotErasePositiveCoverageOfACompletedTarget()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\target", EntryKind.Directory);
        fs.Add(@"C:\Work\target\generated.bin");
        fs.Add(@"C:\Work\unreadable", EntryKind.Directory);
        fs.Denied.Add(@"C:\Work\unreadable");
        var snapshot = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.False(snapshot.IsComplete);
        Assert.True(snapshot.IsCompleteAt(WindowsPath.Parse(@"C:\Work\target")));
        Assert.False(snapshot.IsCompleteAt(Root));
        Assert.False(snapshot.IsCompleteAt(WindowsPath.Parse(@"C:\Work\unreadable")));
    }

    [Fact]
    public async Task DescendantReplacementAndBudgetTruncationCannotProvideTargetCoverage()
    {
        var fs = Fixture();
        var target = fs.Add(@"C:\Work\target", EntryKind.Directory);
        var file = fs.Add(@"C:\Work\target\changing.bin");
        fs.OnInspect = entry => entry.Path == file.Path ? entry with { LogicalBytes = 30 } : entry;
        var snapshot = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.Contains(snapshot.Issues, issue => issue.Code == "entry_changed");
        Assert.False(snapshot.IsCompleteAt(target.Path));
        fs.OnInspect = null;
        snapshot = await new StorageScanner(fs).ScanAsync(Root, new(MaxEntries: 2), null, default);
        Assert.False(snapshot.IsCompleteAt(target.Path));
        Assert.False(snapshot.IsCompleteAt(Root));
    }

    [Fact]
    public async Task UnreadableFilePreservesOtherFilesAndItsOwnCoverageIssue()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\a.bin");
        fs.Add(@"C:\Work\locked.bin");
        fs.Unavailable.Add(@"C:\Work\locked.bin", "active_or_inaccessible");
        fs.Add(@"C:\Work\z.bin");
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.False(result.IsComplete);
        Assert.Equal(3, result.Entries.Length);
        Assert.Contains(result.Issues, issue => issue.Path.Name == "locked.bin" && issue.Code == "active_or_inaccessible");
    }

    [Fact]
    public async Task UnavailableEntriesStillConsumeTheEntryBudget()
    {
        var fs = Fixture();
        for (var index = 0; index < 20; index++)
        {
            var entry = fs.Add($@"C:\Work\{index}.bin");
            fs.Unavailable[entry.Path.Value] = "permission_denied";
        }
        var result = await new StorageScanner(fs).ScanAsync(Root, new(MaxEntries: 3), null, default);
        Assert.Single(result.Entries);
        Assert.Equal(3, result.Issues.Length);
        Assert.Contains(result.Issues, issue => issue.Code == "entry_limit");
    }

    [Fact]
    public async Task EntryLimitIsExplicitAndBounded()
    {
        var fs = Fixture();
        for (var index = 0; index < 20; index++) fs.Add($@"C:\Work\{index}.bin");
        var result = await new StorageScanner(fs).ScanAsync(Root, new(MaxEntries: 3), null, default);
        Assert.Equal(3, result.Entries.Length);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Contains(result.Issues, issue => issue.Code == "entry_limit");
    }

    [Fact]
    public async Task EmptyRootAtExactEntryLimitIsComplete()
    {
        var result = await new StorageScanner(Fixture()).ScanAsync(Root, new(MaxEntries: 1), null, default);
        Assert.True(result.IsComplete);
        Assert.Single(result.Entries);
    }

    [Fact]
    public async Task DepthLimitCannotBeReportedAsComplete()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\nested", EntryKind.Directory);
        fs.Add(@"C:\Work\nested\not-read.bin");
        var result = await new StorageScanner(fs).ScanAsync(Root, new(MaxDepth: 1), null, default);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Contains(result.Issues, issue => issue.Code == "depth_limit");
        Assert.DoesNotContain(result.Entries, item => item.Entry.Path.Name == "not-read.bin");
    }

    [Fact]
    public async Task DirectoryReplacementInvalidatesItsEnumeration()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\untrusted.bin");
        var inspections = 0;
        fs.OnInspect = entry => ++inspections == 1 ? entry : entry with { ChangeUtc = entry.ChangeUtc.AddSeconds(1) };
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.False(result.IsComplete);
        Assert.Single(result.Entries);
        Assert.Contains(result.Issues, issue => issue.Code == "directory_changed");
    }

    [Fact]
    public async Task RejectsOutOfDirectoryMetadata()
    {
        var fs = Fixture();
        fs.InjectedChildren.Add(fs.Add(@"C:\Outside\secret.bin"));
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.False(result.IsComplete);
        Assert.Single(result.Entries);
        Assert.Contains(result.Issues, issue => issue.Code == "invalid_directory_entry");
    }

    [Theory]
    [InlineData(false, 2, ScanState.Partial)]
    [InlineData(true, 3, ScanState.Complete)]
    public async Task UsesDirectorySpecificCaseSemantics(bool sensitive, int count, ScanState expected)
    {
        var fs = Fixture(sensitive);
        fs.Add(@"C:\Work\a.bin");
        fs.Add(@"C:\Work\A.bin");
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.Equal(expected, result.State);
        Assert.Equal(count, result.Entries.Length);
    }

    [Fact]
    public async Task CancellationReturnsOnlyObservedEntries()
    {
        var fs = Fixture();
        using var cancellation = new CancellationTokenSource();
        fs.BeforeRead = (_, _) => { cancellation.Cancel(); return Task.CompletedTask; };
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, cancellation.Token);
        Assert.Equal(ScanState.Cancelled, result.State);
        Assert.Single(result.Entries);
        Assert.Contains(result.Issues, issue => issue.Code == "cancelled");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ProgressIsBoundedAndFinishesWithTheExactObservedCount(bool advanceTime)
    {
        var fs = Fixture();
        for (var index = 0; index < 4096; index++) fs.Add($@"C:\Work\generated-{index:D4}.bin");
        var clock = new ProgressClock();
        fs.OnInspect = entry =>
        {
            if (advanceTime && entry.Kind == EntryKind.File) clock.Timestamp += TimeSpan.FromMilliseconds(5).Ticks;
            return entry;
        };
        var updates = new List<(ScanProgress Value, long Timestamp)>();
        var result = await new StorageScanner(fs, clock).ScanAsync(Root, new(),
            new ScanObserver(value => updates.Add((value, clock.Timestamp))), default);
        Assert.Equal(ScanState.Complete, result.State);
        Assert.Equal(4097, result.Entries.Length);
        Assert.Equal(1, updates[0].Value.MeasuredEntries);
        Assert.Equal(result.Entries.Length, updates[^1].Value.MeasuredEntries);
        Assert.Equal(updates.Select(item => item.Value.MeasuredEntries).Distinct().Order(), updates.Select(item => item.Value.MeasuredEntries));
        if (!advanceTime) Assert.Equal(2, updates.Count);
        else
        {
            Assert.InRange(updates.Count, 3, 84);
            for (var index = 1; index < updates.Count - 1; index++)
                Assert.True(clock.GetElapsedTime(updates[index - 1].Timestamp, updates[index].Timestamp) >= TimeSpan.FromMilliseconds(250));
        }
    }

    [Fact]
    public async Task ProgressConsumerFailureDoesNotDiscardACompleteScan()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\retained.bin");
        var snapshot = await new StorageScanner(fs).ScanAsync(Root, new(),
            new ScanObserver(_ => throw new InvalidOperationException("Generated observer failure.")), default);
        Assert.Equal(ScanState.Complete, snapshot.State);
        Assert.Equal(2, snapshot.Entries.Length);
        Assert.True(snapshot.IsCompleteAt(Root));
    }

    [Fact]
    public async Task TimeLimitCancelsBlockedEnumeration()
    {
        var fs = Fixture();
        fs.BeforeRead = (_, token) => Task.Delay(Timeout.InfiniteTimeSpan, token);
        var result = await new StorageScanner(fs).ScanAsync(Root, new(MaxDuration: TimeSpan.FromMilliseconds(40)), null, default);
        Assert.Equal(ScanState.Partial, result.State);
        Assert.Contains(result.Issues, issue => issue.Code == "time_limit");
    }

    [Fact]
    public async Task RefusesReparseRoot()
    {
        var fs = new MemoryFileSystem();
        fs.Add(Root.Value, EntryKind.ReparsePoint);
        var error = await Assert.ThrowsAsync<ShouException>(() => new StorageScanner(fs).ScanAsync(Root, new(), null, default));
        Assert.Equal("unsupported_location", error.Code);
        Assert.Empty(fs.Enumerated);
    }

    [Fact]
    public async Task RepeatedDirectoryIdentityDoesNotRecurse()
    {
        var fs = Fixture();
        fs.Add(@"C:\Work\cycle", EntryKind.Directory, identity: fs.Entries[Root.Value].Identity);
        var result = await new StorageScanner(fs).ScanAsync(Root, new(), null, default);
        Assert.False(result.IsComplete);
        Assert.Single(fs.Enumerated);
        Assert.Contains(result.Issues, issue => issue.Code == "duplicate_directory_identity");
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(1, 0)]
    [InlineData(1_000_001, 1)]
    [InlineData(1, 65)]
    public async Task RejectsInvalidBudgets(int entries, int depth) =>
        await Assert.ThrowsAsync<ShouException>(() => new StorageScanner(Fixture()).ScanAsync(Root, new(entries, depth), null, default));
}
