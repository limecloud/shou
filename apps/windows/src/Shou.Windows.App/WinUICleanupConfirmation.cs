using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class WinUICleanupConfirmation(FrameworkElement owner, TextCatalog text, CleanupPlan expected) : ICleanupConfirmation
{
    public async Task<bool> RequestAsync(CleanupReview review, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (review.PlanId != expected.Id || review.Digest != expected.Digest || review.Action != CleanupAction.Permanent ||
            expected.Action != review.Action || review.ExpiresAt != expected.ExpiresAt || review.Items.Length != expected.Items.Length ||
            !review.Items.Select(item => item.ItemId).SequenceEqual(expected.Items.Select(item => item.Id)))
            throw new ShouException("confirmation_required", "The cleanup review changed.");
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
                if (!owner.IsLoaded || owner.XamlRoot is null)
                    throw new ShouException("confirmation_required", "The cleanup review is no longer visible.");
                var content = new StackPanel { Spacing = 12 };
                content.Children.Add(new TextBlock { Text = text.Get("Permanent deletion cannot be undone."), TextWrapping = TextWrapping.Wrap });
                content.Children.Add(new TextBlock { Text = text.Format("%lld items selected", expected.Items.Length) });
                foreach (var item in expected.Items)
                    content.Children.Add(new TextBlock
                    {
                        Text = item.Path.Value + "\n" + StorageRow.FormatBytes(item.AllocatedBytes) + " · " + text.Get(item.Risk == "high" ? "High Risk" : "Review"),
                        TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true
                    });
                dialog = new ContentDialog
                {
                    XamlRoot = owner.XamlRoot, Title = text.Get("Review Cleanup"),
                    PrimaryButtonText = text.Get("Clean Permanently"), CloseButtonText = text.Get("Cancel"),
                    DefaultButton = ContentDialogButton.Close,
                    Content = new ScrollViewer { Content = content, MaxHeight = 440, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
                };
                cancellationToken.ThrowIfCancellationRequested();
                var result = await dialog.ShowAsync();
                completion.TrySetResult(!cancellationToken.IsCancellationRequested && owner.IsLoaded && result == ContentDialogResult.Primary);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { completion.TrySetCanceled(cancellationToken); }
            catch (Exception error)
            {
                NativeDiagnostics.Write(error);
                completion.TrySetException(new ShouException("confirmation_required", "The cleanup confirmation could not be completed.", error));
            }
            finally { dialog = null; }
        })) completion.TrySetException(new ShouException("confirmation_required", "The cleanup review dispatcher is unavailable."));
        return await completion.Task.ConfigureAwait(false);
    }
}
