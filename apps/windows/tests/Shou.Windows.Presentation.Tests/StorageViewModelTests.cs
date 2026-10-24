using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class StorageViewModelTests
{
    private static readonly WindowsPath Root = WindowsPath.Parse(@"C:\Work");
    private static ScanSnapshot Snapshot(ScanState state) => new("scan_fixture", Root,
        new(1, new string('1', 32), "S-1-5-21-1000"), DateTimeOffset.UnixEpoch,
        state, ImmutableArray<MeasuredEntry>.Empty, ImmutableArray<ScanIssue>.Empty, []);

    private sealed class Scanner : IStorageScanner
    {
        public Queue<TaskCompletionSource<ScanSnapshot>> Calls { get; } = new();
        public List<CancellationToken> Tokens { get; } = [];
        public List<IProgress<ScanProgress>?> Progress { get; } = [];
        public Task<ScanSnapshot> ScanAsync(WindowsPath root, ScanBudget budget,
            IProgress<ScanProgress>? progress, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken); Progress.Add(progress);
            var call = new TaskCompletionSource<ScanSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
            Calls.Enqueue(call);
            return call.Task;
        }
    }

    [Theory]
    [InlineData(ScanState.Complete, StoragePageState.Ready)]
    [InlineData(ScanState.Partial, StoragePageState.Partial)]
    [InlineData(ScanState.Cancelled, StoragePageState.Cancelled)]
    public async Task PresentsActualCoverage(ScanState result, StoragePageState page)
    {
        var scanner = new Scanner();
        using var model = new StorageViewModel(scanner);
        var task = model.ScanAsync(Root);
        Assert.True(model.IsBusy);
        scanner.Calls.Dequeue().SetResult(Snapshot(result));
        await task;
        Assert.False(model.IsBusy);
        Assert.Equal(page, model.State);
        Assert.Equal(result, model.Snapshot!.State);
    }

    [Fact]
    public async Task SupersededResultCannotOverwriteNewScan()
    {
        var scanner = new Scanner();
        using var model = new StorageViewModel(scanner);
        var first = model.ScanAsync(Root);
        var old = scanner.Calls.Dequeue();
        var second = model.ScanAsync(Root);
        var current = scanner.Calls.Dequeue();
        Assert.True(scanner.Tokens[0].IsCancellationRequested);
        current.SetResult(Snapshot(ScanState.Complete));
        await second;
        old.SetResult(Snapshot(ScanState.Partial));
        await first;
        Assert.Equal(StoragePageState.Ready, model.State);
        Assert.True(model.Snapshot!.IsComplete);
    }

    [Fact]
    public async Task CancelSignalsCurrentScanAndRetainsCancellationState()
    {
        var scanner = new Scanner();
        using var model = new StorageViewModel(scanner);
        var task = model.ScanAsync(Root);
        model.Cancel();
        Assert.True(scanner.Tokens[0].IsCancellationRequested);
        scanner.Calls.Dequeue().SetCanceled(scanner.Tokens[0]);
        await task;
        Assert.Equal(StoragePageState.Cancelled, model.State);
        Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task ErrorDoesNotExposeRawExceptionText()
    {
        var scanner = new Scanner();
        using var model = new StorageViewModel(scanner);
        var task = model.ScanAsync(Root);
        scanner.Calls.Dequeue().SetException(new ShouException("permission_denied", "private diagnostic path"));
        await task;
        Assert.Equal(StoragePageState.Failed, model.State);
        Assert.Equal("permission_denied", model.ErrorCode);
        Assert.Null(model.Snapshot);
    }

    [Fact]
    public async Task ProgressFromSupersededAndCompletedScansCannotLeakIntoCurrentPage()
    {
        var scanner = new Scanner();
        using var model = new StorageViewModel(scanner);
        var first = model.ScanAsync(Root); var old = scanner.Calls.Dequeue();
        scanner.Progress[0]!.Report(new(12, Root.Append("old")));
        var current = model.ScanAsync(Root); var completion = scanner.Calls.Dequeue();
        Assert.Null(model.Progress);
        scanner.Progress[0]!.Report(new(99, Root.Append("late")));
        Assert.Null(model.Progress);
        scanner.Progress[1]!.Report(new(3, Root.Append("current")));
        completion.SetResult(Snapshot(ScanState.Complete)); await current;
        var final = model.Progress;
        scanner.Progress[1]!.Report(new(100, Root.Append("after")));
        Assert.Equal(final, model.Progress);
        old.SetResult(Snapshot(ScanState.Partial)); await first;
        Assert.Equal(StoragePageState.Ready, model.State);
    }

    [Fact]
    public async Task DisposalCancelsAndPreventsLateNotifications()
    {
        var scanner = new Scanner();
        var model = new StorageViewModel(scanner);
        var changes = 0;
        model.PropertyChanged += (_, _) => changes++;
        var task = model.ScanAsync(Root);
        model.Dispose();
        var before = changes;
        Assert.True(scanner.Tokens[0].IsCancellationRequested);
        scanner.Calls.Dequeue().SetResult(Snapshot(ScanState.Complete));
        await task;
        Assert.Equal(before, changes);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => model.ScanAsync(Root));
    }
}
