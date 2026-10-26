using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

/// <summary>Binds the inline uninstall click to one reviewed installation and its acknowledged installer impact.</summary>
public sealed class ApplicationUninstallClickConfirmation(ApplicationUninstallPlan expected, Func<CancellationToken, Task<bool>> isReviewVisible,
    TimeProvider? timeProvider = null) : IApplicationUninstallConfirmation
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private int consumed;

    public async Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken)
    {
        if (Interlocked.Exchange(ref consumed, 1) != 0)
            throw new ShouException("confirmation_required", "This uninstall click has already been consumed.");
        cancellationToken.ThrowIfCancellationRequested();
        if (!expected.AllowInstallerDataChanges || !expected.Review.CanPreparePlan || !plan.Review.CanPreparePlan || !plan.AllowInstallerDataChanges ||
            plan.Id != expected.Id || plan.Digest != expected.Digest || plan.OwnerSid != expected.OwnerSid ||
            plan.CreatedAt != expected.CreatedAt || plan.ExpiresAt != expected.ExpiresAt ||
            plan.Review.Digest != expected.Review.Digest || plan.Review.Application.Id != expected.Review.Application.Id ||
            plan.Review.Installation.Identity != expected.Review.Installation.Identity || plan.Review.Activity != expected.Review.Activity || !IsCurrent())
            throw new ShouException("confirmation_required", "The uninstall review changed.");
        var visible = await isReviewVisible(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return visible && IsCurrent();
    }

    private bool IsCurrent() => expected.CreatedAt <= clock.GetUtcNow() && clock.GetUtcNow() < expected.ExpiresAt;
}
