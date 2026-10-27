using System.Text.Json;

namespace Shou.Windows.Core;

public sealed record DeveloperLogInspection(string ToolId, FileEntry File, bool Writable);
public sealed record DeveloperLogCleanupPlan(string Id, DeveloperLogInspection Inspection, DateTimeOffset ExpiresAt);
public sealed record DeveloperLogCleanupResult(DeveloperLogCleanupPlan Plan, string State, DeveloperLogInspection? Observed, string? Issue);
public interface IDeveloperLogCleaning
{
    Task<DeveloperLogInspection> InspectAsync(CancellationToken cancellationToken);
    Task ClearAsync(DeveloperLogInspection expected, CancellationToken cancellationToken);
}

/// <summary>A current exact-file review authorizes one permanent truncation, with no recovery copy.</summary>
public sealed class DeveloperLogCleanup(IDeveloperLogCleaning platform, Func<IRecordStore> makeStore, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly SemaphoreSlim operation = new(1, 1);
    private DeveloperLogCleanupPlan? current;

    public async Task<DeveloperLogCleanupPlan> PrepareAsync(CancellationToken cancellationToken = default)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            current = null;
            var value = await platform.InspectAsync(cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrEmpty(value.ToolId) || value.File.Kind != EntryKind.File || value.File.LinkCount != 1 ||
                !value.Writable || value.File.LogicalBytes <= 0) throw Failure("developer_log_unavailable");
            return current = new(Guid.NewGuid().ToString("N"), value, clock.GetUtcNow().AddMinutes(2));
        }
        finally { operation.Release(); }
    }

    public async Task<DeveloperLogCleanupResult> ExecuteAsync(DeveloperLogCleanupPlan plan, string confirmedId, CancellationToken cancellationToken = default)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var saved = current; current = null;
            if (!ReferenceEquals(saved, plan) || confirmedId != plan.Id || clock.GetUtcNow() >= plan.ExpiresAt) throw Failure("confirmation_required");
            await using var lease = await makeStore().AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
            if (await platform.InspectAsync(cancellationToken).ConfigureAwait(false) != plan.Inspection || clock.GetUtcNow() >= plan.ExpiresAt)
                throw Failure("developer_log_changed");
            await lease.WriteAsync("developer_log_intent_" + plan.Id, JsonSerializer.SerializeToUtf8Bytes(plan), cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            DeveloperLogCleanupResult result;
            try
            {
                // Once dispatched, finish this one file and its read-back before permitting exit.
                await platform.ClearAsync(plan.Inspection, CancellationToken.None).ConfigureAwait(false);
                var after = await platform.InspectAsync(CancellationToken.None).ConfigureAwait(false);
                var verified = after.ToolId == plan.Inspection.ToolId && after.File.Path == plan.Inspection.File.Path &&
                    after.File.Identity == plan.Inspection.File.Identity && after.File.LogicalBytes == 0;
                result = new(plan, verified ? "succeeded" : "unknown", after, verified ? null : "developer_log_unverified");
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            { result = new(plan, "unknown", null, (error as ShouException)?.Code ?? "developer_log_unavailable"); }
            await lease.WriteAsync("developer_log_result_" + plan.Id, JsonSerializer.SerializeToUtf8Bytes(result), CancellationToken.None).ConfigureAwait(false);
            return result;
        }
        finally { operation.Release(); }
    }
    private static ShouException Failure(string code) => new(code, "Reload the exact log and review its current file before clearing it.");
}
