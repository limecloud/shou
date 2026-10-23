using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

public enum StartupControlAction { Enable, Disable }
public enum StartupControlState { Applying, Completed, Failed, Cancelled, Unknown }
public enum StartupControlNativeOutcome { Applied, NotStarted, Unknown }

// Only the current actor SID is retained. Other owners/principals remain boolean eligibility facts.
public sealed record StartupControlTask(string TaskPath, string DefinitionDigest, string ActorSid, bool Enabled,
    bool OwnerMatchesActor, bool PrincipalMatchesActor, bool InteractiveToken, bool LeastPrivilege,
    bool ProtectedLocation, ImmutableArray<string> Issues);
public interface IStartupControlInspector
{
    Task<StartupControlTask> InspectAsync(string taskPath, CancellationToken cancellationToken);
}
public sealed record StartupControlReview(int Version, string Id, StartupControlAction Action, StartupControlTask Task,
    DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, ImmutableArray<string> BlockingReasons, string Digest)
{
    public bool DesiredEnabled => Action == StartupControlAction.Enable;
    public bool CanChange => BlockingReasons.IsEmpty;
    public bool ExecutionAvailable => false;
}
public interface IStartupControlConfirmation
{
    Task<bool> RequestAsync(StartupControlReview review, CancellationToken cancellationToken);
}
public sealed record StartupControlNativeResult(StartupControlNativeOutcome Outcome, bool? ObservedEnabled,
    bool? DefinitionMatches, string? Reason = null);
public interface IStartupControlMutation
{
    bool Available { get; }
    // Recheck actor and exact definition before changing only task Enabled. Await the real result once dispatched.
    Task<StartupControlNativeResult> ApplyAsync(StartupControlReview review, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken);
}
public sealed record StartupControlExecution(int Version, string Id, StartupControlReview Review, DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt, StartupControlState State, StartupControlNativeResult? Result)
{
    public bool ObservationRequired => State is StartupControlState.Applying or StartupControlState.Unknown;
    public bool RetryAvailable => false;
    public bool RestoreAvailable => false;
}

public sealed class StartupControlReviewer(IStartupControlInspector inspector, string ownerSid, TimeProvider? timeProvider = null)
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(5);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<StartupControlReview> InspectAsync(string taskPath, StartupControlAction action, CancellationToken cancellationToken = default)
    {
        if (!ValidTaskPath(taskPath) || !Enum.IsDefined(action) || !ApplicationUninstallReviewer.Sid(ownerSid)) throw Input();
        cancellationToken.ThrowIfCancellationRequested();
        var task = await inspector.InspectAsync(taskPath, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (task is null || !string.Equals(task.TaskPath, taskPath, StringComparison.OrdinalIgnoreCase)) throw InvalidObservation();
        ValidateTask(task, ownerSid);
        var now = clock.GetUtcNow();
        var review = new StartupControlReview(1, RecordKey.New("startup_control"), action, task, now, now + Lifetime, Reasons(task, action), "");
        return review with { Digest = Digest(review) };
    }

    public static bool ValidTaskPath(string? path) => StartupInventoryService.DisplayText(path, 32760) && path![0] == '\\' &&
        path.Length > 1 && !path.Split('\\').Skip(1).Any(part => part.Length == 0 || part is "." or ".." || part.Contains('/'));
    internal static string Digest(StartupControlReview review) => RecordJson.Digest(new { review.Action, review.Task, review.BlockingReasons });
    internal static void ValidateReview(StartupControlReview review, string ownerSid)
    {
        if (review is null || review.Version != 1 || !RecordKey.IsId(review.Id, "startup_control") || !Enum.IsDefined(review.Action) ||
            review.CreatedAt.Offset != TimeSpan.Zero || review.ExpiresAt.Offset != TimeSpan.Zero || review.ExpiresAt - review.CreatedAt != Lifetime ||
            review.Task is null || review.BlockingReasons.IsDefault) throw InvalidObservation();
        ValidateTask(review.Task, ownerSid);
        if (!review.BlockingReasons.SequenceEqual(Reasons(review.Task, review.Action)) || review.Digest != Digest(review)) throw InvalidObservation();
    }
    private static void ValidateTask(StartupControlTask task, string ownerSid)
    {
        if (!ValidTaskPath(task.TaskPath) || !RecordJson.IsDigest(task.DefinitionDigest) || task.ActorSid != ownerSid ||
            !ApplicationUninstallReviewer.Sid(task.ActorSid) || task.Issues.IsDefault || task.Issues.Length > 16 ||
            task.Issues.Any(issue => !ApplicationUninstallReviewer.Code(issue))) throw InvalidObservation();
    }
    private static ImmutableArray<string> Reasons(StartupControlTask task, StartupControlAction action)
    {
        var reasons = ImmutableArray.CreateBuilder<string>();
        if (task.ProtectedLocation || task.TaskPath.Equals(@"\Microsoft", StringComparison.OrdinalIgnoreCase) ||
            task.TaskPath.StartsWith(@"\Microsoft\", StringComparison.OrdinalIgnoreCase)) reasons.Add("protected_startup_task");
        if (!task.OwnerMatchesActor) reasons.Add("startup_task_owner_not_current_user");
        if (!task.PrincipalMatchesActor) reasons.Add("startup_task_principal_not_current_user");
        if (!task.InteractiveToken || !task.LeastPrivilege) reasons.Add("unsupported_startup_task_context");
        if (task.Enabled == (action == StartupControlAction.Enable)) reasons.Add("startup_task_already_in_requested_state");
        reasons.AddRange(task.Issues);
        return reasons.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray();
    }
    private static ShouException Input() => new("invalid_argument", "Choose an exact scheduled-task path and enable or disable action.");
    private static ShouException InvalidObservation() => new("startup_inspection_invalid", "The startup task observation is invalid or belongs to another actor.");
}

public sealed class StartupControlService(IRecordStore store, StartupControlReviewer reviewer, IStartupControlMutation mutation,
    string ownerSid, TimeProvider? timeProvider = null)
{
    public const int MaximumExecutionBytes = 262_144;
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<StartupControlExecution> ExecuteAsync(StartupControlReview review, IStartupControlConfirmation confirmation,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(confirmation);
        StartupControlReviewer.ValidateReview(review, ownerSid);
        RequireCurrent(review);
        if (!review.CanChange || !mutation.Available) throw new ShouException("unsupported_capability", "This scheduled-task change is unavailable. Read its eligibility review.");
        if (await store.ReadAsync(review.Id, MaximumExecutionBytes, cancellationToken).ConfigureAwait(false) is not null)
            throw new ShouException("plan_consumed", "This startup operation already has a durable intent. Read its result; do not replay it.");
        await RecheckAsync(review, cancellationToken).ConfigureAwait(false);
        RequireCurrent(review);
        if (!await confirmation.RequestAsync(review, cancellationToken).ConfigureAwait(false))
            throw new ShouException("confirmation_required", "Confirm the exact scheduled task and action in the current process.");
        cancellationToken.ThrowIfCancellationRequested();
        RequireCurrent(review);
        var confirmedAt = clock.GetUtcNow();
        var authorizationExpiresAt = new[] { review.ExpiresAt, confirmedAt + TimeSpan.FromMinutes(1) }.Min();
        await using var lease = await store.AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
        if (await lease.ReadAsync(review.Id, MaximumExecutionBytes, cancellationToken).ConfigureAwait(false) is not null)
            throw new ShouException("plan_consumed", "This startup operation already has a durable intent. Read its result; do not replay it.");
        await RecheckAsync(review, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        RequireCurrent(review);
        var now = clock.GetUtcNow();
        if (!mutation.Available) throw new ShouException("unsupported_capability", "Scheduled-task changes are unavailable on this host.");
        if (now < confirmedAt || now >= authorizationExpiresAt) throw new ShouException("confirmation_required", "The current startup confirmation expired during verification.");
        var execution = new StartupControlExecution(1, review.Id, review, now, now, StartupControlState.Applying, null);
        await SaveAsync(lease, execution).ConfigureAwait(false);
        StartupControlNativeResult result;
        try
        {
            result = cancellationToken.IsCancellationRequested
                ? new(StartupControlNativeOutcome.NotStarted, null, null, "cancelled_before_startup_change")
                : await mutation.ApplyAsync(review, authorizationExpiresAt, cancellationToken).ConfigureAwait(false);
            if (!ValidResult(result)) result = Unknown("invalid_native_result");
        }
        catch (Exception error) when (error is not OutOfMemoryException) { result = Unknown("startup_result_unknown"); }
        execution = execution with { Result = result, State = State(review, result), UpdatedAt = new[] { now, clock.GetUtcNow() }.Max() };
        await SaveAsync(lease, execution).ConfigureAwait(false);
        return execution;
    }

    public async Task<StartupControlExecution> ShowAsync(string operationId, CancellationToken cancellationToken = default)
    {
        if (!RecordKey.IsId(operationId, "startup_control")) throw new ShouException("invalid_argument", "Choose a valid startup operation identifier.");
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken).ConfigureAwait(false);
        var bytes = lease is null ? null : await lease.ReadAsync(operationId, MaximumExecutionBytes, cancellationToken).ConfigureAwait(false);
        if (bytes is null) throw new ShouException("not_found", "No startup operation was recorded. This does not establish the current task state.");
        try
        {
            var execution = JsonSerializer.Deserialize<StartupControlExecution>(bytes, ContractJson.Options) ?? throw Corrupt();
            Validate(execution);
            if (execution.Id != operationId) throw Corrupt();
            return execution;
        }
        catch (Exception error) when (error is JsonException or ShouException or ArgumentException or NullReferenceException)
        { throw new ShouException("corrupt_record", "The startup operation record is invalid; it was not replayed or changed.", error); }
    }
    private async Task RecheckAsync(StartupControlReview review, CancellationToken token)
    {
        var current = await reviewer.InspectAsync(review.Task.TaskPath, review.Action, token).ConfigureAwait(false);
        if (!current.CanChange || current.Digest != review.Digest) throw new ShouException("startup_changed", "The task or actor changed. Review and confirm a fresh observation.");
    }
    private void RequireCurrent(StartupControlReview review)
    {
        var now = clock.GetUtcNow();
        if (now < review.CreatedAt || now >= review.ExpiresAt) throw new ShouException("plan_stale", "Review and confirm the startup task again before changing it.");
    }
    private void Validate(StartupControlExecution execution)
    {
        StartupControlReviewer.ValidateReview(execution.Review, ownerSid);
        if (execution.Version != 1 || execution.Id != execution.Review.Id || !execution.Review.CanChange ||
            execution.StartedAt.Offset != TimeSpan.Zero || execution.UpdatedAt.Offset != TimeSpan.Zero ||
            execution.StartedAt < execution.Review.CreatedAt || execution.StartedAt >= execution.Review.ExpiresAt || execution.UpdatedAt < execution.StartedAt ||
            !Enum.IsDefined(execution.State) || (execution.State == StartupControlState.Applying
                ? execution.Result is not null || execution.UpdatedAt != execution.StartedAt
                : !ValidResult(execution.Result) || execution.State != State(execution.Review, execution.Result!))) throw Corrupt();
    }
    private async Task SaveAsync(IRecordLease lease, StartupControlExecution execution)
    {
        Validate(execution);
        try { await lease.WriteAsync(execution.Id, RecordJson.Encode(execution, MaximumExecutionBytes), CancellationToken.None).ConfigureAwait(false); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { throw new ShouException("journal_write_failed", execution.State == StartupControlState.Applying
            ? "Startup intent publication could not be confirmed. No task setter was invoked; inspect the operation record."
            : "The task may have changed, but the outcome could not be saved. Inspect the operation record and current task state.", error); }
    }
    private static bool ValidResult(StartupControlNativeResult? value) => value is not null && Enum.IsDefined(value.Outcome) &&
        (value.Reason is null || ApplicationUninstallReviewer.Code(value.Reason)) &&
        (value.Outcome != StartupControlNativeOutcome.NotStarted || value.ObservedEnabled is null && value.DefinitionMatches is null);
    private static StartupControlState State(StartupControlReview review, StartupControlNativeResult result) => result.Outcome switch
    {
        StartupControlNativeOutcome.Applied when result.DefinitionMatches == true && result.ObservedEnabled == review.DesiredEnabled => StartupControlState.Completed,
        StartupControlNativeOutcome.NotStarted when result.Reason == "cancelled_before_startup_change" => StartupControlState.Cancelled,
        StartupControlNativeOutcome.NotStarted => StartupControlState.Failed,
        _ => StartupControlState.Unknown
    };
    private static StartupControlNativeResult Unknown(string reason) => new(StartupControlNativeOutcome.Unknown, null, null, reason);
    private static ShouException Corrupt() => new("corrupt_record", "The startup execution does not match its reviewed task.");
}
