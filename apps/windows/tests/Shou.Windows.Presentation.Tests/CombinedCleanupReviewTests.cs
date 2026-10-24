using System.Collections.Immutable;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed partial class CleanupReviewTests
{
    [Fact]
    public async Task ProductCountsDescribeRuleGroupsWhileSelectionKeepsEveryExactLocation()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([AtLocation(1), AtLocation(2)], [], "complete")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(2, model.ResultCount); Assert.Equal(1, model.ResultGroupCount);
        Assert.Equal(1, model.FilteredGroupCount);
        var category = Assert.Single(model.CategorySummaries);
        Assert.Equal(2, category.Count); Assert.Equal(1, category.GroupCount);
        Assert.True(model.SetCategorySelected(null, true));
        Assert.Equal(2, model.SelectedCount); Assert.Equal(1, model.SelectedGroupCount);
        model.SetFilter(null, null, "no-generated-match");
        Assert.Equal(0, model.FilteredGroupCount); Assert.Equal(1, model.SelectedGroupCount);
        Assert.Null(model.Plan);
    }

    [Fact]
    public async Task ReviewableMenuReplacesSelectionWithoutSelectingHighRiskOrBlockedItemsOrChangingFilters()
    {
        var reviewed = Candidate(1) with { Risk = "review" };
        var high = Candidate(2);
        var blocked = Candidate(3, blocked: true) with { Risk = "review" };
        var operations = new Operations { Result = Scan([reviewed, high, blocked]) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.True(model.SetSelected(high.Id, true));
        model.SetFilter(null, null, "no-generated-match");
        Assert.True(model.SelectReviewable());
        Assert.Equal("no-generated-match", model.Search); Assert.Empty(model.Rows);
        model.SetFilter(null, null, "");
        Assert.Equal(reviewed.Id, Assert.Single(model.Rows.Where(row => row.Selected)).Candidate.Id);
        Assert.Null(operations.PlannedScan); Assert.Null(model.Plan);
    }

    [Fact]
    public async Task SelectionsFromTwoLocationsProduceOneExactPlanAndSurviveFilters()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([AtLocation(1), AtLocation(2)], [], "complete")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.True(model.AllLocations); Assert.Equal(2, model.Rows.Length);
        Assert.True(model.SetSelected(Candidate(1).Id, true));
        model.SelectWorkspace(Location(2).Id);
        Assert.True(model.SetSelected(Candidate(2).Id, true));
        model.SetFilter(null, null, "does not match"); Assert.Empty(model.Rows); Assert.Equal(2, model.SelectedCount);
        await model.PreparePlanAsync();
        Assert.Equal(2, operations.Selections.Length); Assert.Equal(2, model.Plan!.Sources.Length);
        Assert.Equal(2, model.Plan.Items.Length);
        Assert.All(model.Plan.Items, item => Assert.Contains(operations.Selections, source => source.ScanId == item.ScanId && source.CandidateIds.Contains(item.CandidateId)));
        model.ShowAllResults(); model.SetFilter(null, null, "");
        Assert.All(model.Rows, row => Assert.True(row.Selected));
    }

    [Fact]
    public async Task CategorySummariesUseScannedBytesAndSelectionDoesNotPlanCleanup()
    {
        var cache = Candidate(1) with { RuleId = "shou.builtin.cache", Risk = "review", AllocatedBytes = 1_000 };
        var personal = Candidate(2) with { AllocatedBytes = 2_500 };
        var operations = new Operations { Result = Scan([cache, personal]) };
        using var model = new CleanupReviewViewModel(operations, new Dictionary<string, string> { [cache.RuleId] = "cache" });
        await model.LoadAsync();
        await model.ScanAsync(Location().Id);
        Assert.Equal(3_500, model.ResultAllocatedBytes);
        Assert.Equal(0, model.SelectedAllocatedBytes);
        Assert.Equal(("cache", 1, 1_000), Summary(model, "cache"));
        Assert.Equal(("personal", 1, 2_500), Summary(model, "personal"));
        Assert.True(model.SetCategorySelected("cache", true));
        Assert.Equal(1_000, model.SelectedAllocatedBytes);
        Assert.Equal(1_000, model.CategorySummaries.Single(summary => summary.Id == "cache").SelectedBytes);
        Assert.Equal(0, model.CategorySummaries.Single(summary => summary.Id == "personal").SelectedBytes);
        Assert.Null(operations.PlannedScan);
        Assert.Null(model.Plan);
    }

    private static (string Id, int Count, long Bytes) Summary(CleanupReviewViewModel model, string id)
    {
        var summary = model.CategorySummaries.Single(value => value.Id == id);
        return (summary.Id, summary.Count, summary.AllocatedBytes);
    }

    [Fact]
    public async Task CategoriesComeFromCanonicalMetadataAndPersonalRulesStaySeparate()
    {
        using var definition = JsonDocument.Parse("""{"id":"shou.builtin.cache","name":"Cache with spaces"}""");
        var first = Candidate(1) with { RuleId = "shou.builtin.cache", Risk = "review" };
        var scan = Scan([first, Candidate(2)]) with { Rules = [new(definition.RootElement.Clone(), "unused")] };
        var operations = new Operations { Result = scan };
        using var model = new CleanupReviewViewModel(operations, new Dictionary<string, string> { [first.RuleId] = "cache" });
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.Equal(new[] { "cache", "personal" }, model.Categories);
        model.SetFilter("cache", null, "cache with ");
        Assert.Equal("Cache with spaces", Assert.Single(model.Rows).RuleName);
        Assert.True(model.SetFilteredSelected(true));
        model.SetFilter("personal", null, Candidate(2).Path.Value.ToUpperInvariant());
        Assert.Equal(Candidate(2).Id, Assert.Single(model.Rows).Candidate.Id);
        Assert.Equal(1, model.SelectedCount); Assert.False(model.FilteredSelection);
    }

    [Fact]
    public async Task RecommendedSelectionReplacesManualChoiceAndNeverIncludesHighRiskOrBlockedTargets()
    {
        var first = Candidate(1) with { Risk = "review" };
        var operations = new Operations { Result = Scan([first, Candidate(2), Candidate(3, blocked: true) with { Risk = "review" }]) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(2).Id, true);
        Assert.Equal(1, model.RecommendedCount); Assert.True(model.SelectRecommended());
        Assert.Equal(first.Id, Assert.Single(model.Rows.Where(row => row.Selected)).Candidate.Id);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PartialOrCancelledBatchOffersManualTargetsWithoutRecommendations(bool cancelled)
    {
        var scan = AtLocation(1) with { Candidates = [Candidate(1) with { Risk = "review" }] };
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([scan], [new(Location(2).Path, "entry_limit")], cancelled ? "cancelled" : "partial")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync();
        Assert.Equal(0, model.RecommendedCount); Assert.False(Assert.Single(model.Rows).Recommended);
        Assert.True(model.SetSelected(Candidate(1).Id, true));
    }

    [Fact]
    public async Task AGroupSelectionAboveTheGlobalLimitIsAtomic()
    {
        var operations = new Operations { Result = Scan(Enumerable.Range(1, 257).Select(value => Candidate(value)).ToImmutableArray()) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        model.SetSelected(Candidate(1).Id, true);
        Assert.False(model.SetFilteredSelected(true));
        Assert.Equal("selection_limit", model.SelectionErrorCode); Assert.Equal(1, model.SelectedCount);
        Assert.Equal(1, Assert.Single(model.Groups).SelectedCount);
    }

    [Fact]
    public async Task RecommendationLimitNeverSilentlyTruncatesTheProposedSelection()
    {
        var operations = new Operations { Result = Scan(Enumerable.Range(1, 257).Select(value => Candidate(value) with { Risk = "review" }).ToImmutableArray()) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.False(model.SelectRecommended()); Assert.Equal(0, model.SelectedCount);
        Assert.Equal("selection_limit", model.SelectionErrorCode);
    }

    [Fact]
    public async Task GroupSelectionSpansLocationsWithAccurateTriStateAndNoHiddenDeselection()
    {
        var operations = new Operations { Locations = [Location(1), Location(2)],
            BatchOperation = _ => Task.FromResult(new SystemScan([AtLocation(1), AtLocation(2)], [], "complete")) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAllAsync(); model.SetSelected(Candidate(1).Id, true);
        Assert.Null(Assert.Single(model.Groups).Selection); Assert.Null(model.FilteredSelection);
        Assert.True(model.SetGroupSelected("dev.cache", true)); Assert.True(model.FilteredSelection);
        model.SelectWorkspace(Location(1).Id); Assert.True(model.SetFilteredSelected(false));
        Assert.Equal(1, model.SelectedCount); model.ShowAllResults(); Assert.Null(model.FilteredSelection);
        model.ClearSelection(); Assert.Equal(0, model.SelectedCount); Assert.False(model.FilteredSelection);
    }

    [Fact]
    public async Task OverlappingGroupTargetsCannotPartiallyReplaceExistingSelections()
    {
        var operations = new Operations { Result = Scan([Candidate(1, "cache"), Candidate(2, "cache/child"), Candidate(3, "other/cache")]) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id); model.SetSelected(Candidate(3).Id, true);
        Assert.False(model.SetGroupSelected("dev.cache", true));
        Assert.Equal("overlapping_selection", model.SelectionErrorCode); Assert.Equal(1, model.SelectedCount);
        Assert.True(model.Rows.Single(row => row.Candidate.Id == Candidate(3).Id).Selected);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("foreign")]
    [InlineData("path")]
    public async Task ReturnedPlanMustMatchExactSelectionSourcesAndPaths(string change)
    {
        var scan = Scan([Candidate(1)]); var prepared = Plan(scan, [Candidate(1).Id], CleanupAction.Permanent);
        prepared = change switch
        {
            "missing" => prepared with { Items = [] },
            "foreign" => prepared with { Items = prepared.Items.SetItem(0, prepared.Items[0] with { ScanId = Id("scan", 99) }) },
            _ => prepared with { Items = prepared.Items.SetItem(0, prepared.Items[0] with { Path = Candidate(2).Path }) }
        };
        var operations = new Operations { Result = scan, PlanOperation = _ => Task.FromResult(prepared) };
        using var model = new CleanupReviewViewModel(operations);
        await model.LoadAsync(); await model.ScanAsync(Location().Id); model.SetSelected(Candidate(1).Id, true);
        await model.PreparePlanAsync();
        Assert.Null(model.Plan); Assert.False(model.CanPreparePlan); Assert.Equal("plan_stale", model.ErrorCode);
        Assert.Equal(0, model.SelectedCount);
    }
}
