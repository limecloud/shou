using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;
using static Shou.Windows.Presentation.Tests.CleanupReviewTests;

namespace Shou.Windows.Presentation.Tests;

public sealed class CleanupCompletionSummaryTests
{
    private static CleanupPlan Prepared(CleanupAction action = CleanupAction.Permanent) =>
        Plan(Scan([Candidate(1), Candidate(2)]), [Candidate(1).Id, Candidate(2).Id], action);

    private static CleanupExecution Receipt(CleanupPlan plan, CleanupExecutionState state, params CleanupItemState[] items) =>
        new(1, Id("execution"), plan.Id, plan.Digest, plan.Action, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch,
            state, items.Select((item, index) => new CleanupItemResult(plan.Items[index].Id, item)).ToImmutableArray());

    [Theory]
    [InlineData(CleanupAction.Permanent, CleanupItemState.Purged, "Permanently removed; this cannot be undone.")]
    [InlineData(CleanupAction.Trash, CleanupItemState.Trashed, "Moved to Trash; this is not freed space.")]
    public void CompleteRequiresARecordedSuccessForEveryReviewedItem(CleanupAction action, CleanupItemState state, string description)
    {
        var plan = Prepared(action);
        var result = CleanupCompletionSummary.Create(plan, Receipt(plan, CleanupExecutionState.Completed, state, state));
        Assert.True(result.Complete);
        Assert.Equal("Cleanup complete", result.TitleKey);
        Assert.Equal(description, result.DescriptionKey);
        Assert.Equal(8192, result.RemovedBytesEstimate);
        Assert.Equal(2, result.Removed);
    }

    [Fact]
    public void PartialRemovalDoesNotReportTheWholeSelectionAsRemoved()
    {
        var plan = Prepared();
        var result = CleanupCompletionSummary.Create(plan, Receipt(plan, CleanupExecutionState.Partial, CleanupItemState.Purged, CleanupItemState.Failed));
        Assert.False(result.Complete);
        Assert.Equal("Cleanup finished with issues", result.TitleKey);
        Assert.Equal(4096, result.RemovedBytesEstimate);
        Assert.Equal(1, result.Removed);
        Assert.Equal(1, result.Failed);
    }

    [Fact]
    public void MissingRecordNeverImpliesNothingChanged()
    {
        var result = CleanupCompletionSummary.Create(Prepared(), null, "io_error");
        Assert.False(result.HasRecord);
        Assert.False(result.Complete);
        Assert.Equal(0, result.RemovedBytesEstimate);
        Assert.Equal(2, result.Unverified);
        Assert.Contains("does not prove that no files changed", result.DescriptionKey);
    }

    [Theory]
    [InlineData(CleanupItemState.Unknown, false)]
    [InlineData(CleanupItemState.Failed, false)]
    [InlineData(CleanupItemState.Cancelled, true)]
    [InlineData(CleanupItemState.Skipped, true)]
    public void CancellationCannotHideFailuresOrUncertainItems(CleanupItemState state, bool cancelled)
    {
        var plan = Prepared();
        var result = CleanupCompletionSummary.Create(plan, Receipt(plan, CleanupExecutionState.Cancelled, CleanupItemState.Purged, state));
        Assert.False(result.Complete);
        Assert.Equal(cancelled, result.Cancelled);
        Assert.Equal(4096, result.RemovedBytesEstimate);
    }

    [Theory]
    [InlineData("plan")]
    [InlineData("digest")]
    [InlineData("action")]
    [InlineData("duplicate")]
    [InlineData("missing")]
    public void MismatchedRecordsCannotProduceASuccessPage(string mismatch)
    {
        var plan = Prepared();
        var record = Receipt(plan, CleanupExecutionState.Completed, CleanupItemState.Purged, CleanupItemState.Purged);
        record = mismatch switch
        {
            "plan" => record with { PlanId = Id("plan", 2) },
            "digest" => record with { PlanDigest = "different" },
            "action" => record with { Action = CleanupAction.Trash },
            "duplicate" => record with { Items = [record.Items[0], record.Items[0]] },
            _ => record with { Items = [record.Items[0]] }
        };
        var result = CleanupCompletionSummary.Create(plan, record);
        Assert.False(result.Complete);
        Assert.False(result.HasRecord);
        Assert.Equal(0, result.RemovedBytesEstimate);
    }

    [Fact]
    public void InProgressAndErrorStatesCannotBePresentedAsComplete()
    {
        var plan = Prepared();
        var record = Receipt(plan, CleanupExecutionState.Executing, CleanupItemState.Purged, CleanupItemState.Purging);
        var unfinished = CleanupCompletionSummary.Create(plan, record);
        Assert.Equal("Unfinished cleanup", unfinished.TitleKey);
        Assert.Equal(1, unfinished.Unverified);
        var error = CleanupCompletionSummary.Create(plan, Receipt(plan, CleanupExecutionState.Completed, CleanupItemState.Purged, CleanupItemState.Purged), "store_corrupt");
        Assert.False(error.Complete);
        var empty = plan with { Items = [] };
        Assert.False(CleanupCompletionSummary.Create(empty, Receipt(empty, CleanupExecutionState.Completed)).Complete);
    }
}
