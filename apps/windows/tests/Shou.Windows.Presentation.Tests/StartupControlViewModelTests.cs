using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class StartupControlViewModelTests
{
    private const string Path = @"\Generated\Fixture";
    private static StartupItem Item(string path = Path) => new("fixture", StartupSource.ScheduledTasks, path, "Fixture", null, null, []);
    private static StartupControlReview Review(string path = Path, StartupControlAction action = StartupControlAction.Enable)
    {
        var now = DateTimeOffset.UtcNow;
        return new(1, RecordKey.New("startup_control"), action,
            new(path, "sha256:" + new string('a', 64), "S-1-5-21-1000", false, true, true, true, true, false, []),
            now, now.AddMinutes(5), [], "sha256:" + new string('b', 64));
    }
    private static StartupControlExecution Execution(StartupControlReview review, StartupControlState state = StartupControlState.Completed) =>
        new(1, review.Id, review, review.CreatedAt, review.CreatedAt, state,
            state == StartupControlState.Applying ? null : new(StartupControlNativeOutcome.Applied, true, true));
    private sealed class Confirmation : IStartupControlConfirmation
    { public Task<bool> RequestAsync(StartupControlReview review, CancellationToken token) => Task.FromResult(true); }
    private sealed class Operations : IStartupControlOperations
    {
        public bool ExecutionAvailable { get; set; } = true;
        public Func<string, StartupControlAction, CancellationToken, Task<StartupControlReview>> Inspect = (path, action, _) => Task.FromResult(Review(path, action));
        public Func<StartupControlReview, CancellationToken, Task<StartupControlExecution>> Execute = (review, _) => Task.FromResult(Execution(review));
        public Func<string, CancellationToken, Task<StartupControlExecution>> Read = (_, _) => throw new ShouException("not_found", "No record");
        public int Executions;
        public Task<StartupControlReview> InspectAsync(string path, StartupControlAction action, CancellationToken token) => Inspect(path, action, token);
        public Task<StartupControlExecution> ExecuteAsync(StartupControlReview review, IStartupControlConfirmation confirmation, CancellationToken token)
        { Executions++; return Execute(review, token); }
        public Task<StartupControlExecution> ReadAsync(string id, CancellationToken token) => Read(id, token);
    }

    [Fact]
    public async Task DisabledPublicGatePreservesReadOnlyReviewAndCannotDispatch()
    {
        var operations = new Operations { ExecutionAvailable = false };
        using var model = new StartupControlViewModel(operations); model.Bind(Item());
        await model.InspectAsync(StartupControlAction.Enable);
        await model.ExecuteAsync(new Confirmation());
        Assert.NotNull(model.Review);
        Assert.Null(model.OperationId);
        Assert.Equal("unsupported_capability", model.ErrorCode);
        Assert.Equal(0, operations.Executions);
    }

    [Fact]
    public async Task ScopeChangeInvalidatesReviewAndRejectsLateResults()
    {
        var pending = new TaskCompletionSource<StartupControlReview>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Inspect = (_, _, _) => pending.Task };
        using var model = new StartupControlViewModel(operations); model.Bind(Item());
        var task = model.InspectAsync(StartupControlAction.Enable);
        model.Bind(Item(@"\Other")); pending.SetResult(Review()); await task;
        Assert.Null(model.Review);
        Assert.Equal(@"\Other", model.TaskPath);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ForeignTaskOrActionReviewsCannotBeConfirmed(bool foreignAction)
    {
        var operations = new Operations { Inspect = (_, _, _) => Task.FromResult(Review(foreignAction ? Path : @"\Other", foreignAction ? StartupControlAction.Disable : StartupControlAction.Enable)) };
        using var model = new StartupControlViewModel(operations); model.Bind(Item());
        await model.InspectAsync(StartupControlAction.Enable);
        Assert.Null(model.Review);
        Assert.Equal("startup_inspection_invalid", model.ErrorCode);
    }

    [Fact]
    public async Task DispatchClearsReusableReviewAndPreventsSelectionChanges()
    {
        var pending = new TaskCompletionSource<StartupControlExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Execute = (_, _) => pending.Task };
        using var model = new StartupControlViewModel(operations); model.Bind(Item()); await model.InspectAsync(StartupControlAction.Enable);
        var review = model.Review!; var task = model.ExecuteAsync(new Confirmation());
        Assert.True(model.IsExecuting);
        Assert.Null(model.Review);
        Assert.Equal(review.Id, model.OperationId);
        Assert.Throws<ShouException>(() => model.Bind(Item(@"\Other")));
        model.Cancel(); Assert.True(model.StopRequested); Assert.False(task.IsCompleted);
        pending.SetResult(Execution(review)); await task;
        Assert.Equal(StartupControlState.Completed, model.Execution!.State);
        Assert.False(model.IsExecuting);
        await model.ExecuteAsync(new Confirmation()); Assert.Equal(1, operations.Executions);
    }

    [Fact]
    public async Task JournalFailureRetainsExactOperationLookupWithoutRestoringExecution()
    {
        var operations = new Operations { Execute = (_, _) => throw new ShouException("journal_write_failed", "private diagnostic") };
        using var model = new StartupControlViewModel(operations); model.Bind(Item()); await model.InspectAsync(StartupControlAction.Enable);
        var review = model.Review!;
        await model.ExecuteAsync(new Confirmation());
        Assert.Null(model.Review);
        Assert.Equal(review.Id, model.OperationId);
        Assert.Equal("journal_write_failed", model.ErrorCode);
        operations.Read = (_, _) => Task.FromResult(Execution(review, StartupControlState.Applying));
        await model.ReadAsync();
        Assert.True(model.Execution!.ObservationRequired);
        Assert.Null(model.Review);
    }

    [Fact]
    public async Task MissingRecordCannotImplyNoChangeOrRenewExecution()
    {
        var operations = new Operations(); using var model = new StartupControlViewModel(operations);
        model.Bind(Item()); await model.InspectAsync(StartupControlAction.Enable); await model.ExecuteAsync(new Confirmation());
        var id = model.OperationId;
        await model.ReadAsync();
        Assert.Equal("not_found", model.ErrorCode);
        Assert.Equal(id, model.OperationId);
        Assert.Null(model.Review);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ForeignExecutionOrReadResultsAreRejected(bool readResult)
    {
        var operations = new Operations(); using var model = new StartupControlViewModel(operations);
        model.Bind(Item()); await model.InspectAsync(StartupControlAction.Enable);
        if (readResult)
        {
            await model.ExecuteAsync(new Confirmation());
            operations.Read = (_, _) => Task.FromResult(Execution(Review(@"\Other")));
            await model.ReadAsync();
        }
        else
        {
            operations.Execute = (_, _) => Task.FromResult(Execution(Review(@"\Other")));
            await model.ExecuteAsync(new Confirmation());
        }
        Assert.Equal("startup_result_invalid", model.ErrorCode);
        Assert.Null(model.Review);
    }

    [Fact]
    public async Task DisposalStopsPresentationWithoutInventingAnOutcome()
    {
        var pending = new TaskCompletionSource<StartupControlExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Execute = (_, _) => pending.Task };
        var model = new StartupControlViewModel(operations); model.Bind(Item()); await model.InspectAsync(StartupControlAction.Enable);
        var review = model.Review!; var task = model.ExecuteAsync(new Confirmation());
        var notifications = 0; model.PropertyChanged += (_, _) => notifications++;
        model.Dispose(); pending.SetResult(Execution(review)); await task;
        Assert.Null(model.Execution);
        Assert.Equal(0, notifications);
    }
}
