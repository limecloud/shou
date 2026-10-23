using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Shou.Windows.Core;

public sealed record CandidatePage(string ScanId, string ConfigurationRevision, bool PreviewOnly, string State, bool TreeComplete, int MeasuredEntries, int CandidateCount,
    ImmutableArray<RuleCandidate> Candidates, string? NextCursor, ImmutableArray<ScanIssue> Issues, bool ExecutionAvailable = false);

public sealed class CleanupScanService(IRecordStore store, RuleSchemaValidator validator, IStorageScanner scanner,
    CleanupProtectionContext protection, TimeProvider? timeProvider = null, BuiltinRuleCatalog? catalog = null)
{
    public const int MaximumSnapshotBytes = 134_217_728;
    private readonly ConfigurationCodec codec = new(validator);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public Task<CleanupScan> PreviewAsync(string workspaceId, ReadOnlyMemory<byte> bytes, ScanBudget budget, CancellationToken cancellationToken = default) =>
        ProduceAsync(workspaceId, validator.Parse(bytes), budget, cancellationToken);

    public Task<CleanupScan> ScanAsync(string workspaceId, ScanBudget budget, CancellationToken cancellationToken = default) =>
        ProduceAsync(workspaceId, null, budget, cancellationToken);

    private async Task<CleanupScan> ProduceAsync(string workspaceId, CleanupRule? draft, ScanBudget budget, CancellationToken cancellationToken)
    {
        budget.Validate();
        var configuration = codec.Decode(await store.ReadAsync("configuration", ConfigurationCodec.MaximumBytes, cancellationToken));
        var workspace = configuration.Workspaces.FirstOrDefault(value => value.Id == workspaceId) ?? throw Input("Unknown workspace.");
        var rules = draft is null ? EnabledRules(configuration, workspaceId) : [draft];
        if (rules.Any(rule => !rule.AppliesToWindows || rule.RootReference != workspace.RootRef)) throw new ShouException("invalid_rule", "The rule root or platform does not match this workspace.");
        var started = clock.GetTimestamp();
        var scan = await scanner.ScanAsync(workspace.Path, budget, null, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        var classification = Classify(configuration, workspace, rules, scan, budget.Duration - clock.GetElapsedTime(started), cancellationToken);
        var preview = new CleanupScan(1, scan.Id, workspace, budget, configuration.Revision, codec.Digest(configuration),
            rules.Select(rule => new ScanRule(rule.Definition, rule.Digest)).ToImmutableArray(), scan, classification.Candidates, classification.AnalysisIssues, draft is not null);
        var payload = RecordJson.Encode(preview, MaximumSnapshotBytes);
        await store.UpdateAsync(transaction =>
        {
            var current = codec.Decode(transaction.Read("configuration", ConfigurationCodec.MaximumBytes));
            if (codec.Digest(current) != preview.ConfigurationDigest) throw new ShouException("plan_stale", "Configuration changed during preview. Review and scan again.");
            if (transaction.Read(preview.Id, MaximumSnapshotBytes) is not null) throw new ShouException("version_conflict", "A scan with this identifier already exists.");
            transaction.Write(preview.Id, payload);
            return true;
        }, cancellationToken);
        return preview;
    }

    public async Task<CandidatePage> ResultsAsync(string scanId, int limit = 50, string? cursor = null, CancellationToken cancellationToken = default)
    {
        if (!RecordKey.IsId(scanId, "scan") || limit is < 1 or > 500) throw Input("Choose a valid scan identifier and page limit.");
        var bytes = await store.ReadAsync(scanId, MaximumSnapshotBytes, cancellationToken) ?? throw Input("The scan does not exist.");
        var preview = Decode(bytes, scanId, cancellationToken);
        var offset = 0;
        if (cursor is not null)
        {
            try
            {
                if (cursor.Length > 512) throw Input("The cursor is invalid.");
                var fields = Encoding.UTF8.GetString(Convert.FromBase64String(cursor)).Split(':');
                if (fields.Length != 3 || fields[0] != scanId || fields[2] != CursorDigest(bytes) ||
                    !int.TryParse(fields[1], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out offset) || offset < 0 || offset > preview.Candidates.Length)
                    throw Input("The cursor belongs to another scan or has changed.");
            }
            catch (FormatException) { throw Input("The cursor is invalid."); }
        }
        var items = preview.Candidates.Skip(offset).Take(limit).ToImmutableArray();
        var nextOffset = offset + items.Length;
        var next = nextOffset < preview.Candidates.Length ? Convert.ToBase64String(Encoding.UTF8.GetBytes(scanId + ":" + nextOffset.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + CursorDigest(bytes))) : null;
        var state = preview.Scan.State == ScanState.Cancelled ? "cancelled" : preview.Scan.IsComplete && preview.AnalysisIssues.Length == 0 ? "complete" : "partial";
        return new(scanId, preview.ConfigurationRevision, preview.PreviewOnly, state, preview.Scan.IsComplete, preview.Scan.Entries.Length, preview.Candidates.Length, items, next,
            preview.Scan.Issues.AddRange(preview.AnalysisIssues));
    }

    private static string CursorDigest(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    internal CleanupRule[] EnabledRules(Configuration configuration, string workspaceId) => (catalog?.RulesFor(configuration.Workspaces.Single(value => value.Id == workspaceId)) ?? [])
        .Where(rule => !configuration.Bindings.Any(binding => binding.WorkspaceId == workspaceId && binding.RuleId == rule.Id && !binding.Enabled))
        .Concat(configuration.Bindings.Where(binding => binding.WorkspaceId == workspaceId && binding.Enabled && !binding.RuleId.StartsWith(BuiltinRuleCatalog.Prefix, StringComparison.Ordinal))
        .OrderBy(binding => binding.RuleId, StringComparer.Ordinal)
        .Select(binding => configuration.Rules.Single(record => record.Digest == binding.Digest &&
            record.Rule.GetProperty("id").GetString() == binding.RuleId && record.Rule.GetProperty("version").GetString() == binding.Version))
        .Select(record => validator.Parse(Encoding.UTF8.GetBytes(record.Rule.GetRawText())))).OrderBy(rule => rule.Id, StringComparer.Ordinal).ToArray();

    internal RuleClassification Classify(Configuration configuration, Workspace workspace, IEnumerable<CleanupRule> rules,
        ScanSnapshot scan, TimeSpan duration, CancellationToken cancellationToken)
    {
        var candidates = ImmutableArray.CreateBuilder<RuleCandidate>();
        var issues = ImmutableArray.CreateBuilder<ScanIssue>();
        var analysis = new CandidateAnalysisBudget(duration, clock);
        foreach (var rule in rules)
        {
            var result = new RuleClassifier(protection).Classify(configuration, workspace, rule, scan, analysis, cancellationToken);
            candidates.AddRange(result.Candidates);
            issues.AddRange(result.AnalysisIssues);
            if (result.AnalysisIssues.Length > 0) break;
        }
        return new(candidates.ToImmutable(), issues.Distinct().ToImmutableArray());
    }

    internal CleanupScan Decode(byte[] bytes, string scanId, CancellationToken cancellationToken)
    {
        try
        {
            if (bytes.Length > MaximumSnapshotBytes || !RecordKey.IsId(scanId, "scan")) throw InvalidRecord();
            var preview = JsonSerializer.Deserialize<CleanupScan>(bytes, ContractJson.Options) ?? throw InvalidRecord();
            ValidateRecord(preview, scanId, cancellationToken);
            return preview;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentException or NullReferenceException or OverflowException) { throw InvalidRecord(error); }
        catch (ShouException error) when (error.Code != "store_corrupt") { throw InvalidRecord(error); }
    }

    // Saved observations are untrusted input and never serve as an execution authorization.
    private void ValidateRecord(CleanupScan preview, string scanId, CancellationToken cancellationToken)
    {
        if (preview.Version != 1 || preview.Id != scanId || preview.Scan is not { } scan || scan.Id != scanId ||
            preview.Workspace is null || preview.Budget is null || !RecordKey.IsId(preview.WorkspaceId, "ws") || !RecordKey.IsId(preview.ConfigurationRevision, "config") || !RecordJson.IsDigest(preview.ConfigurationDigest) ||
            preview.Rules.IsDefault || preview.Rules.Length > ConfigurationCodec.MaximumRules || preview.PreviewOnly && preview.Rules.Length != 1 ||
            preview.Candidates.IsDefault || preview.AnalysisIssues.IsDefault || scan.Entries.IsDefault || scan.Issues.IsDefault || scan.CompletedDirectories.IsDefault ||
            scan.Entries.Length is < 1 or > 1_000_000 || preview.Candidates.Length > CandidateAnalysisBudget.MaximumAnalysisOperations ||
            scan.Root is null || scan.RootIdentity is null || scan.StartedUtc.Offset != TimeSpan.Zero || !Enum.IsDefined(scan.State)) throw InvalidRecord();
        preview.Budget.Validate();
        codec.Validate(new(1, preview.ConfigurationRevision, [preview.Workspace], [], [], []));
        var rules = new Dictionary<string, CleanupRule>(StringComparer.Ordinal);
        foreach (var record in preview.Rules)
        {
            if (record is null) throw InvalidRecord();
            var rule = validator.Parse(Encoding.UTF8.GetBytes(record.Definition.GetRawText()));
            if (!rule.AppliesToWindows || rule.Digest != record.Digest || rule.RootReference != preview.Workspace.RootRef || !rules.TryAdd(rule.Id, rule)) throw InvalidRecord();
        }
        if (scan.Root != preview.Workspace.Path || scan.RootIdentity != preview.Workspace.Identity || scan.Entries.Length > preview.Budget.MaxEntries) throw InvalidRecord();
        var entries = new Dictionary<WindowsPath, FileEntry>();
        foreach (var item in scan.Entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (item is null || item.Entry is not { } entry || entry.Path is null || entry.Identity is null ||
                !entry.Path.IsWithin(scan.Root, caseSensitive: true) || !Enum.IsDefined(entry.Kind) || entry.LogicalBytes < 0 || entry.AllocatedBytes < 0 ||
                item.AttributedAllocatedBytes < 0 || item.AttributedAllocatedBytes > entry.AllocatedBytes ||
                entry.LastWriteUtc.Offset != TimeSpan.Zero || entry.ChangeUtc.Offset != TimeSpan.Zero || !entries.TryAdd(entry.Path, entry)) throw InvalidRecord();
        }
        if (!entries.TryGetValue(scan.Root, out var root) || root.Kind != EntryKind.Directory || root.Identity != scan.RootIdentity || root.IsCaseSensitive != preview.Workspace.CaseSensitive) throw InvalidRecord();
        var names = new Dictionary<WindowsPath, HashSet<string>>();
        foreach (var entry in entries.Values.Where(entry => entry.Path != scan.Root))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (entry.Path.Parent is not { } parent || !entries.TryGetValue(parent, out var directory) || directory.Kind != EntryKind.Directory) throw InvalidRecord();
            if (!names.TryGetValue(parent, out var siblings)) names[parent] = siblings = new(directory.IsCaseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
            if (!siblings.Add(entry.Path.Name)) throw InvalidRecord();
        }
        var completed = new HashSet<WindowsPath>();
        foreach (var path in scan.CompletedDirectories)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (path is null || !entries.TryGetValue(path, out var entry) || entry.Kind != EntryKind.Directory || !completed.Add(path)) throw InvalidRecord();
        }
        foreach (var entry in entries.Values.Where(entry => entry.Path != scan.Root))
            if (completed.Contains(entry.Path.Parent!) && (entry.Kind is not (EntryKind.File or EntryKind.Directory) || entry.Kind == EntryKind.Directory && !completed.Contains(entry.Path))) throw InvalidRecord();
        foreach (var issue in scan.Issues.Concat(preview.AnalysisIssues))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (issue is null || issue.Path is null || !issue.Path.IsWithin(scan.Root, caseSensitive: true) || issue.Code is not { Length: > 0 and <= 80 } ||
                !issue.Code.All(character => char.IsAsciiLetterLower(character) || character == '_')) throw InvalidRecord();
        }
        foreach (var issue in scan.Issues)
            for (var ancestor = issue.Path; ancestor is not null && ancestor.IsWithin(scan.Root, caseSensitive: true); ancestor = ancestor.Parent)
                if (completed.Contains(ancestor)) throw InvalidRecord();
        if (scan.IsComplete && (scan.Issues.Length != 0 || !completed.Contains(scan.Root)) || !scan.IsComplete && scan.Issues.Length == 0) throw InvalidRecord();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var paths = new HashSet<(string, WindowsPath)>();
        foreach (var candidate in preview.Candidates)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (candidate is null || !RecordKey.IsId(candidate.Id, "candidate") || !ids.Add(candidate.Id) || candidate.Path is null ||
                !paths.Add((candidate.RuleId, candidate.Path)) || candidate.Path == scan.Root || !entries.TryGetValue(candidate.Path, out var entry) || entry.Kind != EntryKind.Directory ||
                candidate.RelativePath != candidate.Path.RelativeTo(scan.Root, caseSensitive: true) || candidate.Identity != entry.Identity ||
                !rules.TryGetValue(candidate.RuleId, out var rule) || candidate.RuleVersion != rule.Version || candidate.AllocatedBytes < 0 || candidate.LogicalBytes < 0 ||
                candidate.NewestModifiedAt.Offset != TimeSpan.Zero || candidate.Risk is not ("review" or "high") || candidate.BlockedReasons.IsDefault ||
                candidate.BlockedReasons.Any(reason => !BlockedReasons.Contains(reason)) ||
                !candidate.BlockedReasons.SequenceEqual(candidate.BlockedReasons.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)) ||
                candidate.State != (candidate.BlockedReasons.Length == 0 ? "review" : "blocked") || candidate.Complete != completed.Contains(candidate.Path) ||
                !candidate.Complete && !candidate.BlockedReasons.Contains("coverage_incomplete") ||
                (candidate.Complete ? !RecordJson.IsDigest(candidate.ManifestDigest) : candidate.ManifestDigest is not null)) throw InvalidRecord();
        }
    }

    private static readonly HashSet<string> BlockedReasons = new(StringComparer.Ordinal)
    {
        "coverage_incomplete", "protected_location", "protected_data", "project_marker_missing", "foreign_owner", "cross_volume",
        "unsupported_entry", "multiple_links", "excluded", "unsupported_metadata", "below_minimum_size", "newer_than_retention"
    };
    private static ShouException Input(string message) => new("invalid_argument", message);
    private static ShouException InvalidRecord(Exception? error = null) => new("store_corrupt", "The saved preview is invalid or unsupported.", error);

}
