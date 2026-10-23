using Shou.Windows.Core;
using Shou.Windows.Presentation;
using static Shou.Windows.Presentation.Tests.CleanupReviewTests;

namespace Shou.Windows.Presentation.Tests;

public sealed class CleanupHistoryTests
{
    private static CleanupHistoryDetail Detail(int id = 1)
    {
        var scan = Scan([Candidate(id)]);
        var plan = Plan(scan, [Candidate(id).Id], CleanupAction.Permanent);
        var execution = new CleanupExecution(1, Id("execution", id), plan.Id, plan.Digest, plan.Action, DateTimeOffset.UnixEpoch,
            DateTimeOffset.UnixEpoch, CleanupExecutionState.Executing, [new(plan.Items[0].Id, CleanupItemState.Purging)]);
        return new(plan, execution, true, true);
    }
    private sealed class Operations : ICleanupHistoryOperations
    {
        public CleanupHistoryPage Page = new("complete", "digest", 0, [], [], null);
        public Func<CancellationToken, Task<CleanupHistoryDetail>>? Show;
        public Func<CancellationToken, Task<CleanupHistoryInspection>>? Inspect;
        public string? Cursor;
        public int Limit;
        public string? Inspected;
        public ScanBudget? Budget;
        public CancellationToken Token;
        public Task<CleanupHistoryPage> ListAsync(int limit, string? cursor, CancellationToken cancellationToken)
        { Limit = limit; Cursor = cursor; return Task.FromResult(Page); }
        public Task<CleanupHistoryDetail> ShowAsync(string executionId, CancellationToken cancellationToken)
        { Token = cancellationToken; return Show?.Invoke(cancellationToken) ?? Task.FromResult(Detail()); }
        public Task<CleanupHistoryInspection> InspectAsync(string executionId, ScanBudget budget, CancellationToken cancellationToken)
        {
            Inspected = executionId; Budget = budget; Token = cancellationToken;
            return Inspect?.Invoke(cancellationToken) ?? Task.FromResult(Inspection());
        }
    }
    private static CleanupHistoryInspection Inspection() => new(Id("execution"), CleanupExecutionState.Executing, DateTimeOffset.UnixEpoch,
        "partial", true, true, 1, [new(Id("item"), CleanupItemState.Purging, new(Location().Path, HistoryLocationState.Missing, true),
            new(null, HistoryLocationState.NotRecorded, false), "needs_verification")]);

    [Fact]
    public async Task EmptyHistoryIsAnEmptyReadWithoutInventingExecutions()
    {
        var operations = new Operations();
        using var model = new CleanupHistoryViewModel(operations);
        await model.RefreshAsync();
        Assert.Empty(model.Page!.Entries);
        Assert.Equal(CleanupHistoryState.Ready, model.State);
        Assert.False(model.CanInspect);
        Assert.Null(model.Detail);
        Assert.Equal(50, operations.Limit);
    }

    [Fact]
    public async Task PagingUsesTheReturnedCursorAndRefreshStartsASeparateSnapshot()
    {
        var operations = new Operations { Page = new("partial", "digest", 2, [], [new(Id("execution"), "store_corrupt")], "next-page") };
        using var model = new CleanupHistoryViewModel(operations);
        await model.RefreshAsync(); Assert.Equal(CleanupHistoryState.Partial, model.State);
        Assert.Single(model.Page!.Issues); Assert.True(model.HasNext);
        await model.NextPageAsync(); Assert.Equal("next-page", operations.Cursor);
        await model.RefreshAsync(); Assert.Null(operations.Cursor);
    }

    [Fact]
    public async Task InspectionNeverChangesRecordedIntentOrGrantsRetryOrRecovery()
    {
        var operations = new Operations();
        using var model = new CleanupHistoryViewModel(operations);
        await model.ShowAsync(Id("execution"));
        var detail = model.Detail;
        await model.InspectAsync();
        Assert.Same(detail, model.Detail);
        Assert.Equal(CleanupItemState.Purging, model.Detail!.Execution.Items[0].State);
        Assert.True(model.Detail.Unfinished);
        Assert.False(model.Detail.RecoveryAvailable);
        Assert.Equal("needs_verification", Assert.Single(model.Inspection!.Items).Assessment);
        Assert.False(model.Inspection.RecordsChanged);
        Assert.Equal(Id("execution"), operations.Inspected);
        Assert.Equal(64, operations.Budget!.MaxDepth);
        Assert.Equal(CleanupHistoryState.Partial, model.State);
    }

    [Fact]
    public async Task ANewDetailDiscardsOlderInspectionAndCannotBeOverwrittenByItsDelayedResult()
    {
        var pending = new TaskCompletionSource<CleanupHistoryInspection>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Inspect = _ => pending.Task };
        using var model = new CleanupHistoryViewModel(operations);
        await model.ShowAsync(Id("execution")); var old = model.InspectAsync(); var token = operations.Token;
        operations.Show = _ => Task.FromResult(Detail(2));
        await model.ShowAsync(Id("execution", 2));
        Assert.True(token.IsCancellationRequested);
        pending.SetResult(Inspection()); await old;
        Assert.Equal(Id("execution", 2), model.Detail!.Execution.Id);
        Assert.Null(model.Inspection);
    }

    [Fact]
    public async Task CancelledInspectionDoesNotPublishEvenWhenTheAdapterCompletes()
    {
        var pending = new TaskCompletionSource<CleanupHistoryInspection>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Inspect = _ => pending.Task };
        using var model = new CleanupHistoryViewModel(operations);
        await model.ShowAsync(Id("execution")); var task = model.InspectAsync(); model.Cancel();
        Assert.True(model.StopRequested);
        pending.SetResult(Inspection()); await task;
        Assert.Equal(CleanupHistoryState.Cancelled, model.State);
        Assert.NotNull(model.Detail);
        Assert.Null(model.Inspection);
    }

    [Fact]
    public async Task FailedDetailDoesNotRetainThePreviousExecutionsPaths()
    {
        var operations = new Operations();
        using var model = new CleanupHistoryViewModel(operations);
        await model.ShowAsync(Id("execution")); await model.InspectAsync();
        operations.Show = _ => throw new ShouException("store_corrupt", "private diagnostic");
        await model.ShowAsync(Id("execution", 2));
        Assert.Equal("store_corrupt", model.ErrorCode);
        Assert.Null(model.Detail); Assert.Null(model.Inspection);
        Assert.False(model.CanInspect);
    }

    [Fact]
    public async Task DisposingPreventsLateDetailNotifications()
    {
        var pending = new TaskCompletionSource<CleanupHistoryDetail>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Show = _ => pending.Task };
        var model = new CleanupHistoryViewModel(operations);
        var task = model.ShowAsync(Id("execution"));
        var changes = 0; model.PropertyChanged += (_, _) => changes++;
        model.Dispose(); pending.SetResult(Detail()); await task;
        Assert.True(operations.Token.IsCancellationRequested);
        Assert.Equal(0, changes); Assert.Null(model.Detail);
    }
}
