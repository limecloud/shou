using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class StartupViewModelTests
{
    private sealed class Reader : IStartupInventory
    {
        public Queue<TaskCompletionSource<StartupInventory>> Calls { get; } = new();
        public List<CancellationToken> Tokens { get; } = [];
        public Task<StartupInventory> ReadAsync(StartupDiscoveryBudget budget, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken);
            var result = new TaskCompletionSource<StartupInventory>(TaskCreationOptions.RunContinuationsAsynchronously);
            Calls.Enqueue(result);
            return result.Task;
        }
    }
    private static StartupInventory Result(int count = 1, bool partial = false) => new(Enumerable.Range(0, count)
        .Select(index => new StartupRegistration(StartupSource.CurrentUserRun, "item_" + index, $"Example {index:D3}")).ToImmutableArray(),
        Enum.GetValues<StartupSource>().Select(source => new StartupSourceCoverage(source,
            partial && source == StartupSource.CommonStartup ? StartupSourceState.Unavailable : StartupSourceState.Complete,
            source == StartupSource.CurrentUserRun ? count : 0, partial && source == StartupSource.CommonStartup ? ["permission_denied"] : [])).ToImmutableArray());

    [Theory]
    [InlineData(false, StartupPageState.Ready)]
    [InlineData(true, StartupPageState.Partial)]
    public async Task PresentsActualSourceCoverage(bool partial, StartupPageState expected)
    {
        var reader = new Reader();
        using var model = new StartupViewModel(new(reader));
        var task = model.RefreshAsync();
        Assert.True(model.IsBusy);
        reader.Calls.Dequeue().SetResult(Result(partial: partial));
        await task;
        Assert.Equal(expected, model.State);
        Assert.Single(model.Page!.Items);
        Assert.False(model.ShowingPreviousResults);
    }

    [Fact]
    public async Task FilteringAndPagingReuseOneSnapshot()
    {
        var reader = new Reader();
        using var model = new StartupViewModel(new(reader));
        var task = model.RefreshAsync();
        reader.Calls.Dequeue().SetResult(Result(205));
        await task;
        var id = model.Page!.SnapshotId;
        model.NextPage();
        Assert.Equal(100, model.Page.Offset);
        model.NextPage();
        Assert.Equal(5, model.Page.Items.Length);
        model.PreviousPage();
        Assert.Equal(100, model.Page.Offset);
        model.Filter("Example 204", StartupSource.CurrentUserRun);
        Assert.Single(model.Page.Items);
        Assert.Equal(id, model.Page.SnapshotId);
        Assert.Single(reader.Tokens);
    }

    [Fact]
    public async Task TaskStatusRemainsSeparateFromStartupAndProcessStateAcrossFilteringAndRefresh()
    {
        var reader = new Reader();
        using var model = new StartupViewModel(new(reader));
        var raw = Result() with
        {
            Registrations = [new(StartupSource.ScheduledTasks, @"\Fixture", "Task", ScheduledTask: new(true, ScheduledTaskState.Running))],
            Sources = Enum.GetValues<StartupSource>().Select(source => new StartupSourceCoverage(source, StartupSourceState.Complete,
                source == StartupSource.ScheduledTasks ? 1 : 0, [])).ToImmutableArray()
        };
        var first = model.RefreshAsync(); reader.Calls.Dequeue().SetResult(raw); await first;
        model.Filter("Task", StartupSource.ScheduledTasks);
        var item = Assert.Single(model.Page!.Items);
        Assert.Equal(ScheduledTaskState.Running, item.ScheduledTask!.State);
        Assert.Equal("not_observed", item.RunningState);
        Assert.False(item.ControlAvailable);
        var second = model.RefreshAsync();
        Assert.True(model.ShowingPreviousResults);
        reader.Calls.Dequeue().SetResult(raw with { Registrations = [raw.Registrations[0] with { ScheduledTask = null, Issues = ["scheduled_task_status_unavailable"] }],
            Sources = raw.Sources.Select(source => source.Source == StartupSource.ScheduledTasks
                ? source with { State = StartupSourceState.Partial, Issues = ["scheduled_task_status_unavailable"] } : source).ToImmutableArray() });
        await second;
        Assert.Null(Assert.Single(model.Page!.Items).ScheduledTask);
        Assert.Equal(StartupPageState.Partial, model.State);
        Assert.False(model.ShowingPreviousResults);
    }

    [Fact]
    public async Task CancelledRefreshKeepsClearlyMarkedPreviousResults()
    {
        var reader = new Reader();
        using var model = new StartupViewModel(new(reader));
        var first = model.RefreshAsync(); reader.Calls.Dequeue().SetResult(Result()); await first;
        var id = model.Page!.SnapshotId;
        var refresh = model.RefreshAsync();
        Assert.Equal(id, model.Page.SnapshotId);
        Assert.True(model.ShowingPreviousResults);
        model.Cancel();
        reader.Calls.Dequeue().SetResult(Result(2));
        await refresh;
        Assert.Equal(StartupPageState.Cancelled, model.State);
        Assert.Equal(id, model.Page.SnapshotId);
        Assert.False(model.IsBusy);
        Assert.True(model.ShowingPreviousResults);
    }

    [Fact]
    public async Task SupersededResultsCannotReplaceANewerScan()
    {
        var reader = new Reader();
        using var model = new StartupViewModel(new(reader));
        var first = model.RefreshAsync(); var old = reader.Calls.Dequeue();
        var second = model.RefreshAsync(); reader.Calls.Dequeue().SetResult(Result(2)); await second;
        old.SetResult(Result()); await first;
        Assert.Equal(2, model.Page!.Total);
        Assert.True(reader.Tokens[0].IsCancellationRequested);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExpectedAndUnexpectedFailuresUnlockWithoutExposingDiagnostics(bool unexpected)
    {
        var reader = new Reader();
        using var model = new StartupViewModel(new(reader));
        var first = model.RefreshAsync(); reader.Calls.Dequeue().SetResult(Result()); await first;
        var id = model.Page!.SnapshotId;
        var refresh = model.RefreshAsync();
        reader.Calls.Dequeue().SetException(unexpected ? new InvalidOperationException("private diagnostic") : new ShouException("permission_denied", "private diagnostic"));
        await refresh;
        Assert.Equal(StartupPageState.Failed, model.State);
        Assert.Equal(unexpected ? "startup_read_failed" : "permission_denied", model.ErrorCode);
        Assert.False(model.IsBusy);
        Assert.Equal(id, model.Page.SnapshotId);
        Assert.True(model.ShowingPreviousResults);
    }

    [Fact]
    public async Task DisposingCancelsAndSuppressesLateResults()
    {
        var reader = new Reader();
        var model = new StartupViewModel(new(reader));
        var notifications = 0;
        model.PropertyChanged += (_, _) => notifications++;
        var task = model.RefreshAsync();
        model.Dispose();
        var before = notifications;
        reader.Calls.Dequeue().SetResult(Result());
        await task;
        Assert.Null(model.Page);
        Assert.Equal(before, notifications);
        Assert.True(reader.Tokens[0].IsCancellationRequested);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => model.RefreshAsync());
    }
}
