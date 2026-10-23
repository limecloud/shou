using System.Collections.Immutable;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class StartupControlTests
{
    private const string Sid = "S-1-5-21-100-200-300-1001";
    private static readonly DateTimeOffset Now = new(2026, 10, 23, 10, 0, 0, TimeSpan.Zero);
    private static StartupControlTask Facts(bool enabled = false) => new(@"\Generated\Fixture", "sha256:" + new string('a', 64), Sid, enabled, true, true, true, true, false, []);
    private sealed class Clock : TimeProvider { public DateTimeOffset Now = StartupControlTests.Now; public override DateTimeOffset GetUtcNow() => Now; }
    private sealed class Inspector : IStartupControlInspector
    {
        public StartupControlTask Value = Facts();
        public int Calls;
        public Action<int>? OnRead;
        public Task<StartupControlTask> InspectAsync(string taskPath, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Calls++; OnRead?.Invoke(Calls); return Task.FromResult(Value); }
    }
    private sealed class Confirmation : IStartupControlConfirmation
    {
        public int Calls;
        public bool Accept = true;
        public Action? OnRequest;
        public Task<bool> RequestAsync(StartupControlReview review, CancellationToken cancellationToken)
        { Calls++; OnRequest?.Invoke(); return Task.FromResult(Accept); }
    }
    private sealed class Mutation : IStartupControlMutation
    {
        public bool Available { get; set; } = true;
        public int Calls;
        public Func<StartupControlReview, Task<StartupControlNativeResult>>? OnApply;
        public Task<StartupControlNativeResult> ApplyAsync(StartupControlReview review, DateTimeOffset expiresAt, CancellationToken cancellationToken)
        { Calls++; return OnApply?.Invoke(review) ?? Task.FromResult(new StartupControlNativeResult(StartupControlNativeOutcome.Applied, review.DesiredEnabled, true)); }
    }
    private sealed class Fixture
    {
        public readonly MemoryRecordStore Store = new();
        public readonly Inspector Inspector = new();
        public readonly Clock Clock = new();
        public readonly Confirmation Confirmation = new();
        public readonly Mutation Mutation = new();
        public StartupControlReviewer Reviewer => new(Inspector, Sid, Clock);
        public StartupControlService Service => new(Store, Reviewer, Mutation, Sid, Clock);
        public Task<StartupControlReview> Review(StartupControlAction action = StartupControlAction.Enable) => Reviewer.InspectAsync(Facts().TaskPath, action);
    }

    [Theory]
    [InlineData(StartupControlAction.Enable)]
    [InlineData(StartupControlAction.Disable)]
    public async Task ExactTaskChangePublishesIntentBeforeMutationAndRetainsObservedResult(StartupControlAction action)
    {
        var f = new Fixture(); f.Inspector.Value = Facts(action == StartupControlAction.Disable);
        var review = await f.Review(action);
        f.Mutation.OnApply = value =>
        {
            Assert.Equal(review, value);
            Assert.Equal(StartupControlState.Applying, JsonSerializer.Deserialize<StartupControlExecution>(f.Store.Records[review.Id], ContractJson.Options)!.State);
            return Task.FromResult(new StartupControlNativeResult(StartupControlNativeOutcome.Applied, review.DesiredEnabled, true));
        };
        var result = await f.Service.ExecuteAsync(review, f.Confirmation);
        Assert.Equal(StartupControlState.Completed, result.State);
        Assert.Equal(2, f.Store.Writes);
        Assert.Single(f.Store.Records);
        Assert.Equal(1, f.Mutation.Calls);
        Assert.False(result.RetryAvailable || result.RestoreAvailable || result.ObservationRequired);
        Assert.Equal(JsonSerializer.Serialize(result, ContractJson.Options), JsonSerializer.Serialize(await f.Service.ShowAsync(result.Id), ContractJson.Options));
    }

    [Fact]
    public async Task ReviewDoesNotOpenStorageOrGrantExecution()
    {
        var f = new Fixture(); var result = await f.Review();
        Assert.True(result.CanChange);
        Assert.False(result.ExecutionAvailable);
        Assert.Empty(f.Store.Records);
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Theory]
    [InlineData("owner")]
    [InlineData("principal")]
    [InlineData("interactive")]
    [InlineData("elevated")]
    [InlineData("protected")]
    [InlineData("already_enabled")]
    [InlineData("issue")]
    public async Task IneligibleTasksCannotReachConfirmationOrMutation(string kind)
    {
        var f = new Fixture(); var task = Facts();
        f.Inspector.Value = kind switch
        {
            "owner" => task with { OwnerMatchesActor = false }, "principal" => task with { PrincipalMatchesActor = false },
            "interactive" => task with { InteractiveToken = false }, "elevated" => task with { LeastPrivilege = false },
            "protected" => task with { ProtectedLocation = true }, "already_enabled" => task with { Enabled = true },
            _ => task with { Issues = ["permission_denied"] }
        };
        var review = await f.Review();
        Assert.False(review.CanChange);
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(0, f.Confirmation.Calls + f.Mutation.Calls + f.Store.Writes);
    }

    [Fact]
    public async Task MicrosoftTaskProtectionDoesNotTrustTheAdapterFlag()
    {
        var f = new Fixture(); f.Inspector.Value = Facts() with { TaskPath = @"\mIcRoSoFt\Fixture" };
        var review = await f.Reviewer.InspectAsync(f.Inspector.Value.TaskPath, StartupControlAction.Enable);
        Assert.Contains("protected_startup_task", review.BlockingReasons);
    }

    [Theory]
    [InlineData("relative")]
    [InlineData("\\")]
    [InlineData("\\Folder\\..\\Task")]
    [InlineData("\\Folder/Task")]
    [InlineData("\\Folder\\\u202eTask")]
    public async Task InvalidTaskPathsAreRejectedBeforeNativeAccess(string path)
    {
        var f = new Fixture();
        await Assert.ThrowsAsync<ShouException>(() => f.Reviewer.InspectAsync(path, StartupControlAction.Enable));
        Assert.Equal(0, f.Inspector.Calls);
    }

    [Fact]
    public async Task UnavailableExecutionNeverPrompts()
    {
        var f = new Fixture(); var review = await f.Review(); f.Mutation.Available = false;
        await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation));
        Assert.Equal(0, f.Confirmation.Calls + f.Mutation.Calls + f.Store.Writes);
    }

    [Fact]
    public async Task DecliningCurrentConfirmationDoesNotWriteIntent()
    {
        var f = new Fixture(); var review = await f.Review(); f.Confirmation.Accept = false;
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(0, f.Mutation.Calls + f.Store.Writes);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(300)]
    public async Task ExpiredOrFutureReviewsCannotBeConfirmed(int seconds)
    {
        var f = new Fixture(); var review = await f.Review(); f.Clock.Now += TimeSpan.FromSeconds(seconds);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(0, f.Confirmation.Calls + f.Mutation.Calls + f.Store.Writes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DefinitionChangesBeforeOrAfterConfirmationPreventDispatch(bool afterConfirmation)
    {
        var f = new Fixture(); var review = await f.Review();
        void Change() => f.Inspector.Value = Facts() with { DefinitionDigest = "sha256:" + new string('b', 64) };
        if (afterConfirmation) f.Confirmation.OnRequest = Change; else Change();
        Assert.Equal("startup_changed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(0, f.Mutation.Calls + f.Store.Writes);
    }

    [Fact]
    public async Task ChangedActorCannotBeUsedToPrepareOrRecheckAChange()
    {
        var f = new Fixture(); var review = await f.Review();
        f.Inspector.Value = Facts() with { ActorSid = "S-1-5-21-100-200-300-1002" };
        await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation));
        Assert.Equal(0, f.Mutation.Calls + f.Store.Writes);
    }

    [Fact]
    public async Task ConfirmationExpiresWhileWaitingForVerification()
    {
        var f = new Fixture(); var review = await f.Review();
        f.Inspector.OnRead = count => { if (count == 3) f.Clock.Now += TimeSpan.FromSeconds(61); };
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(0, f.Mutation.Calls + f.Store.Writes);
    }

    [Fact]
    public async Task FailedIntentPublicationCannotInvokeSetter()
    {
        var f = new Fixture(); var review = await f.Review(); f.Store.FailWrite = true;
        Assert.Equal("journal_write_failed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(0, f.Mutation.Calls);
    }

    [Fact]
    public async Task FailedFinalPublicationLeavesAnUnresolvedIntentWithoutReplay()
    {
        var f = new Fixture(); var review = await f.Review();
        f.Store.FailPublication = (_, _) => f.Store.Writes == 1;
        Assert.Equal("journal_write_failed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        var observed = await f.Service.ShowAsync(review.Id);
        Assert.Equal(StartupControlState.Applying, observed.State);
        Assert.True(observed.ObservationRequired);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation))).Code);
        Assert.Equal(1, f.Mutation.Calls);
        Assert.Equal(1, f.Confirmation.Calls);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(null, null)]
    public async Task MissingChangedOrDisagreeingObservationIsNotCompleted(bool? enabled, bool? definition)
    {
        var f = new Fixture(); var review = await f.Review();
        f.Mutation.OnApply = _ => Task.FromResult(new StartupControlNativeResult(StartupControlNativeOutcome.Applied, enabled, definition));
        var result = await f.Service.ExecuteAsync(review, f.Confirmation);
        Assert.Equal(StartupControlState.Unknown, result.State);
        Assert.True(result.ObservationRequired);
    }

    [Fact]
    public async Task NativeExceptionAfterIntentIsUnknownAndCannotBeReplayed()
    {
        var f = new Fixture(); var review = await f.Review();
        f.Mutation.OnApply = _ => throw new IOException("private diagnostic");
        var result = await f.Service.ExecuteAsync(review, f.Confirmation);
        Assert.Equal(StartupControlState.Unknown, result.State);
        Assert.DoesNotContain("private diagnostic", JsonSerializer.Serialize(result, ContractJson.Options));
        await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review, f.Confirmation));
        Assert.Equal(1, f.Mutation.Calls);
    }

    [Fact]
    public async Task StopAfterIntentBeforeDispatchRecordsNotStartedWithoutMutation()
    {
        var f = new Fixture(); var review = await f.Review(); using var stop = new CancellationTokenSource();
        f.Store.FailPublication = (_, _) => { if (f.Store.Writes == 0) stop.Cancel(); return false; };
        var result = await f.Service.ExecuteAsync(review, f.Confirmation, stop.Token);
        Assert.Equal(StartupControlState.Cancelled, result.State);
        Assert.Equal(0, f.Mutation.Calls);
        Assert.Equal(2, f.Store.Writes);
    }

    [Fact]
    public async Task StopDuringNativeCallWaitsForAndPersistsTheRealOutcome()
    {
        var f = new Fixture(); var review = await f.Review(); using var stop = new CancellationTokenSource();
        var pending = new TaskCompletionSource<StartupControlNativeResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Mutation.OnApply = _ => pending.Task;
        var operation = f.Service.ExecuteAsync(review, f.Confirmation, stop.Token);
        stop.Cancel(); Assert.False(operation.IsCompleted);
        pending.SetResult(new(StartupControlNativeOutcome.Applied, true, true));
        Assert.Equal(StartupControlState.Completed, (await operation).State);
        Assert.Equal(2, f.Store.Writes);
    }

    [Fact]
    public async Task TamperedReviewCannotBorrowAValidDigest()
    {
        var f = new Fixture(); var review = await f.Review();
        await Assert.ThrowsAsync<ShouException>(() => f.Service.ExecuteAsync(review with { Action = StartupControlAction.Disable }, f.Confirmation));
        Assert.Equal(0, f.Mutation.Calls + f.Confirmation.Calls + f.Store.Writes);
    }

    [Fact]
    public async Task ReadOnlyLookupNeverCreatesMissingEvidence()
    {
        var f = new Fixture();
        Assert.Equal("not_found", (await Assert.ThrowsAsync<ShouException>(() => f.Service.ShowAsync(RecordKey.New("startup_control")))).Code);
        Assert.Equal(0, f.Store.Writes + f.Mutation.Calls);
    }
}
