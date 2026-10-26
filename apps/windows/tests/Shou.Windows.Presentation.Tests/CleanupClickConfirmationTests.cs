using System.Collections.Immutable;
using Shou.Windows.Core;
using Shou.Windows.Presentation;
using static Shou.Windows.Presentation.Tests.CleanupReviewTests;

namespace Shou.Windows.Presentation.Tests;

public sealed class CleanupClickConfirmationTests
{
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = DateTimeOffset.UnixEpoch.AddMinutes(1);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    private static CleanupPlan Prepared() => Plan(Scan([Candidate(1), Candidate(2)]), [Candidate(1).Id, Candidate(2).Id], CleanupAction.Permanent);
    private static CleanupReview Review(CleanupPlan plan) => new(plan.Id, plan.Digest, plan.Action, plan.ExpiresAt,
        plan.Items.Select(item => new CleanupReviewItem(item.Id, item.Path, item.RuleId, item.Risk, item.AllocatedBytes, item.Manifest.Length)).ToImmutableArray());

    [Fact]
    public async Task OneClickConfirmsOnlyOnceWithoutAnotherInteraction()
    {
        var plan = Prepared(); var checks = 0;
        var confirmation = new CleanupClickConfirmation(plan, _ => { checks++; return Task.FromResult(true); }, new Clock());
        Assert.True(await confirmation.RequestAsync(Review(plan), default));
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(Review(plan), default))).Code);
        Assert.Equal(1, checks);
    }

    [Theory]
    [InlineData("plan")][InlineData("digest")][InlineData("action")][InlineData("expiry")]
    [InlineData("count")][InlineData("order")][InlineData("item")][InlineData("path")]
    [InlineData("rule")][InlineData("risk")][InlineData("bytes")][InlineData("manifest")]
    public async Task ChangedScopeCannotInheritTheClick(string field)
    {
        var plan = Prepared(); var review = Review(plan); var item = review.Items[0];
        review = field switch
        {
            "plan" => review with { PlanId = Id("other") },
            "digest" => review with { Digest = "changed" },
            "action" => review with { Action = CleanupAction.Trash },
            "expiry" => review with { ExpiresAt = review.ExpiresAt.AddSeconds(1) },
            "count" => review with { Items = [item] },
            "order" => review with { Items = review.Items.Reverse().ToImmutableArray() },
            _ => review with { Items = review.Items.SetItem(0, field switch
            {
                "item" => item with { ItemId = Id("other") },
                "path" => item with { Path = WindowsPath.Parse("C:\\Users\\fixture\\other") },
                "rule" => item with { RuleId = "other" },
                "risk" => item with { Risk = "low" },
                "bytes" => item with { AllocatedBytes = item.AllocatedBytes + 1 },
                _ => item with { ManifestEntries = item.ManifestEntries + 1 }
            }) }
        };
        var confirmation = new CleanupClickConfirmation(plan, _ => throw new InvalidOperationException("Changed scope must be rejected before UI dispatch."), new Clock());
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(review, default))).Code);
    }

    [Fact]
    public async Task HiddenReviewOrExpiryDuringDispatchCannotConfirm()
    {
        var plan = Prepared(); var clock = new Clock();
        Assert.False(await new CleanupClickConfirmation(plan, _ => Task.FromResult(false), clock).RequestAsync(Review(plan), default));
        var confirmation = new CleanupClickConfirmation(plan, _ => { clock.Now = plan.ExpiresAt; return Task.FromResult(true); }, clock);
        Assert.False(await confirmation.RequestAsync(Review(plan), default));
    }

    [Fact]
    public async Task CancellationDuringDispatchCannotConfirmOrReplay()
    {
        var plan = Prepared(); using var cancellation = new CancellationTokenSource();
        var confirmation = new CleanupClickConfirmation(plan, _ => { cancellation.Cancel(); return Task.FromResult(true); }, new Clock());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => confirmation.RequestAsync(Review(plan), cancellation.Token));
        await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(Review(plan), default));
    }
}
