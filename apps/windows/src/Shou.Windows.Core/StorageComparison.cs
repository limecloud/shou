using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

public sealed record StorageAnalysisReference(string Id, WindowsPath RootPath, DateTimeOffset CreatedAt, ScanState State, int EntryCount);
public sealed record StorageComparisonHistory(StorageAnalysisReference Current, ImmutableArray<StorageAnalysisReference> Candidates,
    int ExaminedRecordCount, string Status, ImmutableArray<string> Issues);
public sealed record StorageChange(string Path, EntryKind Kind, string State, long? BeforeBytes, long? AfterBytes, long? DeltaBytes,
    bool? BeforeComplete, bool? AfterComplete);
public sealed record StorageComparison(StorageAnalysisReference Baseline, StorageAnalysisReference Current, string Path, string Metric,
    string Status, long BeforeBytes, long AfterBytes, long? DeltaBytes, int ExaminedEntryCount, int ChangedEntryCount,
    ImmutableArray<StorageChange> Changes, ImmutableArray<string> Issues);

// Private, immutable observation pages reuse the same publication and integrity
// primitives as plans. These records never carry mutation authorization.
public sealed class StorageComparisonService(IRecordStore store)
{
    public const int MaximumMetadataBytes = 4_194_304;
    public const int MaximumReadBytes = 134_217_728;
    private sealed record Node(string Path, FileIdentity Identity, EntryKind Kind, long Bytes, bool Complete, bool CaseSensitive);
    private sealed record Catalog(int FormatVersion, StorageAnalysisReference Analysis, FileIdentity RootIdentity,
        bool CaseSensitive, FileManifestReference Nodes, string Digest);
    private static string Key(string id) => RecordKey.IsId(id, "scan") ? "analysis_" + id[5..] : throw Input();

    public async Task SaveAsync(ScanSnapshot snapshot, CancellationToken token)
    {
        Key(snapshot.Id);
        if (snapshot.Entries.IsDefaultOrEmpty || snapshot.Entries.Length > 1_000_000 || snapshot.CompletedDirectories.IsDefault ||
            snapshot.Issues.IsDefault || !Enum.IsDefined(snapshot.State)) throw Unavailable();
        var entries = snapshot.Entries.ToDictionary(item => item.Entry.Path);
        if (!entries.TryGetValue(snapshot.Root, out var root) || root.Entry.Kind != EntryKind.Directory || root.Entry.Identity != snapshot.RootIdentity) throw Unavailable();
        var complete = snapshot.CompletedDirectories.ToHashSet();
        var totals = new Dictionary<WindowsPath, long>();
        foreach (var item in snapshot.Entries)
        {
            token.ThrowIfCancellationRequested();
            if (!item.Entry.Path.IsWithin(snapshot.Root, caseSensitive: true) || item.AttributedAllocatedBytes < 0 || item.AttributedAllocatedBytes > item.Entry.AllocatedBytes ||
                item.Entry.Path != snapshot.Root && (!entries.TryGetValue(item.Entry.Path.Parent!, out var parent) || parent.Entry.Kind != EntryKind.Directory)) throw Unavailable();
            for (var path = item.Entry.Path; path is not null && path.IsWithin(snapshot.Root, caseSensitive: true); path = path.Parent)
            {
                totals[path] = checked(totals.GetValueOrDefault(path) + item.AttributedAllocatedBytes);
                if (path == snapshot.Root) break;
            }
        }
        var nodes = snapshot.Entries.Select(item => new Node(item.Entry.Path.RelativeTo(snapshot.Root, true), item.Entry.Identity, item.Entry.Kind,
            totals[item.Entry.Path], snapshot.State == ScanState.Complete && (item.Entry.Kind == EntryKind.Directory ? complete.Contains(item.Entry.Path) : item.Entry.Kind == EntryKind.File),
            item.Entry.IsCaseSensitive)).OrderBy(node => node.Path, StringComparer.Ordinal).ToImmutableArray();
        var reference = new StorageAnalysisReference(snapshot.Id, snapshot.Root, snapshot.StartedUtc, snapshot.State, nodes.Length);
        await using var lease = await store.AcquireLeaseAsync(token).ConfigureAwait(false);
        if (await lease.ReadAsync(Key(snapshot.Id), MaximumMetadataBytes, token).ConfigureAwait(false) is not null) throw new ShouException("version_conflict", "This analysis was already published.");
        var pages = await FileManifestRecords.WriteAsync(nodes, Key(snapshot.Id), lease, token).ConfigureAwait(false);
        var catalog = new Catalog(1, reference, snapshot.RootIdentity, root.Entry.IsCaseSensitive, pages, "");
        await lease.WriteAsync(Key(snapshot.Id), RecordJson.Encode(catalog with { Digest = Digest(catalog) }, MaximumMetadataBytes), token).ConfigureAwait(false);
    }

    public async Task<StorageComparisonHistory> HistoryAsync(string scanId, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        try { return await ReadHistory(scanId, deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new ShouException("resource_limit", "Analysis history exceeded its read time limit."); }
    }

    private async Task<StorageComparisonHistory> ReadHistory(string scanId, CancellationToken token)
    {
        await using var lease = await store.AcquireReadLeaseAsync(token).ConfigureAwait(false) ?? throw Unavailable();
        var current = await ReadCatalog(scanId, lease, token).ConfigureAwait(false);
        var keys = await lease.ListKeysAsync("analysis", 4096, token).ConfigureAwait(false);
        var candidates = ImmutableArray.CreateBuilder<StorageAnalysisReference>();
        var issues = new HashSet<string>(StringComparer.Ordinal); var examined = 0; var bytesRead = 0;
        var valid = keys.Where(key => RecordKey.IsId(key, "analysis") && key != Key(scanId)).Order(StringComparer.Ordinal).ToArray();
        foreach (var key in valid.Take(127))
        {
            token.ThrowIfCancellationRequested(); examined++;
            try
            {
                var bytes = await lease.ReadAsync(key, MaximumMetadataBytes, token).ConfigureAwait(false);
                bytesRead = checked(bytesRead + (bytes?.Length ?? 0));
                if (bytesRead > 8_388_608) { issues.Add("history_read_limit"); break; }
                var item = Decode(bytes, "scan_" + key[9..]);
                if (item.Analysis.CreatedAt < current.Analysis.CreatedAt && item.Analysis.RootPath.SamePath(current.Analysis.RootPath, true) &&
                    item.RootIdentity == current.RootIdentity && item.CaseSensitive == current.CaseSensitive) candidates.Add(item.Analysis);
            }
            catch (ShouException) { issues.Add("history_record_unavailable"); }
        }
        if (valid.Length > 127) issues.Add("history_record_limit");
        return new(current.Analysis, candidates.OrderByDescending(item => item.CreatedAt).ThenBy(item => item.Id, StringComparer.Ordinal).ToImmutableArray(),
            examined, issues.Count == 0 ? "complete" : "partial", issues.Order(StringComparer.Ordinal).ToImmutableArray());
    }

    public async Task<StorageComparison> CompareAsync(string baselineId, string scanId, string path = ".", int limit = 50,
        int maxEntries = 100_000, int maxSeconds = 10, CancellationToken cancellationToken = default)
    {
        Key(baselineId); Key(scanId);
        if (baselineId == scanId || limit is < 1 or > 100 || maxEntries is < 1 or > 100_000 || maxSeconds is < 1 or > 30) throw Input();
        if (path != ".") WindowsPath.ValidateRelative(path);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); deadline.CancelAfter(TimeSpan.FromSeconds(maxSeconds));
        var token = deadline.Token;
        try
        {
            await using var lease = await store.AcquireReadLeaseAsync(token).ConfigureAwait(false) ?? throw Unavailable();
            var before = await ReadCatalog(baselineId, lease, token).ConfigureAwait(false);
            var after = await ReadCatalog(scanId, lease, token).ConfigureAwait(false);
            if (before.Analysis.CreatedAt >= after.Analysis.CreatedAt || !before.Analysis.RootPath.SamePath(after.Analysis.RootPath, true) ||
                before.RootIdentity != after.RootIdentity || before.CaseSensitive != after.CaseSensitive) throw Unavailable();
            var bounded = new ReadBudget(lease);
            var oldNodes = await ReadNodes(before, bounded, token).ConfigureAwait(false);
            var newNodes = await ReadNodes(after, bounded, token).ConfigureAwait(false);
            var old = oldNodes.SingleOrDefault(node => node.Path == path); var current = newNodes.SingleOrDefault(node => node.Path == path);
            if (old is null || current is null || old.Kind != EntryKind.Directory || current.Kind != EntryKind.Directory || old.Identity != current.Identity || old.CaseSensitive != current.CaseSensitive) throw Unavailable();
            var covered = old.Complete && current.Complete;
            var issues = new List<string>(); if (!covered) issues.Add("incomplete_coverage");
            var a = oldNodes.Where(node => Parent(node.Path) == path).ToDictionary(node => node.Path, StringComparer.Ordinal);
            var b = newNodes.Where(node => Parent(node.Path) == path).ToDictionary(node => node.Path, StringComparer.Ordinal);
            var changes = new List<StorageChange>(); var examined = 0; var changed = 0;
            foreach (var child in a.Keys.Union(b.Keys, StringComparer.Ordinal).Order(StringComparer.Ordinal))
            {
                token.ThrowIfCancellationRequested();
                if (examined == maxEntries) { issues.Add("comparison_budget_reached"); break; }
                examined++; a.TryGetValue(child, out var left); b.TryGetValue(child, out var right);
                var comparable = covered && left?.Complete == true && right?.Complete == true;
                var same = left is not null && right is not null && left.Identity == right.Identity && left.Kind == right.Kind && left.CaseSensitive == right.CaseSensitive;
                long? delta = same && comparable ? right!.Bytes - left!.Bytes : null;
                if (delta == 0) continue;
                var state = left is null ? "only_current" : right is null ? "only_baseline" : !same ? "replaced" : !comparable ? "not_comparable" : delta > 0 ? "increased" : "decreased";
                changed++; changes.Add(new(child, (right ?? left)!.Kind, state, left?.Bytes, right?.Bytes, delta, left?.Complete, right?.Complete));
                changes = changes.OrderByDescending(Magnitude).ThenBy(item => item.Path, StringComparer.Ordinal).Take(limit).ToList();
            }
            return new(before.Analysis, after.Analysis, path, "allocated_bytes_estimate", issues.Count == 0 ? "complete" : "partial", old.Bytes, current.Bytes,
                covered ? current.Bytes - old.Bytes : null, examined, changed, changes.ToImmutableArray(), issues.ToImmutableArray());
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { throw new ShouException("resource_limit", "Analysis comparison exceeded its read time limit."); }
    }

    private static long Magnitude(StorageChange item) => item.DeltaBytes is { } delta ? Math.Abs(delta) : Math.Max(item.BeforeBytes ?? 0, item.AfterBytes ?? 0);
    private static string? Parent(string path) => path == "." ? null : path.LastIndexOf('/') is var index && index >= 0 ? path[..index] : ".";
    private static string Digest(Catalog value) => RecordJson.Digest(value with { Digest = "" });
    private static async Task<Catalog> ReadCatalog(string id, IRecordReadLease lease, CancellationToken token) => Decode(await lease.ReadAsync(Key(id), MaximumMetadataBytes, token).ConfigureAwait(false), id);
    private static Catalog Decode(byte[]? bytes, string id)
    {
        try
        {
            var value = bytes is null ? null : JsonSerializer.Deserialize<Catalog>(bytes, ContractJson.Options);
            if (value is null || value.FormatVersion != 1 || value.Analysis is null || value.Analysis.Id != id || value.Analysis.RootPath is null || value.RootIdentity is null ||
                value.Analysis.CreatedAt.Offset != TimeSpan.Zero || !Enum.IsDefined(value.Analysis.State) || value.Analysis.EntryCount is < 1 or > 1_000_000 ||
                value.Nodes is null || value.Nodes.Count != value.Analysis.EntryCount || value.Digest != Digest(value)) throw Unavailable();
            return value;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException or NullReferenceException) { throw Unavailable(); }
    }

    private static async Task<ImmutableArray<Node>> ReadNodes(Catalog catalog, IRecordReadLease lease, CancellationToken token)
    {
        try
        {
            var nodes = await FileManifestRecords.ReadAsync<Node>(catalog.Nodes, Key(catalog.Analysis.Id), lease, token).ConfigureAwait(false);
            var paths = new HashSet<string>(StringComparer.Ordinal); string? previous = null;
            foreach (var node in nodes)
            {
                token.ThrowIfCancellationRequested();
                if (node is null || node.Path is null || node.Identity is null || !Enum.IsDefined(node.Kind) || node.Bytes < 0 || !paths.Add(node.Path) ||
                    previous is not null && StringComparer.Ordinal.Compare(previous, node.Path) >= 0) throw Unavailable();
                if (node.Path != ".") WindowsPath.ValidateRelative(node.Path);
                previous = node.Path;
            }
            if (nodes.SingleOrDefault(node => node.Path == ".") is not { Kind: EntryKind.Directory } root || root.Identity != catalog.RootIdentity ||
                root.CaseSensitive != catalog.CaseSensitive || nodes.Any(node => node.Path != "." && !paths.Contains(Parent(node.Path)!))) throw Unavailable();
            return nodes;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException or NullReferenceException) { throw Unavailable(); }
    }

    private sealed class ReadBudget(IRecordReadLease lease) : IRecordReadLease
    {
        private int bytesRead;
        public async ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken token)
        {
            if (MaximumReadBytes - bytesRead < 1) throw new ShouException("resource_limit", "Analysis comparison exceeded its read byte limit.");
            var bytes = await lease.ReadAsync(key, Math.Min(maximumBytes, MaximumReadBytes - bytesRead), token).ConfigureAwait(false);
            bytesRead = checked(bytesRead + (bytes?.Length ?? 0)); return bytes;
        }
        public Task<string[]> ListKeysAsync(string prefix, int maximumDirectoryEntries, CancellationToken token) => throw new NotSupportedException();
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private static ShouException Input() => new("invalid_argument", "Choose distinct analyses, a relative directory and bounded comparison options.");
    private static ShouException Unavailable() => new("comparison_unavailable", "This analysis cannot be compared. Run two new space analyses of the same folder.");
}

public sealed class HistoricalStorageScanner(IStorageScanner scanner, StorageComparisonService history) : IStorageScanner
{
    public async Task<ScanSnapshot> ScanAsync(WindowsPath root, ScanBudget budget, IProgress<ScanProgress>? progress, CancellationToken cancellationToken)
    {
        var snapshot = await scanner.ScanAsync(root, budget, progress, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        await history.SaveAsync(snapshot, cancellationToken).ConfigureAwait(false);
        return snapshot;
    }
}
