using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed partial class CleanupReviewTests
{
    internal static string Id(string prefix, int value = 1) => prefix + "_" + value.ToString("x32");
    internal static Workspace Location(int value = 1) => new(Id("ws", value), "projects-" + value, WindowsPath.Parse("C:/Users/Dev/Projects" + value),
        new(1, value.ToString("x32"), "S-1-5-21-1000"), false, [], DateTimeOffset.UnixEpoch);
    internal static RuleCandidate Candidate(int value, string? path = null, bool blocked = false) => new(Id("candidate", value), "dev.cache", "1.0.0", path ?? "project-" + value + "/cache",
        Location().Path.Append(path ?? "project-" + value + "/cache"), new(1, (1000 + value).ToString("x32"), "S-1-5-21-1000"), 4096, 10,
        DateTimeOffset.UnixEpoch, "high", true, blocked ? "blocked" : "review", blocked ? ["protected_data"] : [], "sha256:" + new string('a', 64));
    internal static CleanupScan Scan(ImmutableArray<RuleCandidate> candidates, bool partial = false, bool preview = false, int id = 1) => new(1, Id("scan", id), Location(), new(), Id("config"),
        "sha256:" + new string('b', 64), [], new(Id("scan", id), Location().Path, Location().Identity, DateTimeOffset.UnixEpoch,
            partial ? ScanState.Partial : ScanState.Complete, [], partial ? [new(Location().Path, "permission_denied")] : [], []), candidates, [], preview);
    internal static CleanupPlan Plan(CleanupScan scan, ImmutableArray<string> ids, CleanupAction action) => new(2, Id("plan"), [new(scan.Id, scan.Workspace, scan.Rules)], scan.Budget,
        scan.ConfigurationRevision, scan.ConfigurationDigest, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch.AddMinutes(10), action,
        scan.Candidates.Where(value => ids.Contains(value.Id)).Select(value => new CleanupPlanItem(Id("item", int.Parse(value.Id[^4..], System.Globalization.NumberStyles.HexNumber)),
            scan.Id, value.Id, value.RuleId, value.RuleVersion, value.RelativePath, value.Path, [], [], value.ManifestDigest!, value.AllocatedBytes, value.LogicalBytes, value.Risk)).ToImmutableArray(),
        "sha256:" + new string('c', 64));

    private sealed class Operations : ICleanupReviewOperations
    {
        public Func<Task<LocationPreparation>>? PrepareOperation;
        public CancellationToken PrepareToken;
        public Task<LocationPreparation> PrepareLocationsAsync(CancellationToken cancellationToken)
        { PrepareToken = cancellationToken; return PrepareOperation?.Invoke() ?? Task.FromResult(new LocationPreparation(Locations, [])); }
        public CleanupScan Result = Scan([Candidate(1)]);
        public ImmutableArray<Workspace> Locations = [Location()];
        public Func<CancellationToken, Task<CleanupScan>>? ScanOperation;
        public Func<CancellationToken, Task<SystemScan>>? BatchOperation;
        public Func<CancellationToken, Task<ImmutableArray<Workspace>>>? LoadOperation;
        public Func<CancellationToken, Task<CleanupPlan>>? PlanOperation;
        public ImmutableArray<string> Selected;
        public ImmutableArray<CleanupSelection> Selections;
        public string? PlannedScan;
        public CleanupAction? Action;
        public CancellationToken ScanToken;
        public CancellationToken PlanToken;
        public ImmutableArray<string> BatchLocations;
        public Task<ImmutableArray<Workspace>> ReadWorkspacesAsync(CancellationToken cancellationToken) => LoadOperation?.Invoke(cancellationToken) ?? Task.FromResult(Locations);
        public Task<CleanupScan> ScanAsync(string workspaceId, ScanBudget budget, CancellationToken cancellationToken)
        { ScanToken = cancellationToken; return ScanOperation?.Invoke(cancellationToken) ?? Task.FromResult(Result); }
        public Task<SystemScan> ScanAllAsync(ImmutableArray<string> workspaceIds, ScanBudget budget, CancellationToken cancellationToken)
        { BatchLocations = workspaceIds; ScanToken = cancellationToken; return BatchOperation?.Invoke(cancellationToken) ?? Task.FromResult(new SystemScan([Result], [], "complete")); }
        public Task<CleanupPlan> CreatePlanAsync(ImmutableArray<CleanupSelection> selections, CleanupAction action, CancellationToken cancellationToken)
        {
            Selections = selections; PlannedScan = selections[0].ScanId; Selected = selections.SelectMany(value => value.CandidateIds).ToImmutableArray(); Action = action; PlanToken = cancellationToken;
            if (PlanOperation is not null) return PlanOperation(cancellationToken);
            var sources = selections.Select(value => value.ScanId == Result.Id ? Result : AtLocation(int.Parse(value.ScanId[^4..], System.Globalization.NumberStyles.HexNumber))).ToArray();
            var plans = sources.Select(source => Plan(source, selections.Single(value => value.ScanId == source.Id).CandidateIds, action)).ToArray();
            return Task.FromResult(plans[0] with { Sources = plans.SelectMany(plan => plan.Sources).ToImmutableArray(), Items = plans.SelectMany(plan => plan.Items).ToImmutableArray() });
        }
    }

    [Fact]
    public async Task LoadingConfiguredLocationsDoesNotScanOrSelectTargets()
    {
        var operations = new Operations { Locations = [Location(2), Location(1)] };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync();
        Assert.Equal(new[] { Location(1), Location(2) }, model.Workspaces);
        Assert.Equal(Location().Id, model.WorkspaceId);
        Assert.Null(model.Snapshot);
        Assert.False(model.CanPreparePlan);
        Assert.Null(operations.PlannedScan);
    }

    [Fact]
    public async Task DiscoveryClearsOldEvidenceAndKeepsPreparationBusyUntilTheWriteResponseReturns()
    {
        var response = new TaskCompletionSource<LocationPreparation>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { PrepareOperation = () => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(1).Id, true); await model.PreparePlanAsync();
        var task = model.DiscoverAsync(); model.Cancel();
        Assert.Equal(CleanupReviewState.Discovering, model.State);
        Assert.Null(model.Plan); Assert.Null(model.Snapshot); Assert.Empty(model.Workspaces);
        Assert.False(operations.PrepareToken.CanBeCanceled); Assert.False(model.StopRequested);
        operations.Locations = [Location(2)];
        response.SetResult(new([Location(2)], [new(Location(3).Path, "permission_denied")])); await task;
        Assert.Equal(Location(2).Id, model.WorkspaceId); Assert.Single(model.DiscoveryIssues);
        Assert.Null(model.Snapshot); Assert.Equal(0, model.SelectedCount);
    }

    [Fact]
    public async Task AFailedPreparationResponseStillReloadsActuallyRegisteredLocations()
    {
        var operations = new Operations { PrepareOperation = () => throw new ShouException("io_error", "private diagnostic") };
        using var model = new CleanupReviewViewModel(operations);
        await model.DiscoverAsync();
        Assert.Equal(CleanupReviewState.Failed, model.State); Assert.Equal("io_error", model.ErrorCode);
        Assert.Single(model.Workspaces); Assert.Null(model.Snapshot); Assert.False(model.CanPreparePlan);
    }

    [Theory]
    [InlineData(false, CleanupReviewState.Ready)]
    [InlineData(true, CleanupReviewState.Partial)]
    public async Task PartialCoverageRemainsVisibleAndHighRiskRequiresExplicitSelection(bool partial, CleanupReviewState expected)
    {
        var operations = new Operations { Result = Scan([Candidate(1), Candidate(2, blocked: true)], partial) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.Equal(expected, model.State);
        Assert.Equal(0, model.SelectedCount);
        Assert.All(model.Rows, row => Assert.False(row.Selected));
        Assert.True(model.SetSelected(Candidate(1).Id, true));
        Assert.False(model.SetSelected(Candidate(2).Id, true));
        Assert.False(model.SetSelected(Id("candidate", 99), true));
        Assert.Equal(1, model.SelectedCount);
    }

    [Fact]
    public async Task DraftPreviewNeverOffersSelectionOrAPlan()
    {
        var operations = new Operations { Result = Scan([Candidate(1)], preview: true) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.False(Assert.Single(model.Rows).Selectable);
        Assert.False(model.SetSelected(Candidate(1).Id, true));
        await Assert.ThrowsAsync<ShouException>(() => model.PreparePlanAsync());
        Assert.Null(operations.PlannedScan);
    }

    [Theory]
    [InlineData("project/cache", "project/cache/child")]
    [InlineData("project/cache", "project/cache")]
    [InlineData("project/cache/child", "project/cache")]
    public async Task OverlappingRulesAndParentChildTargetsCannotDoubleSelect(string first, string second)
    {
        var operations = new Operations { Result = Scan([Candidate(1, first), Candidate(2, second)]) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.True(model.SetSelected(Candidate(1).Id, true));
        Assert.False(model.SetSelected(Candidate(2).Id, true));
        Assert.Equal("overlapping_selection", model.SelectionErrorCode);
        Assert.Equal(1, model.SelectedCount);
    }

    [Fact]
    public async Task PaginationPreservesExplicitSelectionAndBoundsTheWholePlan()
    {
        var operations = new Operations { Result = Scan(Enumerable.Range(1, 257).Select(value => Candidate(value)).ToImmutableArray()) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.Equal(200, model.Rows.Length);
        foreach (var row in model.Rows) Assert.True(model.SetSelected(row.Candidate.Id, true));
        model.MovePage(1);
        Assert.Equal(57, model.Rows.Length);
        foreach (var row in model.Rows.Take(56)) Assert.True(model.SetSelected(row.Candidate.Id, true));
        Assert.False(model.SetSelected(model.Rows.Single(row => !row.Selected).Candidate.Id, true));
        Assert.Equal("selection_limit", model.SelectionErrorCode);
        model.MovePage(-1);
        Assert.All(model.Rows, row => Assert.True(row.Selected));
        await model.PreparePlanAsync();
        Assert.Equal(256, operations.Selected.Length);
        Assert.Equal(CleanupAction.Permanent, operations.Action);
        Assert.Equal(operations.Result.Id, operations.PlannedScan);
        Assert.Equal(CleanupReviewState.Review, model.State);
    }

    [Fact]
    public async Task ChangingSelectionInvalidatesTheDisplayedPlan()
    {
        var operations = new Operations();
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(1).Id, true); await model.PreparePlanAsync();
        Assert.NotNull(model.Plan);
        model.SetSelected(Candidate(1).Id, false);
        Assert.Null(model.Plan);
        Assert.False(model.CanPreparePlan);
    }

    [Fact]
    public async Task ChangingLocationClearsSelectionAndCancelsEvidenceFromThePreviousScope()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)] };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(1).Id, true); await model.PreparePlanAsync();
        model.SelectWorkspace(Location(2).Id);
        Assert.Equal(Location(2).Id, model.WorkspaceId);
        Assert.Null(model.Snapshot); Assert.Null(model.Plan);
        Assert.Equal(0, model.SelectedCount); Assert.False(model.CanPreparePlan);
        var pending = new TaskCompletionSource<CleanupScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        operations.ScanOperation = _ => pending.Task;
        var old = model.ScanAsync(Location(1).Id); var token = operations.ScanToken;
        model.SelectWorkspace(Location(2).Id);
        Assert.True(token.IsCancellationRequested);
        pending.SetResult(operations.Result); await old;
        Assert.Null(model.Snapshot);
        Assert.Equal(CleanupReviewState.Empty, model.State);
    }

    [Fact]
    public async Task RefreshInvalidatesOldSelectionImmediatelyEvenWhenConfigurationCannotBeRead()
    {
        var operations = new Operations();
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(1).Id, true); await model.PreparePlanAsync();
        var pending = new TaskCompletionSource<ImmutableArray<Workspace>>(TaskCreationOptions.RunContinuationsAsynchronously);
        operations.LoadOperation = _ => pending.Task;
        var task = model.LoadAsync();
        Assert.Null(model.Plan); Assert.Null(model.Snapshot);
        Assert.Equal(0, model.SelectedCount); Assert.False(model.CanPreparePlan);
        pending.SetException(new ShouException("permission_denied", "private diagnostic")); await task;
        Assert.Equal(CleanupReviewState.Failed, model.State);
        Assert.False(model.CanPreparePlan);
        Assert.False(model.SetSelected(Candidate(1).Id, true));
    }

    [Fact]
    public async Task ConfigurationMutationClearsPlansAndRejectsOldScopeUntilReloaded()
    {
        var operations = new Operations();
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(1).Id, true); await model.PreparePlanAsync();
        model.InvalidateConfiguration();
        Assert.Null(model.Plan); Assert.Null(model.Snapshot); Assert.Empty(model.Workspaces);
        Assert.Null(model.WorkspaceId); Assert.Equal(0, model.SelectedCount);
        Assert.False(model.CanPreparePlan);
        await Assert.ThrowsAsync<ShouException>(() => model.ScanAsync(Location().Id));
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.True(model.SetSelected(Candidate(1).Id, true));
    }

    [Fact]
    public async Task ConfigurationMutationCancelsAndRejectsAnAlreadyRunningScan()
    {
        var response = new TaskCompletionSource<CleanupScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { ScanOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); var task = model.ScanAsync(Location().Id);
        model.InvalidateConfiguration();
        response.SetResult(operations.Result); await task;
        Assert.True(operations.ScanToken.IsCancellationRequested);
        Assert.Null(model.Snapshot); Assert.Empty(model.Rows);
        Assert.Equal(CleanupReviewState.Empty, model.State);
    }

    [Fact]
    public async Task ConfigurationMutationRejectsAnAlreadyRunningLocationRead()
    {
        var response = new TaskCompletionSource<ImmutableArray<Workspace>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { LoadOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        var task = model.LoadAsync(); model.InvalidateConfiguration();
        response.SetResult([Location()]); await task;
        Assert.Empty(model.Workspaces); Assert.Null(model.WorkspaceId);
        Assert.False(model.CanPreparePlan);
        Assert.Equal(CleanupReviewState.Empty, model.State);
    }

    [Theory]
    [InlineData("plan_stale")]
    [InlineData("activity_unknown")]
    [InlineData("active_target")]
    public async Task FailedRevalidationRequiresNewEvidenceBeforeAnotherPlan(string code)
    {
        var operations = new Operations { PlanOperation = _ => throw new ShouException(code, "private diagnostic") };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id); model.SetSelected(Candidate(1).Id, true);
        await model.PreparePlanAsync();
        Assert.Equal(CleanupReviewState.Failed, model.State);
        Assert.Equal(code, model.ErrorCode);
        Assert.Equal(0, model.SelectedCount);
        Assert.False(model.SetSelected(Candidate(1).Id, true));
        Assert.Null(model.Plan);
        await model.ScanAsync(Location().Id);
        Assert.True(model.SetSelected(Candidate(1).Id, true));
    }

    [Fact]
    public async Task SupersededScansCannotReplaceCurrentEvidenceEvenWhenTheAdapterIgnoresCancellation()
    {
        var first = new TaskCompletionSource<CleanupScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { ScanOperation = _ => first.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); var old = model.ScanAsync(Location().Id); var oldToken = operations.ScanToken;
        operations.ScanOperation = null; operations.Result = Scan([Candidate(2)], id: 2);
        await model.ScanAsync(Location().Id);
        Assert.True(oldToken.IsCancellationRequested);
        first.SetResult(Scan([Candidate(1)])); await old;
        Assert.Equal(Id("scan", 2), model.Snapshot!.Id);
        Assert.Equal(Candidate(2).Id, Assert.Single(model.Rows).Candidate.Id);
    }

    [Fact]
    public async Task CancellationAfterPlanningCannotDisplayAnUnacknowledgedReview()
    {
        var response = new TaskCompletionSource<CleanupPlan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { PlanOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id); model.SetSelected(Candidate(1).Id, true);
        var task = model.PreparePlanAsync(); model.Cancel();
        Assert.True(model.StopRequested);
        Assert.False(model.SetSelected(Candidate(1).Id, false));
        response.SetResult(Plan(operations.Result, [Candidate(1).Id], CleanupAction.Permanent)); await task;
        Assert.True(operations.PlanToken.IsCancellationRequested);
        Assert.Equal(CleanupReviewState.Cancelled, model.State);
        Assert.Null(model.Plan);
    }

    [Fact]
    public async Task DisposingCancelsWithoutLateNotificationsOrEvidencePublication()
    {
        var response = new TaskCompletionSource<CleanupScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { ScanOperation = _ => response.Task };
        var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); var task = model.ScanAsync(Location().Id);
        var changes = 0; model.PropertyChanged += (_, _) => changes++;
        model.Dispose(); response.SetResult(operations.Result); await task;
        Assert.True(operations.ScanToken.IsCancellationRequested);
        Assert.Equal(0, changes);
        Assert.Null(model.Snapshot);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => model.ScanAsync(Location().Id));
    }

    private static CleanupScan AtLocation(int value)
    {
        var scan = Scan([Candidate(value)], id: value);
        var workspace = Location(value);
        return scan with { Workspace = workspace, Scan = scan.Scan with { Root = workspace.Path, RootIdentity = workspace.Identity },
            Candidates = scan.Candidates.Select(candidate => candidate with { Path = workspace.Path.Append(candidate.RelativePath) }).ToImmutableArray() };
    }

    [Fact]
    public async Task BatchUsesDisplayedLocationsAndPreservesSelectionAcrossLocationFilters()
    {
        var first = AtLocation(1); var second = AtLocation(2);
        var operations = new Operations { Locations = [Location(2), Location(1)], BatchOperation = _ => Task.FromResult(new SystemScan([first, second], [], "complete")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(new[] { Location(1).Id, Location(2).Id }, operations.BatchLocations);
        Assert.Equal(first.Id, model.Snapshot!.Id); Assert.Equal(2, model.Batch!.Scans.Length);
        Assert.Equal(0, model.SelectedCount); Assert.False(model.CanPreparePlan);
        Assert.True(model.SetSelected(Candidate(1).Id, true)); await model.PreparePlanAsync();
        Assert.Equal(first.Id, operations.PlannedScan);
        model.SelectWorkspace(Location(2).Id);
        Assert.Equal(second.Id, model.Snapshot!.Id); Assert.Null(model.Plan); Assert.Equal(1, model.SelectedCount);
        Assert.False(model.SetSelected(Candidate(1).Id, true));
        Assert.True(model.SetSelected(Candidate(2).Id, true));
        model.SelectWorkspace(Location(1).Id);
        Assert.Equal(first.Id, model.Snapshot!.Id); Assert.Equal(2, model.SelectedCount);
    }

    [Fact]
    public async Task PartialBatchKeepsUnstartedLocationsVisibleWithoutInventingResults()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([AtLocation(1)], [new(Location(2).Path, "resource_limit")], "partial")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(CleanupReviewState.Partial, model.State);
        Assert.True(model.SetSelected(Candidate(1).Id, true));
        model.SelectWorkspace(Location(2).Id);
        Assert.Null(model.Snapshot); Assert.Empty(model.Rows); Assert.True(model.CanPreparePlan);
        Assert.Single(model.Batch!.Issues);
    }

    [Fact]
    public async Task StopRetainsCompletedBatchObservationsButDoesNotSelectOrPrepareAnything()
    {
        var response = new TaskCompletionSource<SystemScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { Locations = [Location(1), Location(2)], BatchOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); var task = model.ScanAllAsync(); model.Cancel();
        Assert.True(operations.ScanToken.IsCancellationRequested); Assert.True(model.IsBusy);
        response.SetResult(new([AtLocation(1)], [new(Location(2).Path, "cancelled")], "cancelled")); await task;
        Assert.Equal(CleanupReviewState.Cancelled, model.State); Assert.False(model.IsBusy);
        Assert.Equal(AtLocation(1).Id, model.Snapshot!.Id);
        Assert.Equal(0, model.SelectedCount); Assert.Null(model.Plan); Assert.Null(operations.PlannedScan);
    }

    [Theory]
    [InlineData("foreign")]
    [InlineData("duplicate")]
    [InlineData("draft")]
    [InlineData("missing_complete")]
    public async Task BatchCannotPublishUnrelatedDraftDuplicateOrFalselyCompleteResults(string kind)
    {
        var scan = AtLocation(1);
        var scans = kind switch
        {
            "foreign" => new[] { AtLocation(3) },
            "duplicate" => [scan, scan],
            "draft" => [scan with { PreviewOnly = true }],
            _ => [scan]
        };
        var operations = new Operations { Locations = [Location(1), Location(2)], BatchOperation = _ => Task.FromResult(new SystemScan(scans.ToImmutableArray(), [], "complete")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(CleanupReviewState.Failed, model.State); Assert.Equal("scan_result_invalid", model.ErrorCode);
        Assert.Null(model.Batch); Assert.Null(model.Snapshot); Assert.False(model.CanPreparePlan);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfigurationInvalidationAndDisposalRejectLateBatchResults(bool dispose)
    {
        var response = new TaskCompletionSource<SystemScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { BatchOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); var task = model.ScanAllAsync();
        if (dispose) model.Dispose(); else model.InvalidateConfiguration();
        var notifications = 0; model.PropertyChanged += (_, _) => notifications++;
        response.SetResult(new([AtLocation(1)], [], "complete")); await task;
        Assert.True(operations.ScanToken.IsCancellationRequested); Assert.Null(model.Batch); Assert.Null(model.Snapshot);
        Assert.Equal(0, notifications);
    }

    [Fact]
    public async Task SupersededBatchCannotReplaceANewerSingleLocationScan()
    {
        var response = new TaskCompletionSource<SystemScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var operations = new Operations { BatchOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); var old = model.ScanAllAsync(); var token = operations.ScanToken;
        operations.Result = Scan([Candidate(9)], id: 9);
        await model.ScanAsync(Location(1).Id);
        response.SetResult(new([AtLocation(1)], [], "complete")); await old;
        Assert.True(token.IsCancellationRequested); Assert.Null(model.Batch);
        Assert.Equal(operations.Result.Id, model.Snapshot!.Id);
    }

    [Fact]
    public async Task PlanningFailureInvalidatesTheWholeBatchBeforeAnotherScopeCanBeReviewed()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([AtLocation(1), AtLocation(2)], [], "complete")),
            PlanOperation = _ => throw new ShouException("plan_stale", "private diagnostic") };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync(); model.SetSelected(Candidate(1).Id, true);
        await model.PreparePlanAsync(); model.SelectWorkspace(Location(2).Id);
        Assert.Null(model.Batch); Assert.Null(model.Snapshot); Assert.False(model.CanPreparePlan);
    }

    [Fact]
    public async Task UnexpectedBatchErrorsUnlockThePageWithoutExposingDiagnostics()
    {
        var operations = new Operations { BatchOperation = _ => throw new InvalidOperationException("private diagnostic") };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.False(model.IsBusy); Assert.Equal(CleanupReviewState.Failed, model.State);
        Assert.Equal("operation_failed", model.ErrorCode); Assert.Null(model.Batch);
    }

    [Fact]
    public async Task AConfigurationChangeReportedDuringTheBatchBlocksEvenPreviouslyCompletedScopes()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([AtLocation(1)], [new(Location(2).Path, "plan_stale")], "partial")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.False(Assert.Single(model.Rows).Selectable);
        Assert.False(model.SetSelected(Candidate(1).Id, true));
        model.SelectWorkspace(Location(2).Id); model.SelectWorkspace(Location(1).Id);
        Assert.False(Assert.Single(model.Rows).Selectable);
        await Assert.ThrowsAsync<ShouException>(() => model.PreparePlanAsync());
        Assert.Null(operations.PlannedScan);
    }
}
