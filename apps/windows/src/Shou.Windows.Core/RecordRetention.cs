using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

public sealed record StoredAppRecord(string Key, FileEntry Entry);
public sealed record RecordRetentionPolicy(bool KeepLatestScans = true, long MaximumBytes = 268_435_456,
    int MaximumAgeDays = 7, int GraceSeconds = 1800);
public sealed record RecordCollectionUsage(string Collection, long TotalBytes, long RemovableBytes, int RetainedCount);
public sealed record RecordRetentionReason(string Reason, long ByteCount, int RecordCount);
public sealed record RecordRetentionPreview(ImmutableArray<StoredAppRecord> Records, long TotalBytes, long RemovableBytes,
    long QuotaExcessBytes, ImmutableArray<RecordCollectionUsage> Collections, ImmutableArray<RecordRetentionReason> RetentionReasons,
    ImmutableArray<string> Issues);

/// <summary>Collects only reproducible scan publications in private Shou storage.
/// Plans, execution/recovery journals, configuration and their scan dependencies are retained.</summary>
public sealed class RecordRetentionService(IRecordStore store, RuleSchemaValidator validator, TimeProvider? clock = null)
{
    private readonly TimeProvider time = clock ?? TimeProvider.System;
    private static readonly Regex DerivedKey = new(@"^(scan|analysis)_[a-f0-9]{32}(?:_p[0-9]+_[a-f0-9]{24})?$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    public static bool IsDerivedKey(string key) => DerivedKey.IsMatch(key);

    public async Task<RecordRetentionPreview> PreviewAsync(RecordRetentionPolicy policy, CancellationToken token = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(30)); token = deadline.Token;
        await using var lease = await store.AcquireReadLeaseAsync(token).ConfigureAwait(false);
        return lease is null ? Empty() : await PreviewAsync(lease, policy, token).ConfigureAwait(false);
    }

    public async Task<RecordRetentionPreview> CollectAsync(RecordRetentionPolicy policy, ImmutableArray<StoredAppRecord> reviewed,
        CancellationToken token = default)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(30)); token = deadline.Token;
        if (reviewed.IsDefault) throw Stale();
        await using var lease = await store.AcquireLeaseAsync(token).ConfigureAwait(false);
        var preview = await PreviewAsync(lease, policy, token).ConfigureAwait(false);
        if (!reviewed.SequenceEqual(preview.Records)) throw Stale();
        foreach (var record in preview.Records)
            await lease.RemoveDerivedRecordAsync(record, token).ConfigureAwait(false);
        return preview;
    }

    private async Task<RecordRetentionPreview> PreviewAsync(IRecordReadLease lease, RecordRetentionPolicy policy, CancellationToken token)
    {
        if (policy.MaximumBytes < 0 || policy.MaximumAgeDays is < 0 or > 36500 || policy.GraceSeconds is < 0 or > 86400)
            throw new ShouException("invalid_argument", "Choose nonnegative bounded record retention limits.");
        var records = await lease.InspectRecordsAsync(token).ConfigureAwait(false);
        if (records.Select(record => record.Key).Distinct().Count() != records.Length ||
            records.Any(record => record.Entry.LogicalBytes < 0)) throw new ShouException("store_corrupt", "The record inventory is inconsistent.");
        var reasons = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        void Protect(string key, string reason)
        {
            if (!reasons.TryGetValue(key, out var values)) reasons[key] = values = [];
            values.Add(reason);
        }
        var issues = ImmutableArray.CreateBuilder<string>();
        var referenced = new HashSet<string>(StringComparer.Ordinal);
        var plans = new CleanupPlanRecords(new CleanupRecordCodec(validator));
        foreach (var record in records.Where(record => RecordKey.IsId(record.Key, "plan")))
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var plan = await plans.ReadAsync(lease, record.Key, token).ConfigureAwait(false);
                foreach (var source in plan.Sources) referenced.Add(source.ScanId);
            }
            catch (ShouException) { issues.Add("unreadable_plan:" + record.Key); }
        }
        var now = time.GetUtcNow();
        var derived = records.Where(record => IsDerivedKey(record.Key)).GroupBy(record => record.Key.Split("_p", StringSplitOptions.None)[0])
            .OrderBy(group => group.Max(record => record.Entry.LastWriteUtc)).ThenBy(group => group.Key, StringComparer.Ordinal).ToArray();
        var latest = derived.Where(group => group.Any(record => record.Key == group.Key))
            .GroupBy(group => group.Key.StartsWith("analysis_", StringComparison.Ordinal) ? "analysis" : "scan")
            .Select(group => group.Last().Key).ToHashSet(StringComparer.Ordinal);
        foreach (var record in records.Where(record => !IsDerivedKey(record.Key))) Protect(record.Key, "history_dependency");
        var removal = ImmutableArray.CreateBuilder<StoredAppRecord>();
        var total = records.Sum(record => record.Entry.LogicalBytes); var remaining = total;
        foreach (var group in derived)
        {
            var values = group.ToArray(); var parent = group.Key;
            var protectedReasons = new List<string>();
            if (issues.Count > 0) protectedReasons.Add("verification_required");
            if (values.Any(record => record.Entry.LastWriteUtc > now.AddSeconds(-policy.GraceSeconds))) protectedReasons.Add("grace_period");
            if (policy.KeepLatestScans && latest.Contains(parent)) protectedReasons.Add("latest_scan");
            var scanId = parent.StartsWith("analysis_", StringComparison.Ordinal) ? "scan_" + parent[9..] : parent;
            if (referenced.Contains(scanId)) protectedReasons.Add("history_dependency");
            if (protectedReasons.Count > 0)
            {
                foreach (var record in values) foreach (var reason in protectedReasons) Protect(record.Key, reason);
            }
            else if (values.All(record => record.Entry.LastWriteUtc <= now.AddDays(-policy.MaximumAgeDays)) || remaining > policy.MaximumBytes)
            {
                // Unpublish the parent first. An interrupted collection leaves inert pages.
                removal.AddRange(values.OrderBy(record => record.Key == parent ? 0 : 1).ThenBy(record => record.Key, StringComparer.Ordinal));
                remaining -= values.Sum(record => record.Entry.LogicalBytes);
            }
            else foreach (var record in values) Protect(record.Key, "within_policy");
        }
        var removed = removal.Select(record => record.Key).ToHashSet(StringComparer.Ordinal);
        var collections = records.GroupBy(record => record.Key.StartsWith("analysis_", StringComparison.Ordinal) ? "Space scans" :
                record.Key.StartsWith("scan_", StringComparison.Ordinal) ? "Cleanup scans" : "History dependency")
            .Select(group => new RecordCollectionUsage(group.Key, group.Sum(record => record.Entry.LogicalBytes),
                group.Where(record => removed.Contains(record.Key)).Sum(record => record.Entry.LogicalBytes), group.Count(record => !removed.Contains(record.Key))))
            .OrderByDescending(group => group.TotalBytes).ToImmutableArray();
        var retained = records.Where(record => !removed.Contains(record.Key)).SelectMany(record =>
            reasons.GetValueOrDefault(record.Key, ["verification_required"]).Select(reason => (record, reason)))
            .GroupBy(value => value.reason).Select(group => new RecordRetentionReason(group.Key, group.Sum(value => value.record.Entry.LogicalBytes), group.Count()))
            .OrderBy(value => value.Reason, StringComparer.Ordinal).ToImmutableArray();
        return new(removal.ToImmutable(), total, total - remaining, Math.Max(0, remaining - policy.MaximumBytes), collections, retained, issues.ToImmutable());
    }
    private static RecordRetentionPreview Empty() => new([], 0, 0, 0, [], [], []);
    private static ShouException Stale() => new("plan_stale", "Record cleanup changed. Review the current records again.");
}
