using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

/// <summary>Shortcut files have a separate scope from installers and retain the public cleanup gate.</summary>
internal static class ApplicationShortcutsPanel
{
    public static async Task ShowAsync(FrameworkElement owner)
    {
        var text = new TextCatalog();
        var service = new ApplicationShortcutService(new WindowsApplicationShortcuts(), new WindowsFileSystem());
        using var stopped = new CancellationTokenSource();
        var status = new TextBlock { Text = text.Get("Loading…"), TextWrapping = TextWrapping.Wrap };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 340 };
        var content = new StackPanel { Spacing = 12, MinWidth = 420 };
        content.Children.Add(new TextBlock { Text = text.Get("Only this broken shortcut is removed. Its target and associated data are kept."), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(new TextBlock { Text = text.Get("Checks current-user Desktop and Start Menu shortcuts with plain local targets. Other shortcut types are kept."), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(list); content.Children.Add(status);
        var dialog = new ContentDialog { XamlRoot = owner.XamlRoot, Title = text.Get("Broken Shortcuts"), Content = content,
            CloseButtonText = text.Get("Close"), PrimaryButtonText = text.Get("Delete Permanently"), IsPrimaryButtonEnabled = false, DefaultButton = ContentDialogButton.Close };
        var executing = false;
        var operations = new NativeReviewOperations();
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !executing && operations.ExecutionAvailable && list.SelectedItems.Count > 0;
        dialog.Closing += (_, args) => { if (executing) { stopped.Cancel(); args.Cancel = true; } };
        dialog.Opened += async (_, _) =>
        {
            try
            {
                var catalog = await service.ReadAsync(stopped.Token);
                if (stopped.IsCancellationRequested) return;
                foreach (var item in catalog.Items)
                {
                    var details = new StackPanel { Spacing = 4 };
                    details.Children.Add(new TextBlock { Text = item.File.Path.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                    details.Children.Add(new TextBlock { Text = item.File.Path.Value, TextWrapping = TextWrapping.Wrap });
                    details.Children.Add(new TextBlock { Text = text.Get("Target") + ": " + item.Target.Value, TextWrapping = TextWrapping.Wrap });
                    list.Items.Add(new ListViewItem { Content = details, Tag = item });
                }
                status.Text = text.Get(catalog.Items.IsEmpty ? "No verified broken shortcuts." : operations.ExecutionAvailable
                    ? "Permanent deletion cannot be undone." : "Cleanup execution is unavailable until native Windows verification is complete.");
                if (!catalog.Issues.IsEmpty) status.Text += Environment.NewLine + text.Get("Some shortcuts could not be verified and are kept.");
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { NativeDiagnostics.Write(error); status.Text = text.Get("Some shortcuts could not be verified and are kept."); }
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (executing || !operations.ExecutionAvailable || list.SelectedItems.Count == 0) return;
            var deferral = args.GetDeferral();
            var frozen = list.SelectedItems.Cast<ListViewItem>().Select(row => (Row: row, Review: (ApplicationShortcutReview)row.Tag)).ToArray();
            executing = true; list.IsEnabled = false; dialog.IsPrimaryButtonEnabled = false;
            try
            {
                var plans = new List<(ListViewItem Row, ApplicationShortcutReview Review, CleanupPlan Plan)>();
                foreach (var item in frozen)
                {
                    var snapshot = await service.SnapshotAsync(item.Review, stopped.Token);
                    var prepared = await operations.ReviewStorageRemovalAsync(snapshot, [item.Review.File.Path], stopped.Token);
                    if (prepared.Plan is not { Items.Length: 1 } plan || plan.Items[0].Manifest.Length != 1 || plan.Items[0].Manifest[0] != item.Review.File)
                        throw new ShouException("plan_stale", "The shortcut changed. Check this application again.");
                    plans.Add((item.Row, item.Review, plan));
                }
                foreach (var item in plans)
                {
                    await service.SnapshotAsync(item.Review, stopped.Token);
                    var result = await operations.ExecuteAsync(item.Plan.Id, WinUICleanupConfirmation.Create(content, item.Plan), stopped.Token);
                    if (result.State != CleanupExecutionState.Completed) { status.Text = text.Get("Some items were not moved. Inspect history."); return; }
                    list.Items.Remove(item.Row);
                }
                status.Text = text.Get("Permanent deletion completed. Review History for details.");
            }
            catch (OperationCanceledException) { status.Text = text.Get("Cancelled"); }
            catch (Exception error) { NativeDiagnostics.Write(error); status.Text = text.Get("The shortcut changed. Check this application again."); }
            finally { executing = false; list.IsEnabled = true; deferral.Complete(); }
        };
        try { await dialog.ShowAsync(); }
        finally { stopped.Cancel(); }
    }
}
