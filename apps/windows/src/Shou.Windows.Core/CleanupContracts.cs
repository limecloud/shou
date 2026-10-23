using System.Collections.Immutable;

namespace Shou.Windows.Core;

public enum CleanupAction { Permanent, Trash }
public enum CleanupExecutionState { Executing, Completed, Partial, Cancelled, Unknown }
public enum CleanupItemState { Pending, Purging, Moving, Purged, Trashed, Failed, Skipped, Cancelled, Unknown }
public enum CleanupMutationOutcome { Completed, Failed, Cancelled, Unknown }
public enum ActivityState { Idle, Active, Unknown }

public sealed record ActivityObservation(ActivityState State, string? Reason = null);

public sealed record CleanupSelection(string ScanId, ImmutableArray<string> CandidateIds);
public sealed record CleanupPlanSource(string ScanId, Workspace Workspace, ImmutableArray<ScanRule> Rules);

public sealed record CleanupPlanItem(string Id, string ScanId, string CandidateId, string RuleId, string RuleVersion, string RelativePath,
    WindowsPath Path, ImmutableArray<FileEntry> Manifest, ImmutableArray<FileEntry> Context, string ManifestDigest,
    long AllocatedBytes, long LogicalBytes, string Risk);

public sealed record CleanupPlan(int Version, string Id, ImmutableArray<CleanupPlanSource> Sources, ScanBudget Budget,
    string ConfigurationRevision, string ConfigurationDigest,
    DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, CleanupAction Action, ImmutableArray<CleanupPlanItem> Items, string Digest);

public sealed record CleanupItemResult(string ItemId, CleanupItemState State, int RemovedEntries = 0, string? Reason = null,
    WindowsPath? ResultPath = null, FileIdentity? ResultIdentity = null);

public sealed record CleanupExecution(int Version, string Id, string PlanId, string PlanDigest, CleanupAction Action,
    DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, CleanupExecutionState State, ImmutableArray<CleanupItemResult> Items);

public sealed record CleanupMutationResult(CleanupMutationOutcome Outcome, int RemovedEntries = 0, string? Reason = null,
    WindowsPath? ResultPath = null, FileIdentity? ResultIdentity = null);

public sealed record CleanupReviewItem(string ItemId, WindowsPath Path, string RuleId, string Risk, long AllocatedBytes, int ManifestEntries);
public sealed record CleanupReview(string PlanId, string Digest, CleanupAction Action, DateTimeOffset ExpiresAt,
    ImmutableArray<CleanupReviewItem> Items);
public sealed record CleanupProgress(string Phase, string? ItemId, WindowsPath? Path, int ProcessedItems, int TotalItems);

public interface ICleanupConfirmation
{
    Task<bool> RequestAsync(CleanupReview review, CancellationToken cancellationToken);
}

public interface ICleanupActivity
{
    Task<ActivityObservation> InspectAsync(Workspace workspace, CleanupPlanItem item, CancellationToken cancellationToken);
}

/// <summary>Implementations reverify identities and exact manifests at native mutation boundaries; never recurse by path.</summary>
public interface ICleanupMutation
{
    bool Supports(CleanupAction action);
    Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken cancellationToken);
}

/// <summary>Current-call confirmation. It cannot be constructed or restored from a stored approval value.</summary>
public sealed class CleanupConsent
{
    private readonly Guid issuer;
    private readonly string planId;
    private readonly string digest;
    private readonly CleanupAction action;
    private readonly DateTimeOffset expiresAt;
    private int consumed;

    internal CleanupConsent(Guid issuer, CleanupPlan plan, DateTimeOffset expiresAt)
    {
        this.issuer = issuer;
        planId = plan.Id;
        digest = plan.Digest;
        action = plan.Action;
        this.expiresAt = expiresAt;
    }

    internal void Consume(Guid expectedIssuer, CleanupPlan plan, DateTimeOffset now)
    {
        if (issuer != expectedIssuer || planId != plan.Id || digest != plan.Digest || action != plan.Action || now >= expiresAt ||
            Interlocked.Exchange(ref consumed, 1) != 0)
            throw new ShouException("confirmation_required", "Review and confirm the current plan in this process before execution.");
    }
}
