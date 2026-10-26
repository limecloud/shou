using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

/// <summary>Consumes one explicit delete click for the exact selected plan; Core still issues and rechecks consent.</summary>
public sealed class CleanupClickConfirmation(CleanupPlan expected, Func<CancellationToken, Task<bool>> isReviewVisible,
    TimeProvider? timeProvider = null) : ICleanupConfirmation
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private int consumed;

    public async Task<bool> RequestAsync(CleanupReview review, CancellationToken cancellationToken)
    {
        if (Interlocked.Exchange(ref consumed, 1) != 0)
            throw new ShouException("confirmation_required", "This delete click has already been consumed.");
        cancellationToken.ThrowIfCancellationRequested();
        if (expected.Action != CleanupAction.Permanent || expected.Items.IsDefaultOrEmpty || review.Items.IsDefault ||
            review.PlanId != expected.Id || review.Digest != expected.Digest || review.Action != expected.Action ||
            review.ExpiresAt != expected.ExpiresAt || !IsCurrent() ||
            !review.Items.SequenceEqual(expected.Items.Select(item =>
                new CleanupReviewItem(item.Id, item.Path, item.RuleId, item.Risk, item.AllocatedBytes, item.Manifest.Length))))
            throw new ShouException("confirmation_required", "The cleanup review changed.");
        var visible = await isReviewVisible(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return visible && IsCurrent();
    }

    private bool IsCurrent() => expected.CreatedAt <= clock.GetUtcNow() && clock.GetUtcNow() < expected.ExpiresAt;
}
