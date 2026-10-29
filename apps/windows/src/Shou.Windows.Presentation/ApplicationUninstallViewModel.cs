using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface IApplicationUninstallOperations
{
    bool ExecutionAvailable { get; }
    bool ClosingAvailable => false;
    Task CloseAsync(ApplicationUninstallReview review, CancellationToken cancellationToken) =>
        Task.FromException(new ShouException("unsupported_capability", "Quit affected apps, then scan again."));
    Task<ApplicationUninstallReview> InspectAsync(string applicationId, CancellationToken cancellationToken);
    Task<ApplicationUninstallPlan> CreatePlanAsync(string applicationId, string reviewDigest, bool allowInstallerDataChanges, CancellationToken cancellationToken);
    Task<ApplicationUninstallExecution> ExecuteAsync(string planId, IApplicationUninstallConfirmation confirmation, CancellationToken cancellationToken);
    Task<ApplicationUninstallExecution> ReadExecutionAsync(string planId, CancellationToken cancellationToken);
}

public enum ApplicationUninstallPageState { Empty, Inspecting, Authorizing, Closing, Reviewed, Planning, PlanReady, Executing, ReadingExecution, ExecutionReady, Cancelled, Failed }

public sealed class ApplicationUninstallViewModel(IApplicationUninstallOperations operations, TimeProvider? timeProvider = null,
    ISystemAuthorization? authorization = null) : INotifyPropertyChanged, IDisposable
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private CancellationTokenSource? operation;
    private ApplicationUninstallPlan? executionPlan;
    private long generation;
    private bool disposed;
    private bool authorizationRequired;
    public event PropertyChangedEventHandler? PropertyChanged;
    public ApplicationUninstallPageState State { get; private set; }
    public ApplicationUninstallReview? Review { get; private set; }
    public ApplicationUninstallPlan? Plan { get; private set; }
    public ApplicationUninstallExecution? Execution { get; private set; }
    public string? ExecutionPlanId => executionPlan?.Id;
    public string? ErrorCode { get; private set; }
    public bool AllowInstallerDataChanges { get; private set; }
    public bool StopRequested { get; private set; }
    public bool IsExecuting => State == ApplicationUninstallPageState.Executing;
    public bool IsBusy => State is ApplicationUninstallPageState.Inspecting or ApplicationUninstallPageState.Authorizing or ApplicationUninstallPageState.Closing or ApplicationUninstallPageState.Planning or ApplicationUninstallPageState.Executing or ApplicationUninstallPageState.ReadingExecution;
    public bool BlocksSelection => IsBusy && State != ApplicationUninstallPageState.Inspecting;
    public bool RequiresAuthorization => authorization is not null && (authorizationRequired || Review?.RequiresAdministrator == true || ErrorCode == "permission_denied") && authorization.AdministratorState != SystemAuthorizationState.Authorized;
    public bool IsAuthorized => authorization?.AdministratorState == SystemAuthorizationState.Authorized;
    public bool ExecutionAvailable => operations.ExecutionAvailable;
    public bool CanClose => !IsBusy && operations.ClosingAvailable && Review?.Activity.State == ActivityState.Active;
    public bool CanPreparePlan => !IsBusy && !RequiresAuthorization && Review?.CanPreparePlan == true && AllowInstallerDataChanges;
    public bool CanExecute => !IsBusy && ExecutionAvailable && Plan is { } plan && plan.CreatedAt <= clock.GetUtcNow() && clock.GetUtcNow() < plan.ExpiresAt;
    public bool CanReadExecution => !IsBusy && executionPlan is not null;

    public Task InspectAsync(string applicationId) => RunAsync(async token =>
    {
        var review = await operations.InspectAsync(applicationId, token);
        return (review, (ApplicationUninstallPlan?)null);
    }, planning: false);

    public async Task CloseAndRecheckAsync()
    {
        if (!CanClose || Review is not { } review) return;
        var currentGeneration = ++generation;
        using var current = new CancellationTokenSource(); operation = current;
        State = ApplicationUninstallPageState.Closing; Plan = null; ErrorCode = null; StopRequested = false; Notify();
        try { await operations.CloseAsync(review, current.Token); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or OperationCanceledException)
        { if (!disposed && generation == currentGeneration) ErrorCode = error is ShouException known ? known.Code : "application_activity_unknown"; }
        finally { if (!disposed && generation == currentGeneration) { operation = null; State = ApplicationUninstallPageState.Reviewed; Notify(); } }
        if (!disposed && generation == currentGeneration && ErrorCode is null) await InspectAsync(review.Application.Id);
    }

    public Task AuthorizeAsync(string? applicationId = null) => AuthorizeAsync(applicationId, allowRecovery: true);
    public Task PrepareAuthorizationAsync(string applicationId) => AuthorizeAsync(applicationId, allowRecovery: false);
    private async Task AuthorizeAsync(string? applicationId, bool allowRecovery)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var id = Review?.Application.Id ?? applicationId;
        if (IsBusy || authorization is null || id is null || !ApplicationCatalog.IsApplicationId(id)) return;
        var currentGeneration = ++generation;
        using var current = new CancellationTokenSource();
        operation = current;
        authorizationRequired = true;
        Plan = null; ErrorCode = null; StopRequested = false;
        State = ApplicationUninstallPageState.Authorizing; Notify();
        try
        {
            if (allowRecovery) await authorization.AuthorizeAdministratorAsync(current.Token);
            else await authorization.PrepareAdministratorAuthorizationAsync(current.Token);
            if (disposed || generation != currentGeneration) return;
            current.Token.ThrowIfCancellationRequested();
            State = ApplicationUninstallPageState.Reviewed;
        }
        catch (Exception error) when (error is ShouException or OperationCanceledException or IOException or UnauthorizedAccessException)
        {
            if (disposed || generation != currentGeneration) return;
            // Keep the reviewed installation and explicit data choice after cancelled UAC.
            ErrorCode = error is ShouException known ? known.Code : current.IsCancellationRequested ? "authorization_cancelled" : "authorization_unavailable";
            State = ApplicationUninstallPageState.Reviewed;
        }
        finally { if (!disposed && generation == currentGeneration) { operation = null; Notify(); } }
        // Refresh read-only evidence only. Authorization never dispatches an uninstall.
        if (!disposed && generation == currentGeneration && ErrorCode is null) await InspectAsync(id);
    }

    public Task PreparePlanAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!CanPreparePlan || Review is not { } review) throw new ShouException("installer_data_consent_required", "Review this installation and explicitly acknowledge installer-managed data changes.");
        return RunAsync(async token => (review, await operations.CreatePlanAsync(review.Application.Id, review.Digest, true, token)), planning: true);
    }

    private async Task RunAsync(Func<CancellationToken, Task<(ApplicationUninstallReview Review, ApplicationUninstallPlan? Plan)>> action, bool planning)
    {
        using var diagnostic = OperationDiagnostics.Start("ui.application.review");
        ObjectDisposedException.ThrowIf(disposed, this);
        RequireNotExecuting();
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        Plan = null;
        Execution = null;
        executionPlan = null;
        StopRequested = false;
        ErrorCode = null;
        if (!planning) { Review = null; AllowInstallerDataChanges = false; authorizationRequired = false; }
        State = planning ? ApplicationUninstallPageState.Planning : ApplicationUninstallPageState.Inspecting;
        Notify();
        try
        {
            var result = await action(current.Token);
            if (disposed || generation != currentGeneration) return;
            current.Token.ThrowIfCancellationRequested();
            Review = result.Review;
            Plan = result.Plan;
            State = planning ? ApplicationUninstallPageState.PlanReady : ApplicationUninstallPageState.Reviewed;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || generation != currentGeneration) return;
            State = ApplicationUninstallPageState.Cancelled;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            diagnostic.Fail(error);
            if (disposed || generation != currentGeneration) return;
            State = ApplicationUninstallPageState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error";
            if (planning) { Review = null; AllowInstallerDataChanges = false; }
        }
        finally
        {
            diagnostic.Complete(disposed || currentGeneration != generation ? "superseded" : State.ToString().ToLowerInvariant());
            if (!disposed && generation == currentGeneration) { operation = null; Notify(); }
        }
    }

    public Task ExecuteAsync(IApplicationUninstallConfirmation confirmation)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ArgumentNullException.ThrowIfNull(confirmation);
        if (!ExecutionAvailable) throw new ShouException("unsupported_capability", "System uninstall requires a matching native Windows 11 process.");
        if (!CanExecute || Plan is not { } plan) throw new ShouException("plan_stale", "Prepare and confirm a current uninstall plan.");
        return RunExecutionAsync(plan, confirmation);
    }

    public Task ReadExecutionAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!CanReadExecution || executionPlan is not { } plan) throw new ShouException("invalid_argument", "Choose a recorded uninstall attempt when no operation is running.");
        return RunExecutionAsync(plan, null);
    }

    private async Task RunExecutionAsync(ApplicationUninstallPlan expected, IApplicationUninstallConfirmation? confirmation)
    {
        using var diagnostic = OperationDiagnostics.Start("ui.application.execute");
        var reading = confirmation is null;
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        executionPlan = expected;
        Plan = null;
        Review = null;
        Execution = null;
        AllowInstallerDataChanges = false;
        StopRequested = false;
        ErrorCode = null;
        State = reading ? ApplicationUninstallPageState.ReadingExecution : ApplicationUninstallPageState.Executing;
        Notify();
        try
        {
            var result = reading ? await operations.ReadExecutionAsync(expected.Id, current.Token)
                : await operations.ExecuteAsync(expected.Id, confirmation!, current.Token);
            if (disposed || generation != currentGeneration) return;
            // Cancellation of a dispatched installer must never hide a real, durably recorded outcome.
            if (reading) current.Token.ThrowIfCancellationRequested();
            if (result is null || result.PlanId != expected.Id || result.PlanDigest != expected.Digest || result.OwnerSid != expected.OwnerSid)
                throw new ShouException("corrupt_record", "The uninstall result does not belong to the reviewed plan.");
            Execution = result;
            State = ApplicationUninstallPageState.ExecutionReady;
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || generation != currentGeneration) return;
            State = ApplicationUninstallPageState.Cancelled;
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            diagnostic.Fail(error);
            if (disposed || generation != currentGeneration) return;
            State = ApplicationUninstallPageState.Failed;
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : error is IOException ? "io_error" : "internal_error";
        }
        finally
        {
            diagnostic.Complete(disposed || currentGeneration != generation ? "superseded" : State.ToString().ToLowerInvariant());
            if (!disposed && generation == currentGeneration) { operation = null; Notify(); }
        }
    }

    public void SetDataConsent(bool allowed)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy) return;
        AllowInstallerDataChanges = allowed && Review?.CanPreparePlan == true;
        Plan = null;
        if (Review is not null) State = ApplicationUninstallPageState.Reviewed;
        Notify();
    }
    public void Invalidate()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsExecuting) return;
        generation++;
        operation?.Cancel();
        operation = null;
        Review = null;
        Plan = null;
        Execution = null;
        executionPlan = null;
        StopRequested = false;
        ErrorCode = null;
        AllowInstallerDataChanges = false;
        authorizationRequired = false;
        State = ApplicationUninstallPageState.Empty;
        Notify();
    }
    public void Cancel()
    {
        if (disposed || operation is null || StopRequested) return;
        StopRequested = true;
        operation.Cancel();
        Notify();
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        operation?.Cancel();
        operation = null;
        Review = null;
        Plan = null;
        Execution = null;
        executionPlan = null;
        StopRequested = false;
        ErrorCode = null;
        AllowInstallerDataChanges = false;
        State = ApplicationUninstallPageState.Empty;
        GC.SuppressFinalize(this);
    }
    private void Notify()
    {
        if (disposed) return;
        foreach (var property in new[] { nameof(State), nameof(Review), nameof(Plan), nameof(Execution), nameof(ExecutionPlanId), nameof(ErrorCode), nameof(AllowInstallerDataChanges),
            nameof(IsBusy), nameof(BlocksSelection), nameof(RequiresAuthorization), nameof(IsAuthorized), nameof(CanClose), nameof(IsExecuting), nameof(StopRequested), nameof(ExecutionAvailable), nameof(CanPreparePlan), nameof(CanExecute), nameof(CanReadExecution) })
            PropertyChanged?.Invoke(this, new(property));
    }
    private void RequireNotExecuting()
    { if (IsExecuting) throw new ShouException("store_busy", "Wait for the current system installer outcome before changing the reviewed application."); }
}
