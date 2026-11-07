using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class RecordMaintenanceDialog : ContentDialog
{
    private readonly TextCatalog text = new();
    private readonly CheckBox keep = new() { IsChecked = true };
    private readonly StackPanel details = new() { Spacing = 10 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly RecordRetentionService service = new(WindowsRecordStore.ForCurrentUser(), RuleResources.CreateValidator());
    private RecordRetentionPreview? preview;
    private bool busy;

    internal RecordMaintenanceDialog(XamlRoot root)
    {
        XamlRoot = root; Title = text.Get("Shou storage"); CloseButtonText = text.Get("Done");
        FontSize = (double)Application.Current.Resources["ShouBodyFontSize"];
        PrimaryButtonText = text.Get("Delete reviewed records"); IsPrimaryButtonEnabled = false;
        PrimaryButtonStyle = (Style)Application.Current.Resources["ShouDestructiveButton"];
        SecondaryButtonText = text.Get("Check Again"); DefaultButton = ContentDialogButton.Close;
        var panel = new StackPanel { Spacing = 12, MinWidth = 420, MaxWidth = 600 };
        panel.Children.Add(new TextBlock { Text = text.Get("Scan indexes, plans and recovery dependencies are reviewed separately from your files."), TextWrapping = TextWrapping.Wrap });
        keep.Content = text.Get("Keep the latest scan for later inspection");
        keep.Click += async (_, _) => await LoadAsync(); panel.Children.Add(keep);
        panel.Children.Add(new ScrollViewer { MaxHeight = 300, Content = details }); panel.Children.Add(status); Content = panel;
        AutomationProperties.SetAutomationId(this, "records.review");
        Closing += (_, args) => { if (busy) args.Cancel = true; };
        Opened += async (_, _) => await LoadAsync();
        SecondaryButtonClick += async (_, args) => { args.Cancel = true; await LoadAsync(); };
        PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (busy || preview is null) return;
            var reviewed = preview; var policy = Policy;
            SetBusy(true);
            try
            {
                var result = await service.CollectAsync(policy, reviewed.Records);
                status.Text = text.Get("Records removed") + " " + Bytes(result.RemovableBytes);
                preview = null;
            }
            catch (Exception error) { NativeDiagnostics.Write(error); status.Text = error is ShouException ? error.Message : text.Get("Some records need verification and were kept."); preview = null; }
            finally { SetBusy(false); }
            await LoadAsync(preserveStatus: true);
        };
    }

    private RecordRetentionPolicy Policy => new(KeepLatestScans: keep.IsChecked == true);
    private async Task LoadAsync(bool preserveStatus = false)
    {
        if (busy) return;
        SetBusy(true); preview = null; details.Children.Clear(); if (!preserveStatus) status.Text = "";
        var policy = Policy;
        try
        {
            preview = await service.PreviewAsync(policy);
            Add(text.Get("Total") + " " + Bytes(preview.TotalBytes) + "\n" + text.Get("Reviewable records") + " " + Bytes(preview.RemovableBytes));
            foreach (var collection in preview.Collections)
                Add(text.Get(collection.Collection) + ": " + Bytes(collection.TotalBytes) + " / " + text.Get("Reviewable records") + " " + Bytes(collection.RemovableBytes));
            if (preview.QuotaExcessBytes > 0) Add(text.Get("Protected records exceed the cleanup quota.") + " " + Bytes(preview.QuotaExcessBytes));
            Add(text.Get("Why records are kept"));
            foreach (var reason in preview.RetentionReasons) Add(Reason(reason.Reason) + ": " + Bytes(reason.ByteCount));
            Add(text.Get("Retention reasons can overlap. Recovery and active plans remain protected."));
            var scope = new Expander { Header = text.Get("Reviewable records"), HorizontalAlignment = HorizontalAlignment.Stretch,
                Content = new TextBlock { Text = string.Join('\n', preview.Records.Select(record => record.Key)), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } };
            details.Children.Add(scope);
            if (!preview.Issues.IsEmpty) Add(text.Get("Some records need verification and were kept."));
        }
        catch (Exception error) { NativeDiagnostics.Write(error); status.Text = text.Get("Some records need verification and were kept."); }
        finally { SetBusy(false); }
    }
    private void SetBusy(bool value)
    {
        busy = value; keep.IsEnabled = !value; IsSecondaryButtonEnabled = !value;
        IsPrimaryButtonEnabled = !value && preview is { Records.IsEmpty: false };
    }
    private void Add(string value) => details.Children.Add(new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap });
    private string Reason(string value) => text.Get(value switch
    {
        "grace_period" => "Recently created", "latest_scan" => "Latest scan", "history_dependency" => "History dependency",
        "within_policy" => "Within retention policy", _ => "Needs verification"
    });
    private static string Bytes(long bytes) => StorageRow.FormatBytes(bytes);
}
