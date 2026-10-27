using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class HistoryPage : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);
    private bool inspectorClosed;
    private readonly TextCatalog text = new();
    private readonly CleanupHistoryViewModel model;
    private bool disposed;
    private Task? initialLoad;
    private readonly InlineDetails inlineDetails;
    private Expander? requestedDetail;

    public HistoryPage(ICleanupHistoryOperations operations)
    {
        InitializeComponent();
        inlineDetails = new(Inspector, PageLayout);
        model = new(operations);
        PageTitle.Text = text.Get("History");
        EmptyTitle.Text = text.Get("No cleanup history yet.");
        EmptyDescription.Text = text.Get("Completed operations and their recorded results will appear here.");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(InfoButton, text.Get("Information"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(CloseInspectorButton, text.Get("Close Details"));
        Description.Text = text.Get("History observations do not change completed operations or retry unfinished work.");
        RefreshButton.Content = text.Get("Refresh");
        NextButton.Content = text.Get("Next");
        InspectButton.Content = text.Get("Check Recorded Locations");
        CancelButton.Content = text.Get("Stop");
        CoverageNotice.Message = text.Get("Some history records or locations could not be verified.");
        model.PropertyChanged += Changed;
        Render();
    }

    public Task EnsureLoadedAsync() => initialLoad ??= model.RefreshAsync();
    public void InvalidateHistory() => initialLoad = null;
    private void Changed(object? sender, PropertyChangedEventArgs args) => Render();

    private void Render()
    {
        if (disposed) return;
        PageDiagnostics.Update(this, "history", model.State, model.ErrorCode);
        RefreshButton.IsEnabled = !model.IsBusy;
        NextButton.IsEnabled = !model.IsBusy && model.HasNext;
        InspectButton.IsEnabled = model.CanInspect;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested;
        HistoryList.IsEnabled = !model.IsBusy;
        Progress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        Progress.IsIndeterminate = model.IsBusy && AppearanceSettings.AnimationsEnabled;
        CancelButton.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        NextButton.Visibility = model.HasNext ? Visibility.Visible : Visibility.Collapsed;
        EmptyContent.Visibility = !model.IsBusy && model.Page?.Entries.IsEmpty == true ? Visibility.Visible : Visibility.Collapsed;
        var inspect = model.Detail is not null && !inspectorClosed;
        if (!inspect) inlineDetails.Hide();
        CoverageNotice.IsOpen = model.State == CleanupHistoryState.Partial;
        Status.Text = model.ErrorCode is { } error ? ReviewText.Error(text, error) : model.StopRequested ? text.Get("Stopping…") : model.State switch
        {
            CleanupHistoryState.Loading => text.Get("Loading…"),
            CleanupHistoryState.Inspecting => text.Get("Checking recorded locations…"),
            CleanupHistoryState.Cancelled => text.Get("Cancelled"),
            CleanupHistoryState.Ready when model.Page?.Entries.IsEmpty == true => text.Get("No cleanup history yet."),
            _ => ""
        };
        var selectedId = model.Detail?.Execution.Id;
        var displays = model.Page?.Entries.Select(row => new CleanupHistoryDisplay(row.ExecutionId,
            row.StartedAt.ToLocalTime().ToString("g", CultureInfo.GetCultureInfo(text.Locale)),
            text.Get(row.Action == CleanupAction.Permanent ? "Permanent cleanup" : "Move to Recycle Bin"),
            text.Get("Recorded result") + ": " + ReviewText.ExecutionState(text, row.RecordedState) +
                (row.Unfinished || row.NeedsVerification ? ", " + text.Get("Needs Verification") : ""),
            text.Format("%lld of %lld items completed", row.CompletedItems, row.ItemCount),
            text.Get("Details"))).ToArray();
        if (HistoryList.ItemsSource is not CleanupHistoryDisplay[] previous || displays is null ||
            !previous.Select(value => value.AccessibleName).SequenceEqual(displays.Select(value => value.AccessibleName)))
        { inlineDetails.Hide(); HistoryList.ItemsSource = displays; }
        if (selectedId is not null && HistoryList.ItemsSource is CleanupHistoryDisplay[] rows)
            HistoryList.SelectedItem = rows.FirstOrDefault(row => row.ExecutionId == selectedId);
        RenderDetails();
    }

    private void RenderDetails()
    {
        DetailRows.Children.Clear();
        if (model.Detail is not { } detail)
        {
            AddText(DetailRows, text.Get("Select an operation to view its recorded results."));
            return;
        }
        AddText(DetailRows, text.Get("Recorded result") + ": " + ReviewText.ExecutionState(text, detail.Execution.State));
        if (detail.Unfinished || detail.NeedsVerification) AddText(DetailRows, text.Get("This operation is unfinished or needs verification."));
        foreach (var item in detail.Plan.Items)
        {
            var result = detail.Execution.Items.Single(value => value.ItemId == item.Id);
            var row = new StackPanel { Spacing = 4 };
            AddText(row, item.Path.Value, selectable: true);
            AddText(row, text.Get("Recorded result") + ": " + ReviewText.ItemState(text, result.State));
            if (result.RemovedEntries > 0) AddText(row, text.Format("%lld entries removed", result.RemovedEntries));
            if (model.Inspection?.Items.FirstOrDefault(value => value.ItemId == item.Id) is { } observation)
            {
                AddText(row, text.Get("Current observation") + ": " + ReviewText.LocationState(text, observation.Original.State));
                if (observation.Trash.Path is { } trash)
                {
                    AddText(row, trash.Value, selectable: true);
                    AddText(row, ReviewText.LocationState(text, observation.Trash.State));
                }
                if (observation.Assessment == "needs_verification") AddText(row, text.Get("Needs Verification"));
            }
            DetailRows.Children.Add(row);
        }
    }

    private static void AddText(StackPanel parent, string value, bool selectable = false) =>
        parent.Children.Add(new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = selectable });

    private async void RefreshHistory(object sender, RoutedEventArgs args) => await GuardAsync(model.RefreshAsync);
    private async void NextHistoryPage(object sender, RoutedEventArgs args) => await GuardAsync(model.NextPageAsync);
    private async void InspectLocations(object sender, RoutedEventArgs args) => await GuardAsync(model.InspectAsync);
    private void CancelOperation(object sender, RoutedEventArgs args) => model.Cancel();
    private async void OpenExecution(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is CleanupHistoryDisplay row) { inspectorClosed = false; await GuardAsync(() => model.ShowAsync(row.ExecutionId)); }
    }

    private void CloseInspector(object sender, RoutedEventArgs args) { inspectorClosed = true; inlineDetails.Hide(); Render(); }
    private async void ExpandExecution(Expander sender, ExpanderExpandingEventArgs args)
    {
        if (model.IsBusy || sender.Tag is not CleanupHistoryDisplay row) { sender.IsExpanded = false; return; }
        requestedDetail = sender;
        inspectorClosed = false;
        await GuardAsync(() => model.ShowAsync(row.ExecutionId));
        if (!disposed && !inspectorClosed && ReferenceEquals(requestedDetail, sender) && sender.IsExpanded) inlineDetails.Show(sender);
    }
    private void CollapseExecution(Expander sender, ExpanderCollapsedEventArgs args)
    {
        if (!ReferenceEquals(requestedDetail, sender)) return;
        requestedDetail = null; inspectorClosed = true; inlineDetails.Hide();
    }
    private void LoadRowIcon(object sender, RoutedEventArgs args) { if (sender is ContentControl host) host.Content = ProductIcon.Create("history", 20); }
    private async Task GuardAsync(Func<Task> run)
    {
        try { await run(); }
        catch (Exception error)
        {
            NativeDiagnostics.Write(error);
            if (!disposed) Status.Text = ReviewText.Error(text, error is ShouException known ? known.Code : null);
        }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        model.PropertyChanged -= Changed;
        model.Dispose();
        GC.SuppressFinalize(this);
    }
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class CleanupHistoryDisplay(string executionId, string started, string action, string state, string count, string details)
{
    public string ExecutionId { get; } = executionId;
    public string Started { get; } = started;
    public string Action { get; } = action;
    public string State { get; } = state;
    public string Count { get; } = count;
    public string Details { get; } = details;
    public string Meta => Started + ", " + State;
    public string AccessibleName => Started + ", " + Action + ", " + State + ", " + Count;
}
