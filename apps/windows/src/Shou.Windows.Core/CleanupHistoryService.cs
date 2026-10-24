using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;

namespace Shou.Windows.Core;

/// <summary>Journal queries and bounded observations never change records, retry operations or grant recovery.</summary>
public sealed class CleanupHistoryService(IRecordStore store, RuleSchemaValidator validator, IWindowsFileSystem fileSystem,
    IStorageScanner scanner, string ownerSid, TimeProvider? timeProvider = null)
{
    public const int MaximumDirectoryEntries = 4096;
    public const int MaximumListBytes = 33_554_432;
    public static readonly TimeSpan ListDuration = TimeSpan.FromSeconds(10);
    private readonly CleanupRecordCodec records = new(validator);
    private readonly CleanupPlanRecords plans = new(new CleanupRecordCodec(validator));
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<CleanupHistoryPage> ListAsync(int limit = 50, string? cursor = null, CancellationToken cancellationToken = default)
    {
        if (limit is < 1 or > 500) throw Input("Choose a history page size from 1 to 500.");
        var continuation = ReadCursor(cursor, limit);
        using var deadline = new CancellationTokenSource(ListDuration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            var token = linked.Token;
            await using var lease = await store.AcquireReadLeaseAsync(token);
            var keys = lease is null ? [] : await lease.ListKeysAsync("execution", MaximumDirectoryEntries, token);
            var summaries = new List<CleanupHistorySummary>();
            var issues = ImmutableArray.CreateBuilder<CleanupHistoryIssue>();
            var fingerprints = new List<(string Id, string Digest)>();
            var stable = true;
            var totalBytes = 0;
            foreach (var key in keys.Order(StringComparer.Ordinal))
            {
                token.ThrowIfCancellationRequested();
                var fingerprinted = false;
                try
                {
                    var bytes = await lease!.ReadAsync(key, CleanupRecordCodec.MaximumExecutionBytes, token)
                        ?? throw new ShouException("source_changed", "An execution record disappeared during enumeration.");
                    totalBytes = checked(totalBytes + bytes.Length);
                    if (totalBytes > MaximumListBytes) throw new ListBudgetException();
                    fingerprints.Add((key, Convert.ToHexStringLower(SHA256.HashData(bytes))));
                    fingerprinted = true;
                    var execution = records.DecodeExecutionSummary(bytes, key);
                    summaries.Add(new(execution.Id, execution.PlanId, execution.Action, execution.StartedAt, execution.UpdatedAt,
                        execution.State, execution.Items.Length, execution.Items.Count(item => item.State is CleanupItemState.Purged or CleanupItemState.Trashed),
                        Unfinished(execution), Uncertain(execution)));
                }
                catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
                {
                    var code = ErrorCode(error);
                    issues.Add(new(key, code));
                    // Unreadable records cannot produce a stable continuation token.
                    if (!fingerprinted) { stable = false; fingerprints.Add((key, "unreadable:" + code)); }
                }
            }
            token.ThrowIfCancellationRequested();
            var digest = RecordJson.Digest(fingerprints.Select(value => new { execution_id = value.Id, digest = value.Digest }).ToArray());
            var ordered = summaries.OrderByDescending(value => value.StartedAt).ThenBy(value => value.ExecutionId, StringComparer.Ordinal).ToArray();
            var offset = continuation?.Offset ?? 0;
            if (continuation is not null && (continuation.Digest != digest || !stable || offset >= ordered.Length))
                throw new ShouException("source_changed", "The history changed or could not be fully read. Start a new history query.");
            var entries = ordered.Skip(offset).Take(limit).ToImmutableArray();
            var nextOffset = offset + entries.Length;
            var next = nextOffset < ordered.Length && stable
                ? Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new HistoryCursor(1, digest, nextOffset, limit), ContractJson.Options)) : null;
            return new(issues.Count == 0 ? "complete" : "partial", digest, keys.Length, entries, issues.ToImmutable(), next);
        }
        catch (ListBudgetException) { throw new ShouException("resource_limit", "History exceeds its 32 MiB read budget. No partial list is presented as complete."); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        { throw new ShouException("time_limit", "History could not be read within ten seconds."); }
    }

    public async Task<CleanupPlan> PlanAsync(string planId, CancellationToken cancellationToken = default)
    {
        if (!RecordKey.IsId(planId, "plan")) throw Input("Choose a valid plan identifier.");
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken);
        return await ReadPlanAsync(lease, planId, cancellationToken);
    }

    public async Task<CleanupHistoryDetail> ShowAsync(string executionId, CancellationToken cancellationToken = default)
    {
        ValidateExecutionId(executionId);
        await using var lease = await store.AcquireReadLeaseAsync(cancellationToken);
        return await ReadDetailAsync(lease, executionId, cancellationToken);
    }

    public async Task<CleanupHistoryInspection> InspectAsync(string executionId, ScanBudget budget, CancellationToken cancellationToken = default)
    {
        ValidateExecutionId(executionId);
        budget.Validate();
        using var deadline = new CancellationTokenSource(budget.Duration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var started = clock.GetTimestamp();
        var token = linked.Token;
        try
        {
            await using var lease = await store.AcquireReadLeaseAsync(token);
            var detail = await ReadDetailAsync(lease, executionId, token);
            var entriesLeft = budget.MaxEntries;
            var items = ImmutableArray.CreateBuilder<CleanupHistoryInspectionItem>();
            for (var index = 0; index < detail.Plan.Items.Length; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var source = detail.Plan.Items[index];
                var result = detail.Execution.Items[index];
                var original = await ObserveAsync(source.Path, source, budget, entriesLeft, started, token, cancellationToken);
                entriesLeft -= original.ObservedEntries;
                var trash = result.ResultPath is { } path
                    ? await ObserveAsync(path, source, budget, entriesLeft, started, token, cancellationToken)
                    : new HistoryLocation(null, HistoryLocationState.NotRecorded, true);
                entriesLeft -= trash.ObservedEntries;
                items.Add(new(source.Id, result.State, original, trash, Assess(result, original, trash)));
            }
            cancellationToken.ThrowIfCancellationRequested();
            var values = items.ToImmutable();
            var uncertain = detail.NeedsVerification || values.Any(item => item.Assessment is "needs_verification" or "conflict");
            return new(executionId, detail.Execution.State, clock.GetUtcNow(), !uncertain && values.All(item => item.Original.Complete && item.Trash.Complete) ? "complete" : "partial",
                detail.Unfinished, uncertain,
                budget.MaxEntries - entriesLeft, values);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        { throw new ShouException("time_limit", "The execution record could not be opened within the inspection budget."); }
    }

    private async Task<HistoryLocation> ObserveAsync(WindowsPath path, CleanupPlanItem item, ScanBudget budget, int entriesLeft,
        long started, CancellationToken token, CancellationToken externalToken)
    {
        var count = 0;
        try
        {
            externalToken.ThrowIfCancellationRequested();
            if (entriesLeft < 1) return new(path, HistoryLocationState.Unavailable, false, Reason: "entry_limit");
            token.ThrowIfCancellationRequested();
            count = 1;
            var root = await fileSystem.InspectAsync(path, token);
            var expected = item.Manifest[0] with { Path = path };
            if (root != expected) return new(path, HistoryLocationState.Changed, true, count, "identity_or_metadata_changed");
            if (root.Kind == EntryKind.File) return new(path, HistoryLocationState.Matches, true, count);
            var remaining = budget.Duration - clock.GetElapsedTime(started);
            if (remaining <= TimeSpan.Zero) return new(path, HistoryLocationState.Unavailable, false, count, "time_limit");
            if (entriesLeft <= count) return new(path, HistoryLocationState.Unavailable, false, count, "entry_limit");
            var scan = await scanner.ScanAsync(path, budget with { MaxEntries = entriesLeft - count, MaxDuration = remaining }, null, token);
            count += scan.Entries.Length;
            externalToken.ThrowIfCancellationRequested();
            if (!scan.IsComplete || !scan.IsCompleteAt(path))
                return new(path, HistoryLocationState.Unavailable, false, count, token.IsCancellationRequested ? "time_limit" : scan.Issues.FirstOrDefault()?.Code ?? "incomplete_manifest");
            var manifest = item.Manifest.Select(entry => entry with
            {
                Path = entry.Path == item.Path ? path : path.Append(entry.Path.RelativeTo(item.Path, caseSensitive: true))
            }).OrderBy(entry => entry.Path.Value, StringComparer.Ordinal);
            var actual = scan.Entries.Select(value => value.Entry).OrderBy(entry => entry.Path.Value, StringComparer.Ordinal);
            var matches = scan.Root == path && scan.RootIdentity == expected.Identity && manifest.SequenceEqual(actual);
            return new(path, matches ? HistoryLocationState.Matches : HistoryLocationState.Changed, true, count,
                matches ? null : "manifest_changed");
        }
        catch (OperationCanceledException) when (!externalToken.IsCancellationRequested)
        { return new(path, HistoryLocationState.Unavailable, false, count, "time_limit"); }
        catch (ShouException error) when (error.Code == "not_found")
        { return new(path, HistoryLocationState.Missing, true, count); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return new(path, HistoryLocationState.Unavailable, false, count, ErrorCode(error)); }
    }

    private async Task<CleanupHistoryDetail> ReadDetailAsync(IRecordReadLease? lease, string id, CancellationToken token)
    {
        var bytes = lease is null ? null : await lease.ReadAsync(id, CleanupRecordCodec.MaximumExecutionBytes, token);
        var summary = records.DecodeExecutionSummary(bytes ?? throw Missing(), id);
        var plan = await ReadPlanAsync(lease, summary.PlanId, token);
        var execution = records.DecodeExecution(bytes!, plan);
        return new(plan, execution, Unfinished(execution), Uncertain(execution));
    }

    private async Task<CleanupPlan> ReadPlanAsync(IRecordReadLease? lease, string id, CancellationToken token)
    {
        if (lease is null) throw Missing();
        CleanupPlan plan;
        try { plan = await plans.ReadAsync(lease, id, token); }
        catch (ShouException error) when (error.Code == "invalid_argument") { throw Missing(); }
        if (plan.Sources.Any(source => source.Workspace.Identity.OwnerSid != ownerSid)) throw new ShouException("store_corrupt", "The plan belongs to a different user.");
        return plan;
    }

    private static string Assess(CleanupItemResult result, HistoryLocation original, HistoryLocation trash)
    {
        if (result.State == CleanupItemState.Purged && original.State == HistoryLocationState.Missing) return "verified_permanent";
        if (result.State == CleanupItemState.Trashed)
        {
            if (original.State is HistoryLocationState.Matches or HistoryLocationState.Changed) return "conflict";
            if (original.State == HistoryLocationState.Missing && trash.State == HistoryLocationState.Matches) return "verified_trash";
        }
        if (result.State is CleanupItemState.Pending or CleanupItemState.Skipped or CleanupItemState.Failed or CleanupItemState.Cancelled &&
            result.RemovedEntries == 0 && original.State == HistoryLocationState.Matches) return "unchanged";
        return "needs_verification";
    }

    private static bool Unfinished(CleanupExecution execution) => execution.State == CleanupExecutionState.Executing;
    private static bool Uncertain(CleanupExecution execution) => Unfinished(execution) || execution.State == CleanupExecutionState.Unknown ||
        execution.Items.Any(item => item.State is CleanupItemState.Purging or CleanupItemState.Moving or CleanupItemState.Unknown);
    private static void ValidateExecutionId(string id) { if (!RecordKey.IsId(id, "execution")) throw Input("Choose a valid execution identifier."); }
    private static HistoryCursor? ReadCursor(string? cursor, int limit)
    {
        if (cursor is null) return null;
        try
        {
            if (cursor.Length is < 1 or > 512) throw new FormatException();
            var value = JsonSerializer.Deserialize<HistoryCursor>(Convert.FromBase64String(cursor), ContractJson.Options);
            if (value is null || value.Version != 1 || !RecordJson.IsDigest(value.Digest) || value.Offset is < 1 or > MaximumDirectoryEntries || value.Limit != limit)
                throw new FormatException();
            return value;
        }
        catch (Exception error) when (error is FormatException or JsonException) { throw Input("The history cursor is invalid for this page size."); }
    }
    private sealed record HistoryCursor(int Version, string Digest, int Offset, int Limit);
    private sealed class ListBudgetException : Exception;
    private static string ErrorCode(Exception error) => error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed";
    private static ShouException Input(string message) => new("invalid_argument", message);
    private static ShouException Missing() => new("not_found", "The saved cleanup record does not exist.");
}
