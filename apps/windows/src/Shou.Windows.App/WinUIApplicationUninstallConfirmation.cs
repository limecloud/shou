using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class WinUIApplicationUninstallConfirmation(FrameworkElement owner, TextCatalog text) : IApplicationUninstallConfirmation
{
    public async Task<bool> RequestAsync(ApplicationUninstallPlan plan, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var dispatcher = owner.DispatcherQueue;
        ContentDialog? dialog = null;
        using var registration = cancellationToken.Register(() =>
        {
            completion.TrySetCanceled(cancellationToken);
            dispatcher.TryEnqueue(() => dialog?.Hide());
        });
        // Core may request confirmation from a pool thread after native preflight.
        if (!dispatcher.TryEnqueue(async () =>
        {
            try
            {
                if (completion.Task.IsCompleted) return;
                cancellationToken.ThrowIfCancellationRequested();
                if (!owner.IsLoaded || owner.XamlRoot is null)
                    throw new ShouException("confirmation_required", "The uninstall review is no longer visible.");
                var review = plan.Review;
                var identity = review.Installation.Identity!;
                var lines = new List<string> { review.Application.Name };
                if (!string.IsNullOrEmpty(review.Installation.Version)) lines.Add(text.Get("Version") + ": " + review.Installation.Version);
                if (!string.IsNullOrEmpty(review.Installation.Publisher)) lines.Add(text.Get("Publisher") + ": " + review.Installation.Publisher);
                if (review.Installation.InstalledRoot is { } root) lines.Add(root.Path.Value);
                lines.Add((identity.Kind == ApplicationInstallerKind.Msi ? "MSI: " : "MSIX: ") + identity.SystemId);
                lines.Add(text.Get("The system installer may stop managed apps or services and remove data. Shou cannot restore this operation."));
                lines.Add(text.Get("Additional residual files are not included. Uninstall only this reviewed installation?"));
                dialog = new ContentDialog
                {
                    XamlRoot = owner.XamlRoot,
                    Title = text.Get("Confirm Uninstall"),
                    PrimaryButtonText = text.Get("Uninstall"),
                    CloseButtonText = text.Get("Cancel"),
                    DefaultButton = ContentDialogButton.Close,
                    Content = new ScrollViewer
                    {
                        MaxHeight = 420,
                        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                        Content = new TextBlock { Text = string.Join(Environment.NewLine + Environment.NewLine, lines), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
                    }
                };
                cancellationToken.ThrowIfCancellationRequested();
                var result = await dialog.ShowAsync();
                completion.TrySetResult(!cancellationToken.IsCancellationRequested && owner.IsLoaded && result == ContentDialogResult.Primary);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { completion.TrySetCanceled(cancellationToken); }
            catch (Exception error)
            {
                NativeDiagnostics.Write(error);
                completion.TrySetException(new ShouException("confirmation_required", "The uninstall confirmation could not be completed.", error));
            }
            finally { dialog = null; }
        })) completion.TrySetException(new ShouException("confirmation_required", "The uninstall review dispatcher is unavailable."));
        return await completion.Task.ConfigureAwait(false);
    }
}
