using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record PrivacyPlan(int Version, string Id, string ScanId, string ScanDigest, string OwnerSid,
    DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, PrivacyWindow Window, string ConfigurationDigest,
    ImmutableArray<PrivacySourceObservation> Sources, bool SignOutAcknowledged, string Digest);

public enum PrivacyExecutionState { Executing, Completed, Partial }
public enum PrivacyItemState { Pending, Executing, Completed, Failed, Cancelled, Skipped, Unknown }
public enum PrivacyMutationOutcome { Unknown, Completed, RolledBack, NotStarted, Cancelled }
public sealed record PrivacyItemResult(string SourceId, PrivacyItemState State, long? RemovedRecords, string? Reason);
/// <summary>Sanitized durable outcomes; no profile descriptors, paths, row values, SQL or restoration data.</summary>
public sealed record PrivacyReceipt(int Version, string Id, string PlanId, string PlanDigest, PrivacyWindow Window,
    DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, PrivacyExecutionState State, ImmutableArray<PrivacyItemResult> Items, string Digest);
public sealed record PrivacyMutationResult(PrivacyMutationOutcome Outcome, long? RemovedRecords = null, string? Reason = null);
public sealed record PrivacyMutationRequest(PrivacySourceObservation Source, PrivacyWindow Window, string OwnerSid, DateTimeOffset AuthorizationExpiresAt);
public readonly record struct PrivacyConfirmationDecision(bool IrreversibleDeletion, bool SignOut);
public interface IPrivacyConfirmation
{
    Task<PrivacyConfirmationDecision> RequestAsync(PrivacyPlan plan, CancellationToken cancellationToken);
}
public interface IPrivacyMutation
{
    bool Available { get; }
    /// <summary>Revalidate native identity/activity and count inside one immediate SQLite transaction.
    /// Return only after commit/rollback and handle release. Unknown outcomes must never imply rollback.</summary>
    Task<PrivacyMutationResult> ApplyAsync(PrivacyMutationRequest request, CancellationToken cancellationToken);
}

/// <summary>Current, process-local and single-use confirmation, never restored from stored acknowledgement fields.</summary>
public sealed class PrivacyConsent
{
    private readonly Guid issuer;
    private readonly string planId, digest;
    private readonly DateTimeOffset issuedAt, expiresAt;
    private int consumed;
    internal PrivacyConsent(Guid issuer, PrivacyPlan plan, DateTimeOffset issuedAt)
    {
        this.issuer = issuer; planId = plan.Id; digest = plan.Digest; this.issuedAt = issuedAt;
        expiresAt = new[] { plan.ExpiresAt, issuedAt + TimeSpan.FromMinutes(1) }.Min();
    }
    internal void Consume(Guid expectedIssuer, PrivacyPlan plan, DateTimeOffset now)
    {
        RequireCurrent(now);
        if (issuer != expectedIssuer || planId != plan.Id || digest != plan.Digest || Interlocked.Exchange(ref consumed, 1) != 0)
            throw new ShouException("confirmation_required", "Confirm this exact privacy plan in the current process before execution.");
    }
    internal void RequireCurrent(DateTimeOffset now)
    {
        if (now < issuedAt || now >= expiresAt) throw new ShouException("confirmation_required", "The current privacy confirmation expired or its clock moved backwards.");
    }
}
