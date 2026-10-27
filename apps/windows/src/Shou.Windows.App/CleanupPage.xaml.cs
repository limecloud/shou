using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class CleanupPage : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);
    private readonly TextCatalog text = new();
    private readonly CleanupReviewViewModel model;
    private readonly CleanupReviewScope scope;
    private readonly CleanupExecutionViewModel execution;
    private bool rendering;
    private bool disposed;
    private Task? activeExecution;
    private string? dismissedCompletion;
    private string? renderedCompletion;
    private bool completionDetailsVisible;
    private readonly HashSet<string> expandedRules = [];
    public event EventHandler? LocationsPrepared;
    public event EventHandler? BusyChanged;
    public event EventHandler? HistoryRequested;
    public event Action<string>? DestinationRequested;
    public bool HasActiveCleanup => activeExecution is { IsCompleted: false } || execution.IsExecuting;
    public bool ShowingCompletion => CompletionContent.Visibility == Visibility.Visible;
    private bool IsBusy => model.IsBusy || execution.IsBusy || HasActiveCleanup;
    public void RequestCleanupStop() => execution.Cancel();

    public CleanupPage(CleanupReviewViewModel review, ICleanupExecutionOperations executionOperations, bool projectsOnly = false)
    {
        InitializeComponent();
        model = review;
        scope = projectsOnly ? CleanupReviewScope.ProjectOutputs : CleanupReviewScope.All;
        execution = new(executionOperations);
        PageTitle.Text = text.Get("Room for") + "\n" + text.Get("what comes next.");
        StartIcon.Content = ProductIcon.Create("cleanup", (double)Application.Current.Resources["ShouStartIconSize"]);
        var emptyIcon = ProductIcon.Create("complete", (double)Application.Current.Resources["ShouStartIconSize"]);
        ProductIcon.Select(emptyIcon, "TextFillColorSecondaryBrush");
        EmptyResultIcon.Content = emptyIcon;
        var scanLabel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var scanIcon = ProductIcon.Create("cleanup"); ProductIcon.Select(scanIcon, "ShouActionTextBrush");
        scanLabel.Children.Add(scanIcon); scanLabel.Children.Add(new TextBlock { Text = text.Get("Start Scan") }); StartButton.Content = scanLabel;
        CommonScanItem.Text = text.Get("Scan Common Locations"); LocationsMenuItem.Text = text.Get("Scan Locations…");
        var options = new Button { Content = text.Get("Cleanup Options"), Style = (Style)Application.Current.Resources["ShouToolbarButton"] };
        AutomationProperties.SetAutomationId(options, "cleanup.options");
        var menu = new MenuFlyout();
        options.Flyout = menu;
        PageToolbar.Children.Add(options);
        foreach (var flyout in new[] { menu, (MenuFlyout)StartMenuButton.Flyout })
        {
            foreach (var (title, page) in new[] { ("Cleanup Rules", "configuration"), ("Project Cleanup", "projects") })
            {
                var item = new MenuFlyoutItem { Text = text.Get(title) };
                item.Click += (_, _) => { if (!IsBusy) DestinationRequested?.Invoke(page); };
                flyout.Items.Add(item);
            }
        }
        FreeSpaceItem.Visibility = Visibility.Collapsed;
        InvestigateLink.Visibility = ExternalToolsLink.Visibility = LocationsLink.Visibility = Visibility.Collapsed;
        FreeSpaceItem.Text = text.Get("Scan & Free Space");
        ToolTipService.SetToolTip(FreeSpaceItem, text.Get("Cleanup execution is unavailable in this development build."));
        InvestigateLink.Content = text.Get("Investigate a Folder with AI…"); ExternalToolsLink.Content = text.Get("External AI Tools…"); LocationsLink.Content = text.Get("Scan Locations…");
        ToolTipService.SetToolTip(InvestigateLink, text.Get("AI investigation is not available in this Windows preview."));
        ToolTipService.SetToolTip(ExternalToolsLink, text.Get("AI investigation is not available in this Windows preview."));
        AutomationProperties.SetName(StartMenuButton, text.Get("Cleanup Options"));
        RescanButton.Content = text.Get("Scan Again");
        LocationMenuButton.Content = text.Get("Scan Locations");
        StartDescription.Text = text.Get("Find caches and temporary files you can clear.");
        if (projectsOnly)
        {
            PageTitle.Text = text.Get("More room to build.");
            StartDescription.Text = text.Get("Review build outputs and dependencies from local and cloned projects. Source files are kept.");
        }
        WorkspaceVisuals.ArrangeLanding(StartContent, StartIcon, PageTitle, StartDescription, projectsOnly ? "projects" : "cleanup");
        if (!projectsOnly) StartContent.Children.Add(WorkspaceVisuals.Destinations(text, page =>
        {
            if (!IsBusy) DestinationRequested?.Invoke(page);
        }));
        Description.Text = text.Get("Choose items to review. High-risk items require your selection.");
        Locations.PlaceholderText = text.Get("Scan Locations");
        AutomationProperties.SetName(Locations, text.Get("Scan Locations"));
        RefreshButton.Content = text.Get("Refresh");
        DiscoverButton.Content = text.Get("Find Scan Locations");
        ScanButton.Content = text.Get("Scan Selected Location");
        ScanAllButton.Content = text.Get("Scan All Locations");
        CancelButton.Content = text.Get("Stop");
        AllResultsButton.Content = text.Get("All Scan Locations");
        SelectionMenuButton.Content = text.Get("Select Items");
        RecommendedMenuItem.Text = text.Get("Use Recommended Selection");
        ReviewableMenuItem.Text = text.Get("Select Reviewable Items");
        AllEligibleMenuItem.Text = text.Get("Select All Eligible Items, Including High Risk");
        ClearSelectionMenuItem.Text = text.Get("Clear Selection");
        SearchFilter.PlaceholderText = text.Get(projectsOnly ? "Search projects or paths" : "Search rules or paths");
        AutomationProperties.SetName(FilteredSelection, text.Get("Select All"));
        AutomationProperties.SetName(SearchFilter, SearchFilter.PlaceholderText);
        AutomationProperties.SetName(CategoryFilter, text.Get("Cleanup Category"));
        AutomationProperties.SetName(RuleFilter, text.Get("Cleanup Rule"));
        CategoryFilter.SelectionChanged += (_, _) => ChangeFilter(categoryChanged: true);
        CoverageDetailsButton.Content = text.Get("Some locations need attention");
        StartCoverageDetailsButton.Content = text.Get("Some locations need attention");
        RuleFilter.SelectionChanged += (_, _) => ChangeFilter(categoryChanged: false);
        PreviousButton.Content = text.Get("Previous");
        NextButton.Content = text.Get("Next");
        CleanButton.Content = text.Get("Delete Permanently");
        AutomationProperties.SetHelpText(CleanButton, text.Get("Permanent deletion cannot be undone."));
        EstimatedHeading.Text = text.Get("Estimated Space to Free");
        ToolTipService.SetToolTip(CleanButton, text.Get(execution.ExecutionAvailable
            ? "These files will be permanently removed. This action cannot be undone."
            : "Cleanup execution is unavailable in this development build."));
        ReadExecutionButton.Content = text.Get("Read Recorded Result");
        CompletionDetailsButton.Content = text.Get("Details");
        CompletionScanButton.Content = text.Get("Scan Again");
        CompletionHistoryButton.Content = text.Get("View History");
        CompletionBackButton.Content = text.Get("Back");
        CompletionSkippedLabel.Text = text.Get("Skipped");
        CompletionFailedLabel.Text = text.Get("Failed items");
        CompletionUnverifiedLabel.Text = text.Get("Needs verification");
        CompletionContent.KeyDown += (sender, args) =>
        {
            if (args.Key != global::Windows.System.VirtualKey.Escape) return;
            CloseCompletion(sender, args);
            args.Handled = true;
        };
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

    public Task EnsureLoadedAsync()
    {
        if (HasActiveCleanup) return Task.CompletedTask;
        model.SetScope(scope);
        Render();
        return model.EnsureLoadedAsync();
    }
    private void Changed(object? sender, PropertyChangedEventArgs args)
    {
        if (execution.Plan is not null && model.Plan?.Id != execution.Plan.Id) execution.BindPlan(null);
        Render();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }
    private void ExecutionChanged(object? sender, PropertyChangedEventArgs args)
    {
        Render();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Render()
    {
        if (disposed || rendering || model.ReviewScope != scope) return;
        rendering = true;
        try
        {
            var activity = execution.IsBusy || model.IsBusy;
            var completion = !activity && execution.AttemptedPlan is { } attempted && attempted.Id != dismissedCompletion;
            var results = model.Batch is not null || model.Snapshot is not null;
            LandingScroll.Visibility = StartContent.Visibility = !activity && !completion && !results ? Visibility.Visible : Visibility.Collapsed;
            ResultsContent.Visibility = !activity && !completion && results ? Visibility.Visible : Visibility.Collapsed;
            PageToolbar.Visibility = !activity && !completion && results ? Visibility.Visible : Visibility.Collapsed;
            CompletionContent.Visibility = completion ? Visibility.Visible : Visibility.Collapsed;
            if (completion) RenderCompletion();
            StartButton.IsEnabled = RescanButton.IsEnabled = !IsBusy;
            LocationMenuButton.IsEnabled = !IsBusy;
            CapacitySummary.Text = text.Format("%lld cleanup items found", model.ResultGroupCount);
            FoundEstimate.Text = text.Get(scope == CleanupReviewScope.ProjectOutputs ? "Matched cleanup items" : "Found (estimate)") + " " + StorageRow.FormatBytes(model.ResultAllocatedBytes);
            var stopping = execution.IsExecuting ? execution.StopRequested : model.StopRequested;
            ReviewControls.Visibility = ReviewStatus.Visibility = ReviewActions.Visibility = Candidates.Visibility = activity ? Visibility.Collapsed : Visibility.Visible;
            var stageTitle = text.Get(
                !execution.IsExecuting ? model.State switch { CleanupReviewState.Discovering => "Finding scan locations…", CleanupReviewState.Scanning => "Scanning…", CleanupReviewState.Loading => "Loading…", _ => "Checking selected files…" } :
                execution.Progress?.Phase is null or "preflight" or "checking" ? "Checking selected files…" : "Cleaning…");
            var fraction = execution.IsExecuting ? execution.FractionCompleted : null;
            ExecutionActivity.Update(activity, stageTitle, execution.IsExecuting ? "intake" : "search",
                execution.IsExecuting ? execution.CurrentPath : "", fraction, stopping,
                canStop: model.State != CleanupReviewState.Discovering);
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
            CoverageDetailsButton.Visibility = CoverageNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
            CoverageNotice.Message = issues.IsEmpty ? text.Get("Some locations could not be read. Sizes show only measured data.") :
                string.Join("\n\n", issues.Distinct().Take(20).Select(issue => issue.Path.Value + "\n" + ReviewText.Error(text, issue.Code)));
            StartCoverageNotice.IsOpen = !activity && !results && !issues.IsEmpty;
            StartCoverageDetailsButton.Visibility = StartCoverageNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
            StartCoverageNotice.Message = CoverageNotice.Message;
            ScanState.Text = text.Get(model.Batch?.State == "complete" || model.Batch is null && model.Snapshot?.Scan.IsComplete == true ? "Scan Complete" : "Partial Scan");
            PreviousButton.IsEnabled = !IsBusy && model.HasPrevious;
            NextButton.IsEnabled = !IsBusy && model.HasNext;
            CleanButton.IsEnabled = !IsBusy && execution.ExecutionAvailable && model.CanPreparePlan;
            SelectionMenuButton.IsEnabled = !IsBusy && model.ResultCount > 0;
            PreviousButton.Visibility = model.HasPrevious ? Visibility.Visible : Visibility.Collapsed;
            NextButton.Visibility = model.HasNext ? Visibility.Visible : Visibility.Collapsed;
            ReadExecutionButton.IsEnabled = !IsBusy && execution.CanReadExecution;
            ReadExecutionButton.Visibility = execution.CanReadExecution ? Visibility.Visible : Visibility.Collapsed;
            CleanButton.Visibility = Visibility.Visible;
            Candidates.IsEnabled = !IsBusy;
            AllResultsButton.Visibility = model.Batch is not null && !model.AllLocations ? Visibility.Visible : Visibility.Collapsed;
            AllResultsButton.IsEnabled = !IsBusy && !model.AllLocations;
            CategoryFilter.IsEnabled = RuleFilter.IsEnabled = SearchFilter.IsEnabled = !IsBusy;
            var summaries = model.CategorySummaries;
            var categories = new[] { CategoryRow("", text.Get("All Items"), model.ResultGroupCount, summaries.Sum(value => value.SelectableCount), model.SelectedCount, model.ResultAllocatedBytes, model.SelectedAllocatedBytes, !IsBusy) }
                .Concat(summaries.Select(value => CategoryRow(value.Id, CategoryTitle(value.Id), value.GroupCount, value.SelectableCount, value.SelectedCount, value.AllocatedBytes, value.SelectedBytes, !IsBusy))).ToArray();
            CategoryFilter.ItemsSource = categories;
            CategoryFilter.SelectedItem = categories.FirstOrDefault(value => value.Id == (model.Category ?? "")) ?? categories[0];
            var heading = categories.FirstOrDefault(value => value.Id == (model.Category ?? "")) ?? categories[0];
            CategoryHeading.Text = heading.Title;
            CategoryCount.Text = text.Format("%lld items", model.FilteredGroupCount);
            CategoryMetrics.Text = StorageRow.FormatBytes(model.FilteredSelectedBytes) + " / " + StorageRow.FormatBytes(model.FilteredAllocatedBytes);
            var groups = new[] { new CleanupFilterDisplay(null, text.Get("All Rules")) }.Concat(model.Groups.Select(group =>
                new CleanupFilterDisplay(group.RuleId, text.Get(group.Name) + ", " + text.Format("%lld of %lld selected", group.SelectedCount, group.SelectableCount)))).ToArray();
            RuleFilter.ItemsSource = groups;
            RuleFilter.SelectedItem = groups.FirstOrDefault(value => value.Id == model.RuleId) ?? groups[0];
            if (SearchFilter.Text != model.Search) SearchFilter.Text = model.Search;
            FilteredSelection.IsEnabled = !IsBusy && model.FilteredCount > 0;
            FilteredSelection.IsChecked = model.FilteredSelection;
            RecommendedMenuItem.IsEnabled = !IsBusy && model.RecommendedCount > 0;
            ClearSelectionMenuItem.IsEnabled = !IsBusy && model.SelectedCount > 0;
            UnavailableNotice.Visibility = execution.ExecutionAvailable ? Visibility.Collapsed : Visibility.Visible;
            ExecutionDetails.Text = ExecutionText();
            SelectedCount.Text = text.Format("%lld items selected", model.SelectedGroupCount);
            EstimatedBytes.Text = StorageRow.FormatBytes(model.SelectedAllocatedBytes);
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
            ReviewStatus.Visibility = model.SelectionErrorCode is not null || model.ErrorCode is not null ? Visibility.Visible : Visibility.Collapsed;
            StartStatus.Text = model.ErrorCode is not null || model.State == CleanupReviewState.Cancelled ? Status.Text :
                model.NoUsableLocations ? text.Get("No scan locations are available. Review Scan Locations or add a folder.") :
                text.Get("Common locations are found automatically. No project setup needed.");
            if (model.ErrorCode is not null)
            {
                var stage = model.ErrorStage is "prepare_locations" or "discovering" ? text.Get("Scan setup failed.") : text.Get("Scan failed.");
                StartStatus.Text = stage + " " + Status.Text + "\n" + text.Format("Diagnostic reference: %@", model.DiagnosticReference ?? "");
            }
            var displays = model.Rows.Select(row => new CleanupCandidateDisplay(row,
                CategoryTitle(row.Category) + ", " + text.Get(row.RuleName),
                !row.Candidate.BlockedReasons.IsEmpty ? string.Join(", ", row.Candidate.BlockedReasons.Select(reason => ReviewText.BlockedReason(text, reason))) :
                row.Selectable ? text.Get(row.Candidate.Risk == "high" ? "High Risk" : row.Recommended ? "Recommended" : "Review") :
                    text.Get("The scan or settings changed. Scan again before reviewing."))).ToArray();
            var displaysById = displays.ToDictionary(row => row.Id, StringComparer.Ordinal);
            var groupsForPage = scope == CleanupReviewScope.ProjectOutputs ? model.ProjectGroups.Select(group =>
            {
                var items = group.Rows.Where(row => displaysById.ContainsKey(row.Candidate.Id)).Select(row => displaysById[row.Candidate.Id]).ToArray();
                return new CleanupRuleDisplay(group.Id, group.Path.Name, group.Selection, !IsBusy && group.SelectableCount > 0, items,
                    items.Length < group.Count ? text.Format("Showing %lld of %lld matched locations", items.Length, group.Count) : text.Format("%lld locations", group.Count), StorageRow.FormatBytes(group.AllocatedBytes),
                    group.SelectedBytes > 0 ? text.Get("Selected") + " " + StorageRow.FormatBytes(group.SelectedBytes) : "",
                    group.SelectedBytes > 0 ? Visibility.Visible : Visibility.Collapsed,
                    group.IdentifiedProject ? "" : text.Get("Grouped by scan location"), group.Path.Value);
            }).Where(group => group.Items.Length > 0).ToArray() : displays.GroupBy(row => row.Row.Candidate.RuleId).Select(group =>
            {
                var summary = model.Groups.Single(value => value.RuleId == group.Key);
                return new CleanupRuleDisplay(group.Key, text.Get(summary.Name),
                    summary.Selection, !IsBusy && summary.SelectableCount > 0, group.ToArray(), text.Format("%lld locations", summary.Count),
                    StorageRow.FormatBytes(summary.AllocatedBytes),
                    summary.SelectedBytes > 0 ? text.Get("Selected") + " " + StorageRow.FormatBytes(summary.SelectedBytes) : "",
                    summary.SelectedBytes > 0 ? Visibility.Visible : Visibility.Collapsed,
                    summary.SelectableCount == 0 ? text.Get("Review required") : group.Any(row => row.Row.Candidate.Risk == "high") ? text.Get("High risk") : "");
            }).ToArray();
            Candidates.ItemsSource = groupsForPage;
            EmptyResults.Visibility = groupsForPage.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            EmptyResultsTitle.Text = text.Get(string.IsNullOrEmpty(model.Search) ? "No matching cleanup items" : "No search results");
            EmptyResultsDescription.Text = string.IsNullOrEmpty(model.Search) ? "" : text.Get("Try another rule name or path.");
            EmptyResultsDescription.Visibility = string.IsNullOrEmpty(model.Search) ? Visibility.Collapsed : Visibility.Visible;
            PageDiagnostics.Update(this, scope == CleanupReviewScope.ProjectOutputs ? "projects" : "cleanup", model.State, model.ErrorCode, model.ResultCount);
        }
        finally { rendering = false; }
    }

    private string CategoryTitle(string category) => text.Get(category switch
    {
        "cache" => "User Cache Files", "build" => "Project Build Outputs", "dependencies" => "Dependencies",
        "logs" => "Log Files", "application" => "Application Caches", "browser" => "Browser Data",
        "developer" => "Developer Tools", "system" => "System Caches", "personal" => "Personal Rules", _ => "Other"
    });
    private void ChangeFilter(bool categoryChanged)
    {
        if (disposed || rendering || IsBusy) return;
        var categoryId = (CategoryFilter.SelectedItem as CleanupCategoryDisplay)?.Id;
        model.SetFilter(string.IsNullOrEmpty(categoryId) ? null : categoryId,
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
    private void SelectReviewable(object sender, RoutedEventArgs args) => model.SelectReviewable();
    private void SelectAllEligible(object sender, RoutedEventArgs args) => model.SetCategorySelected(null, true);
    private void LoadRuleGroup(object sender, RoutedEventArgs args) { if (sender is Expander { Tag: string id } row) row.IsExpanded = expandedRules.Contains(id); }
    private void ExpandRuleGroup(Expander sender, ExpanderExpandingEventArgs args) { if (sender.Tag is string id) expandedRules.Add(id); }
    private void CollapseRuleGroup(Expander sender, ExpanderCollapsedEventArgs args) { if (!rendering && sender.Tag is string id) expandedRules.Remove(id); }
    private void LoadGroupIcon(object sender, RoutedEventArgs args)
    {
        if (sender is not ContentControl host) return;
        var icon = ProductIcon.Create(scope == CleanupReviewScope.ProjectOutputs ? "projects" : (host.DataContext as CleanupRuleDisplay)?.Items.FirstOrDefault()?.Row.Category switch
        { "build" => "hammer", "developer" => "terminal", _ => "archive" }, 28);
        ProductIcon.Select(icon, "TextFillColorSecondaryBrush");
        host.Content = icon;
    }
    private void LoadCategoryIcon(object sender, RoutedEventArgs args)
    {
        if (sender is not ContentControl host) return;
        var icon = ProductIcon.Create(host.Tag as string ?? "cleanup", 18);
        ProductIcon.Select(icon, "TextFillColorSecondaryBrush");
        host.Content = icon;
    }
    private void ChangeCategorySelection(object sender, RoutedEventArgs args)
    {
        if (disposed || rendering || IsBusy || sender is not CheckBox { Tag: string id } box) return;
        var value = box.IsChecked == true;
        if (!model.SetCategorySelected(string.IsNullOrEmpty(id) ? null : id, value))
        {
            rendering = true;
            try { box.IsChecked = !value; }
            finally { rendering = false; }
        }
    }
    private CleanupCategoryDisplay CategoryRow(string id, string title, int count, int selectable, int selected, long bytes, long selectedBytes, bool canToggle)
    {
        var state = selectable == 0 || selected == 0 ? false : selected == selectable ? (bool?)true : null;
        return new(id, title, StorageRow.FormatBytes(bytes) + ", " + text.Format("%lld items", count),
            selected == 0 ? "" : text.Get("Selected") + " " + StorageRow.FormatBytes(selectedBytes),
            selected == 0 ? Visibility.Collapsed : Visibility.Visible, state, canToggle && selectable > 0, CategoryIcon(id));
    }
    private static string CategoryIcon(string? id) => id switch
    {
        "" => "tray", "application" => "storage", "browser" => "language", "developer" => "terminal", "build" => "hammer", "personal" => "configuration",
        "system" or "cache" => "drive", _ => "archive"
    };

    private async void StartCleanupScan(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        await model.DiscoverAsync();
        if (disposed) return;
        PageDiagnostics.Update(this, "cleanup", model.State, model.ErrorCode, model.ResultCount);
        LocationsPrepared?.Invoke(this, EventArgs.Empty);
        if (model.ErrorCode is null && !model.Workspaces.IsEmpty) await model.ScanAllAsync();
    });

    private void ShowLocations(object sender, RoutedEventArgs args)
    {
        if (model.NoUsableLocations && DestinationRequested is { } navigate) navigate("configuration");
        else LocationMenuButton.Flyout.ShowAt(LocationsLink);
    }

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
    private void ChangeGroupSelection(object sender, RoutedEventArgs args)
    {
        if (disposed || rendering || IsBusy || sender is not CheckBox { Tag: string id }) return;
        if (scope == CleanupReviewScope.ProjectOutputs)
        {
            var project = model.ProjectGroups.FirstOrDefault(value => value.Id == id);
            if (project is not null) model.SetProjectSelected(id, project.Selection != true);
            return;
        }
        var group = model.Groups.FirstOrDefault(value => value.RuleId == id);
        if (group is not null) model.SetGroupSelected(id, group.Selection != true);
    }
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

    private async void ExecuteCleanup(object sender, RoutedEventArgs args) => await GuardAsync(async () =>
    {
        if (IsBusy || !execution.ExecutionAvailable) return;
        if (!model.CanPreparePlan) return;
        await model.PreparePlanAsync();
        if (disposed || model.Plan is not { } plan) return;
        execution.BindPlan(plan);
        if (!execution.CanExecute) return;
        activeExecution = execution.ExecuteAsync(WinUICleanupConfirmation.Create(this, plan));
        model.InvalidateConfiguration();
        BusyChanged?.Invoke(this, EventArgs.Empty);
        try { await activeExecution; }
        finally { activeExecution = null; Render(); BusyChanged?.Invoke(this, EventArgs.Empty); }
    });
    private async void ReadExecution(object sender, RoutedEventArgs args) => await GuardAsync(execution.ReadExecutionAsync);

    private void RenderCompletion()
    {
        if (execution.AttemptedPlan is not { } plan) return;
        var firstAppearance = renderedCompletion != plan.Id;
        if (firstAppearance) { renderedCompletion = plan.Id; completionDetailsVisible = false; }
        var summary = CleanupCompletionSummary.Create(plan, execution.Execution, execution.ErrorCode);
        var icon = ProductIcon.Create(summary.Complete ? "complete" : summary.Cancelled ? "paused" : "warning",
            (double)Application.Current.Resources["ShouCompletionIconSize"]);
        ProductIcon.Select(icon, (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[summary.Complete
            ? "SystemFillColorSuccessBrush" : summary.Cancelled ? "TextFillColorSecondaryBrush" : "SystemFillColorCautionBrush"]);
        CompletionIcon.Content = icon;
        CompletionTitle.Text = text.Get(summary.TitleKey);
        AutomationProperties.SetItemStatus(CompletionTitle, summary.Complete ? "completed" : summary.Cancelled ? "cancelled" : summary.HasRecord ? "partial" : "unverified");
        CompletionDescription.Text = text.Get(summary.DescriptionKey);
        CompletionDate.Text = summary.StartedAt?.ToLocalTime().ToString("g", System.Globalization.CultureInfo.CurrentCulture) ?? "";
        CompletionDate.Visibility = summary.StartedAt is null ? Visibility.Collapsed : Visibility.Visible;
        CompletionBytes.Text = StorageRow.FormatBytes(summary.RemovedBytesEstimate);
        CompletionBytes.Visibility = summary.HasRecord ? Visibility.Visible : Visibility.Collapsed;
        CompletionRemovedLabel.Text = text.Get(summary.Permanent ? "Permanently removed" : "Moved");
        CompletionRemoved.Text = summary.Removed.ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
        CompletionSkipped.Text = summary.Skipped.ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
        CompletionFailed.Text = summary.Failed.ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
        CompletionUnverified.Text = summary.Unverified.ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
        ThemeResources.Apply(CompletionFailed, TextBlock.ForegroundProperty, "Foreground", summary.Failed > 0 ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush");
        ThemeResources.Apply(CompletionUnverified, TextBlock.ForegroundProperty, "Foreground", summary.Unverified > 0 ? "SystemFillColorCautionBrush" : "TextFillColorSecondaryBrush");
        CompletionMetrics.Visibility = !summary.Complete && summary.HasRecord ? Visibility.Visible : Visibility.Collapsed;
        CompletionDetailsButton.Visibility = !summary.Complete && summary.HasRecord && !completionDetailsVisible ? Visibility.Visible : Visibility.Collapsed;
        CompletionDetails.Visibility = !summary.Complete && (!summary.HasRecord || completionDetailsVisible) ? Visibility.Visible : Visibility.Collapsed;
        CompletionScanButton.Visibility = summary.Complete ? Visibility.Collapsed : Visibility.Visible;
        CompletionHistoryButton.Visibility = !summary.Complete && summary.HasRecord ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(CompletionContent, CompletionTitle.Text);
        if (firstAppearance) CompletionBackButton.Focus(FocusState.Programmatic);
    }

    private void ShowCompletionDetails(object sender, RoutedEventArgs args) { completionDetailsVisible = true; Render(); }
    private void CloseCompletion(object sender, RoutedEventArgs args)
    {
        if (IsBusy) return;
        dismissedCompletion = execution.AttemptedPlan?.Id;
        Render();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }
    private void ScanAfterCompletion(object sender, RoutedEventArgs args)
    {
        CloseCompletion(sender, args);
        StartCleanupScan(sender, args);
    }
    private void ShowCompletionHistory(object sender, RoutedEventArgs args)
    {
        CloseCompletion(sender, args);
        HistoryRequested?.Invoke(this, EventArgs.Empty);
    }

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
                lines.Add(path + ", " + ReviewText.ItemState(text, item.State) + (item.Reason is null ? "" : ", " + ReviewText.Error(text, item.Reason)));
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
    public string Name => Row.Candidate.Path.Name;
    public string Size => StorageRow.FormatBytes(Row.Candidate.AllocatedBytes);
    public bool Selected => Row.Selected;
    public bool Selectable => Row.Selectable;
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class CleanupCategoryDisplay(string id, string title, string detail, string selectedLine, Visibility selectedVisibility, bool? selection, bool canToggle, string icon)
{
    public string Id { get; } = id;
    public string Title { get; } = title;
    public string Detail { get; } = detail;
    public string SelectedLine { get; } = selectedLine;
    public Visibility SelectedVisibility { get; } = selectedVisibility;
    public bool? Selection { get; } = selection;
    public bool CanToggle { get; } = canToggle;
    public string Icon { get; } = icon;
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class CleanupFilterDisplay(string? id, string title)
{
    public string? Id { get; } = id;
    public string Title { get; } = title;
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class CleanupRuleDisplay(string id, string title, bool? selection, bool canToggle, CleanupCandidateDisplay[] items, string count, string size,
    string selectedSize, Visibility selectedVisibility, string notice, string path = "")
{
    public string Id { get; } = id; public string Title { get; } = title;
    public string SelectionLabel => (string.IsNullOrEmpty(Path) ? Title : Path) + ", " + Count;
    public bool? Selection { get; } = selection; public bool CanToggle { get; } = canToggle;
    public CleanupCandidateDisplay[] Items { get; } = items;
    public string Count { get; } = count; public string Size { get; } = size;
    public string SelectedSize { get; } = selectedSize; public Visibility SelectedVisibility { get; } = selectedVisibility;
    public string Notice { get; } = notice;
    public string Path { get; } = path;
    public Visibility PathVisibility => string.IsNullOrEmpty(Path) ? Visibility.Collapsed : Visibility.Visible;
    public Visibility NoticeVisibility => string.IsNullOrEmpty(Notice) ? Visibility.Collapsed : Visibility.Visible;
    public Microsoft.UI.Xaml.Media.Brush NoticeForeground => (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
        CanToggle && Items.Any(item => item.Row.Candidate.Risk == "high") ? "SystemFillColorCautionBrush" : "TextFillColorSecondaryBrush"];
}
