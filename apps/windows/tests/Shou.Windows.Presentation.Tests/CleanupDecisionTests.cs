using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed partial class CleanupReviewTests
{
    [Fact]
    public async Task LargestFirstReviewAndKeptItemsSurviveFiltersAndRecommendations()
    {
        var small = Candidate(1) with { Risk = "review", AllocatedBytes = 12 };
        var large = Candidate(2) with { AllocatedBytes = 9000 };
        var blocked = Candidate(3, blocked: true);
        using var model = new CleanupReviewViewModel(new Operations { Result = Scan([small, large, blocked]) });
        await model.LoadAsync(); await model.ScanAsync(Location().Id);
        Assert.Equal(large.Id, model.Rows[0].Candidate.Id);
        Assert.Equal(0, model.SelectedCount);
        Assert.True(model.SetSelected(large.Id, true));
        Assert.True(model.KeepThisTime(small.Id, true));
        Assert.True(model.SelectRecommended());
        Assert.Equal(0, model.SelectedCount);
        model.SetDecisionFilter(CleanupDecisionFilter.Kept);
        Assert.Equal(small.Id, Assert.Single(model.Rows).Candidate.Id);
        Assert.False(model.SetSelected(small.Id, true));
        Assert.True(model.KeepThisTime(small.Id, false));
        model.SetDecisionFilter(CleanupDecisionFilter.Protected);
        Assert.Equal(blocked.Id, Assert.Single(model.Rows).Candidate.Id);
        model.SetDecisionFilter(CleanupDecisionFilter.Recommended);
        Assert.Equal(small.Id, Assert.Single(model.Rows).Candidate.Id);
        Assert.True(model.SelectRecommended()); Assert.Equal(1, model.SelectedCount);
        model.SetDecisionFilter(CleanupDecisionFilter.Decision);
        Assert.Equal(large.Id, Assert.Single(model.Rows).Candidate.Id);
        Assert.Equal(1, model.SelectedCount);
    }
}
