using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class PrivacyPage : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);
    private readonly TextCatalog text = new();
    private readonly NativePrivacyScanOperations operations = new();
    private readonly PrivacyScanViewModel model;
    private string? lastPlanId;
    private SourceRow[] rows = [];
    private CancellationTokenSource? mutation;
    private CancellationTokenSource? historyRead;
    private bool historyExpanded;
    public bool HasActiveCleanup => mutation is not null;
    public event EventHandler? BusyChanged;
    private bool initialized, disposed;
    public PrivacyPage()
    {
        model = new(operations);
        InitializeComponent();
        PageTitle.Text = text.Get("Review privacy sources");
        var icon = ProductIcon.Create("privacy", (double)Application.Current.Resources["ShouStartIconSize"]);
        ProductIcon.Select(icon, (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorTertiaryBrush"]);
        StartIcon.Content = icon;
        PageNotice.Text = text.Get("Close the browser first. Cleaning permanently deletes selected database records. It does not move them to Trash or provide restore. No sources are selected automatically.");
        RangeLabel.Text = text.Get("Time range"); RangeNotice.Text = text.Get("History: visit time · Cookies: last access time");
        StartButton.Content = text.Get("Start Scan");
        StartDescription.Text = text.Get("Scan to see aggregate counts and availability. Browsing records are never displayed.");
        WorkspaceVisuals.ArrangeLanding(StartContent, StartIcon, PageTitle, StartDescription, "privacy");
        StartButton.Visibility = Visibility.Visible;
        AutomationProperties.SetName(InfoButton, text.Get("Information"));
        Description.Text = text.Get("Close browsers, choose a time range, and scan supported history and cookies.");
        CookieReviewLabel.Text = text.Get("I understand that clearing cookies can sign me out of websites.");
        AutomationProperties.SetName(CookieReview, CookieReviewLabel.Text);
        ClearSelectionButton.Content = text.Get("Clear Selection");
        RemoveButton.Content = text.Get("Review Permanent Deletion…");
        ReadReceiptButton.Content = ReceiptTitle.Text = text.Get("Read Recorded Result");
        ReadReceiptButton.IsEnabled = false;
        CoverageFootnote.Text = text.Get("Supported: standard Chrome, Chromium, Edge, Brave and Firefox profiles. Site storage, saved passwords, autofill, custom profiles, extensions and cloud copies are not cleaned.");
        HistoryHeading.Text = text.Get("Recent privacy receipts"); HistoryDisclosure.Text = "▶";
        AutomationProperties.SetName(HistoryToggle, HistoryHeading.Text);
        AutomationProperties.SetItemStatus(HistoryToggle, "collapsed");
        Sources.SelectionMode = ListViewSelectionMode.None;
        ScanButton.Content = text.Get("Scan Privacy Sources"); StopButton.Content = text.Get("Stop");
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
    public void CancelScan() { model.Cancel(); historyRead?.Cancel(); }
    public void CancelCleanup() { mutation?.Cancel(); historyRead?.Cancel(); }
    private void Changed(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PrivacyScanViewModel.Scan)) Render();
        else if (args.PropertyName == nameof(PrivacyScanViewModel.AllowCookieReview)) UpdateSelection();
    }
    private void Render()
    {
        if (disposed) return;
        PageDiagnostics.Update(this, "privacy", model.State, model.ErrorCode, model.Scan?.Sources.Length);
        RangeBox.IsEnabled = !model.IsBusy && !HasActiveCleanup;
        ScanButton.IsEnabled = RangeBox.IsEnabled && historyRead is null;
        StopButton.IsEnabled = model.IsBusy && !model.StopRequested;
        PageToolbar.Visibility = ReviewContent.Visibility = model.IsBusy ? Visibility.Collapsed : Visibility.Visible;
        ScanActivity.Update(model.IsBusy, text.Get("Scanning…"), "privacy", stopRequested: model.StopRequested);
        LandingScroll.Visibility = StartContent.Visibility = !model.IsBusy && model.Scan is null ? Visibility.Visible : Visibility.Collapsed;
        SourcesCard.Visibility = SelectionFooter.Visibility = !model.IsBusy && model.Scan is not null ? Visibility.Visible : Visibility.Collapsed;
        StartButton.IsEnabled = ScanButton.IsEnabled; StopButton.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        Sources.IsEnabled = !HasActiveCleanup;
        FailureNotice.IsOpen = model.State == PrivacyScanPageState.Failed;
        FailureNotice.Message = text.Get("Privacy sources could not be scanned. Check browser access and try again.");
        CoverageNotice.IsOpen = model.State == PrivacyScanPageState.Partial;
        Status.Text = model.State == PrivacyScanPageState.Cancelled ? text.Get("Cancelled") : "";
        Status.Visibility = Status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        Boundaries.Text = model.Scan is { } result ? text.Format("Fixed range: %@ to %@", result.Window.Start?.ToLocalTime().ToString("g") ?? text.Get("All time"), result.Window.End.ToLocalTime().ToString("g")) : "";
        Boundaries.Visibility = model.Scan is null ? Visibility.Collapsed : Visibility.Visible;
        rows = model.Scan?.Sources.Select(source => new SourceRow(source, text)).ToArray() ?? [];
        Sources.ItemsSource = rows;
        UpdateSelection();
    }
    private void RangeChanged(object sender, SelectionChangedEventArgs args) { if (initialized && !disposed && RangeBox.SelectedItem is RangeOption option) model.SetRange(option.Range); }
    private async void ScanSources(object sender, RoutedEventArgs args) { if (!disposed && !model.IsBusy && !HasActiveCleanup && historyRead is null) await model.ScanAsync(); }
    private void StopScan(object sender, RoutedEventArgs args) => model.Cancel();
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; historyRead?.Cancel(); model.PropertyChanged -= Changed; model.Dispose(); GC.SuppressFinalize(this);
    }
    private sealed record RangeOption(PrivacyTimeRange Range, string Label);
    private sealed class SourceRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;
        public PrivacySourceObservation Source { get; }
        public string Title { get; }
        public string Kind { get; }
        public string Count { get; }
        public string Status { get; }
        public string AccessibleName => Title + " · " + Kind;
        public string AutomationId => "privacy.source." + Source.Source.Id;
        public FrameworkElement Icon { get; }
        public bool Selected { get; private set; }
        public bool Selectable { get; private set; }
        public SourceRow(PrivacySourceObservation source, TextCatalog text)
        {
            Source = source; Title = source.Source.Browser + " · " + source.Source.Profile;
            Kind = text.Get(source.Source.Kind == PrivacyDataKind.History ? "Browsing history" : "Cookies · may sign you out");
            Count = source.RecordCount?.ToString(System.Globalization.CultureInfo.CurrentCulture) ?? "—";
            Status = text.Get(source.State switch
            {
                PrivacySourceState.Ready => "Ready to review", PrivacySourceState.Empty => "No matching records",
                PrivacySourceState.BrowserRunning => "Close browser first", PrivacySourceState.ActivityUnknown => "Browser activity could not be verified.",
                PrivacySourceState.PermissionRequired => "Browser database access was denied.", PrivacySourceState.SchemaUnsupported => "Unsupported database",
                PrivacySourceState.Excluded => "Protected by exclusions", _ => "Browser database unavailable."
            });
            Icon = ProductIcon.Create(source.Source.Kind == PrivacyDataKind.Cookies ? "cookie" : "history", (double)Application.Current.Resources["ShouPrivacyIconSize"]);
            ProductIcon.Select(Icon, (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]);
        }
        public void Refresh(PrivacyScanViewModel model)
        {
            Selected = model.IsSelected(Source.Source.Id); Selectable = model.CanSelect(Source.Source.Id);
            PropertyChanged?.Invoke(this, new(nameof(Selected))); PropertyChanged?.Invoke(this, new(nameof(Selectable)));
        }
    }
    private void ToggleSource(object sender, RoutedEventArgs args)
    {
        if (sender is not CheckBox { Tag: SourceRow row } check || HasActiveCleanup) return;
        model.SetSelected(row.Source.Source.Id, check.IsChecked == true);
        UpdateSelection();
    }
    private void ChangeCookieReview(object sender, RoutedEventArgs args)
    { if (!HasActiveCleanup) model.SetCookieReview(CookieReview.IsChecked == true); }
    private void ClearSelection(object sender, RoutedEventArgs args)
    { if (!HasActiveCleanup) model.ClearSelection(); }
    private void UpdateSelection()
    {
        if (disposed) return;
        foreach (var row in rows) row.Refresh(model);
        CookieReview.IsEnabled = !model.IsBusy && !HasActiveCleanup;
        CookieReview.IsChecked = model.AllowCookieReview;
        ClearSelectionButton.IsEnabled = !model.IsBusy && !HasActiveCleanup && model.SelectedSourceCount > 0;
        SelectionSummary.Text = text.Get("Selected") + " " + model.SelectedSourceCount + " · " + model.SelectedRecordCount + " " + text.Get("records");
        AutomationProperties.SetItemStatus(SelectionSummary, model.SelectedSourceCount.ToString(System.Globalization.CultureInfo.InvariantCulture));
        RemoveButton.IsEnabled = WindowsCleanupMutation.PublicExecutionAvailable && !model.IsBusy && !HasActiveCleanup && model.SelectedSourceCount > 0 &&
            model.SelectedSources.All(source => model.CanSelect(source.Source.Id));
        ReadReceiptButton.IsEnabled = lastPlanId is not null && !HasActiveCleanup;
    }
    private async void RemoveSources(object sender, RoutedEventArgs args)
    {
        if (!RemoveButton.IsEnabled || model.Scan is not { } scan) return;
        var selected = model.SelectedSources;
        using var cancellation = new CancellationTokenSource(); mutation = cancellation;
        UpdateSelection(); ScanButton.IsEnabled = RangeBox.IsEnabled = Sources.IsEnabled = false;
        BusyChanged?.Invoke(this, EventArgs.Empty);
        using var diagnostic = OperationDiagnostics.Start("ui.privacy.remove");
        try
        {
            var cookies = selected.Any(source => source.Source.Kind == PrivacyDataKind.Cookies);
            var plan = await operations.CreatePlanAsync(scan.Id, selected.Select(source => source.Source.Id).ToArray(), cookies && model.AllowCookieReview, cancellation.Token);
            var content = new StackPanel { Spacing = 12 };
            content.Children.Add(new TextBlock { Text = string.Join(Environment.NewLine, plan.Sources.Select(source => source.Source.Browser + " · " + source.Source.Profile + " · " +
                text.Get(source.Source.Kind == PrivacyDataKind.History ? "Browsing history" : "Cookies · may sign you out") + " · " + source.RecordCount)), TextWrapping = TextWrapping.Wrap });
            content.Children.Add(new TextBlock { Text = text.Format("Fixed range: %@ to %@", plan.Window.Start?.ToLocalTime().ToString("g") ?? text.Get("All time"), plan.Window.End.ToLocalTime().ToString("g")), TextWrapping = TextWrapping.Wrap });
            content.Children.Add(new TextBlock { Text = text.Get("This cannot be undone through Shou. Each source commits separately; a failure may leave a partial result. Cloud-synced copies and other browser data remain outside this scope."), TextWrapping = TextWrapping.Wrap });
            var permanent = new CheckBox { Content = new TextBlock { Text = text.Get("I understand that deletion is permanent and has no restore."), TextWrapping = TextWrapping.Wrap } };
            content.Children.Add(permanent);
            var signOut = new CheckBox { Content = new TextBlock { Text = text.Get("I understand deleting cookies may sign me out."), TextWrapping = TextWrapping.Wrap }, Visibility = cookies ? Visibility.Visible : Visibility.Collapsed };
            content.Children.Add(signOut);
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = text.Get("Permanently delete privacy records?"), Content = new ScrollViewer { Content = content }, PrimaryButtonText = text.Get("Delete Permanently"), CloseButtonText = text.Get("Cancel"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false };
            void UpdateConsent(object sender, RoutedEventArgs e) => dialog.IsPrimaryButtonEnabled = permanent.IsChecked == true && (!cookies || signOut.IsChecked == true);
            permanent.Checked += UpdateConsent; permanent.Unchecked += UpdateConsent;
            signOut.Checked += UpdateConsent; signOut.Unchecked += UpdateConsent;
            AutomationProperties.SetAutomationId(permanent, "privacy.permanent");
            AutomationProperties.SetAutomationId(signOut, "privacy.signout");
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || permanent.IsChecked != true || cookies && signOut.IsChecked != true) { diagnostic.Complete("cancelled"); return; }
            lastPlanId = plan.Id;
            ReceiptTitle.Text = text.Get("In progress"); ReceiptItems.ItemsSource = null; ReceiptCard.Visibility = Visibility.Visible;
            var receipt = await operations.ExecuteAsync(plan.Id, new CurrentPrivacyClick(plan.Digest, cookies), cancellation.Token);
            diagnostic.Complete(receipt.State.ToString().ToLowerInvariant(), receipt.Items.Length);
            await model.ScanAsync();
            PresentReceipt(receipt);
            await LoadHistoryAsync();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        { diagnostic.Complete("cancelled"); Status.Text = text.Get("Cancelled"); Status.Visibility = Visibility.Visible; }
        catch (Exception error) { diagnostic.Fail(error); NativeDiagnostics.Write(error); FailureNotice.Message = ReviewText.Error(text, error is ShouException known ? known.Code : "io_error"); FailureNotice.IsOpen = true; }
        finally { mutation = null; Sources.IsEnabled = true; ScanButton.IsEnabled = RangeBox.IsEnabled = !model.IsBusy; UpdateSelection(); BusyChanged?.Invoke(this, EventArgs.Empty); }
    }
    private async void ReadReceipt(object sender, RoutedEventArgs args)
    {
        if (lastPlanId is null || HasActiveCleanup) return;
        try { PresentReceipt(await operations.ReadReceiptAsync(lastPlanId, CancellationToken.None)); }
        catch (Exception error) { NativeDiagnostics.Write(error); FailureNotice.Message = ReviewText.Error(text, error is ShouException known ? known.Code : "io_error"); FailureNotice.IsOpen = true; }
    }
    private void PresentReceipt(PrivacyReceipt receipt)
    {
        ReceiptTitle.Text = text.Get(receipt.State switch
        {
            PrivacyExecutionState.Completed => "Privacy cleaning completed", PrivacyExecutionState.Executing => "In progress", _ => "Some sources were not cleaned"
        });
        ReceiptItems.ItemsSource = ReceiptRows(receipt);
        AutomationProperties.SetItemStatus(ReceiptItems, receipt.State.ToString().ToLowerInvariant());
        ReceiptCard.Visibility = Visibility.Visible;
    }
    private ReceiptRow[] ReceiptRows(PrivacyReceipt receipt) => receipt.Items.Select(item => new ReceiptRow(item.SourceId,
            (item.RemovedRecords?.ToString(System.Globalization.CultureInfo.CurrentCulture) ?? "—") + " · " + text.Get(item.State switch
            {
                PrivacyItemState.Completed => "Completed", PrivacyItemState.Failed => "Failed", PrivacyItemState.Cancelled => "Cancelled",
                PrivacyItemState.Skipped => "Skipped", PrivacyItemState.Pending => "Not started", PrivacyItemState.Executing => "In progress", _ => "Needs Verification"
            }) + (item.Reason is null ? "" : " · " + ReviewText.Error(text, item.Reason)))).ToArray();
    public async Task LoadHistoryAsync()
    {
        if (disposed) return;
        historyRead?.Cancel(); using var current = new CancellationTokenSource(); historyRead = current;
        ScanButton.IsEnabled = StartButton.IsEnabled = false;
        using var diagnostic = OperationDiagnostics.Start("ui.privacy.history");
        try
        {
            var history = await operations.ReadHistoryAsync(current.Token);
            if (disposed || !ReferenceEquals(historyRead, current)) { diagnostic.Complete("superseded"); return; }
            current.Token.ThrowIfCancellationRequested();
            HistoryItems.ItemsSource = history.Select(receipt => new HistoryReceiptRow(receipt.StartedAt.ToLocalTime().ToString("g") + " · " +
                text.Get(receipt.State switch { PrivacyExecutionState.Completed => "Completed", PrivacyExecutionState.Partial => "Partially completed", _ => "In progress" }),
                ReceiptRows(receipt).Select(row => row.SourceId + " · " + row.Detail).ToArray())).ToArray();
            AutomationProperties.SetItemStatus(HistoryItems, history.Length.ToString(System.Globalization.CultureInfo.InvariantCulture));
            HistorySection.Visibility = history.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
            HistoryFailure.IsOpen = false;
            diagnostic.Complete("loaded", history.Length);
        }
        catch (OperationCanceledException) when (current.IsCancellationRequested) { diagnostic.Complete("cancelled"); }
        catch (Exception error)
        {
            diagnostic.Fail(error); NativeDiagnostics.Write(error);
            if (!disposed && ReferenceEquals(historyRead, current))
            {
                HistorySection.Visibility = Visibility.Collapsed;
                HistoryFailure.Message = text.Get("Privacy history could not be loaded. Try again."); HistoryFailure.IsOpen = true;
            }
        }
        finally
        {
            if (ReferenceEquals(historyRead, current))
            {
                historyRead = null;
                if (!disposed) ScanButton.IsEnabled = StartButton.IsEnabled = !model.IsBusy && !HasActiveCleanup;
            }
        }
    }
    private void ToggleHistory(object sender, RoutedEventArgs args)
    {
        historyExpanded = !historyExpanded;
        HistoryItems.Visibility = historyExpanded ? Visibility.Visible : Visibility.Collapsed;
        HistoryDisclosure.Text = historyExpanded ? "▼" : "▶";
        AutomationProperties.SetItemStatus(HistoryToggle, historyExpanded ? "expanded" : "collapsed");
    }
    private sealed record ReceiptRow(string SourceId, string Detail);
    private sealed record HistoryReceiptRow(string Title, string[] Items);
    private sealed class CurrentPrivacyClick(string digest, bool signOut) : IPrivacyConfirmation
    {
        public Task<PrivacyConfirmationDecision> RequestAsync(PrivacyPlan plan, CancellationToken token)
        { token.ThrowIfCancellationRequested(); return Task.FromResult(new PrivacyConfirmationDecision(plan.Digest == digest, signOut)); }
    }
}
