using System.Collections.Immutable;
using System.ComponentModel;
using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

public interface ICleanupReviewOperations
{
    Task<ImmutableArray<Workspace>> ReadWorkspacesAsync(CancellationToken cancellationToken);
    Task<LocationPreparation> PrepareLocationsAsync(CancellationToken cancellationToken);
    Task<CleanupScan> ScanAsync(string workspaceId, ScanBudget budget, CancellationToken cancellationToken);
    Task<SystemScan> ScanAllAsync(ImmutableArray<string> workspaceIds, ScanBudget budget, CancellationToken cancellationToken);
    Task<CleanupPlan> CreatePlanAsync(ImmutableArray<CleanupSelection> selections, CleanupAction action, CancellationToken cancellationToken);
}

public enum CleanupReviewState { Empty, Loading, Discovering, Scanning, Ready, Partial, Preparing, Review, Cancelled, Failed }
public enum CleanupReviewScope { All, ProjectOutputs }
public sealed record CleanupCandidateSelection(RuleCandidate Candidate, string ScanId, string WorkspaceId, string RuleName, string Category,
    bool Selected, bool Selectable, bool Recommended);
public sealed record CleanupRuleGroup(string RuleId, string Name, string Category, int Count, int SelectableCount, int SelectedCount,
    long AllocatedBytes, long SelectedBytes)
{
    public bool? Selection => SelectedCount == 0 ? false : SelectedCount == SelectableCount ? true : null;
}

public sealed record CleanupCategorySummary(string Id, int Count, int SelectableCount, int SelectedCount, long AllocatedBytes, long SelectedBytes, int GroupCount = 0)
{
    public bool? Selection => SelectableCount == 0 || SelectedCount == 0 ? false : SelectedCount == SelectableCount ? true : null;
}

/// <summary>Reviewing and planning have no execution capability or reusable approval value.</summary>
public sealed class CleanupReviewViewModel(ICleanupReviewOperations operations, IReadOnlyDictionary<string, string>? builtinCategories = null,
    CleanupReviewScope reviewScope = CleanupReviewScope.All) : INotifyPropertyChanged, IDisposable
{
    public const int PageSize = 200;
    public const int MaximumSelection = 256;
    private CancellationTokenSource? operation;
    private long generation;
    private bool disposed;
    private bool requiresRescan;
    private readonly Dictionary<string, CleanupCandidateSelection> selected = new(StringComparer.Ordinal);
    public event PropertyChangedEventHandler? PropertyChanged;
    public CleanupReviewState State { get; private set; }
    public ImmutableArray<Workspace> Workspaces { get; private set; } = [];
    public string? WorkspaceId { get; private set; }
    public CleanupScan? Snapshot { get; private set; }
    public SystemScan? Batch { get; private set; }
    public CleanupPlan? Plan { get; private set; }
    public string? ErrorCode { get; private set; }
    public string? ErrorStage { get; private set; }
    public string? DiagnosticReference { get; private set; }
    public string? SelectionErrorCode { get; private set; }
    public ImmutableArray<ScanIssue> DiscoveryIssues { get; private set; } = [];
    public bool DiscoveryAttempted { get; private set; }
    public bool NoUsableLocations => DiscoveryAttempted && Workspaces.IsEmpty && !IsBusy;
    public int Offset { get; private set; }
    public bool AllLocations { get; private set; }
    public string? Category { get; private set; }
    public string? RuleId { get; private set; }
    public string Search { get; private set; } = "";
    private ImmutableArray<CleanupCandidateSelection> results = [];
    public int SelectedCount => selected.Count;
    public long SelectedAllocatedBytes => selected.Values.Aggregate(0L, (total, row) =>
        row.Candidate.AllocatedBytes > long.MaxValue - total ? long.MaxValue : total + row.Candidate.AllocatedBytes);
    public bool IsBusy => State is CleanupReviewState.Loading or CleanupReviewState.Discovering or CleanupReviewState.Scanning or CleanupReviewState.Preparing;
    public bool StopRequested => operation?.IsCancellationRequested == true;
    private bool BatchRequiresRescan => Batch?.Issues.Any(issue => issue.Code == "plan_stale") == true;
    public bool CanPreparePlan => !IsBusy && !requiresRescan && !BatchRequiresRescan && selected.Count > 0;
    public bool HasPrevious => Offset > 0;
    public bool HasNext => Offset + PageSize < Filtered.Length;
    public int ResultCount => results.Length;
    public int FilteredCount => Filtered.Length;
    public int RecommendedCount => results.Count(row => row.Recommended && Selectable(row));
    public ImmutableArray<CleanupCandidateSelection> Rows => Filtered.Skip(Offset).Take(PageSize)
        .Select(row => row with { Selected = selected.ContainsKey(row.Candidate.Id), Selectable = Selectable(row) }).ToImmutableArray();
    public ImmutableArray<string> Categories => results.Select(row => row.Category).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray();
    public long ResultAllocatedBytes => SumBytes(results);
    public int ResultGroupCount => results.Select(row => row.Candidate.RuleId).Distinct(StringComparer.Ordinal).Count();
    public int SelectedGroupCount => selected.Values.Select(row => row.Candidate.RuleId).Distinct(StringComparer.Ordinal).Count();
    public int FilteredGroupCount => Filtered.Select(row => row.Candidate.RuleId).Distinct(StringComparer.Ordinal).Count();
    public long FilteredAllocatedBytes => SumBytes(Filtered);
    public long FilteredSelectedBytes => SumBytes(Filtered.Where(row => selected.ContainsKey(row.Candidate.Id)));
    public ImmutableArray<CleanupCategorySummary> CategorySummaries => results.GroupBy(row => row.Category, StringComparer.Ordinal)
        .Select(group => new CleanupCategorySummary(group.Key, group.Count(), group.Count(Selectable),
            group.Count(row => selected.ContainsKey(row.Candidate.Id)), SumBytes(group), SumBytes(group.Where(row => selected.ContainsKey(row.Candidate.Id))),
            group.Select(row => row.Candidate.RuleId).Distinct(StringComparer.Ordinal).Count()))
        .OrderBy(summary => summary.Id, StringComparer.Ordinal).ToImmutableArray();
    public ImmutableArray<CleanupRuleGroup> Groups => results.Where(row => (AllLocations || row.WorkspaceId == WorkspaceId) &&
            (Category is null || row.Category == Category)).GroupBy(row => row.Candidate.RuleId)
        .Select(group => new CleanupRuleGroup(group.Key, group.First().RuleName, group.First().Category, group.Count(),
            group.Count(Selectable), group.Count(row => selected.ContainsKey(row.Candidate.Id)),
            SumBytes(group), SumBytes(group.Where(row => selected.ContainsKey(row.Candidate.Id)))))
        .OrderBy(group => group.Name, StringComparer.Ordinal).ToImmutableArray();
    public bool? FilteredSelection => SelectionState(Filtered);
    private ImmutableArray<CleanupCandidateSelection> Filtered => results.Where(row => (AllLocations || row.WorkspaceId == WorkspaceId) &&
        (Category is null || row.Category == Category) && (RuleId is null || row.Candidate.RuleId == RuleId) &&
        (Search.Length == 0 || row.RuleName.Contains(Search, StringComparison.OrdinalIgnoreCase) ||
            row.Candidate.Path.Value.Contains(Search, StringComparison.OrdinalIgnoreCase)))
        .ToImmutableArray();

    public Task LoadAsync() => RunAsync(CleanupReviewState.Loading, async token =>
    {
        var locations = await operations.ReadWorkspacesAsync(token);
        return () =>
        {
            Workspaces = locations.OrderBy(value => value.Path.Value, StringComparer.Ordinal).ToImmutableArray();
            WorkspaceId = Workspaces.Any(value => value.Id == WorkspaceId) ? WorkspaceId : Workspaces.FirstOrDefault()?.Id;
            ClearScan();
            State = CleanupReviewState.Empty;
        };
    }, ClearScan);

    public Task DiscoverAsync() => RunAsync(CleanupReviewState.Discovering, async token =>
    {
        // Registration may commit even if the caller closes the page. Re-read actual configuration afterward.
        LocationPreparation? result = null;
        string? failure = null;
        try { result = await operations.PrepareLocationsAsync(CancellationToken.None); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or OperationCanceledException)
        { failure = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "read_failed"; }
        var locations = await operations.ReadWorkspacesAsync(CancellationToken.None);
        return () =>
        {
            Workspaces = locations.OrderBy(value => value.Path.Value, StringComparer.Ordinal).ToImmutableArray();
            WorkspaceId = Workspaces.Any(value => value.Id == WorkspaceId) ? WorkspaceId : Workspaces.FirstOrDefault()?.Id;
            DiscoveryIssues = result?.Issues ?? [];
            DiscoveryAttempted = true;
            ErrorCode = failure;
            ErrorStage = failure is null ? null : "prepare_locations";
            State = failure is null ? CleanupReviewState.Empty : CleanupReviewState.Failed;
        };
    }, () => { ClearScan(); Workspaces = []; WorkspaceId = null; });

    public Task ScanAsync(string workspaceId, ScanBudget? budget = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!Workspaces.Any(workspace => workspace.Id == workspaceId)) throw new ShouException("invalid_argument", "Choose a registered scan location.");
        return RunAsync(CleanupReviewState.Scanning, async token =>
        {
            var snapshot = await operations.ScanAsync(workspaceId, budget ?? new(), token);
            return () =>
            {
                Snapshot = snapshot;
                BuildResults([snapshot]);
                State = CoverageState();
            };
        }, () => { WorkspaceId = workspaceId; ClearScan(); });
    }

    public Task ScanAllAsync(ScanBudget? budget = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (Workspaces.IsEmpty) throw new ShouException("invalid_argument", "Configure scan locations before scanning all locations.");
        var scope = Workspaces;
        return RunAsync(CleanupReviewState.Scanning, async token =>
        {
            var batch = await operations.ScanAllAsync(scope.Select(workspace => workspace.Id).ToImmutableArray(), budget ?? new(), token);
            if (batch.Scans.IsDefault || batch.Issues.IsDefault || batch.State is not ("complete" or "partial" or "cancelled") ||
                batch.Scans.Any(scan => scan.PreviewOnly || !scope.Any(workspace => workspace.SameRegistration(scan.Workspace))) ||
                batch.Scans.Select(scan => scan.WorkspaceId).Distinct().Count() != batch.Scans.Length ||
                batch.Scans.Select(scan => scan.Id).Distinct().Count() != batch.Scans.Length ||
                batch.State == "complete" && (batch.Scans.Length != scope.Length || !batch.Issues.IsEmpty ||
                    batch.Scans.Any(scan => !scan.Scan.IsScopeComplete || !scan.AnalysisIssues.IsEmpty)))
                throw new ShouException("scan_result_invalid", "The batch does not describe the registered scan locations.");
            if (token.IsCancellationRequested) batch = batch with { State = "cancelled" };
            return () =>
            {
                Batch = batch;
                AllLocations = true;
                BuildResults(batch.Scans);
                Snapshot = batch.Scans.FirstOrDefault(scan => scan.WorkspaceId == WorkspaceId) ?? batch.Scans.FirstOrDefault();
                if (Snapshot is not null) WorkspaceId = Snapshot.WorkspaceId;
                State = batch.State == "cancelled" ? CleanupReviewState.Cancelled : CoverageState();
            };
        }, ClearScan, retainCompletedOnStop: true);
    }

    public void SelectWorkspace(string workspaceId)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (WorkspaceId == workspaceId && !AllLocations) return;
        if (!Workspaces.Any(value => value.Id == workspaceId)) throw new ShouException("invalid_argument", "Choose a registered scan location.");
        generation++;
        operation?.Cancel();
        operation = null;
        WorkspaceId = workspaceId;
        if (Batch is null) ClearReview();
        Plan = null;
        Offset = 0;
        AllLocations = false;
        Snapshot = Batch?.Scans.FirstOrDefault(scan => scan.WorkspaceId == workspaceId);
        ErrorCode = null;
        ErrorStage = null;
        DiagnosticReference = null;
        SelectionErrorCode = null;
        State = CoverageState();
        NotifyAll();
    }

    public void InvalidateConfiguration()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        generation++;
        operation?.Cancel();
        operation = null;
        Workspaces = [];
        WorkspaceId = null;
        ClearScan();
        ErrorCode = null;
        SelectionErrorCode = null;
        State = CleanupReviewState.Empty;
        NotifyAll();
    }

    public bool SetSelected(string candidateId, bool value)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || requiresRescan || BatchRequiresRescan) return false;
        var row = Filtered.FirstOrDefault(item => item.Candidate.Id == candidateId);
        if (row is null) { SelectionErrorCode = "selection_unavailable"; NotifyAll(); return false; }
        return ChangeSelection([row], value);
    }

    public void ShowAllResults()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || Batch is null) return;
        AllLocations = true;
        Offset = 0;
        Plan = null;
        State = CoverageState();
        NotifyAll();
    }

    public void SetFilter(string? category, string? ruleId, string? search)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy) return;
        if (category is not null && !Categories.Contains(category) || ruleId is not null && !results.Any(row => row.Candidate.RuleId == ruleId))
            throw new ShouException("invalid_argument", "Choose an observed result category or rule.");
        Category = category;
        RuleId = ruleId;
        Search = search ?? "";
        if (Search.Length > 512) Search = Search[..512];
        Offset = 0;
        // Filters affect presentation only; already reviewed selections keep their exact source binding.
        SelectionErrorCode = null;
        NotifyAll();
    }

    public bool SetCategorySelected(string? category, bool value) => ChangeSelection(results.Where(row =>
        (category is null || row.Category == category) && Selectable(row)), value);
    public bool SetFilteredSelected(bool value) => ChangeSelection(Filtered.Where(Selectable), value);
    public bool SetGroupSelected(string ruleId, bool value) => ChangeSelection(results.Where(row => row.Candidate.RuleId == ruleId && Selectable(row)), value);
    public bool SelectRecommended() => ChangeSelection(results.Where(row => row.Recommended && Selectable(row)), true, replace: true);
    public bool SelectReviewable() => ChangeSelection(results.Where(row => row.Candidate.Risk != "high" && Selectable(row)), true, replace: true);
    public void ClearSelection() => ChangeSelection([], false, replace: true);

    private bool ChangeSelection(IEnumerable<CleanupCandidateSelection> rows, bool value, bool replace = false)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || requiresRescan || BatchRequiresRescan) return false;
        SelectionErrorCode = null;
        var next = replace ? new Dictionary<string, CleanupCandidateSelection>(StringComparer.Ordinal) : new(selected, StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (value && !Selectable(row)) { SelectionErrorCode = "selection_unavailable"; break; }
            if (value && !next.ContainsKey(row.Candidate.Id) && next.Count >= MaximumSelection) { SelectionErrorCode = "selection_limit"; break; }
            if (value && next.Values.Any(item => item.Candidate.Id != row.Candidate.Id &&
                (row.Candidate.Path.IsWithin(item.Candidate.Path) || item.Candidate.Path.IsWithin(row.Candidate.Path))))
            { SelectionErrorCode = "overlapping_selection"; break; }
            if (value) next[row.Candidate.Id] = row;
            else next.Remove(row.Candidate.Id);
        }
        // A group or recommendation action either succeeds in full or leaves the previous exact selection intact.
        if (SelectionErrorCode is null)
        {
            selected.Clear();
            foreach (var pair in next) selected.Add(pair.Key, pair.Value);
            Plan = null;
            State = CoverageState();
        }
        NotifyAll();
        return SelectionErrorCode is null;
    }

    public void MovePage(int direction)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (IsBusy || direction is not (-1 or 1) || direction == -1 && !HasPrevious || direction == 1 && !HasNext) return;
        Offset += direction * PageSize;
        NotifyAll();
    }

    public Task PreparePlanAsync()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!CanPreparePlan) throw new ShouException("invalid_argument", "Select current reviewable targets before preparing a plan.");
        var selection = selected.Values.GroupBy(row => row.ScanId).OrderBy(group => group.Key, StringComparer.Ordinal)
            .Select(group => new CleanupSelection(group.Key, group.Select(row => row.Candidate.Id).Order(StringComparer.Ordinal).ToImmutableArray())).ToImmutableArray();
        return RunAsync(CleanupReviewState.Preparing, async token =>
        {
            var plan = await operations.CreatePlanAsync(selection, CleanupAction.Permanent, token);
            if (plan.Action != CleanupAction.Permanent || plan.Items.IsDefault || plan.Sources.IsDefault || plan.Items.Length != selected.Count ||
                plan.Sources.Length != selection.Length || plan.Sources.Select(source => source.ScanId).Distinct().Count() != selection.Length ||
                plan.Sources.Any(source => !selection.Any(value => value.ScanId == source.ScanId) ||
                    !Workspaces.Any(workspace => workspace.SameRegistration(source.Workspace))) ||
                plan.Items.Select(item => item.CandidateId).Distinct().Count() != selected.Count ||
                plan.Items.Any(item => !selected.TryGetValue(item.CandidateId, out var row) || item.ScanId != row.ScanId || item.Path != row.Candidate.Path ||
                    item.RuleId != row.Candidate.RuleId || item.RuleVersion != row.Candidate.RuleVersion || item.ManifestDigest != row.Candidate.ManifestDigest))
                throw new ShouException("plan_stale", "The returned plan does not describe the exact selected sources and targets.");
            return () => { Plan = plan; State = CleanupReviewState.Review; };
        }, () => Plan = null, failure: () => { requiresRescan = true; selected.Clear(); Batch = null; });
    }

    public void Cancel()
    {
        if (operation is null || State == CleanupReviewState.Discovering) return;
        operation.Cancel();
        NotifyAll();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        operation?.Cancel();
        operation = null;
        GC.SuppressFinalize(this);
    }

    private async Task RunAsync(CleanupReviewState busy, Func<CancellationToken, Task<Action>> run, Action? start = null, Action? failure = null,
        bool retainCompletedOnStop = false)
    {
        using var diagnostic = OperationDiagnostics.Start("ui.cleanup." + busy.ToString().ToLowerInvariant());
        ObjectDisposedException.ThrowIf(disposed, this);
        var currentGeneration = ++generation;
        operation?.Cancel();
        using var current = new CancellationTokenSource();
        operation = current;
        start?.Invoke();
        State = busy;
        ErrorCode = null;
        ErrorStage = null;
        DiagnosticReference = diagnostic.Id;
        SelectionErrorCode = null;
        NotifyAll();
        try
        {
            var apply = await run(current.Token);
            // Only batch observations may be published after stop. Planning still requires an acknowledged live request.
            if (!retainCompletedOnStop) current.Token.ThrowIfCancellationRequested();
            if (!disposed && currentGeneration == generation) apply();
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested)
        {
            if (disposed || currentGeneration != generation) return;
            State = CleanupReviewState.Cancelled;
        }
        catch (Exception error)
        {
            diagnostic.Fail(error);
            if (disposed || currentGeneration != generation) return;
            failure?.Invoke();
            State = CleanupReviewState.Failed;
            ErrorStage = busy.ToString().ToLowerInvariant();
            ErrorCode = error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : error is IOException ? "read_failed" : "operation_failed";
        }
        finally
        {
            diagnostic.Complete(disposed || currentGeneration != generation ? "superseded" : State.ToString().ToLowerInvariant(), ResultCount,
                DiscoveryIssues.Length + (Batch?.Issues.Length ?? 0));
            if (!disposed && currentGeneration == generation) { operation = null; NotifyAll(); }
        }
    }

    private static long SumBytes(IEnumerable<CleanupCandidateSelection> rows) => rows.Aggregate(0L, (total, row) =>
        row.Candidate.AllocatedBytes > long.MaxValue - total ? long.MaxValue : total + row.Candidate.AllocatedBytes);
    private bool Selectable(CleanupCandidateSelection row) => !requiresRescan && !BatchRequiresRescan && row.Selectable;
    private bool? SelectionState(IEnumerable<CleanupCandidateSelection> rows)
    {
        var eligible = rows.Where(Selectable).ToArray();
        var count = eligible.Count(row => selected.ContainsKey(row.Candidate.Id));
        return count == 0 ? false : count == eligible.Length ? true : null;
    }
    private void BuildResults(ImmutableArray<CleanupScan> snapshots)
    {
        results = snapshots.SelectMany(snapshot => snapshot.Candidates.Select(candidate =>
        {
            var definition = snapshot.Rules.FirstOrDefault(rule => rule.Definition.GetProperty("id").GetString() == candidate.RuleId);
            var name = definition?.Definition.GetProperty("name").GetString() ?? candidate.RuleId;
            var category = !candidate.RuleId.StartsWith(BuiltinRuleCatalog.Prefix, StringComparison.Ordinal) ? "personal" :
                builtinCategories?.GetValueOrDefault(candidate.RuleId) ?? "other";
            var selectable = !snapshot.PreviewOnly && candidate.Complete && candidate.State == "review" && candidate.BlockedReasons.IsEmpty;
            var recommended = selectable && candidate.Risk == "review" && snapshot.Scan.IsScopeComplete && snapshot.AnalysisIssues.IsEmpty &&
                (Batch is null || Batch.State == "complete");
            return new CleanupCandidateSelection(candidate, snapshot.Id, snapshot.WorkspaceId, name, category, false, selectable, recommended);
        })).Where(row => reviewScope == CleanupReviewScope.All || row.Category is "build" or "dependencies")
            .OrderBy(row => row.Category, StringComparer.Ordinal).ThenBy(row => row.RuleName, StringComparer.Ordinal)
            .ThenBy(row => row.Candidate.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    }
    private CleanupReviewState CoverageState() => Batch?.State is "partial" or "cancelled" ? CleanupReviewState.Partial : Snapshot is not { } snapshot ? CleanupReviewState.Empty :
        snapshot.Scan.IsScopeComplete && snapshot.AnalysisIssues.IsEmpty ? CleanupReviewState.Ready : CleanupReviewState.Partial;
    private void ClearScan()
    {
        ClearReview();
        Batch = null;
        DiscoveryIssues = [];
        DiscoveryAttempted = false;
    }
    private void ClearReview()
    {
        Snapshot = null;
        Plan = null;
        Offset = 0;
        AllLocations = false;
        Category = RuleId = null;
        Search = "";
        results = [];
        requiresRescan = false;
        selected.Clear();
    }
    private void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
