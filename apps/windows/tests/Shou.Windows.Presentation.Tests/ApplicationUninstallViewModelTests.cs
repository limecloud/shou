using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class ApplicationUninstallViewModelTests
{
    private sealed class Operations : IApplicationUninstallOperations
    {
        public bool ExecutionAvailable { get; set; }
        public Queue<TaskCompletionSource<ApplicationUninstallReview>> Reviews { get; } = new();
        public Queue<TaskCompletionSource<ApplicationUninstallPlan>> Plans { get; } = new();
        public Queue<TaskCompletionSource<ApplicationUninstallExecution>> Executions { get; } = new();
        public Queue<TaskCompletionSource<ApplicationUninstallExecution>> Reads { get; } = new();
        public List<(string PlanId, IApplicationUninstallConfirmation Confirmation)> ExecutionRequests { get; } = [];
        public List<string> ReadRequests { get; } = [];
        public List<CancellationToken> Tokens { get; } = [];
        public List<(string ApplicationId, string Digest, bool Consent)> Requests { get; } = [];
        public Task<ApplicationUninstallReview> InspectAsync(string applicationId, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken);
            var call = new TaskCompletionSource<ApplicationUninstallReview>(TaskCreationOptions.RunContinuationsAsynchronously);
            Reviews.Enqueue(call);
            return call.Task;
        }
        public Task<ApplicationUninstallPlan> CreatePlanAsync(string applicationId, string reviewDigest, bool allowInstallerDataChanges, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken);
            Requests.Add((applicationId, reviewDigest, allowInstallerDataChanges));
            var call = new TaskCompletionSource<ApplicationUninstallPlan>(TaskCreationOptions.RunContinuationsAsynchronously);
            Plans.Enqueue(call);
            return call.Task;
        }
        public Task<ApplicationUninstallExecution> ExecuteAsync(string planId, IApplicationUninstallConfirmation confirmation, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken);
            ExecutionRequests.Add((planId, confirmation));
            var call = new TaskCompletionSource<ApplicationUninstallExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
            Executions.Enqueue(call);
            return call.Task;
        }
        public Task<ApplicationUninstallExecution> ReadExecutionAsync(string planId, CancellationToken cancellationToken)
        {
            Tokens.Add(cancellationToken);
            ReadRequests.Add(planId);
            var call = new TaskCompletionSource<ApplicationUninstallExecution>(TaskCreationOptions.RunContinuationsAsynchronously);
            Reads.Enqueue(call);
            return call.Task;
        }
    }

    private sealed class Confirmation : IApplicationUninstallConfirmation
    {
        public Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken) => Task.FromResult(false);
    }
    internal sealed class Clock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    internal static ApplicationUninstallReview Review(bool blocked = false, string name = "Example") => new(
        new("application_" + new string('a', 64), ApplicationSource.CurrentUserRegistry, "{00000000-0000-0000-0000-000000000001}", name,
            "1.0", "Publisher", null, null, false, [], true),
        new(new(ApplicationInstallerKind.Msi, "{00000000-0000-0000-0000-000000000001}", MsiInstallationContext.UserUnmanaged,
            "S-1-5-21-1000", "{00000000-0000-0000-0000-000000000002}"), name, "1.0", "Publisher", null, blocked, []),
        new(ActivityState.Idle, "no_observed_installation_users"), DateTimeOffset.UtcNow,
        blocked ? ["protected_application"] : [], ["installer_managed_data_may_be_removed"], "sha256:" + new string('b', 64));

    internal static ApplicationUninstallPlan Plan(ApplicationUninstallReview review) => new(1, "uninstall_plan_" + new string('0', 32),
        "S-1-5-21-1000", review.ObservedAt, review.ObservedAt.AddMinutes(15), review, true, "sha256:" + new string('c', 64));

    private static async Task<ApplicationUninstallReview> LoadAsync(Operations operations, ApplicationUninstallViewModel model, bool blocked = false)
    {
        var review = Review(blocked);
        var task = model.InspectAsync(review.Application.Id);
        operations.Reviews.Dequeue().SetResult(review);
        await task;
        return review;
    }

    private static async Task<ApplicationUninstallPlan> PrepareAsync(Operations operations, ApplicationUninstallViewModel model)
    {
        var review = await LoadAsync(operations, model);
        model.SetDataConsent(true);
        var plan = Plan(review);
        var prepare = model.PreparePlanAsync();
        operations.Plans.Dequeue().SetResult(plan);
        await prepare;
        return plan;
    }
    private static ApplicationUninstallExecution Execution(ApplicationUninstallPlan plan,
        ApplicationUninstallState state = ApplicationUninstallState.Completed) => new(1, ApplicationUninstallService.ExecutionId(plan.Id),
        plan.Id, plan.Digest, plan.OwnerSid, plan.CreatedAt, plan.CreatedAt, state,
        state switch
        {
            ApplicationUninstallState.Completed => new(SystemUninstallOutcome.Succeeded, InstallationPresence.Absent),
            ApplicationUninstallState.Failed => new(SystemUninstallOutcome.Failed, InstallationPresence.Present),
            ApplicationUninstallState.Cancelled => new(SystemUninstallOutcome.Cancelled, InstallationPresence.Unknown),
            _ => new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown)
        });

    [Fact]
    public async Task UnavailableExecutionDoesNotConsumePreparedPlanOrRequestConfirmation()
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        Assert.False(model.CanExecute);
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => model.ExecuteAsync(new Confirmation()))).Code);
        Assert.Same(plan, model.Plan);
        Assert.Empty(operations.ExecutionRequests);
        Assert.False(model.CanReadExecution);
    }

    [Fact]
    public async Task ExecutionPassesExactPlanAndSeparateConfirmationAndPreventsSelectionChangesOrReplay()
    {
        var operations = new Operations { ExecutionAvailable = true };
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var confirmation = new Confirmation();
        Assert.True(model.CanExecute);
        var run = model.ExecuteAsync(confirmation);
        Assert.Equal((plan.Id, (IApplicationUninstallConfirmation)confirmation), Assert.Single(operations.ExecutionRequests));
        Assert.True(model.IsExecuting);
        Assert.Null(model.Plan);
        Assert.Null(model.Review);
        Assert.False(model.AllowInstallerDataChanges);
        Assert.False(model.CanReadExecution);
        model.Invalidate();
        Assert.True(model.IsExecuting);
        Assert.False(operations.Tokens[^1].IsCancellationRequested);
        Assert.Equal("store_busy", (await Assert.ThrowsAsync<ShouException>(() => model.InspectAsync("other"))).Code);
        await Assert.ThrowsAsync<ShouException>(() => model.ExecuteAsync(confirmation));
        var result = Execution(plan);
        operations.Executions.Dequeue().SetResult(result);
        await run;
        Assert.Same(result, model.Execution);
        Assert.Equal(ApplicationUninstallPageState.ExecutionReady, model.State);
        Assert.False(model.CanExecute);
        Assert.True(model.CanReadExecution);
        Assert.Single(operations.ExecutionRequests);
    }

    [Theory]
    [InlineData(ApplicationUninstallState.Completed)]
    [InlineData(ApplicationUninstallState.Failed)]
    [InlineData(ApplicationUninstallState.Unknown)]
    [InlineData(ApplicationUninstallState.Cancelled)]
    public async Task StopKeepsWaitingAndDoesNotHideRecordedInstallerOutcome(ApplicationUninstallState state)
    {
        var operations = new Operations { ExecutionAvailable = true };
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var run = model.ExecuteAsync(new Confirmation());
        model.Cancel(); model.Cancel();
        Assert.True(model.StopRequested);
        Assert.True(operations.Tokens[^1].IsCancellationRequested);
        Assert.True(model.IsExecuting);
        Assert.False(run.IsCompleted);
        var result = Execution(plan, state);
        operations.Executions.Dequeue().SetResult(result);
        await run;
        Assert.Same(result, model.Execution);
        Assert.Equal(ApplicationUninstallPageState.ExecutionReady, model.State);
    }

    [Theory]
    [InlineData("journal_write_failed")]
    [InlineData("confirmation_required")]
    [InlineData("plan_consumed")]
    public async Task ExecutionErrorRetainsExactReadOnlyRecordQueryWithoutRetry(string code)
    {
        var operations = new Operations { ExecutionAvailable = true };
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var run = model.ExecuteAsync(new Confirmation());
        operations.Executions.Dequeue().SetException(new ShouException(code, "Private diagnostic"));
        await run;
        Assert.Equal(code, model.ErrorCode);
        Assert.Null(model.Plan);
        Assert.False(model.CanExecute);
        Assert.True(model.CanReadExecution);
        var read = model.ReadExecutionAsync();
        Assert.Equal(plan.Id, Assert.Single(operations.ReadRequests));
        var intent = Execution(plan) with { State = ApplicationUninstallState.Uninstalling, Result = null };
        operations.Reads.Dequeue().SetResult(intent);
        await read;
        Assert.Same(intent, model.Execution);
        Assert.Equal(ApplicationUninstallPageState.ExecutionReady, model.State);
        Assert.Single(operations.ExecutionRequests);
    }

    [Theory]
    [InlineData(false, "plan")]
    [InlineData(false, "digest")]
    [InlineData(false, "owner")]
    [InlineData(true, "plan")]
    [InlineData(true, "digest")]
    [InlineData(true, "owner")]
    public async Task ExecutionAndRecordQueriesRejectDifferentPlanBindings(bool reading, string field)
    {
        var operations = new Operations { ExecutionAvailable = true };
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var run = model.ExecuteAsync(new Confirmation());
        var result = Execution(plan);
        if (reading)
        {
            operations.Executions.Dequeue().SetResult(result);
            await run;
            run = model.ReadExecutionAsync();
        }
        var invalid = field switch
        {
            "plan" => result with { PlanId = "uninstall_plan_" + new string('f', 32) },
            "digest" => result with { PlanDigest = "sha256:" + new string('f', 64) },
            _ => result with { OwnerSid = "S-1-5-21-2000" }
        };
        (reading ? operations.Reads : operations.Executions).Dequeue().SetResult(invalid);
        await run;
        Assert.Null(model.Execution);
        Assert.Equal("corrupt_record", model.ErrorCode);
        Assert.True(model.CanReadExecution);
        Assert.False(model.CanExecute);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnexpectedExecutionOrReadErrorUnlocksThePageAndRetainsRecordQuery(bool reading)
    {
        var operations = new Operations { ExecutionAvailable = true };
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var run = model.ExecuteAsync(new Confirmation());
        if (reading)
        {
            operations.Executions.Dequeue().SetResult(Execution(plan));
            await run;
            run = model.ReadExecutionAsync();
        }
        (reading ? operations.Reads : operations.Executions).Dequeue().SetException(new InvalidOperationException("Private diagnostic"));
        await run;
        Assert.False(model.IsExecuting);
        Assert.False(model.IsBusy);
        Assert.True(model.CanReadExecution);
        Assert.False(model.CanExecute);
        Assert.Equal("internal_error", model.ErrorCode);
        Assert.Null(model.Execution);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancelledOrInvalidatedReadDoesNotPublishLateResult(bool invalidate)
    {
        var operations = new Operations { ExecutionAvailable = true };
        using var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var run = model.ExecuteAsync(new Confirmation());
        operations.Executions.Dequeue().SetResult(Execution(plan));
        await run;
        var read = model.ReadExecutionAsync();
        if (invalidate) model.Invalidate(); else model.Cancel();
        Assert.True(operations.Tokens[^1].IsCancellationRequested);
        operations.Reads.Dequeue().SetResult(Execution(plan));
        await read;
        Assert.Null(model.Execution);
        Assert.Equal(invalidate ? ApplicationUninstallPageState.Empty : ApplicationUninstallPageState.Cancelled, model.State);
        Assert.Equal(!invalidate, model.CanReadExecution);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DisposeDuringExecutionOrReadCancelsWithoutLateNotifications(bool reading)
    {
        var operations = new Operations { ExecutionAvailable = true };
        var model = new ApplicationUninstallViewModel(operations);
        var plan = await PrepareAsync(operations, model);
        var run = model.ExecuteAsync(new Confirmation());
        if (reading)
        {
            operations.Executions.Dequeue().SetResult(Execution(plan));
            await run;
            run = model.ReadExecutionAsync();
        }
        var changes = 0;
        model.PropertyChanged += (_, _) => changes++;
        model.Dispose();
        (reading ? operations.Reads : operations.Executions).Dequeue().SetResult(Execution(plan));
        await run;
        Assert.True(operations.Tokens[^1].IsCancellationRequested);
        Assert.Equal(0, changes);
        Assert.Null(model.Execution);
        Assert.Null(model.ExecutionPlanId);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(15)]
    public async Task ClockRollbackOrPlanExpiryPreventsDispatch(int minutes)
    {
        var operations = new Operations { ExecutionAvailable = true };
        var clock = new Clock(DateTimeOffset.UtcNow);
        using var model = new ApplicationUninstallViewModel(operations, clock);
        var plan = await PrepareAsync(operations, model);
        clock.Now = plan.CreatedAt.AddMinutes(minutes);
        Assert.False(model.CanExecute);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => model.ExecuteAsync(new Confirmation()))).Code);
        Assert.Same(plan, model.Plan);
        Assert.Empty(operations.ExecutionRequests);
    }

    [Fact]
    public async Task ReviewRequiresSeparateDataConsentAndPlanningPassesTheReviewedIdentity()
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        var review = await LoadAsync(operations, model);
        Assert.False(model.AllowInstallerDataChanges);
        Assert.False(model.CanPreparePlan);
        Assert.Equal("installer_data_consent_required", (await Assert.ThrowsAsync<ShouException>(() => model.PreparePlanAsync())).Code);
        Assert.Empty(operations.Plans);
        model.SetDataConsent(true);
        var task = model.PreparePlanAsync();
        Assert.True(model.IsBusy);
        Assert.Equal((review.Application.Id, review.Digest, true), Assert.Single(operations.Requests));
        operations.Plans.Dequeue().SetResult(Plan(review));
        await task;
        Assert.Equal(ApplicationUninstallPageState.PlanReady, model.State);
        Assert.False(model.Plan!.ExecutionAvailable);
        model.SetDataConsent(false);
        Assert.Null(model.Plan);
        Assert.False(model.CanPreparePlan);
        Assert.Equal(ApplicationUninstallPageState.Reviewed, model.State);
    }

    [Fact]
    public async Task ProtectedInstallationCannotObtainDataConsentOrAPlan()
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        await LoadAsync(operations, model, blocked: true);
        model.SetDataConsent(true);
        Assert.False(model.AllowInstallerDataChanges);
        Assert.False(model.CanPreparePlan);
        await Assert.ThrowsAsync<ShouException>(() => model.PreparePlanAsync());
        Assert.Empty(operations.Requests);
    }

    [Theory]
    [InlineData(ActivityState.Active)]
    [InlineData(ActivityState.Unknown)]
    public async Task RunningOrUnknownActivityDisablesDataConsentAndPlanning(ActivityState state)
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        var review = Review() with { Activity = new(state, "fixture_activity") };
        var load = model.InspectAsync(review.Application.Id);
        operations.Reviews.Dequeue().SetResult(review);
        await load;
        model.SetDataConsent(true);
        Assert.False(model.AllowInstallerDataChanges);
        Assert.False(model.CanPreparePlan);
        await Assert.ThrowsAsync<ShouException>(() => model.PreparePlanAsync());
        Assert.Empty(operations.Requests);
    }

    [Fact]
    public async Task NewSelectionOrRefreshClearsReviewAndConsentAndDiscardsThePendingPlan()
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        var review = await LoadAsync(operations, model);
        model.SetDataConsent(true);
        var task = model.PreparePlanAsync();
        model.Invalidate();
        Assert.True(operations.Tokens[^1].IsCancellationRequested);
        operations.Plans.Dequeue().SetResult(Plan(review));
        await task;
        Assert.Equal(ApplicationUninstallPageState.Empty, model.State);
        Assert.Null(model.Plan);
        Assert.Null(model.Review);
        Assert.False(model.AllowInstallerDataChanges);
    }

    [Fact]
    public async Task LateOldInspectionCannotReplaceTheNewApplication()
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        var old = model.InspectAsync("old");
        var oldCall = operations.Reviews.Dequeue();
        var next = model.InspectAsync("new");
        operations.Reviews.Dequeue().SetResult(Review(name: "New"));
        await next;
        oldCall.SetResult(Review(name: "Old"));
        await old;
        Assert.True(operations.Tokens[0].IsCancellationRequested);
        Assert.Equal("New", model.Review!.Application.Name);
        Assert.False(model.AllowInstallerDataChanges);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancelDoesNotPublishALateSuccessfulInspectionOrPlan(bool planning)
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        var review = await LoadAsync(operations, model);
        model.SetDataConsent(true);
        var task = planning ? model.PreparePlanAsync() : model.InspectAsync(review.Application.Id);
        model.Cancel();
        Assert.True(operations.Tokens[^1].IsCancellationRequested);
        if (planning) operations.Plans.Dequeue().SetResult(Plan(review));
        else operations.Reviews.Dequeue().SetResult(review);
        await task;
        Assert.Equal(ApplicationUninstallPageState.Cancelled, model.State);
        Assert.Null(model.Plan);
        Assert.False(model.IsBusy);
    }

    [Fact]
    public async Task ChangedInstallationClearsConsentAndRequiresANewReview()
    {
        var operations = new Operations();
        using var model = new ApplicationUninstallViewModel(operations);
        await LoadAsync(operations, model);
        model.SetDataConsent(true);
        var task = model.PreparePlanAsync();
        operations.Plans.Dequeue().SetException(new ShouException("application_changed", "Private diagnostic"));
        await task;
        Assert.Equal(ApplicationUninstallPageState.Failed, model.State);
        Assert.Equal("application_changed", model.ErrorCode);
        Assert.Null(model.Review);
        Assert.Null(model.Plan);
        Assert.False(model.AllowInstallerDataChanges);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DisposeCancelsAndSuppressesSynchronousAndLateNotifications(bool planning)
    {
        var operations = new Operations();
        var model = new ApplicationUninstallViewModel(operations);
        var review = await LoadAsync(operations, model);
        model.SetDataConsent(true);
        var task = planning ? model.PreparePlanAsync() : model.InspectAsync(review.Application.Id);
        var changes = 0;
        model.PropertyChanged += (_, _) => changes++;
        model.Dispose();
        if (planning) operations.Plans.Dequeue().SetResult(Plan(review));
        else operations.Reviews.Dequeue().SetResult(review);
        await task;
        Assert.True(operations.Tokens[^1].IsCancellationRequested);
        Assert.Equal(0, changes);
        Assert.Null(model.Review);
        Assert.Null(model.Plan);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => model.PreparePlanAsync());
        model.Dispose();
    }
}
