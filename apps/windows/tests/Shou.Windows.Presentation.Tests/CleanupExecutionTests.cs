using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;
using static Shou.Windows.Presentation.Tests.CleanupReviewTests;

namespace Shou.Windows.Presentation.Tests;

public sealed class CleanupExecutionTests
{
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = DateTimeOffset.UnixEpoch.AddMinutes(1);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    private static CleanupPlan Prepared() => Plan(Scan([Candidate(1), Candidate(2)]), [Candidate(1).Id, Candidate(2).Id], CleanupAction.Permanent);
    private static CleanupExecution Result(CleanupPlan plan, CleanupExecutionState state = CleanupExecutionState.Completed) => new(1, Id("execution"), plan.Id, plan.Digest, plan.Action,
        DateTimeOffset.UnixEpoch.AddMinutes(1), DateTimeOffset.UnixEpoch.AddMinutes(1), state,
        plan.Items.Select((item, index) => new CleanupItemResult(item.Id, state == CleanupExecutionState.Completed || index == 0 ? CleanupItemState.Purged :
            state == CleanupExecutionState.Partial ? CleanupItemState.Failed : CleanupItemState.Unknown)).ToImmutableArray());
    private sealed class Confirmation : ICleanupConfirmation
    {
        public Task<bool> RequestAsync(CleanupReview review, CancellationToken cancellationToken) => throw new InvalidOperationException("Only Core may issue current consent.");
    }
    private sealed class Operations : ICleanupExecutionOperations
    {
        public bool ExecutionAvailable { get; set; } = true;
        public Func<CancellationToken, Task<CleanupExecution>>? Run;
        public Func<CancellationToken, Task<CleanupExecution?>>? Read;
        public string? ExecutedPlan;
        public string? ReadPlan;
        public ICleanupConfirmation? Confirmation;
        public CancellationToken Token;
        public Task<CleanupExecution> ExecuteAsync(string planId, ICleanupConfirmation confirmation, CancellationToken cancellationToken)
        {
            ExecutedPlan = planId; Confirmation = confirmation; Token = cancellationToken;
            return Run?.Invoke(cancellationToken) ?? Task.FromResult(Result(Prepared()));
        }
        public Task<CleanupExecution?> ReadExecutionAsync(string planId, CancellationToken cancellationToken)
        { ReadPlan = planId; Token = cancellationToken; return Read?.Invoke(cancellationToken) ?? Task.FromResult<CleanupExecution?>(Result(Prepared())); }
    }

    [Fact]
    public async Task AClosedNativeGateCannotDispatchOrAskForConfirmation()
    {
        var operations = new Operations { ExecutionAvailable = false };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared());
        Assert.False(model.CanExecute);
        var error = await Assert.ThrowsAsync<ShouException>(() => model.ExecuteAsync(new Confirmation()));
        Assert.Equal("unsupported_capability", error.Code);
        Assert.Null(operations.ExecutedPlan); Assert.Null(operations.Confirmation); Assert.Null(model.AttemptedPlan);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(600)]
    public async Task ExpiredPlansAndClockRollbackCannotDispatch(int seconds)
    {
        var clock = new Clock { Now = DateTimeOffset.UnixEpoch.AddSeconds(seconds) };
        var operations = new Operations();
        using var model = new CleanupExecutionViewModel(operations, clock);
        model.BindPlan(Prepared());
        Assert.False(model.CanExecute);
        await Assert.ThrowsAsync<ShouException>(() => model.ExecuteAsync(new Confirmation()));
        Assert.Null(operations.ExecutedPlan);
    }

    [Fact]
    public async Task TrashIsNotConvertedToPermanentCleanup()
    {
        var operations = new Operations();
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared() with { Action = CleanupAction.Trash });
        Assert.False(model.CanExecute);
        await Assert.ThrowsAsync<ShouException>(() => model.ExecuteAsync(new Confirmation()));
        Assert.Null(operations.ExecutedPlan);
    }

    [Theory]
    [InlineData(CleanupExecutionState.Completed)]
    [InlineData(CleanupExecutionState.Partial)]
    [InlineData(CleanupExecutionState.Unknown)]
    public async Task StopWaitsForRealResultsAndCannotRebindReadOrReplayAnActiveAttempt(CleanupExecutionState state)
    {
        var response = new TaskCompletionSource<CleanupExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Run = _ => response.Task };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        var plan = Prepared(); var confirmation = new Confirmation(); model.BindPlan(plan);
        var task = model.ExecuteAsync(confirmation);
        Assert.Equal(plan.Id, operations.ExecutedPlan); Assert.Same(confirmation, operations.Confirmation);
        Assert.Null(model.Plan); Assert.True(model.IsExecuting); Assert.False(model.CanReadExecution);
        model.BindPlan(plan with { Id = Id("plan", 2) });
        Assert.Null(model.Plan); Assert.Equal(plan, model.AttemptedPlan);
        await Assert.ThrowsAsync<ShouException>(() => model.ReadExecutionAsync());
        model.Cancel(); Assert.True(operations.Token.IsCancellationRequested); Assert.True(model.IsExecuting);
        response.SetResult(Result(plan, state)); await task;
        Assert.Equal(state, model.Execution!.State); Assert.Equal(CleanupExecutionPageState.Result, model.State);
        Assert.False(model.IsBusy); Assert.True(model.CanReadExecution);
        model.BindPlan(plan);
        Assert.False(model.CanExecute); Assert.NotNull(model.Execution);
    }

    [Fact]
    public async Task AJournalFailureKeepsTheExactAttemptAvailableForReadOnlyLookup()
    {
        var operations = new Operations { Run = _ => throw new ShouException("journal_write_failed", "private path") };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); await model.ExecuteAsync(new Confirmation());
        Assert.Equal("journal_write_failed", model.ErrorCode); Assert.Null(model.Execution); Assert.Null(model.Plan);
        Assert.True(model.CanReadExecution); Assert.False(model.CanExecute);
        await model.ReadExecutionAsync();
        Assert.Equal(Prepared().Id, operations.ReadPlan); Assert.Equal(CleanupExecutionState.Completed, model.Execution!.State);
    }

    [Fact]
    public async Task AnAbsentRecordDoesNotCreateASuccessfulOrRetryableOutcome()
    {
        var operations = new Operations { Run = _ => throw new ShouException("confirmation_required", "not confirmed"), Read = _ => Task.FromResult<CleanupExecution?>(null) };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); await model.ExecuteAsync(new Confirmation()); await model.ReadExecutionAsync();
        Assert.Equal("execution_not_recorded", model.ErrorCode); Assert.Null(model.Execution); Assert.False(model.CanExecute);
        Assert.True(model.CanReadExecution);
    }

    [Theory]
    [InlineData("plan")]
    [InlineData("digest")]
    [InlineData("action")]
    [InlineData("missing_item")]
    [InlineData("duplicate_item")]
    [InlineData("state")]
    public async Task UnrelatedOrMalformedResultsCannotBeDisplayed(string kind)
    {
        var result = Result(Prepared());
        result = kind switch
        {
            "plan" => result with { PlanId = Id("plan", 2) },
            "digest" => result with { PlanDigest = "sha256:" + new string('d', 64) },
            "action" => result with { Action = CleanupAction.Trash },
            "missing_item" => result with { Items = [result.Items[0]] },
            "duplicate_item" => result with { Items = [result.Items[0], result.Items[0]] },
            _ => result with { State = (CleanupExecutionState)999 }
        };
        var operations = new Operations { Run = _ => Task.FromResult(result) };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); await model.ExecuteAsync(new Confirmation());
        Assert.Equal(CleanupExecutionPageState.Failed, model.State); Assert.Equal("store_corrupt", model.ErrorCode);
        Assert.Null(model.Execution); Assert.True(model.CanReadExecution); Assert.False(model.CanExecute);
    }

    [Fact]
    public async Task UnexpectedErrorsUnlockWithoutLeakingDiagnosticsOrRestoringExecution()
    {
        var operations = new Operations { Run = _ => throw new InvalidOperationException("private diagnostic") };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); await model.ExecuteAsync(new Confirmation());
        Assert.False(model.IsBusy); Assert.Equal("internal_error", model.ErrorCode); Assert.Null(model.Plan);
        Assert.True(model.CanReadExecution);
    }

    [Fact]
    public async Task CancelledConfirmationRetainsTheAttemptWithoutInventingAFilesystemResult()
    {
        var response = new TaskCompletionSource<CleanupExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Run = _ => response.Task };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); var task = model.ExecuteAsync(new Confirmation()); model.Cancel();
        response.SetCanceled(operations.Token); await task;
        Assert.Equal(CleanupExecutionPageState.Cancelled, model.State); Assert.Null(model.Execution);
        Assert.True(model.CanReadExecution); Assert.False(model.CanExecute);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancelledOrInvalidatedRecordReadsCannotPublishLateData(bool invalidate)
    {
        var response = new TaskCompletionSource<CleanupExecution?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Read = _ => response.Task };
        using var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); await model.ExecuteAsync(new Confirmation()); var task = model.ReadExecutionAsync();
        if (invalidate) model.BindPlan(null); else model.Cancel();
        response.SetResult(Result(Prepared())); await task;
        Assert.True(operations.Token.IsCancellationRequested); Assert.Null(model.Execution);
        Assert.False(model.CanExecute);
    }

    [Fact]
    public async Task DisposingCancelsWithoutPublishingALateMutationResult()
    {
        var response = new TaskCompletionSource<CleanupExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Run = _ => response.Task };
        var model = new CleanupExecutionViewModel(operations, new Clock());
        model.BindPlan(Prepared()); var task = model.ExecuteAsync(new Confirmation()); model.Dispose();
        var changes = 0; model.PropertyChanged += (_, _) => changes++;
        response.SetResult(Result(Prepared())); await task;
        Assert.True(operations.Token.IsCancellationRequested); Assert.Equal(0, changes);
        Assert.Null(model.Execution); Assert.Null(model.Plan); Assert.Null(model.AttemptedPlan);
    }
}
