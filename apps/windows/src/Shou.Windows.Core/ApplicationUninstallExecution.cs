using System.Text.Json;

namespace Shou.Windows.Core;

public enum ApplicationUninstallState { Uninstalling, Completed, Failed, Cancelled, Unknown }
public enum SystemUninstallOutcome { Succeeded, Failed, Cancelled, NotStarted, Unknown }
public enum InstallationPresence { Present, Absent, Changed, Unknown }

/// <summary>The installer report and the subsequent identity observation are independent facts.</summary>
public sealed record ApplicationUninstallResult(SystemUninstallOutcome Outcome, InstallationPresence Presence,
    int? NativeCode = null, bool RestartRequired = false, string? Reason = null);

public sealed record ApplicationUninstallExecution(int Version, string Id, string PlanId, string PlanDigest, string OwnerSid,
    DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, ApplicationUninstallState State, ApplicationUninstallResult? Result)
{
    public bool ObservationRequired => State is ApplicationUninstallState.Uninstalling or ApplicationUninstallState.Unknown;
    public bool RetryAvailable => false;
    public bool RestoreAvailable => false;
}

public interface IApplicationUninstallConfirmation
{
    Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken);
}

/// <summary>Recheck current identity, actor and activity immediately before invoking the system installer.
/// Once started, await its actual completion without killing it or abandoning the caller's mutation lease.</summary>
public interface IApplicationUninstallMutation
{
    bool Supports(ApplicationInstallerKind kind);
    Task<ApplicationUninstallResult> ApplyAsync(ApplicationUninstallReview review, string ownerSid, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken);
}

/// <summary>An in-process, single-use confirmation; never serialized or reconstructed from local approval fields.</summary>
public sealed class ApplicationUninstallConsent
{
    private readonly Guid issuer;
    private readonly string planId;
    private readonly string digest;
    internal DateTimeOffset ExpiresAt { get; }
    private int consumed;

    internal ApplicationUninstallConsent(Guid issuer, ApplicationUninstallPlan plan, DateTimeOffset expiresAt)
    { this.issuer = issuer; planId = plan.Id; digest = plan.Digest; ExpiresAt = expiresAt; }

    internal void Consume(Guid expectedIssuer, ApplicationUninstallPlan plan, DateTimeOffset now)
    {
        if (issuer != expectedIssuer || planId != plan.Id || digest != plan.Digest || now >= ExpiresAt ||
            Interlocked.Exchange(ref consumed, 1) != 0)
            throw new ShouException("confirmation_required", "Review and confirm this uninstall plan in the current process before execution.");
    }

    internal void RequireCurrent(DateTimeOffset now)
    { if (now >= ExpiresAt) throw new ShouException("confirmation_required", "The uninstall confirmation expired during verification. Confirm the current plan again."); }
}

public sealed class ApplicationUninstallService(IRecordStore store, ApplicationUninstallReviewer reviewer, string ownerSid,
    IApplicationUninstallMutation mutation, TimeProvider? timeProvider = null)
{
    public const int MaximumExecutionBytes = 16_384;
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly ApplicationUninstallPlanner plans = new(store, reviewer, ownerSid, timeProvider);
    private readonly Guid confirmationIssuer = Guid.NewGuid();

    public async Task<ApplicationUninstallConsent> ConfirmAsync(string planId, IApplicationUninstallConfirmation confirmation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(confirmation);
        var plan = await plans.ShowAsync(planId, cancellationToken).ConfigureAwait(false);
        RequireCurrent(plan);
        RequireSupported(plan);
        RequireUnused(await store.ReadAsync(ExecutionId(planId), MaximumExecutionBytes, cancellationToken).ConfigureAwait(false));
        await RecheckAsync(plan, cancellationToken).ConfigureAwait(false);
        RequireCurrent(plan);
        if (!await confirmation.RequestAsync(plan, cancellationToken).ConfigureAwait(false)) throw ConfirmationRequired();
        cancellationToken.ThrowIfCancellationRequested();
        RequireCurrent(plan);
        return new(confirmationIssuer, plan, new[] { plan.ExpiresAt, clock.GetUtcNow() + TimeSpan.FromMinutes(1) }.Min());
    }

    public async Task<ApplicationUninstallExecution> ExecuteAsync(string planId, ApplicationUninstallConsent? consent,
        CancellationToken cancellationToken = default)
    {
        var key = ExecutionId(planId);
        if (consent is null) throw ConfirmationRequired();
        await using var lease = await store.AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
        var plan = plans.Decode(await lease.ReadAsync(planId, ApplicationUninstallPlanner.MaximumPlanBytes, cancellationToken).ConfigureAwait(false)
            ?? throw new ShouException("not_found", "The uninstall plan does not exist."), planId);
        RequireCurrent(plan);
        RequireSupported(plan);
        RequireUnused(await lease.ReadAsync(key, MaximumExecutionBytes, cancellationToken).ConfigureAwait(false));
        consent.Consume(confirmationIssuer, plan, clock.GetUtcNow());
        await RecheckAsync(plan, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        RequireCurrent(plan);
        consent.RequireCurrent(clock.GetUtcNow());
        var now = clock.GetUtcNow();
        var execution = new ApplicationUninstallExecution(1, key, plan.Id, plan.Digest, ownerSid, now, now,
            ApplicationUninstallState.Uninstalling, null);
        // Publication must complete before any installer can start. The durable intent also consumes the plan.
        await SaveAsync(lease, execution, plan).ConfigureAwait(false);
        ApplicationUninstallResult result;
        try
        {
            result = cancellationToken.IsCancellationRequested
                ? new(SystemUninstallOutcome.NotStarted, InstallationPresence.Unknown, Reason: "cancelled_before_installer")
                : await mutation.ApplyAsync(plan.Review, ownerSid, consent.ExpiresAt, cancellationToken).ConfigureAwait(false);
            if (!ValidResult(result)) result = Unknown("invalid_native_result");
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            // An exception after durable intent is not proof that the installer made no changes.
            result = Unknown("native_result_unknown");
        }
        execution = execution with { State = State(result), Result = result, UpdatedAt = new[] { now, clock.GetUtcNow() }.Max() };
        // Caller cancellation must not discard a real installer result or release the lease prematurely.
        await SaveAsync(lease, execution, plan).ConfigureAwait(false);
        return execution;
    }

    public async Task<ApplicationUninstallExecution> ShowAsync(string planId, CancellationToken cancellationToken = default)
    {
        var key = ExecutionId(planId);
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken).ConfigureAwait(false);
        if (lease is null) throw new ShouException("not_found", "No uninstall execution was recorded for this plan.");
        var plan = plans.Decode(await lease.ReadAsync(planId, ApplicationUninstallPlanner.MaximumPlanBytes, cancellationToken).ConfigureAwait(false)
            ?? throw new ShouException("not_found", "The uninstall plan does not exist."), planId);
        var bytes = await lease.ReadAsync(key, MaximumExecutionBytes, cancellationToken).ConfigureAwait(false)
            ?? throw new ShouException("not_found", "No uninstall execution was recorded for this plan.");
        try
        {
            var execution = JsonSerializer.Deserialize<ApplicationUninstallExecution>(bytes, ContractJson.Options) ?? throw Corrupt();
            Validate(execution, plan);
            return execution;
        }
        catch (Exception error) when (error is JsonException or ShouException or ArgumentException or NullReferenceException)
        { throw new ShouException("corrupt_record", "The uninstall execution is invalid. It was not replayed or changed.", error); }
    }

    public static string ExecutionId(string planId) => RecordKey.IsId(planId, "uninstall_plan")
        ? "uninstall_execution_" + planId["uninstall_plan_".Length..]
        : throw new ShouException("invalid_argument", "Choose a valid uninstall plan identifier.");

    private async Task RecheckAsync(ApplicationUninstallPlan plan, CancellationToken token)
    {
        var current = await reviewer.InspectAsync(plan.Review.Application.Id, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (!current.CanPreparePlan || current.Digest != plan.Review.Digest)
            throw new ShouException("application_changed", "The installation or activity changed. Inspect it and prepare a new plan.");
    }
    private void RequireCurrent(ApplicationUninstallPlan plan)
    {
        var now = clock.GetUtcNow();
        if (now < plan.CreatedAt || now >= plan.ExpiresAt) throw new ShouException("plan_stale", "The uninstall plan is no longer current. Prepare and confirm a new plan.");
    }
    private void RequireSupported(ApplicationUninstallPlan plan)
    {
        if (!mutation.Supports(plan.Review.Installation.Identity!.Kind)) throw new ShouException("unsupported_capability", "System uninstall execution is unavailable on this host.");
    }
    private static void RequireUnused(byte[]? bytes)
    { if (bytes is not null) throw new ShouException("plan_consumed", "This uninstall plan has a durable execution intent and cannot be replayed. Read its recorded outcome."); }
    private static async Task SaveAsync(IRecordLease lease, ApplicationUninstallExecution execution, ApplicationUninstallPlan plan)
    {
        Validate(execution, plan);
        try { await lease.WriteAsync(execution.Id, RecordJson.Encode(execution, MaximumExecutionBytes), CancellationToken.None).ConfigureAwait(false); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            throw new ShouException("journal_write_failed", execution.State == ApplicationUninstallState.Uninstalling
                ? "Uninstall intent publication could not be confirmed. No installer was invoked; inspect the saved execution before taking further action."
                : "The installer may have changed the installation, but its outcome could not be saved. Inspect the saved execution before taking further action.", error);
        }
    }
    private static void Validate(ApplicationUninstallExecution execution, ApplicationUninstallPlan plan)
    {
        if (execution.Version != 1 || execution.Id != ExecutionId(plan.Id) || execution.PlanId != plan.Id || execution.PlanDigest != plan.Digest ||
            execution.OwnerSid != plan.OwnerSid || execution.StartedAt.Offset != TimeSpan.Zero || execution.UpdatedAt.Offset != TimeSpan.Zero ||
            execution.StartedAt < plan.CreatedAt || execution.StartedAt >= plan.ExpiresAt || execution.UpdatedAt < execution.StartedAt ||
            !Enum.IsDefined(execution.State) || (execution.State == ApplicationUninstallState.Uninstalling
                ? execution.Result is not null || execution.UpdatedAt != execution.StartedAt
                : !ValidResult(execution.Result) || execution.State != State(execution.Result!))) throw Corrupt();
    }
    private static bool ValidResult(ApplicationUninstallResult? result) => result is not null && Enum.IsDefined(result.Outcome) &&
        Enum.IsDefined(result.Presence) && (result.Reason is null || ApplicationUninstallReviewer.Code(result.Reason)) &&
        (!result.RestartRequired || result.Outcome == SystemUninstallOutcome.Succeeded) &&
        (result.Outcome != SystemUninstallOutcome.NotStarted || result.NativeCode is null && !result.RestartRequired);
    private static ApplicationUninstallState State(ApplicationUninstallResult result) => result.Outcome switch
    {
        SystemUninstallOutcome.Succeeded when result.Presence == InstallationPresence.Absent => ApplicationUninstallState.Completed,
        SystemUninstallOutcome.Failed => ApplicationUninstallState.Failed,
        SystemUninstallOutcome.Cancelled => ApplicationUninstallState.Cancelled,
        SystemUninstallOutcome.NotStarted when result.Reason == "cancelled_before_installer" => ApplicationUninstallState.Cancelled,
        SystemUninstallOutcome.NotStarted => ApplicationUninstallState.Failed,
        _ => ApplicationUninstallState.Unknown
    };
    private static ApplicationUninstallResult Unknown(string reason) => new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown, Reason: reason);
    private static ShouException ConfirmationRequired() => new("confirmation_required", "Review and confirm the current uninstall plan before execution.");
    private static ShouException Corrupt() => new("corrupt_record", "The uninstall execution does not match the saved plan.");
}
