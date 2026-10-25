using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed partial class CleanupReviewTests
{
    private static readonly IReadOnlyDictionary<string, string> ProjectCategories = new Dictionary<string, string>
    { ["shou.builtin.output"] = "build", ["shou.builtin.dependencies"] = "dependencies", ["shou.builtin.cache"] = "cache" };
    private static RuleCandidate ProjectCandidate(int id, string path, string rule = "shou.builtin.output") => Candidate(id, path) with { RuleId = rule, Risk = "review" };
    private static CleanupScan ProjectScan(params RuleCandidate[] candidates)
    {
        var scan = Scan(candidates.ToImmutableArray());
        var marker = new FileEntry(Location().Path.Append("app/Package.swift"), new(1, new string('f', 32), "S-1-5-21-1000"),
            EntryKind.File, 0, 0, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch);
        return scan with { Scan = scan.Scan with { Entries = [new(marker, 0)] } };
    }

    [Fact]
    public async Task SwitchingPagesReusesLoadedLocationsScanAndExactSelection()
    {
        var output = ProjectCandidate(1, "app/.build");
        var cache = ProjectCandidate(2, "shared/cache", "shou.builtin.cache");
        var operations = new Operations { Result = ProjectScan(output, cache) };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.EnsureLoadedAsync(); await model.ScanAllAsync();
        Assert.True(model.SetSelected(cache.Id, true));
        model.SetFilter("cache", null, "shared");
        model.SetScope(CleanupReviewScope.ProjectOutputs); await model.EnsureLoadedAsync();
        Assert.Equal(1, operations.LoadCalls); Assert.Equal(1, operations.BatchCalls); Assert.Equal(0, operations.ScanCalls);
        Assert.Equal(output.Id, Assert.Single(model.Rows).Candidate.Id); Assert.Equal(0, model.SelectedCount);
        Assert.Null(model.Category); Assert.Equal("", model.Search);
        Assert.True(model.SetSelected(output.Id, true));
        model.SetFilter(null, null, "app");
        model.SetScope(CleanupReviewScope.All); await model.EnsureLoadedAsync();
        Assert.Equal("cache", model.Category); Assert.Equal("shared", model.Search);
        Assert.Equal(2, model.SelectedCount); Assert.True(Assert.Single(model.Rows).Selected);
        model.SetScope(CleanupReviewScope.ProjectOutputs);
        Assert.Equal("app", model.Search); Assert.True(Assert.Single(model.Rows).Selected);
    }

    [Theory]
    [InlineData("clear")]
    [InlineData("recommended")]
    [InlineData("reviewable")]
    public async Task ProjectReplacementMenusPreserveSelectionsOutsideTheProjectScope(string action)
    {
        var output = ProjectCandidate(1, "app/.build");
        var high = ProjectCandidate(2, "app/manual") with { Risk = "high" };
        var cache = ProjectCandidate(3, "shared/cache", "shou.builtin.cache");
        var operations = new Operations { Result = ProjectScan(output, high, cache) };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.True(model.SetSelected(cache.Id, true)); Assert.True(model.SetSelected(high.Id, true));
        model.SetScope(CleanupReviewScope.ProjectOutputs);
        switch (action)
        {
            case "clear": model.ClearSelection(); break;
            case "recommended": Assert.True(model.SelectRecommended()); break;
            default: Assert.True(model.SelectReviewable()); break;
        }
        Assert.Equal(action == "clear" ? 0 : 1, model.SelectedCount);
        Assert.DoesNotContain(model.Rows, row => row.Candidate.Id == high.Id && row.Selected);
        model.SetScope(CleanupReviewScope.All);
        Assert.True(model.Rows.Single(row => row.Candidate.Id == cache.Id).Selected);
        Assert.Equal(action == "clear" ? 1 : 2, model.SelectedCount);
    }

    [Fact]
    public async Task ProjectPlanContainsOnlyProjectSourcesWhileSmartCleanupKeepsTheWholeSelection()
    {
        var output = ProjectCandidate(1, "app/.build");
        var cache = ProjectCandidate(2, "shared/cache", "shou.builtin.cache");
        var operations = new Operations { Result = ProjectScan(output, cache) };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.LoadAsync(); await model.ScanAllAsync(); Assert.True(model.SetCategorySelected(null, true));
        model.SetScope(CleanupReviewScope.ProjectOutputs);
        model.SetFilter(null, null, "no-matches");
        Assert.Equal(1, model.SelectedCount); Assert.Equal(output.AllocatedBytes, model.SelectedAllocatedBytes);
        await model.PreparePlanAsync();
        Assert.Equal(output.Id, Assert.Single(model.Plan!.Items).CandidateId);
        Assert.Equal(output.Id, Assert.Single(operations.Selected));
        model.SetScope(CleanupReviewScope.All);
        Assert.Null(model.Plan); Assert.Equal(2, model.SelectedCount);
        await model.PreparePlanAsync();
        Assert.Equal(new[] { output.Id, cache.Id }, operations.Selected);
    }

    [Fact]
    public async Task AReturnedPlanCannotSmuggleAnAlreadySelectedCacheIntoTheProjectScope()
    {
        var output = ProjectCandidate(1, "app/.build");
        var cache = ProjectCandidate(2, "shared/cache", "shou.builtin.cache");
        var scan = ProjectScan(output, cache);
        var operations = new Operations { Result = scan, PlanOperation = _ => Task.FromResult(Plan(scan, [output.Id, cache.Id], CleanupAction.Permanent)) };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.LoadAsync(); await model.ScanAllAsync(); model.SetCategorySelected(null, true);
        model.SetScope(CleanupReviewScope.ProjectOutputs); await model.PreparePlanAsync();
        Assert.Null(model.Plan); Assert.Equal("plan_stale", model.ErrorCode); Assert.False(model.CanPreparePlan);
        model.SetScope(CleanupReviewScope.All); Assert.Equal(0, model.SelectedCount); Assert.False(model.CanPreparePlan);
    }

    [Fact]
    public async Task SwitchingScopeCancelsAndRejectsALatePlanWithoutDiscardingSelections()
    {
        var response = new TaskCompletionSource<CleanupPlan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var output = ProjectCandidate(1, "app/.build"); var scan = ProjectScan(output);
        var operations = new Operations { Result = scan, PlanOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.LoadAsync(); await model.ScanAllAsync(); model.SetSelected(output.Id, true);
        var task = model.PreparePlanAsync(); var token = operations.PlanToken;
        model.SetScope(CleanupReviewScope.ProjectOutputs);
        Assert.True(token.IsCancellationRequested); Assert.False(model.IsBusy); Assert.Null(model.Plan);
        response.SetResult(Plan(scan, [output.Id], CleanupAction.Permanent)); await task;
        Assert.Null(model.Plan); Assert.Equal(1, model.SelectedCount); Assert.True(model.CanPreparePlan);
    }

    [Fact]
    public async Task ScopeCanChangeDuringScanningWithoutStartingASecondScanOrLosingTheResult()
    {
        var response = new TaskCompletionSource<SystemScan>(TaskCreationOptions.RunContinuationsAsynchronously);
        var output = ProjectCandidate(1, "app/.build"); var cache = ProjectCandidate(2, "shared/cache", "shou.builtin.cache");
        var operations = new Operations { BatchOperation = _ => response.Task };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.EnsureLoadedAsync(); var task = model.ScanAllAsync();
        model.SetScope(CleanupReviewScope.ProjectOutputs); await model.EnsureLoadedAsync();
        Assert.False(operations.ScanToken.IsCancellationRequested); Assert.True(model.IsBusy); Assert.Equal(1, operations.BatchCalls);
        response.SetResult(new([ProjectScan(output, cache)], [], "complete")); await task;
        Assert.Equal(output.Id, Assert.Single(model.Rows).Candidate.Id);
        model.SetScope(CleanupReviewScope.All); Assert.Equal(2, model.ResultCount);
    }

    [Fact]
    public async Task ProjectGroupsHaveAccurateTriStatePathsSearchAndCapacity()
    {
        var output = ProjectCandidate(1, "app/.build"); var dependencies = ProjectCandidate(2, "app/dependencies", "shou.builtin.dependencies");
        var blocked = ProjectCandidate(3, "app/blocked") with { State = "blocked", BlockedReasons = ["protected_data"] };
        var fallback = ProjectCandidate(4, "unknown/target");
        using var model = new CleanupReviewViewModel(new Operations { Result = ProjectScan(output, dependencies, blocked, fallback) }, ProjectCategories,
            CleanupReviewScope.ProjectOutputs);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(2, model.ResultGroupCount);
        var project = model.ProjectGroups.Single(group => group.IdentifiedProject);
        Assert.Equal(Location().Path.Append("app"), project.Path); Assert.Equal(3, project.Count); Assert.Equal(2, project.SelectableCount);
        Assert.Equal(12_288, project.AllocatedBytes); Assert.False(project.Selection);
        Assert.True(model.SetSelected(output.Id, true));
        Assert.Null(model.ProjectGroups.Single(group => group.IdentifiedProject).Selection);
        model.SetFilter(null, null, "dependencies");
        project = Assert.Single(model.ProjectGroups); Assert.Equal(1, project.Count); Assert.False(project.Selection);
        Assert.True(model.SetProjectSelected(project.Id, true));
        model.SetFilter(null, null, ""); project = model.ProjectGroups.Single(group => group.IdentifiedProject);
        Assert.True(project.Selection); Assert.Equal(8192, project.SelectedBytes); Assert.False(model.SetSelected(blocked.Id, true));
        Assert.True(model.SetProjectSelected(project.Id, false)); Assert.Equal(0, model.SelectedCount);
    }

    [Fact]
    public async Task ProjectGroupPaginationKeepsExactSourcesAcrossPages()
    {
        var outputs = Enumerable.Range(1, 205).Select(id => ProjectCandidate(id, "app/output-" + id.ToString("D3"))).ToArray();
        var operations = new Operations { Result = ProjectScan(outputs) };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories, CleanupReviewScope.ProjectOutputs);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(200, model.Rows.Length); Assert.Equal(205, Assert.Single(model.ProjectGroups).Count);
        Assert.True(model.SetProjectSelected(Assert.Single(model.ProjectGroups).Id, true));
        Assert.Equal(205, model.SelectedCount); model.MovePage(1);
        Assert.Equal(5, model.Rows.Length); Assert.All(model.Rows, row => Assert.True(row.Selected));
        await model.PreparePlanAsync(); Assert.Equal(205, model.Plan!.Items.Length);
        Assert.Equal(outputs.Select(row => row.Id).Order(), operations.Selected.Order());
    }

    [Fact]
    public async Task ProjectGroupSelectionAboveTheGlobalLimitIsAtomicAndPreservesHiddenCacheSelection()
    {
        var outputs = Enumerable.Range(1, 256).Select(id => ProjectCandidate(id, "app/output-" + id)).ToArray();
        var cache = ProjectCandidate(300, "shared/cache", "shou.builtin.cache");
        using var model = new CleanupReviewViewModel(new Operations { Result = ProjectScan([.. outputs, cache]) }, ProjectCategories);
        await model.LoadAsync(); await model.ScanAllAsync(); model.SetSelected(cache.Id, true);
        model.SetScope(CleanupReviewScope.ProjectOutputs);
        Assert.False(model.SetProjectSelected(Assert.Single(model.ProjectGroups).Id, true));
        Assert.Equal("selection_limit", model.SelectionErrorCode); Assert.Equal(0, model.SelectedCount);
        model.SetScope(CleanupReviewScope.All); Assert.Equal(1, model.SelectedCount);
        model.SetFilter("cache", null, "");
        Assert.True(model.Rows.Single(row => row.Candidate.Id == cache.Id).Selected);
    }

    [Fact]
    public async Task ConfigurationInvalidationReloadsOnceAndInvalidatesBothScopes()
    {
        var output = ProjectCandidate(1, "app/.build");
        var operations = new Operations { Result = ProjectScan(output) };
        using var model = new CleanupReviewViewModel(operations, ProjectCategories);
        await model.EnsureLoadedAsync(); await model.ScanAllAsync(); model.SetSelected(output.Id, true);
        model.SetScope(CleanupReviewScope.ProjectOutputs); model.SetFilter(null, null, "app");
        model.InvalidateConfiguration();
        Assert.Null(model.Batch); Assert.Empty(model.ProjectGroups); Assert.Equal(0, model.SelectedCount);
        await model.EnsureLoadedAsync(); model.SetScope(CleanupReviewScope.All); await model.EnsureLoadedAsync();
        Assert.Equal(2, operations.LoadCalls); Assert.Empty(model.Rows); Assert.Equal("", model.Search);
        Assert.False(model.CanPreparePlan); Assert.Null(operations.PlannedScan);
    }
}
