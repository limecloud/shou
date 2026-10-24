using System.ComponentModel;
using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class CleanupPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly CleanupReviewViewModel model;
    private readonly CleanupExecutionViewModel execution;
    private bool rendering;
    private bool disposed;
    private Task? initialLoad;
    private Task? activeExecution;
    public event EventHandler? LocationsPrepared;
    public event EventHandler? BusyChanged;
    public bool HasActiveCleanup => activeExecution is { IsCompleted: false } || execution.IsExecuting;
    private bool IsBusy => model.IsBusy || execution.IsBusy || HasActiveCleanup;
    public void RequestCleanupStop() => execution.Cancel();

    public CleanupPage(ICleanupReviewOperations operations, ICleanupExecutionOperations executionOperations, BuiltinRuleCatalog catalog)
    {
        InitializeComponent();
        model = new(operations, catalog.Templates.ToImmutableDictionary(template => template.Id, template => template.Category));
        execution = new(executionOperations);
        PageTitle.Text = text.Get("Smart Cleanup");
        Description.Text = text.Get("Choose items to review. High-risk items require your selection.");
        Locations.PlaceholderText = text.Get("Scan Locations");
        AutomationProperties.SetName(Locations, text.Get("Scan Locations"));
        RefreshButton.Content = text.Get("Refresh");
        DiscoverButton.Content = text.Get("Find Scan Locations");
        ScanButton.Content = text.Get("Scan Selected Location");
        ScanAllButton.Content = text.Get("Scan All Locations");
        CancelButton.Content = text.Get("Stop");
        AllResultsButton.Content = text.Get("All Scan Locations");
        FilteredSelection.Content = text.Get("Select Matching Items");
        RecommendedButton.Content = text.Get("Select Recommended Items");
        ClearSelectionButton.Content = text.Get("Clear Selection");
        SearchFilter.PlaceholderText = text.Get("Search rules or paths");
        AutomationProperties.SetName(SearchFilter, text.Get("Search rules or paths"));
        AutomationProperties.SetName(CategoryFilter, text.Get("Cleanup Category"));
        AutomationProperties.SetName(RuleFilter, text.Get("Cleanup Rule"));
        CategoryFilter.SelectionChanged += (_, _) => ChangeFilter(categoryChanged: true);
        RuleFilter.SelectionChanged += (_, _) => ChangeFilter(categoryChanged: false);
        PreviousButton.Content = text.Get("Previous");
        NextButton.Content = text.Get("Next");
        ReviewButton.Content = text.Get("Review Selected Items");
        CleanButton.Content = text.Get("Clean Permanently");
        ReadExecutionButton.Content = text.Get("Read Recorded Result");
        UnavailableNotice.Text = text.Get("Cleanup execution is unavailable in this development build.");
        CoverageNotice.Message = text.Get("Some locations could not be read. Sizes show only measured data.");
        model.PropertyChanged += Changed;
        execution.PropertyChanged += ExecutionChanged;
        Locations.SelectionChanged += (_, _) =>
        {
            if (!disposed && !rendering && !IsBusy && Locations.SelectedItem is ScanLocationDisplay display) model.SelectWorkspace(display.Workspace.Id);
        };
        Render();
    }

    public Task EnsureLoadedAsync() => HasActiveCleanup ? Task.CompletedTask : initialLoad ??= model.LoadAsync();
    public void InvalidateConfiguration()
    {
        if (disposed || HasActiveCleanup) return;
        initialLoad = null;
        model.InvalidateConfiguration();
    }
    private void Changed(object? sender, PropertyChangedEventArgs args)
    {
        if (execution.Plan is not null && model.Plan?.Id != execution.Plan.Id) execution.BindPlan(null);
        Render();
    }
    private void ExecutionChanged(object? sender, PropertyChangedEventArgs args)
    {
        Render();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Render()
    {
        if (disposed || rendering) return;
        rendering = true;
        try
        {
            var activity = execution.IsExecuting || model.State == CleanupReviewState.Preparing;
            var stopping = execution.IsExecuting ? execution.StopRequested : model.StopRequested;
            ExecutionActivity.Visibility = activity ? Visibility.Visible : Visibility.Collapsed;
            ReviewControls.Visibility = ReviewStatus.Visibility = ReviewActions.Visibility = Candidates.Visibility = activity ? Visibility.Collapsed : Visibility.Visible;
            ExecutionMotion.IsActive = activity && !stopping;
            ExecutionTitle.Text = text.Get(stopping ? "Stopping at a safe boundary…" :
                !execution.IsExecuting || execution.Progress?.Phase is null or "preflight" or "checking" ? "Checking selected files…" : "Cleaning…");
            var fraction = execution.IsExecuting ? execution.FractionCompleted : null;
            ExecutionMeter.IsIndeterminate = fraction is null;
            ExecutionMeter.Value = (fraction ?? 0) * 100;
            ExecutionPercentage.Text = fraction?.ToString("P0", System.Globalization.CultureInfo.CurrentCulture) ?? "";
            ExecutionPath.Text = execution.IsExecuting ? execution.DisplayPath : "";
            ToolTipService.SetToolTip(ExecutionPath, execution.CurrentPath);
            ExecutionStop.Content = text.Get(stopping ? "Stopping at a safe boundary…" : "Stop");
            ExecutionStop.IsEnabled = activity && !stopping;
            var selectedLocation = model.WorkspaceId;
            if (Locations.ItemsSource is not ScanLocationDisplay[] existing || !existing.Select(value => value.Workspace).SequenceEqual(model.Workspaces))
            {
                var rows = model.Workspaces.Select(value => new ScanLocationDisplay(value)).ToArray();
                Locations.ItemsSource = rows;
                Locations.SelectedItem = rows.FirstOrDefault(value => value.Workspace.Id == selectedLocation);
            }
            else Locations.SelectedItem = existing.FirstOrDefault(value => value.Workspace.Id == selectedLocation);
            Locations.IsEnabled = !IsBusy;
            RefreshButton.IsEnabled = !IsBusy;
            DiscoverButton.IsEnabled = !IsBusy;
            ScanButton.IsEnabled = !IsBusy && Locations.SelectedItem is ScanLocationDisplay;
            ScanAllButton.IsEnabled = !IsBusy && !model.Workspaces.IsEmpty;
            CancelButton.IsEnabled = execution.IsBusy ? !execution.StopRequested : model.IsBusy && !model.StopRequested && model.State != CleanupReviewState.Discovering;
            Progress.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
            var issues = model.DiscoveryIssues.AddRange(model.Batch?.Issues ?? []);
            CoverageNotice.IsOpen = model.State == CleanupReviewState.Partial || !issues.IsEmpty;
            CoverageNotice.Message = text.Get("Some locations could not be read. Sizes show only measured data.") + (issues.IsEmpty ? "" : "\n" +
                string.Join("\n", issues.Take(20).Select(issue => issue.Path.Value + " · " + ReviewText.Error(text, issue.Code))));
            BatchSummary.Visibility = model.Batch is null ? Visibility.Collapsed : Visibility.Visible;
            BatchSummary.Text = model.Batch is not { } batch ? "" : text.Format("Results for %lld of %lld locations", batch.Scans.Length, model.Workspaces.Length) + " · " +
                text.Get(batch.State == "cancelled" ? "Scan cancelled" : batch.State == "partial" ? "Partial Coverage" : "Scan complete") + "\n" +
                text.Get("Selections across locations are reviewed together. Filtering keeps your selection.");
            PreviousButton.IsEnabled = !IsBusy && model.HasPrevious;
            NextButton.IsEnabled = !IsBusy && model.HasNext;
            ReviewButton.IsEnabled = !IsBusy && model.CanPreparePlan;
            CleanButton.IsEnabled = !IsBusy && execution.CanExecute;
            ReadExecutionButton.IsEnabled = !IsBusy && execution.CanReadExecution;
            Candidates.IsEnabled = !IsBusy;
            AllResultsButton.Visibility = model.Batch is null ? Visibility.Collapsed : Visibility.Visible;
            AllResultsButton.IsEnabled = !IsBusy && !model.AllLocations;
            CategoryFilter.IsEnabled = RuleFilter.IsEnabled = SearchFilter.IsEnabled = !IsBusy;
            var categories = new[] { new CleanupFilterDisplay(null, text.Get("All Categories")) }.Concat(model.Categories.Select(value => new CleanupFilterDisplay(value, CategoryTitle(value)))).ToArray();
            CategoryFilter.ItemsSource = categories;
            CategoryFilter.SelectedItem = categories.FirstOrDefault(value => value.Id == model.Category);
            var groups = new[] { new CleanupFilterDisplay(null, text.Get("All Rules")) }.Concat(model.Groups.Select(group =>
                new CleanupFilterDisplay(group.RuleId, text.Get(group.Name) + " · " + text.Format("%lld of %lld selected", group.SelectedCount, group.SelectableCount)))).ToArray();
            RuleFilter.ItemsSource = groups;
            RuleFilter.SelectedItem = groups.FirstOrDefault(value => value.Id == model.RuleId) ?? groups[0];
            if (SearchFilter.Text != model.Search) SearchFilter.Text = model.Search;
            FilteredSelection.IsEnabled = !IsBusy && model.FilteredCount > 0;
            FilteredSelection.IsChecked = model.FilteredSelection;
            RecommendedButton.IsEnabled = !IsBusy && model.RecommendedCount > 0;
            ClearSelectionButton.IsEnabled = !IsBusy && model.SelectedCount > 0;
            UnavailableNotice.Visibility = execution.ExecutionAvailable ? Visibility.Collapsed : Visibility.Visible;
            ExecutionDetails.Text = ExecutionText();
            SelectedCount.Text = text.Format("%lld items selected", model.SelectedCount) + " · " + StorageRow.FormatBytes(model.SelectedAllocatedBytes) +
                " · " + text.Format("%lld matching items", model.FilteredCount);
            Status.Text = model.SelectionErrorCode is { } selection ? ReviewText.Error(text, selection) : model.ErrorCode is { } error ? ReviewText.Error(text, error) :
                model.StopRequested ? text.Get("Stopping…") : model.State switch
                {
                    CleanupReviewState.Loading => text.Get("Loading…"),
                    CleanupReviewState.Discovering => text.Get("Finding scan locations…"),
                    CleanupReviewState.Scanning => text.Get("Scanning…"),
                    CleanupReviewState.Preparing => text.Get("Preparing review…"),
                    CleanupReviewState.Cancelled => text.Get("Scan cancelled"),
                    CleanupReviewState.Ready when model.Snapshot?.Candidates.IsEmpty == true => text.Get("No matching cleanup items were found."),
                    CleanupReviewState.Empty when model.Workspaces.IsEmpty => text.Get("No scan locations are configured yet."),
                    _ => text.Get("Scanning uses the enabled rules for this location.")
                };
            Candidates.ItemsSource = model.Rows.Select(row => new CleanupCandidateDisplay(row,
                CategoryTitle(row.Category) + " · " + text.Get(row.RuleName),
                !row.Candidate.BlockedReasons.IsEmpty ? string.Join(" · ", row.Candidate.BlockedReasons.Select(reason => ReviewText.BlockedReason(text, reason))) :
                row.Selectable ? text.Get(row.Candidate.Risk == "high" ? "High Risk" : row.Recommended ? "Recommended" : "Review") :
                    text.Get("The scan or settings changed. Scan again before reviewing."))).ToArray();
        }
        finally { rendering = false; }
    }

    private string CategoryTitle(string category) => text.Get(category switch
    {
        "cache" => "Cache Files", "build" => "Build Artifacts", "dependencies" => "Dependencies",
        "logs" => "Log Files", "application" => "Applications", "browser" => "Browser Data",
        "developer" => "Developer Tools", "system" => "System Caches", "personal" => "Personal Rules", _ => "Other"
    });
    private void ChangeFilter(bool categoryChanged)
    {
        if (disposed || rendering || IsBusy) return;
        model.SetFilter((CategoryFilter.SelectedItem as CleanupFilterDisplay)?.Id,
            categoryChanged ? null : (RuleFilter.SelectedItem as CleanupFilterDisplay)?.Id, SearchFilter.Text);
    }
    private void ChangeSearch(object sender, TextChangedEventArgs args) => ChangeFilter(categoryChanged: false);
    private void ShowAllResults(object sender, RoutedEventArgs args) => model.ShowAllResults();
    private void ChangeFilteredSelection(object sender, RoutedEventArgs args)
    {
        if (disposed || rendering || IsBusy) return;
        model.SetFilteredSelected(model.FilteredSelection != true);
    }
    private void SelectRecommended(object sender, RoutedEventArgs args) => model.SelectRecommended();
    private void ClearSelection(object sender, RoutedEventArgs args) => model.ClearSelection();

    private async void RefreshLocations(object sender, RoutedEventArgs args) => await GuardAsync(model.LoadAsync);
    private async void DiscoverLocations(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        await model.DiscoverAsync();
        if (!disposed) LocationsPrepared?.Invoke(this, EventArgs.Empty);
    });
    private async void ScanLocation(object sender, RoutedEventArgs args)
    {
        if (Locations.SelectedItem is ScanLocationDisplay display) await GuardAsync(() => model.ScanAsync(display.Workspace.Id));
    }
    private async void ScanAllLocations(object sender, RoutedEventArgs args) => await GuardAsync(() => model.ScanAllAsync());
    private void CancelOperation(object sender, RoutedEventArgs args)
    { if (execution.IsBusy) execution.Cancel(); else model.Cancel(); }
    private void PreviousPage(object sender, RoutedEventArgs args) => model.MovePage(-1);
    private void NextPage(object sender, RoutedEventArgs args) => model.MovePage(1);
    private void ChangeSelection(object sender, RoutedEventArgs args)
    {
        if (disposed || rendering || IsBusy || sender is not CheckBox { Tag: string id } checkbox) return;
        var value = checkbox.IsChecked == true;
        if (model.Rows.Any(row => row.Candidate.Id == id && row.Selected == value)) return;
        if (!model.SetSelected(id, value))
        {
            rendering = true;
            try { checkbox.IsChecked = !value; }
            finally { rendering = false; }
        }
    }

    private async void ReviewSelection(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        await model.PreparePlanAsync();
        if (disposed || model.Plan is not { } plan) return;
        execution.BindPlan(plan);
        var scope = new StackPanel { Spacing = 12 };
        scope.Children.Add(new TextBlock { Text = text.Format("%lld items selected", plan.Items.Length) });
        scope.Children.Add(new TextBlock { Text = text.Get("Permanent deletion cannot be undone."), TextWrapping = TextWrapping.Wrap });
        foreach (var item in plan.Items)
        {
            var row = new StackPanel { Spacing = 4 };
            row.Children.Add(new TextBlock { Text = item.Path.Value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            row.Children.Add(new TextBlock { Text = StorageRow.FormatBytes(item.AllocatedBytes) + " · " + text.Get(item.Risk == "high" ? "High Risk" : "Review") });
            scope.Children.Add(row);
        }
        if (!execution.ExecutionAvailable) scope.Children.Add(new TextBlock { Text = text.Get("Cleanup execution is unavailable in this development build."), TextWrapping = TextWrapping.Wrap });
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = text.Get("Review Cleanup"), CloseButtonText = text.Get("Done"),
            Content = new ScrollViewer { Content = scope, MaxHeight = 480 }, DefaultButton = ContentDialogButton.Close
        };
        await dialog.ShowAsync();
    });

    private async void ExecuteCleanup(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        if (IsBusy || !execution.CanExecute || execution.Plan is not { } plan) return;
        activeExecution = execution.ExecuteAsync(new WinUICleanupConfirmation(this, text, plan));
        model.InvalidateConfiguration();
        initialLoad = null;
        BusyChanged?.Invoke(this, EventArgs.Empty);
        try { await activeExecution; }
        finally { activeExecution = null; Render(); BusyChanged?.Invoke(this, EventArgs.Empty); }
    });
    private async void ReadExecution(object sender, RoutedEventArgs args) => await GuardAsync(execution.ReadExecutionAsync);

    private string ExecutionText()
    {
        if (execution.IsExecuting) return text.Get(execution.StopRequested ? "Stopping cleanup; waiting for the current item result…" : "Cleaning selected items…");
        if (execution.State == CleanupExecutionPageState.Reading) return text.Get("Loading…");
        var lines = new List<string>();
        if (execution.AttemptedPlan is { } plan) lines.Add(text.Get("Cleanup Plan") + ": " + plan.Id);
        if (execution.Execution is { } result)
        {
            lines.Add(text.Get("Recorded result") + ": " + ReviewText.ExecutionState(text, result.State));
            foreach (var item in result.Items)
            {
                var path = execution.AttemptedPlan!.Items.Single(target => target.Id == item.ItemId).Path.Value;
                lines.Add(path + " · " + ReviewText.ItemState(text, item.State) + (item.Reason is null ? "" : " · " + ReviewText.Error(text, item.Reason)));
            }
        }
        else if (execution.AttemptedPlan is not null)
            lines.Add(text.Get("A recorded outcome is unavailable. This does not prove that no files changed. Read the recorded result before continuing."));
        if (execution.ErrorCode is { } code && code != "execution_not_recorded") lines.Add(ReviewText.Error(text, code));
        return string.Join("\n", lines);
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
        execution.PropertyChanged -= ExecutionChanged;
        model.Dispose();
        execution.Dispose();
        GC.SuppressFinalize(this);
    }

}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class CleanupCandidateDisplay(CleanupCandidateSelection row, string ruleName, string explanation)
{
    public CleanupCandidateSelection Row { get; } = row;
    public string RuleName { get; } = ruleName;
    public string Explanation { get; } = explanation;
    public string Id => Row.Candidate.Id;
    public string Path => Row.Candidate.Path.Value;
    public string Size => StorageRow.FormatBytes(Row.Candidate.AllocatedBytes);
    public bool Selected => Row.Selected;
    public bool Selectable => Row.Selectable;
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class CleanupFilterDisplay(string? id, string title)
{
    public string? Id { get; } = id;
    public string Title { get; } = title;
}
