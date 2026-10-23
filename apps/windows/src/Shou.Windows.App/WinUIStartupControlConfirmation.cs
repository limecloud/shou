using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class WinUIStartupControlConfirmation(FrameworkElement owner, TextCatalog text) : IStartupControlConfirmation
{
    public async Task<bool> RequestAsync(StartupControlReview review, CancellationToken cancellationToken)
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
        if (!dispatcher.TryEnqueue(async () =>
        {
            try
            {
                if (completion.Task.IsCompleted) return;
                cancellationToken.ThrowIfCancellationRequested();
                if (!owner.IsLoaded || owner.XamlRoot is null) throw new ShouException("confirmation_required", "The startup review is no longer visible.");
                var action = text.Get(review.DesiredEnabled ? "Enable Startup Task" : "Disable Startup Task");
                dialog = new ContentDialog
                {
                    XamlRoot = owner.XamlRoot, Title = action, PrimaryButtonText = action, CloseButtonText = text.Get("Cancel"),
                    DefaultButton = ContentDialogButton.Close,
                    Content = new ScrollViewer
                    {
                        MaxHeight = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                        Content = new TextBlock { Text = review.Task.TaskPath + "\n\n" +
                            text.Get("This changes only the task switch. Running instances are not stopped, and startup conditions may still prevent it from running."),
                            TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
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
                completion.TrySetException(new ShouException("confirmation_required", "The startup confirmation could not be completed.", error));
            }
            finally { dialog = null; }
        })) completion.TrySetException(new ShouException("confirmation_required", "The startup review dispatcher is unavailable."));
        return await completion.Task.ConfigureAwait(false);
    }
}
