using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed partial class CleanupReviewTests
{
    [Fact]
    public async Task HeadlineGroupCountStaysWithUnfilteredBytesAfterCategoryFilter()
    {
        var cache = Candidate(1) with { RuleId = "shou.builtin.cache", Risk = "review", AllocatedBytes = 1_000 };
        var personal = Candidate(2) with { AllocatedBytes = 2_500 };
        var operations = new Operations { Result = Scan([cache, personal]) };
        using var model = new CleanupReviewViewModel(operations, new Dictionary<string, string> { [cache.RuleId] = "cache" });
        await model.LoadAsync();
        await model.ScanAsync(Location().Id);
        Assert.Equal(2, model.ResultGroupCount);
        Assert.Equal(3_500, model.ResultAllocatedBytes);
        Assert.Equal(2, model.Groups.Length);
        model.SetFilter("cache", null, "");
        Assert.Single(model.Groups);
        Assert.Equal(2, model.ResultGroupCount);
        Assert.Equal(3_500, model.ResultAllocatedBytes);
        Assert.Null(operations.PlannedScan);
        Assert.Null(model.Plan);
    }
}
