using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class StorageComparisonDialog : ContentDialog
{
    private readonly TextCatalog text = new();
    private readonly StorageComparisonService service = new(WindowsRecordStore.ForCurrentUser());
    private readonly StackPanel content = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly string scanId;
    private string path;
    private bool closed;
    private long generation;

    internal StorageComparisonDialog(XamlRoot root, string scanId, string path)
    {
        this.scanId = scanId; this.path = path; XamlRoot = root;
        Title = text.Get("Compare Analyses"); CloseButtonText = text.Get("Close"); DefaultButton = ContentDialogButton.Close;
        Resources["ContentDialogMaxWidth"] = Application.Current.Resources["ShouComparisonSheetWidth"];
        content.Spacing = (double)Application.Current.Resources["ShouPageSpacing"];
        Content = new ScrollViewer { Content = content, MaxHeight = (double)Application.Current.Resources["ShouComparisonSheetHeight"], HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Opened += async (_, _) => await LoadHistory();
        Closed += (_, _) => { closed = true; generation++; lifetime.Cancel(); lifetime.Dispose(); };
    }

    private async Task LoadHistory()
    {
        try
        {
            content.Children.Clear(); AddText(text.Get("Reading analysis history…"));
            var history = await Task.Run(() => service.HistoryAsync(scanId, lifetime.Token), lifetime.Token);
            if (closed) return;
            content.Children.Clear(); AddText(history.Current.RootPath.Value);
            AddText(text.Get("Current Analysis") + ": " + history.Current.CreatedAt.ToLocalTime());
            AddText(text.Get("Read-only observations. Historical analyses do not authorize cleanup."));
            if (history.Status == "partial") AddText(text.Get("History is limited to readable recent analyses. Some records were skipped."));
            if (history.Candidates.IsEmpty) { AddText(text.Get("Run two space analyses of the same folder to compare them. Cleared and legacy analyses may be unavailable.")); return; }
            var picker = new ComboBox { Header = text.Get("Earlier Analysis"), ItemsSource = history.Candidates,
                DisplayMemberPath = nameof(StorageAnalysisReference.CreatedAt), HorizontalAlignment = HorizontalAlignment.Stretch };
            content.Children.Add(picker);
            var results = new StackPanel { Spacing = (double)Application.Current.Resources["ShouSectionSpacing"] };
            content.Children.Add(results);
            picker.SelectionChanged += async (_, _) =>
            {
                if (picker.SelectedItem is StorageAnalysisReference selected) await Compare(selected.Id, results);
            };
            picker.SelectedIndex = 0;
        }
        catch (OperationCanceledException) when (closed) { }
        catch (Exception) { if (!closed) { content.Children.Clear(); AddText(text.Get("Comparison unavailable")); } }
    }

    private async Task Compare(string baselineId, StackPanel results)
    {
        var request = ++generation;
        try
        {
            results.Children.Clear(); results.Children.Add(Label(text.Get("Comparing analyses…")));
            var value = await Task.Run(() => service.CompareAsync(baselineId, scanId, path, cancellationToken: lifetime.Token), lifetime.Token);
            if (closed || request != generation) return;
            results.Children.Clear();
            results.Children.Add(Label(value.Path));
            results.Children.Add(Label(text.Get("Earlier Size") + ": " + StorageRow.FormatBytes(value.BeforeBytes)));
            results.Children.Add(Label(text.Get("Current Size") + ": " + StorageRow.FormatBytes(value.AfterBytes)));
            results.Children.Add(Label(text.Get("Observed Change") + ": " + (value.DeltaBytes is { } delta ? Signed(delta) : text.Get("Not comparable"))));
            if (value.Status == "partial") results.Children.Add(Label(text.Get("Partial comparison. Ranking covers only examined entries; incomplete coverage has no numeric growth conclusion.")));
            foreach (var change in value.Changes)
            {
                var row = new StackPanel { Spacing = (double)Application.Current.Resources["ShouItemSpacing"] };
                row.Children.Add(Label(change.Path));
                row.Children.Add(Label(change.DeltaBytes is { } bytes ? Signed(bytes) : text.Get(change.State switch
                { "only_current" => "Only in current analysis", "only_baseline" => "Only in earlier analysis", "replaced" => "Object replaced", _ => "Not comparable" })));
                row.Children.Add(Label(text.Get("Earlier Size") + ": " + Observed(change.BeforeBytes, change.BeforeComplete) + " → " +
                    text.Get("Current Size") + ": " + Observed(change.AfterBytes, change.AfterComplete)));
                if (change.Kind == EntryKind.Directory && change.BeforeBytes is not null && change.AfterBytes is not null && change.State != "replaced")
                {
                    var open = new Button { Content = text.Get("Open Directory") };
                    open.Click += async (_, _) => { path = change.Path; await Compare(baselineId, results); };
                    row.Children.Add(open);
                }
                results.Children.Add(new Border { Style = (Style)Application.Current.Resources["ShouCard"], Child = row });
            }
            if (value.Changes.IsEmpty) results.Children.Add(Label(text.Get("No changed observations in this directory.")));
            results.Children.Add(Label(text.Get("Allocated sizes are estimates. Hard-link attribution, shared blocks and sparse files can affect changes; these values are not reclaimable space. An item seen in only one analysis is not proof of creation or deletion.")));
        }
        catch (OperationCanceledException) when (closed) { }
        catch (Exception) { if (!closed && request == generation) { results.Children.Clear(); results.Children.Add(Label(text.Get("Comparison unavailable"))); } }
    }

    private string Observed(long? bytes, bool? complete) => bytes is { } amount ? (complete == false ? "≥ " : "") + StorageRow.FormatBytes(amount) : text.Get("Not observed");
    private static string Signed(long bytes) => (bytes > 0 ? "+" : bytes < 0 ? "−" : "") + StorageRow.FormatBytes(Math.Abs(bytes));
    private static TextBlock Label(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private void AddText(string value) => content.Children.Add(Label(value));
}
