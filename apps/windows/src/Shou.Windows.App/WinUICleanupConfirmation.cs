using Microsoft.UI.Xaml;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal static class WinUICleanupConfirmation
{
    // Created only by an explicit delete click, after freezing the selected scope.
    public static ICleanupConfirmation Create(FrameworkElement owner, CleanupPlan expected) =>
        new CleanupClickConfirmation(expected, cancellationToken => IsReviewVisibleAsync(owner, cancellationToken));

    internal static Task<bool> IsReviewVisibleAsync(FrameworkElement owner, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        cancellationToken.ThrowIfCancellationRequested();
        if (!owner.DispatcherQueue.TryEnqueue(() =>
        {
            if (cancellationToken.IsCancellationRequested) completion.TrySetCanceled(cancellationToken);
            else completion.TrySetResult(owner.IsLoaded && owner.XamlRoot is not null && owner.Visibility == Visibility.Visible);
        })) completion.TrySetException(new ShouException("confirmation_required", "The cleanup review dispatcher is unavailable."));
        return completion.Task.WaitAsync(cancellationToken);
    }
}
