using System.ComponentModel;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;
using Microsoft.Windows.Storage.Pickers;

namespace Shou.Windows.App;

public sealed partial class ConfigurationPage : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);
    private readonly BuiltinRuleCatalog catalog;
    private readonly TextCatalog text = new();
    private readonly ConfigurationViewModel model;
    private readonly nint windowHandle;
    private bool rendering;
    private bool interacting;
    private bool disposed;
    private Task? initialLoad;
    private string? interactionError;
    private CancellationTokenSource? ruleRead;
    public event EventHandler? EvidenceInvalidated;
    public event EventHandler? BusyChanged;
    public bool IsBusy => model.IsBusy || interacting;

    public ConfigurationPage(IConfigurationOperations operations, nint windowHandle, BuiltinRuleCatalog catalog)
    {
        InitializeComponent();
        this.windowHandle = windowHandle;
        this.catalog = catalog;
        model = new(operations, catalog);
        PageTitle.Text = text.Get("Cleanup Rules");
        CatalogBanner.Text = text.Get("Customize cleanup rules for Windows");
        LocationLabel.Text = text.Get("Scan Location"); SourceLabel.Text = text.Get("Rule Source"); CatalogHeading.Text = text.Get("Cleanup Rules");
        Description.Text = text.Get("Browse the rule catalog. Choose a scan location to change applicable rules.");
        ExclusionsButton.Content = text.Get("Exclusions"); AdvancedButton.Content = text.Get("Rule Versions and Locations");
        SourceFilter.ItemsSource = new[] { text.Get("All"), text.Get("Built-in Rules"), text.Get("Personal Rules") };
        SourceFilter.SelectedIndex = 0; CatalogSearch.PlaceholderText = text.Get("Search rules or paths");
        AutomationProperties.SetName(SourceFilter, text.Get("Rule Source")); AutomationProperties.SetName(CatalogSearch, text.Get("Search rules or paths"));
        ImportButton.Content = text.Get("Import Rule…");
        RefreshButton.Content = text.Get("Refresh");
        RulesHeading.Text = text.Get("Cleanup Rules");
        Rules.PlaceholderText = text.Get("Choose a rule version");
        AutomationProperties.SetName(Rules, text.Get("Cleanup Rules"));
        EnableButton.Content = text.Get("Enable Selected Version");
        DisableButton.Content = text.Get("Disable Selected Version");
        LocationsHeading.Text = text.Get("Scan Locations");
        Locations.PlaceholderText = text.Get("Scan Locations");
        AutomationProperties.SetName(Locations, text.Get("Scan Locations"));
        AddLocationButton.Content = text.Get("Choose Folder for This Rule…");
        RemoveLocationButton.Content = text.Get("Remove Scan Location");
        LocationsNotice.Text = text.Get("Importing a rule does not change which version is enabled. A location already used by the rule is selected automatically.");
        ExclusionsHeading.Text = text.Get("Exclusions");
        ExclusionScope.ItemsSource = new[] { text.Get("All Scan Locations"), text.Get("Selected Scan Location"), text.Get("Project in Selected Location") };
        ExclusionScope.SelectedIndex = 0;
        AutomationProperties.SetName(ExclusionScope, text.Get("Exclusion Scope"));
        ExclusionsNotice.Text = text.Get("Global protections also apply to future locations. Excluded content protects the whole containing cleanup target.");
        ProjectPath.Header = text.Get("Project folder relative to the scan location");
        ProjectPath.PlaceholderText = "apps/demo";
        ExclusionPattern.Header = text.Get("Relative exclusion pattern");
        ExclusionPattern.PlaceholderText = "**/keep";
        AddExclusionButton.Content = text.Get("Preview Exclusion…");
        RemoveExclusionButton.Content = text.Get("Remove Exclusion");
        AutomationProperties.SetName(Exclusions, text.Get("Exclusions"));
        model.PropertyChanged += Changed;
        model.EvidenceInvalidated += InvalidateEvidence;
        Render();
    }

    public Task EnsureLoadedAsync() => initialLoad ??= model.LoadAsync();
    public void ShowScanLocations()
    {
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (disposed || IsBusy || !Locations.IsLoaded) return;
            Locations.Focus(FocusState.Programmatic); Locations.IsDropDownOpen = true;
        });
    }
    public void ShowExclusions()
    {
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (!disposed && !IsBusy && ExclusionsButton.IsLoaded) ExclusionsButton.Flyout.ShowAt(ExclusionsButton);
        });
    }
    public void InvalidateConfiguration() => initialLoad = null;
    private void InvalidateEvidence(object? sender, EventArgs args) => EvidenceInvalidated?.Invoke(this, args);
    private void Changed(object? sender, PropertyChangedEventArgs args) { Render(); BusyChanged?.Invoke(this, EventArgs.Empty); }
    private void Render()
    {
        if (model is null || disposed || rendering) return;
        PageDiagnostics.Update(this, "configuration", model.State, model.ErrorCode);
        rendering = true;
        try
        {
            var enabled = model.CanEdit && !interacting;
            ImportButton.IsEnabled = enabled;
            RefreshButton.IsEnabled = !IsBusy;
            Rules.IsEnabled = enabled;
            Locations.IsEnabled = enabled;
            if (Rules.ItemsSource is not RuleVersionDisplay[] rules || !rules.Select(value => value.Rule).SequenceEqual(model.Rules))
                Rules.ItemsSource = model.Rules.Select(value => new RuleVersionDisplay(value)).ToArray();
            Rules.SelectedItem = ((RuleVersionDisplay[])Rules.ItemsSource).FirstOrDefault(value => value.Rule == model.SelectedRule);
            if (Locations.ItemsSource is not ScanLocationDisplay[] locations || !locations.Select(value => value.Workspace).SequenceEqual(model.Workspaces))
                Locations.ItemsSource = model.Workspaces.Select(value => new ScanLocationDisplay(value)).ToArray();
            Locations.SelectedItem = ((ScanLocationDisplay[])Locations.ItemsSource).FirstOrDefault(value => value.Workspace.Id == model.WorkspaceId);
            RuleDetails.Text = model.SelectedRule is { } rule ? text.Get(rule.Builtin ? "Built-in Rules" : "Personal Rules") + "\n" + rule.Description + "\n" + text.Get(rule.Risk == "high" ? "High Risk" : "Review") : "";
            BindingStatus.Text = model.SelectedRule is null ? text.Get("Choose a rule version") : !model.SelectedRule.AppliesToWindows ? text.Get("This rule is not available on Windows.") :
                model.SelectedWorkspace is null ? text.Get("Choose a scan folder for this rule.") : model.SelectedWorkspace.RootRef != model.SelectedRule.RootReference ? text.Get("This rule does not apply to the selected scan location.") :
                model.SelectedBinding is { } binding ? text.Format(binding.Enabled ? "Enabled version: %@" : "Disabled version: %@", binding.Version) : text.Get("Not enabled for this location.");
            EnableButton.IsEnabled = !interacting && model.CanEnable;
            DisableButton.IsEnabled = !interacting && model.CanDisable;
            AddLocationButton.IsEnabled = !interacting && model.CanAddLocation;
            RemoveLocationButton.IsEnabled = enabled && model.SelectedWorkspace is not null;
            ExclusionScope.IsEnabled = enabled;
            ProjectPath.Visibility = ExclusionScope.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
            ProjectPath.IsEnabled = ExclusionPattern.IsEnabled = enabled && (AllLocations || model.SelectedWorkspace is not null);
            AddExclusionButton.IsEnabled = ExclusionPattern.IsEnabled;
            Exclusions.IsEnabled = enabled;
            var patterns = AllLocations ? model.GlobalExclusions : model.WorkspaceExclusions;
            if (Exclusions.ItemsSource is not System.Collections.Immutable.ImmutableArray<string> existing || !existing.Equals(patterns)) Exclusions.ItemsSource = patterns;
            RemoveExclusionButton.IsEnabled = enabled && Exclusions.SelectedItem is string;
            InheritedProtections.Text = !AllLocations && !model.GlobalExclusions.IsEmpty ? text.Format("Inherited global protections: %@", string.Join(", ", model.GlobalExclusions)) : "";
            Progress.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
            CatalogList.IsEnabled = enabled;
            var entries = model.Snapshot is { } configuration ? RuleCatalog.Read(catalog, configuration, model.SelectedWorkspace, SourceFilter.SelectedIndex switch { 1 => "builtin", 2 => "personal", _ => "all" }, CatalogSearch.Text) : [];
            CatalogList.ItemsSource = entries.Select(entry => new RuleCatalogDisplay(entry, text.Get(entry.Name), text.Get(entry.Description),
                string.IsNullOrEmpty(entry.Limitation) ? "" : text.Get(entry.Limitation),
                string.IsNullOrEmpty(entry.Location) ? "" : text.Get(entry.Location), enabled)).ToArray();
            CatalogCount.Text = text.Format("%lld rules", entries.Length);
            Status.Text = model.IsSaving ? text.Get("Saving settings…") : interactionError ?? (model.RefreshErrorCode is not null ? text.Get("Settings could not be reloaded. Refresh before making more changes.") :
                model.ErrorCode is { } code ? ConfigurationError(code) : IsBusy ? text.Get("Loading…") : text.Get("Settings changes require a new scan. They do not start cleanup."));
        }
        finally { rendering = false; }
    }

    private void FilterCatalog(object sender, SelectionChangedEventArgs args) { if (model is not null && !rendering) Render(); }
    private void SearchCatalog(object sender, TextChangedEventArgs args) { if (model is not null && !rendering) Render(); }
    private async void ToggleCatalogRule(object sender, RoutedEventArgs args)
    {
        if (disposed || rendering || IsBusy || sender is not Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Tag: RuleCatalogEntry entry } toggle || toggle.IsChecked == entry.Enabled || !entry.Applicable) return;
        await GuardAsync(async () => { model.SelectRule(entry.Id, entry.Version); await model.SetRuleAsync(toggle.IsChecked == true); });
    }

    private bool AllLocations => ExclusionScope.SelectedIndex == 0;
    private void SelectRule(object sender, SelectionChangedEventArgs args)
    {
        if (!disposed && !rendering && !IsBusy && Rules.SelectedItem is RuleVersionDisplay display) model.SelectRule(display.Rule.Id, display.Rule.Version);
    }
    private void SelectLocation(object sender, SelectionChangedEventArgs args)
    {
        if (!disposed && !rendering && !IsBusy && Locations.SelectedItem is ScanLocationDisplay display) model.SelectWorkspace(display.Workspace.Id);
    }
    private void ChangeExclusionScope(object sender, SelectionChangedEventArgs args)
    {
        // XAML initialization can raise selection events before the model is constructed.
        if (model is not null && !disposed && !rendering) { Exclusions.SelectedItem = null; Render(); }
    }
    private void SelectExclusion(object sender, SelectionChangedEventArgs args) { if (!rendering && !disposed) Render(); }
    private async void RefreshConfiguration(object sender, RoutedEventArgs args) => await GuardAsync(model.LoadAsync);
    private async void EnableRule(object sender, RoutedEventArgs args) => await GuardAsync(() => model.SetRuleAsync(true));
    private async void DisableRule(object sender, RoutedEventArgs args) => await GuardAsync(() => model.SetRuleAsync(false));

    private async void ImportRule(object sender, RoutedEventArgs args) => await InteractAsync(async () =>
    {
        var picker = new FileOpenPicker(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle));
        picker.FileTypeFilter.Add(".json");
        var file = await picker.PickSingleFileAsync();
        if (disposed || file is null) return;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        ruleRead = deadline;
        try
        {
            var bytes = await new WindowsFileSystem().ReadRuleFileAsync(WindowsPath.Parse(file.Path), deadline.Token);
            if (!disposed) await model.ImportRuleAsync(bytes);
        }
        catch (OperationCanceledException) when (!disposed)
        { throw new ShouException("time_limit", "The rule file could not be read within the time limit."); }
        finally { ruleRead = null; }
    });

    private async void AddLocation(object sender, RoutedEventArgs args) => await InteractAsync(async () =>
    {
        var picker = new FolderPicker(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle));
        var folder = await picker.PickSingleFolderAsync();
        if (!disposed && folder is not null) await model.AddLocationAsync(WindowsPath.Parse(folder.Path));
    });

    private async void RemoveLocation(object sender, RoutedEventArgs args) => await InteractAsync(async () =>
    {
        if (model.SelectedWorkspace is not { } workspace) return;
        if (await ConfirmAsync(text.Get("Remove Scan Location"), workspace.Path.Value + "\n\n" + text.Get("Remove this location and its rule settings? Files and imported rules are kept."), text.Get("Remove")) && !disposed)
            await model.RemoveLocationAsync();
    });

    private async void AddExclusion(object sender, RoutedEventArgs args) => await InteractAsync(async () =>
    {
        var project = ExclusionScope.SelectedIndex == 2 ? ProjectPath.Text : null;
        var pattern = project is not null && string.IsNullOrWhiteSpace(ExclusionPattern.Text) ? "**" : ExclusionPattern.Text;
        var resolved = model.PreviewExclusion(pattern, AllLocations, project);
        var scope = AllLocations ? text.Get("All Scan Locations") : model.SelectedWorkspace!.Path.Value;
        if (await ConfirmAsync(text.Get("Preview Exclusion"), scope + "\n" + resolved + "\n\n" + text.Get("This protection applies to future scans. Scan again after saving."), text.Get("Save")) && !disposed)
        {
            await model.AddExclusionAsync(pattern, AllLocations, project);
            if (!disposed && model.ErrorCode is null && model.RefreshErrorCode is null) { ExclusionPattern.Text = ""; ProjectPath.Text = ""; }
        }
    });

    private async void RemoveExclusion(object sender, RoutedEventArgs args) => await InteractAsync(async () =>
    {
        if (Exclusions.SelectedItem is not string pattern) return;
        if (await ConfirmAsync(text.Get("Remove Exclusion"), pattern + "\n\n" + text.Get("Removing this protection requires a new scan before cleanup can be reviewed."), text.Get("Remove")) && !disposed)
            await model.RemoveExclusionAsync(pattern, AllLocations);
    });

    private async Task<bool> ConfirmAsync(string title, string message, string action)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = title, PrimaryButtonText = action, CloseButtonText = text.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private async Task InteractAsync(Func<Task> run)
    {
        if (disposed || IsBusy) return;
        interacting = true;
        Render(); BusyChanged?.Invoke(this, EventArgs.Empty);
        try { await GuardAsync(run); }
        finally
        {
            interacting = false;
            if (!disposed) { Render(); BusyChanged?.Invoke(this, EventArgs.Empty); }
        }
    }
    private async Task GuardAsync(Func<Task> run)
    {
        interactionError = null;
        try { await run(); }
        catch (Exception error)
        {
            NativeDiagnostics.Write(error);
            if (!disposed) interactionError = ConfigurationError(error is ShouException known ? known.Code : null);
        }
        if (!disposed) Render();
    }
    private string ConfigurationError(string? code) => code switch
    {
        "invalid_rule" => text.Get("This rule could not be validated. Check its JSON and supported platform."),
        "version_conflict" => text.Get("This rule version already has different content. Import a new version instead."),
        "invalid_argument" or "invalid_path" or "invalid_pattern" => text.Get("Check the selected location and relative paths. A rule's location reference can be registered only once."),
        "resource_limit" => text.Get("The rule or settings exceed the supported size limit."),
        "time_limit" or "unsafe_path" or "unsupported_location" or "not_found" or "source_changed" => text.Get("The rule file could not be read. Choose a local file and try again."),
        _ => ReviewText.Error(text, code)
    };
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        model.PropertyChanged -= Changed;
        model.EvidenceInvalidated -= InvalidateEvidence;
        ruleRead?.Cancel();
        ruleRead = null;
        model.Dispose();
        GC.SuppressFinalize(this);
    }
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class RuleVersionDisplay(RuleVersionChoice rule)
{
    public RuleVersionChoice Rule { get; } = rule;
    public string Label => Rule.Label;
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class ScanLocationDisplay(Workspace workspace)
{
    public Workspace Workspace { get; } = workspace;
    public string Path => Workspace.Path.Value;
}

[Microsoft.UI.Xaml.Data.Bindable]
public sealed class RuleCatalogDisplay(RuleCatalogEntry entry, string name, string summary, string limitation, string location, bool editable)
{
    public RuleCatalogEntry Entry { get; } = entry;
    public string Name { get; } = name; public string Summary { get; } = summary;
    public string Limitation { get; } = limitation; public string Location { get; } = location;
    public string Patterns => Entry.Patterns; public bool Enabled => Entry.Enabled; public bool CanToggle => editable && Entry.Applicable;
}
