using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class HistoryPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly CleanupHistoryViewModel model;
    private bool disposed;
    private Task? initialLoad;

    public HistoryPage(ICleanupHistoryOperations operations)
    {
        InitializeComponent();
        model = new(operations);
        PageTitle.Text = text.Get("History");
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
    private void Changed(object? sender, PropertyChangedEventArgs args) => Render();

    private void Render()
    {
        if (disposed) return;
        RefreshButton.IsEnabled = !model.IsBusy;
        NextButton.IsEnabled = !model.IsBusy && model.HasNext;
        InspectButton.IsEnabled = model.CanInspect;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested;
        HistoryList.IsEnabled = !model.IsBusy;
        Progress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
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
        HistoryList.ItemsSource = model.Page?.Entries.Select(row => new CleanupHistoryDisplay(row.ExecutionId,
            row.StartedAt.ToLocalTime().ToString("g", CultureInfo.GetCultureInfo(text.Locale)),
            text.Get(row.Action == CleanupAction.Permanent ? "Permanent cleanup" : "Move to Recycle Bin"),
            text.Get("Recorded result") + ": " + ReviewText.ExecutionState(text, row.RecordedState) +
                (row.Unfinished || row.NeedsVerification ? " · " + text.Get("Needs Verification") : ""),
            text.Format("%lld of %lld items completed", row.CompletedItems, row.ItemCount))).ToArray();
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
        if (args.ClickedItem is CleanupHistoryDisplay row) await GuardAsync(() => model.ShowAsync(row.ExecutionId));
    }

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
public sealed class CleanupHistoryDisplay(string executionId, string started, string action, string state, string count)
{
    public string ExecutionId { get; } = executionId;
    public string Started { get; } = started;
    public string Action { get; } = action;
    public string State { get; } = state;
    public string Count { get; } = count;
    public string AccessibleName => Started + " · " + Action + " · " + State + " · " + Count;
}
