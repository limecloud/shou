using Microsoft.UI.Xaml;
using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal static class WinUIApplicationUninstallConfirmation
{
    public static IApplicationUninstallConfirmation Create(FrameworkElement owner, ApplicationUninstallPlan expected) =>
        new ApplicationUninstallClickConfirmation(expected, cancellationToken => WinUICleanupConfirmation.IsReviewVisibleAsync(owner, cancellationToken));
}
