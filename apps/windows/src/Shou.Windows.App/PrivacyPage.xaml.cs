using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class PrivacyPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly PrivacyScanViewModel model = new(new NativePrivacyScanOperations());
    private bool initialized, disposed;
    public PrivacyPage()
    {
        InitializeComponent();
        PageTitle.Text = text.Get("Privacy");
        Description.Text = text.Get("Close browsers, choose a time range, and scan supported history and cookies.");
        ReadOnlyNotice.Text = text.Get("Privacy scanning is read-only. Record deletion is not available yet.");
        ScanButton.Content = text.Get("Scan"); StopButton.Content = text.Get("Stop");
        AutomationProperties.SetName(RangeBox, text.Get("Time range"));
        AutomationProperties.SetName(Sources, text.Get("Privacy"));
        RangeBox.ItemsSource = Enum.GetValues<PrivacyTimeRange>().Select(range => new RangeOption(range, text.Get(range switch
        {
            PrivacyTimeRange.LastHour => "Last hour", PrivacyTimeRange.LastDay => "Last 24 hours",
            PrivacyTimeRange.LastSevenDays => "Last 7 days", _ => "All time"
        }))).ToArray();
        RangeBox.SelectedIndex = 0;
        CoverageNotice.Message = text.Get("Some privacy sources could not be inspected. Counts cover only available sources.");
        model.PropertyChanged += Changed; initialized = true; Render();
    }
    public void InvalidateConfiguration() => model.Invalidate();
    public void CancelScan() => model.Cancel();
    private void Changed(object? sender, PropertyChangedEventArgs args) { if (args.PropertyName == nameof(PrivacyScanViewModel.Scan)) Render(); }
    private void Render()
    {
        if (disposed) return;
        ScanButton.IsEnabled = RangeBox.IsEnabled = !model.IsBusy;
        StopButton.IsEnabled = model.IsBusy && !model.StopRequested;
        Progress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CoverageNotice.IsOpen = model.State == PrivacyScanPageState.Partial;
        Status.Text = model.ErrorCode is not null ? text.Get("Privacy sources could not be scanned. Check browser access and try again.") : model.StopRequested ? text.Get("Stopping…") : model.State switch
        {
            PrivacyScanPageState.Scanning => text.Get("Loading…"), PrivacyScanPageState.Cancelled => text.Get("Cancelled"),
            _ when model.Scan is { } scan => text.Format("%lld privacy sources inspected", scan.Sources.Length), _ => ""
        };
        Boundaries.Text = model.Scan is { } result ? text.Format("Fixed range: %@ to %@", result.Window.Start?.ToLocalTime().ToString("g") ?? text.Get("All time"), result.Window.End.ToLocalTime().ToString("g")) : "";
        Sources.ItemsSource = model.Scan?.Sources.Select(source => new SourceRow(
            source.Source.Browser + " · " + source.Source.Profile + " · " + text.Get(source.Source.Kind == PrivacyDataKind.History ? "Browsing history" : "Cookies"),
            source.State is PrivacySourceState.Ready or PrivacySourceState.Empty ? text.Format("%lld matching records", source.RecordCount ?? 0) : text.Get(source.State switch
            {
                PrivacySourceState.BrowserRunning => "Close browser first", PrivacySourceState.ActivityUnknown => "Browser activity could not be verified.",
                PrivacySourceState.PermissionRequired => "Browser database access was denied.", PrivacySourceState.SchemaUnsupported => "Unsupported database",
                PrivacySourceState.Excluded => "Protected by exclusions", _ => "Browser database unavailable."
            }))).ToArray();
    }
    private void RangeChanged(object sender, SelectionChangedEventArgs args) { if (initialized && !disposed && RangeBox.SelectedItem is RangeOption option) model.SetRange(option.Range); }
    private async void ScanSources(object sender, RoutedEventArgs args) { if (!disposed && !model.IsBusy) await model.ScanAsync(); }
    private void StopScan(object sender, RoutedEventArgs args) => model.Cancel();
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; model.PropertyChanged -= Changed; model.Dispose(); GC.SuppressFinalize(this);
    }
    private sealed record RangeOption(PrivacyTimeRange Range, string Label);
    private sealed record SourceRow(string Title, string Detail);
}
