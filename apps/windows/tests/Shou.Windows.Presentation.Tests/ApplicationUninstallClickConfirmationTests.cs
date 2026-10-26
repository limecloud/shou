using Shou.Windows.Core;
using Shou.Windows.Presentation;
using static Shou.Windows.Presentation.Tests.ApplicationUninstallViewModelTests;

namespace Shou.Windows.Presentation.Tests;

public sealed class ApplicationUninstallClickConfirmationTests
{
    [Fact]
    public async Task InlineClickConfirmsOneInstallationOnlyOnce()
    {
        var plan = Plan(Review());
        var confirmation = new ApplicationUninstallClickConfirmation(plan, _ => Task.FromResult(true), new Clock(plan.CreatedAt));
        Assert.True(await confirmation.RequestAsync(plan, default));
        await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(plan, default));
    }

    [Theory]
    [InlineData("plan")][InlineData("digest")][InlineData("owner")][InlineData("consent")]
    [InlineData("expiry")][InlineData("review")][InlineData("application")][InlineData("identity")][InlineData("activity")]
    public async Task ChangedInstallationOrImpactCannotUseTheClick(string field)
    {
        var expected = Plan(Review());
        var changed = field switch
        {
            "plan" => expected with { Id = "another_plan" },
            "digest" => expected with { Digest = "changed" },
            "owner" => expected with { OwnerSid = "another_owner" },
            "consent" => expected with { AllowInstallerDataChanges = false },
            "expiry" => expected with { ExpiresAt = expected.ExpiresAt.AddSeconds(1) },
            "review" => expected with { Review = expected.Review with { Digest = "changed" } },
            "application" => expected with { Review = expected.Review with { Application = expected.Review.Application with { Id = "another_application" } } },
            "identity" => expected with { Review = expected.Review with { Installation = expected.Review.Installation with { Identity = expected.Review.Installation.Identity! with { SystemId = "another_identity" } } } },
            _ => expected with { Review = expected.Review with { Activity = new(ActivityState.Active) } }
        };
        var confirmation = new ApplicationUninstallClickConfirmation(expected, _ => throw new InvalidOperationException("Changed installation must be rejected before dispatch."), new Clock(expected.CreatedAt));
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(changed, default))).Code);
    }

    [Fact]
    public async Task ClosedPageExpiryAndCancellationCannotConfirm()
    {
        var plan = Plan(Review()); var clock = new Clock(plan.CreatedAt);
        Assert.False(await new ApplicationUninstallClickConfirmation(plan, _ => Task.FromResult(false), clock).RequestAsync(plan, default));
        using var cancellation = new CancellationTokenSource();
        var confirmation = new ApplicationUninstallClickConfirmation(plan, _ => { cancellation.Cancel(); return Task.FromResult(true); }, new Clock(plan.CreatedAt));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => confirmation.RequestAsync(plan, cancellation.Token));
        await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(plan, default));
        var expiring = new Clock(plan.CreatedAt);
        Assert.False(await new ApplicationUninstallClickConfirmation(plan, _ => { expiring.Now = plan.ExpiresAt; return Task.FromResult(true); }, expiring).RequestAsync(plan, default));
    }
}
