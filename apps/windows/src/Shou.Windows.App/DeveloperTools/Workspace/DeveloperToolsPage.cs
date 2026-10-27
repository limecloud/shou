using System.Collections.Immutable;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class DeveloperToolsPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly DeveloperToolCatalog catalog = WindowsDeveloperTools.LoadCatalog();
    private readonly DeveloperToolService service;
    private readonly bool ai;
    private readonly nint windowHandle;
    private DeveloperLogsView? logsView;
    private bool showLogs;
    private readonly StackPanel header = new() { Spacing = 12 };
    private readonly StackPanel rail = new() { Spacing = 6 };
    private readonly List<ToggleSwitch> switches = [];
    private readonly DeveloperServiceController serviceController;
    private DeveloperServiceSnapshot? services;
    private string sourceFilter = "all";
    private string? changingServiceId;
    private DeveloperServiceAction? changingServiceAction;
    private readonly StackPanel content = new() { Spacing = 16 };
    private readonly StackPanel footer = new() { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly TextBox search = new() { MaxLength = 256, Width = 260 };
    private readonly StackPanel collection = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
    private int collectionIndex = 2;
    private readonly CheckBox installedOnly = new();
    private readonly Grid workspaceGrid = new();
    private readonly Button scan = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly ProgressBar progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    private readonly HashSet<string> favorites = new(StringComparer.Ordinal);
    private readonly List<Button> commands = [];
    private readonly CancellationTokenSource lifetime = new();
    private DeveloperToolInventory? inventory;
    private DeveloperToolDefinition? focused;
    private DeveloperToolPackage? package;
    private DeveloperToolInspection? inspection;
    private DeveloperToolPlan? plan;
    private DeveloperToolResult? result;
    private AIWorkspaceSnapshot? workspace;
    private bool workspaceLoading;
    private bool showWorkspace;
    private int workspaceRevision;
    private bool busy, disposed;
    private string? serviceStage;
    private DeveloperServiceResult? serviceResult;
    private bool inventoryLoading, servicesLoading;
    private CancellationTokenSource? serviceRead;
    private HashSet<string> serviceReadToolIds = new(StringComparer.Ordinal);
    private readonly HashSet<string> loadedServiceTools = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> serviceObservationDates = new(StringComparer.Ordinal);
    internal bool HasActiveMutation { get; private set; }
    internal event EventHandler? BusyChanged;

    internal DeveloperToolsPage(nint windowHandle, bool ai = false)
    {
        this.ai = ai; this.windowHandle = windowHandle; FontSize = Size("ShouBodyFontSize");
        service = new(catalog, new WindowsDeveloperTools(), WindowsRecordStore.ForCurrentUser);
        serviceController = new(catalog, new WindowsDeveloperServices(), WindowsRecordStore.ForCurrentUser);
        var root = new Grid();
        root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new()); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var inset = (double)Application.Current.Resources["ShouWorkspaceInset"];
        header.Margin = new(inset, 12, inset, 12);
        search.PlaceholderText = text.Get("Search developer tools"); scan.Content = text.Get("Refresh Tools & Services");
        AutomationProperties.SetAutomationId(search, "developer.search"); AutomationProperties.SetAutomationId(scan, "developer.scan");
        var filters = new Grid { ColumnSpacing = 12 };
        filters.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); filters.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        filters.ColumnDefinitions.Add(new()); filters.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(WorkspaceVisuals.Artwork("projects", 44, 36));
        filters.Children.Add(title); Grid.SetColumn(collection, 1); filters.Children.Add(collection);
        search.HorizontalAlignment = HorizontalAlignment.Right; Grid.SetColumn(search, 2); filters.Children.Add(search);
        Grid.SetColumn(scan, 3); filters.Children.Add(scan); header.Children.Add(filters); root.Children.Add(header);
        var feedback = new StackPanel { Spacing = 8, Margin = new(inset, 0, inset, 8) };
        feedback.Children.Add(progress); feedback.Children.Add(status); Grid.SetRow(feedback, 1); root.Children.Add(feedback);
        installedOnly.Content = text.Get("Installed Only");
        installedOnly.Checked += (_, _) => Render(); installedOnly.Unchecked += (_, _) => Render();
        workspaceGrid.ColumnDefinitions.Add(new() { Width = new((double)Application.Current.Resources["ShouToolRailWidth"]) }); workspaceGrid.ColumnDefinitions.Add(new());
        rail.Margin = new(12);
        workspaceGrid.Children.Add(new ScrollViewer { Content = rail, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        var scroll = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        content.Margin = new(inset, 12, inset, 20); Grid.SetColumn(scroll, 1); workspaceGrid.Children.Add(scroll);
        Grid.SetRow(workspaceGrid, 2); root.Children.Add(workspaceGrid);
        void Fit() { content.Width = Math.Max(0, scroll.ViewportWidth - 2 * inset); search.Width = ActualWidth < 1080 ? 160 : 260; }
        scroll.SizeChanged += (_, _) => Fit(); scroll.Loaded += (_, _) => Fit();
        footer.Margin = new(inset, 12, inset, 16); Grid.SetRow(footer, 3); root.Children.Add(footer); Content = root;
        search.TextChanged += (_, _) => Render();
        scan.Click += async (_, _) => await ScanAsync();
        Render();
    }
    internal async Task EnsureLoadedAsync()
    {
        try
        {
            var stored = await WindowsRecordStore.ForCurrentUser().ReadAsync("developer_tool_favorites", 64 * 1024, lifetime.Token);
            if (stored is not null) foreach (var id in JsonSerializer.Deserialize<string[]>(stored) ?? []) favorites.Add(id);
        }
        catch (Exception error) when (error is not OutOfMemoryException) { NativeDiagnostics.Write(error); }
        if (!disposed && inventory is null) await ScanAsync();
    }
    private async Task ScanAsync()
    {
        if (busy || disposed || inventoryLoading) return;
        inspection = null; plan = null; result = null;
        serviceRead?.Cancel(); servicesLoading = false; loadedServiceTools.Clear(); InvalidateServiceObservations();
        inventoryLoading = true; scan.IsEnabled = false; progress.Visibility = Visibility.Visible;
        status.Text = text.Get("Scanning Installed Tools…"); Render();
        try
        {
            var updates = new Progress<DeveloperToolInventory>(value => { if (!disposed && inventoryLoading) { inventory = value; Render(); } });
            inventory = await new WindowsDeveloperToolInventory().ScanAsync(catalog, lifetime.Token, updates);
            if (!disposed) status.Text = inventory.Issues.IsEmpty ? text.Get("Installed tool discovery finished.") :
                text.Get("Some sources could not be read.");
        }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!disposed) ShowError(error); }
        finally { inventoryLoading = false; if (!disposed) { scan.IsEnabled = !busy; progress.Visibility = Visibility.Collapsed; Render(); } }
        if (!disposed) await LoadServicesAsync();
    }
    private DeveloperToolInstallation[] Installations(string id) => inventory?.Installations.Where(r => r.ToolId == id).ToArray() ?? [];
    private DeveloperService[] ToolServices(string id) => services?.Services.Where(r => r.ToolId == id).ToArray() ?? [];
    private void Render()
    {
        if (disposed) return;
        content.Children.Clear(); rail.Children.Clear(); footer.Children.Clear(); commands.Clear(); switches.Clear();
        collection.Children.Clear();
        foreach (var (index, key) in new[] { (2, "My Workspace"), (0, "Add Tools") })
        {
            var choice = Command(key, () => { collectionIndex = index; inspection = null; plan = null; Render(); if (collectionIndex == 2) _ = LoadServicesAsync(); });
            choice.CornerRadius = (CornerRadius)Application.Current.Resources["ShouControlRadius"];
            if (index == collectionIndex) choice.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            AutomationProperties.SetAutomationId(choice, "developer.collection." + index);
            collection.Children.Add(choice);
        }
        if (collectionIndex == 0) collection.Children.Add(installedOnly);
        workspaceGrid.ColumnDefinitions[0].Width = collectionIndex == 0 ? new(0) : new((double)Application.Current.Resources["ShouToolRailWidth"]);
        footer.Visibility = plan is null ? Visibility.Collapsed : Visibility.Visible;
        var tools = catalog.Tools.Where(t => t.IsAI == ai &&
            (collectionIndex != 0 || installedOnly.IsChecked != true || Installations(t.Id).Length > 0 || ToolServices(t.Id).Length > 0) && (collectionIndex != 2 || favorites.Contains(t.Id)) &&
            (search.Text.Length == 0 || t.Name.Contains(search.Text, StringComparison.OrdinalIgnoreCase) || t.Id.Contains(search.Text, StringComparison.OrdinalIgnoreCase))).ToArray();
        if (collectionIndex == 0) { RenderCatalog(tools); return; }
        foreach (var group in catalog.Categories)
        {
            var rows = tools.Where(t => t.Category == group.Id).ToArray(); if (rows.Length == 0) continue;
            var label = Caption(text.Get(group.Title)); label.Margin = new(10, 12, 0, 4); rail.Children.Add(label);
            foreach (var tool in rows)
            {
                var row = new Grid { ColumnSpacing = 4 }; row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                var button = Command(tool.Name, () => Open(tool), "developer.tool." + tool.Id); button.HorizontalAlignment = HorizontalAlignment.Stretch;
                button.HorizontalContentAlignment = HorizontalAlignment.Left; button.MinHeight = 48;
                var buttonBody = new StackPanel { Spacing = 3 }; buttonBody.Children.Add(Label(tool.Name)); buttonBody.Children.Add(Caption(text.Get(ToolStatus(tool.Id)))); button.Content = buttonBody;
                if (focused?.Id == tool.Id) ThemeResources.Apply(button, Control.BackgroundProperty, "Background", "ShouNavSelectionBrush");
                var flyout = new MenuFlyout(); var pin = new MenuFlyoutItem { Text = text.Get("Remove from Workspace") };
                pin.Click += (_, _) => _ = ToggleFavoriteAsync(tool.Id); flyout.Items.Add(pin); button.ContextFlyout = flyout; row.Children.Add(button);
                var sources = ToolServices(tool.Id);
                if (sources.Length == 1) { var toggle = ServiceSwitch(sources[0], showProgress: false); Grid.SetColumn(toggle, 1); row.Children.Add(toggle); }
                else if (sources.Length > 1) { var multiple = Caption(text.Get("Multiple Services")); Grid.SetColumn(multiple, 1); row.Children.Add(multiple); }
                rail.Children.Add(row);
            }
        }
        if (focused is null || !tools.Any(t => t.Id == focused.Id))
        {
            if (tools.FirstOrDefault() is { } first) { Open(first); return; }
            focused = null; rail.Children.Add(Label("No matching developer tools."));
            content.Children.Add(WorkspaceVisuals.Artwork("projects", 180, 130)); content.Children.Add(Label("Add tools to your workspace"));
            content.Children.Add(Command("Add Tools", () => { search.Text = ""; collectionIndex = 0; Render(); }, "developer.workspace.add")); return;
        }
        RenderDetail();
    }
    private FrameworkElement ServiceSwitch(DeveloperService value, bool showProgress = true)
    {
        if (changingServiceId == value.Id) return showProgress ? new ProgressRing { IsActive = true, Width = 32, Height = 32 } : Caption("");
        if (value.State is not ("running" or "stopped")) return Caption(text.Get("Unknown"));
        var toggle = new ToggleSwitch { IsOn = value.State == "running", OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = !busy && !inventoryLoading && !servicesLoading && value.Controllable && WindowsDeveloperServices.PublicExecutionAvailable, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(toggle, "developer.service." + value.Id);
        AutomationProperties.SetName(toggle, text.Get(value.State == "running" ? "Stop Service" : "Start Service") + ", " + value.Name + ", " + value.Source);
        ToolTipService.SetToolTip(toggle, value.Source + ", " + value.Version + "\n" + value.InstallationPath + "\n" + text.Get(WindowsDeveloperServices.PublicExecutionAvailable ?
            "Start or stop this service now. Existing login-start registration is preserved." : "Windows service control requires native acceptance. Current status is read-only."));
        toggle.Toggled += (_, _) => { if (toggle.IsEnabled && toggle.IsOn != (value.State == "running")) _ = ChangeServiceAsync(value, toggle.IsOn ? DeveloperServiceAction.Start : DeveloperServiceAction.Stop); };
        switches.Add(toggle); return toggle;
    }
    private void RenderCatalog(DeveloperToolDefinition[] tools)
    {
        foreach (var group in catalog.Categories)
        {
            var rows = tools.Where(t => t.Category == group.Id).ToArray();
            if (rows.Length == 0) continue;
            content.Children.Add(Label(group.Title));
            var grid = new Grid { ColumnSpacing = 20 };
            var columns = ActualWidth >= 920 ? 2 : 1;
            for (var column = 0; column < columns; column++) grid.ColumnDefinitions.Add(new());
            for (var index = 0; index < rows.Length; index++)
            {
                var tool = rows[index];
                if (index % columns == 0) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
                var row = new Grid { ColumnSpacing = 12, Padding = new(12, 14, 12, 14) };
                row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                var identity = new StackPanel { Spacing = 5 };
                identity.Children.Add(Label(tool.Name)); identity.Children.Add(Caption(text.Get(ToolStatus(tool.Id))));
                var origins = Installations(tool.Id).Select(i => text.Get(i.Source)).Distinct(StringComparer.Ordinal);
                identity.Children.Add(Caption(string.Join(" / ", origins))); row.Children.Add(identity);
                var toggle = new ToggleSwitch { IsOn = favorites.Contains(tool.Id), OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center, IsEnabled = !busy };
                AutomationProperties.SetAutomationId(toggle, "developer.workspace.select." + tool.Id);
                AutomationProperties.SetName(toggle, text.Get(favorites.Contains(tool.Id) ? "Remove from Workspace" : "Add to Workspace") + ", " + tool.Name);
                toggle.Toggled += (_, _) => { if (toggle.IsEnabled) _ = ToggleFavoriteAsync(tool.Id); };
                Grid.SetColumn(toggle, 1); row.Children.Add(toggle);
                Grid.SetRow(row, index / columns); Grid.SetColumn(row, index % columns); grid.Children.Add(row);
            }
            content.Children.Add(grid);
        }
        if (tools.Length == 0) content.Children.Add(Label("No matching developer tools."));
    }
    private Task RefreshServicesAsync() => LoadServicesAsync(force: true);
    private async Task LoadServicesAsync(bool force = false)
    {
        if (busy || inventoryLoading || inventory is null || disposed || servicesLoading) return;
        var requested = catalog.Tools.Where(t => t.IsAI == ai && favorites.Contains(t.Id) && (force || !loadedServiceTools.Contains(t.Id))).Select(t => t.Id).ToHashSet(StringComparer.Ordinal);
        if (requested.Count == 0) return;
        serviceRead?.Dispose();
        var read = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); serviceRead = read;
        serviceReadToolIds = requested; servicesLoading = true;
        if (services is not null) services = services with { Services = services.Services.Select(row => requested.Contains(row.ToolId) ? row with { Issue = "developer_service_refresh_required" } : row).ToImmutableArray() };
        Render();
        try
        {
            var observed = await serviceController.ScanAsync(inventory, read.Token, toolIds: requested);
            if (read.IsCancellationRequested || disposed) return;
            var retained = services?.Services.Where(row => !requested.Contains(row.ToolId)) ?? [];
            services = new(retained.Concat(observed.Services).ToImmutableArray(), observed.Issues);
            foreach (var id in requested) { serviceObservationDates[id] = DateTimeOffset.Now; loadedServiceTools.Add(id); }
        }
        catch (OperationCanceledException) when (read.IsCancellationRequested) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!read.IsCancellationRequested && !disposed) ShowError(error); }
        finally { if (ReferenceEquals(serviceRead, read)) { servicesLoading = false; serviceReadToolIds.Clear(); if (!disposed) Render(); } }
        if (requested.All(loadedServiceTools.Contains) && !disposed) await LoadServicesAsync();
    }
    private string ServiceState(DeveloperService row) => changingServiceId == row.Id ? serviceStage switch { "checking" => "Checking Service…", "stopping" => "Stopping…", "stopped" => "Service stopped. Starting…", "starting" => "Starting…", _ => "Verifying Service…" } : row.State switch { "running" => "Running", "stopped" => "Stopped", "starting" => "Starting…", "stopping" => "Stopping…", _ => "State Unknown" };
    private void InvalidateServiceObservations()
    {
        if (services is not null) services = services with { Services = services.Services.Select(row => row with { Issue = "developer_service_refresh_required" }).ToImmutableArray() };
    }
    private static string ServiceFailureMessage(string? stage) => stage switch
    {
        "stopping" => "Stopping failed. No new instance was started.",
        "starting" => "Starting failed. Check the service log before retrying.",
        "verifying" => "The requested state could not be verified. Refresh status before retrying.",
        _ => "The service could not be verified before the action. Refresh status before retrying."
    };
    private string ToolStatus(string id)
    {
        var rows = ToolServices(id); if (rows.Length == 1) return ServiceState(rows[0]); if (rows.Length > 1) return "Multiple Services";
        var copies = Installations(id); return copies.Length == 0 ? inventory is null ? "Not inspected" : "Not found in scanned sources" : copies.Any(r => r.Status == "registered") ? "Installed" : "Detected executable";
    }
    private FrameworkElement ServiceActions(DeveloperService value)
    {
        var body = new StackPanel { Spacing = 6 }; body.Children.Add(Caption(text.Get(ServiceState(value))));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 }; actions.Children.Add(ServiceSwitch(value));
        var restart = Command("Restart Service", () => _ = ChangeServiceAsync(value, DeveloperServiceAction.Restart), "developer.restart." + value.Id);
        restart.Content = new FontIcon { Glyph = "\uE777", FontSize = 14 }; AutomationProperties.SetName(restart, text.Get("Restart Service")); ToolTipService.SetToolTip(restart, text.Get("Restart Service"));
        restart.IsEnabled = !busy && !inventoryLoading && !servicesLoading && value.Controllable && value.State == "running" && WindowsDeveloperServices.PublicExecutionAvailable;
        if (changingServiceId != value.Id) actions.Children.Add(restart); body.Children.Add(actions); return body;
    }
    private async Task ChangeServiceAsync(DeveloperService expected, DeveloperServiceAction action)
    {
        if (busy || !favorites.Contains(expected.ToolId) || inventoryLoading || servicesLoading || !WindowsDeveloperServices.PublicExecutionAvailable) return;
        changingServiceId = expected.Id; changingServiceAction = action; serviceStage = "checking"; serviceResult = null; HasActiveMutation = true; SetBusy(true); Render();
        status.Text = text.Get("Waiting for the service to reach its requested state…");
        try
        {
            var progress = new Progress<DeveloperServiceProgress>(value => { if (!disposed && changingServiceId == value.ServiceId) { serviceStage = value.Stage; status.Text = text.Get(ServiceState(expected)); } });
            var outcome = await serviceController.PerformAsync(action, expected, lifetime.Token, progress);
            serviceResult = outcome;
            status.Text = text.Get(outcome.State == "succeeded" ? action == DeveloperServiceAction.Restart ? "Service restarted and verified." : "Service state verified." : outcome.State == "partial" ? "The service stopped, but restart did not finish. Refresh its source before continuing." : "The service result needs verification. Refresh its source; Shou will not retry automatically.");
            if (outcome.State == "succeeded" && services is not null && outcome.Observed is { } verified)
                services = services with { Services = services.Services.Select(row => row.Id == expected.Id ? verified : row).ToImmutableArray() };
            else if (services is not null && outcome.Observed is { } observed)
                services = services with { Services = services.Services.Select(row => row.Id == expected.Id ? observed with { Issue = "developer_service_refresh_required" } : row).ToImmutableArray() };
            if (outcome.FailureCode is not null) status.Text += ", " + outcome.FailureCode;
            serviceObservationDates[expected.ToolId] = DateTimeOffset.Now;
        }
        catch (Exception error) when (error is not OutOfMemoryException) { InvalidateServiceObservations(); ShowError(error); }
        finally { changingServiceId = null; changingServiceAction = null; serviceStage = null; HasActiveMutation = false; if (!disposed) { SetBusy(false); Render(); } }
    }
    private void Open(DeveloperToolDefinition tool)
    {
        if (busy) return;
        logsView?.Dispose(); logsView = null; showLogs = false;
        focused = tool; package = tool.Packages.FirstOrDefault(p => p.Provider == "winget"); inspection = null; plan = null; result = null; serviceResult = null; workspace = null; showWorkspace = false; sourceFilter = "all"; status.Text = ""; Render();
        _ = LoadWorkspaceAsync();
        _ = LoadServicesAsync();
    }
    private void RenderDetail()
    {
        var tool = focused!;
        var heading = new Grid { ColumnSpacing = 12 };
        heading.ColumnDefinitions.Add(new()); heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var identity = new StackPanel { Spacing = 5 };
        identity.Children.Add(new TextBlock { Text = text.Get(tool.Name), FontSize = Size("ShouToolTitleSize"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        heading.Children.Add(identity);
        var favorite = Command("Remove from Workspace", () => _ = ToggleFavoriteAsync(tool.Id), "developer.workspace.remove." + tool.Id);
        Grid.SetColumn(favorite, 1); heading.Children.Add(favorite);
        var guide = new HyperlinkButton { Content = text.Get("Official Guide"), NavigateUri = new Uri(tool.Homepage) };
        Grid.SetColumn(guide, 2); heading.Children.Add(guide); content.Children.Add(heading);
        if (!ai)
        {
            var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            var versions = Command("Installation & Versions", () => { showLogs = false; Render(); }, "developer.tab.versions");
            var logs = Command("Logs", () => { showLogs = true; Render(); }, "developer.tab.logs");
            versions.IsEnabled = logs.IsEnabled = !busy && plan is null;
            (showLogs ? logs : versions).Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            tabs.Children.Add(versions); tabs.Children.Add(logs); content.Children.Add(tabs);
            if (showLogs)
            {
                if (logsView is null)
                {
                    logsView = new(tool.Id, windowHandle, value => { HasActiveMutation = value; SetBusy(value); if (!value) Render(); });
                    _ = logsView.DiscoverAsync(Installations(tool.Id).ToImmutableArray(), ToolServices(tool.Id).ToImmutableArray());
                }
                content.Children.Add(logsView); return;
            }
        }
        if (AIWorkspaceSummary.Supports(tool.Id))
        {
            var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            var installationTab = Command("Installation & Versions", () => { showWorkspace = false; Render(); });
            var configurationTab = Command("Configuration & Extensions", () => { showWorkspace = true; Render(); });
            installationTab.IsEnabled = configurationTab.IsEnabled = !busy && plan is null;
            (showWorkspace ? configurationTab : installationTab).Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            tabs.Children.Add(installationTab); tabs.Children.Add(configurationTab); content.Children.Add(tabs);
            if (showWorkspace) { RenderWorkspace(); return; }
        }
        var copies = Installations(tool.Id);
        var sources = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var source in new[] { "all" }.Concat(copies.Select(r => r.Source).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)))
        {
            var chip = Command(source == "all" ? "All Sources" : source, () => { sourceFilter = source; inspection = null; Render(); });
            chip.CornerRadius = (CornerRadius)Application.Current.Resources["ShouControlRadius"]; chip.IsEnabled = !busy && plan is null;
            if (sourceFilter == source) chip.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            sources.Children.Add(chip);
        }
        content.Children.Add(new ScrollViewer { Content = sources, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        if (copies.Length > 0)
        {
            var installed = new StackPanel { Spacing = 12 }; installed.Children.Add(Label("Existing Installations"));
            Grid TableRow() { var row = new Grid { ColumnSpacing = 12 }; row.ColumnDefinitions.Add(new() { Width = new((double)Application.Current.Resources["ShouToolVersionWidth"]) }); row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new() { Width = new((double)Application.Current.Resources["ShouToolSourceWidth"]) }); row.ColumnDefinitions.Add(new() { Width = new((double)Application.Current.Resources["ShouToolServiceWidth"]) }); return row; }
            var titles = TableRow(); var keys = new[] { "Version", "Path", "Installation Source", "Service" };
            for (var index = 0; index < keys.Length; index++) { var label = Caption(text.Get(keys[index])); Grid.SetColumn(label, index); titles.Children.Add(label); } installed.Children.Add(titles);
            foreach (var copy in copies.Where(r => sourceFilter == "all" || r.Source == sourceFilter))
            {
                var row = TableRow(); row.Children.Add(Label(copy.Version ?? "Version not verified"));
                var paths = new StackPanel { Spacing = 6 }; paths.Children.Add(new TextBlock { Text = copy.Path, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                if (!copy.LaunchPaths.IsDefaultOrEmpty) paths.Children.Add(Caption(text.Get("Launch Paths") + "\n" + string.Join("\n", copy.LaunchPaths)));
                Grid.SetColumn(paths, 1); row.Children.Add(paths); var origin = Label(copy.Source); Grid.SetColumn(origin, 2); row.Children.Add(origin);
                var matches = ToolServices(tool.Id).Where(s => s.Source == copy.Source && s.Version == copy.Version && s.InstallationPath.Equals(copy.Path, StringComparison.OrdinalIgnoreCase)).ToArray();
                var control = matches.Length == 1 ? Caption(text.Get(matches[0].State == "running" ? "Running" : matches[0].State == "stopped" ? "Stopped" : "State Unknown")) : matches.Length > 1 ? Caption(text.Get("Multiple Services")) : Caption("—");
                if (matches.Length == 0) ToolTipService.SetToolTip(control, text.Get("Service control is not connected for this installation."));
                var actions = new StackPanel { Spacing = 6 }; actions.Children.Add(control);
                if (WindowsDeveloperTools.PackageFor(copy, catalog) is not null)
                {
                    var uninstall = ManagementCommand("Review Uninstall", () => _ = PrepareUninstallAsync(copy), "developer.installation.uninstall." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(copy.Id))).ToLowerInvariant()[..16]);
                    uninstall.Style = (Style)Application.Current.Resources["ShouDestructiveButton"];
                    actions.Children.Add(uninstall);
                }
                Grid.SetColumn(actions, 3); row.Children.Add(actions); installed.Children.Add(row);
            }
            content.Children.Add(Surface(installed));
        }
        var serviceRows = ToolServices(tool.Id);
        {
            var serviceDetails = new StackPanel { Spacing = 12 }; serviceDetails.Children.Add(Label("Service Instances"));
            if (serviceObservationDates.TryGetValue(tool.Id, out var observed)) serviceDetails.Children.Add(Caption(text.Get("Last Checked") + ": " + observed.ToString("T", System.Globalization.CultureInfo.CurrentCulture)));
            var refresh = Command(servicesLoading ? "Checking Service…" : "Refresh Status", () => _ = RefreshServicesAsync());
            refresh.IsEnabled = !busy && !inventoryLoading && !servicesLoading; serviceDetails.Children.Add(refresh);
            foreach (var row in serviceRows)
            {
                var instance = new StackPanel { Spacing = 10 };
                instance.Children.Add(Fact("Service", row.Source + ", " + row.Version + (row.ProcessId is { } pid ? ", PID " + pid : "")));
                instance.Children.Add(ServiceActions(row));
                instance.Children.Add(new TextBlock { Text = row.ConfigurationPath, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                instance.Children.Add(Label(row.Issue is not null ? row.Issue == "developer_service_native_acceptance_pending" ? "Windows service control requires native acceptance. Current status is read-only." : "This service source or definition could not be verified. Its switch is unavailable." :
                    row.RegisteredAtLogin ? "Login startup: already registered. Restart and stop preserve this setting." : "Login startup: not registered. Starting this service runs it for the current session."));
                serviceDetails.Children.Add(Surface(instance));
            }
            if (serviceResult is { FailureCode: { } code } failed && failed.Service.ToolId == tool.Id)
            {
                serviceDetails.Children.Add(Label(ServiceFailureMessage(failed.Stage)));
                serviceDetails.Children.Add(new TextBlock { Text = code, IsTextSelectionEnabled = true });
            }
            if (serviceRows.Length == 0) serviceDetails.Children.Add(Label(inventoryLoading || servicesLoading ? "Service discovery is running in the background. You can keep browsing tools." : "No verified service instances in the scanned sources."));
            content.Children.Add(Surface(serviceDetails));
        }
        if (sourceFilter is not ("all" or "WinGet")) { content.Children.Add(Label("Native source not connected yet")); return; }
        if (result is not null) content.Children.Add(Label(result.State == "succeeded" ? "Developer tool change verified" : "Developer tool result needs verification"));
        if (package is null)
        {
            content.Children.Add(Label("Not connected. Use the official guide.")); return;
        }
        var details = new StackPanel { Spacing = 14 };
        details.Children.Add(Label(plan is null ? "Installation & Versions" : plan.Action == DeveloperToolAction.Install ? "Review Installation" : "Review Uninstall"));
        details.Children.Add(new TextBlock { Text = "WinGet, " + package.Token, IsTextSelectionEnabled = true });
        if (inspection is not null)
        {
            details.Children.Add(Fact("Installed Version", inspection.InstalledVersion ?? text.Get("Not installed by this source")));
            details.Children.Add(Fact("Available Version", inspection.AvailableVersion ?? text.Get("Unavailable")));
            details.Children.Add(Fact("Installation Scope", text.Get(inspection.Scope == ManagedPackageScope.User ? "Current user" : inspection.Scope == ManagedPackageScope.System ? "All users" : "Unknown")));
        }
        if (plan is null)
        {
            details.Children.Add(ManagementCommand("Inspect Tool", () => _ = InspectAsync(), "developer.inspect"));
            if (inspection?.Allows(DeveloperToolAction.Install) == true) details.Children.Add(ManagementCommand("Review Installation", () => _ = PrepareAsync(DeveloperToolAction.Install)));
            if (inspection?.Allows(DeveloperToolAction.Uninstall) == true) details.Children.Add(ManagementCommand("Review Uninstall", () => _ = PrepareAsync(DeveloperToolAction.Uninstall)));
        }
        else
        {
            if (plan.Action == DeveloperToolAction.Install && copies.Length > 0) details.Children.Add(Label("Other installations will be kept. This installs an additional copy from the selected source."));
            details.Children.Add(Label("Installers may request administrator approval, close applications, or change their data. Shou does not restart Windows or restore an upgrade."));
            details.Children.Add(Label("This review is valid for two minutes and can be used once."));
            footer.Children.Add(Command("Cancel", () => { plan = null; Render(); }));
            var confirm = Command(plan.Action == DeveloperToolAction.Install ? "Confirm Installation" : "Confirm Uninstall", () => _ = ExecuteAsync(), "developer.confirm");
            confirm.Style = (Style)Application.Current.Resources[plan.Action == DeveloperToolAction.Install ? "AccentButtonStyle" : "ShouDestructiveButton"];
            confirm.IsEnabled = !busy && WindowsDeveloperTools.PublicExecutionAvailable; footer.Children.Add(confirm);
        }
        if (!WindowsDeveloperTools.PublicExecutionAvailable) details.Children.Add(Label("Native installer acceptance is pending on Windows. Discovery and review are available; installation and uninstallation remain disabled."));
        content.Children.Add(Surface(details));
    }
    private async Task LoadWorkspaceAsync()
    {
        var revision = ++workspaceRevision;
        workspace = null; workspaceLoading = false;
        if (focused is not { } tool || !AIWorkspaceSummary.Supports(tool.Id)) return;
        workspaceLoading = true; Render();
        try
        {
            var observed = await new WindowsAIWorkspace().InspectAsync(tool.Id, lifetime.Token);
            if (!disposed && workspaceRevision == revision && focused?.Id == tool.Id) workspace = observed;
        }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!disposed) status.Text = text.Get("Could not inspect"); }
        finally { if (!disposed && workspaceRevision == revision && focused?.Id == tool.Id) { workspaceLoading = false; Render(); } }
    }
    private void RenderWorkspace()
    {
        var body = new StackPanel { Spacing = 14 };
        body.Children.Add(Label("Configuration & Extensions"));
        if (workspaceLoading) body.Children.Add(new ProgressBar { IsIndeterminate = true });
        foreach (var resource in workspace?.Resources ?? [])
        {
            body.Children.Add(Label(resource.Kind switch { "mcp" => "MCP Declarations", "skills" => "Installed Skills", "instructions" => "Global Instructions", _ => "Provider Configuration" }));
            body.Children.Add(Label(resource.State == "present" ? "Found" : resource.State == "missing" ? "Not found in this location" : resource.State == "partial" ? "Partial coverage" : "Could not inspect"));
            body.Children.Add(new TextBlock { Text = resource.Path, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
            if (!resource.Names.IsEmpty) body.Children.Add(new TextBlock { Text = string.Join("\n", resource.Names), TextWrapping = TextWrapping.Wrap });
            if (resource.State is "present" or "partial") body.Children.Add(Command("Open Configuration Folder", () => _ = RevealWorkspaceAsync(resource)));
        }
        body.Children.Add(Label("Known user locations; activation not verified."));
        body.Children.Add(Command("Refresh", () => _ = LoadWorkspaceAsync())); content.Children.Add(Surface(body));
    }
    private async Task RevealWorkspaceAsync(AIWorkspaceResource resource)
    {
        try
        {
            var path = resource.Kind == "skills" ? resource.Path : System.IO.Path.GetDirectoryName(resource.Path)!;
            if (!await global::Windows.System.Launcher.LaunchFolderPathAsync(path)) status.Text = text.Get("Could not open this location.");
        }
        catch (Exception error) when (error is not OutOfMemoryException) { status.Text = text.Get("Could not open this location."); }
    }
    private async Task InspectAsync()
    {
        if (busy || inventoryLoading || servicesLoading || focused is null || package is null) return;
        SetBusy(true); status.Text = text.Get("Inspecting…"); plan = null; result = null;
        try { inspection = await service.InspectAsync(focused.Id, package, lifetime.Token); status.Text = ""; }
        catch (Exception error) { inspection = null; ShowError(error); }
        finally { SetBusy(false); Render(); }
    }
    private async Task PrepareAsync(DeveloperToolAction action)
    {
        if (busy || inventoryLoading || servicesLoading || focused is null || inspection is null) return;
        SetBusy(true);
        try { plan = await service.PrepareAsync(focused.Id, action, inspection, lifetime.Token); }
        catch (Exception error) { inspection = null; ShowError(error); }
        finally { SetBusy(false); Render(); }
    }
    private async Task PrepareUninstallAsync(DeveloperToolInstallation copy)
    {
        if (busy || inventoryLoading || servicesLoading || focused?.Id != copy.ToolId || WindowsDeveloperTools.PackageFor(copy, catalog) is not { } reference) return;
        SetBusy(true); plan = null; inspection = null; result = null;
        try
        {
            if (ToolServices(copy.ToolId).Any(row => row.InstallationPath.Equals(copy.Path, StringComparison.OrdinalIgnoreCase) && row.State != "stopped"))
                throw new ShouException("developer_tool_running", "Stop the instances using this installation before uninstalling it.");
            var observed = await service.InspectAsync(copy.ToolId, reference, lifetime.Token);
            var sameLocation = observed.InstallationPath is { } location && !copy.Path.StartsWith("winget:", StringComparison.Ordinal) &&
                WindowsPath.Parse(location).SamePath(WindowsPath.Parse(copy.Path));
            if (!sameLocation || observed.InstalledVersion != copy.Version || !observed.Allows(DeveloperToolAction.Uninstall))
                throw new ShouException("developer_tool_changed", "Inspect this installation again.");
            package = reference; sourceFilter = "WinGet"; inspection = observed;
            plan = await service.PrepareAsync(copy.ToolId, DeveloperToolAction.Uninstall, observed, lifetime.Token);
        }
        catch (Exception error) { inspection = null; ShowError(error); }
        finally { SetBusy(false); Render(); }
    }
    private async Task ExecuteAsync()
    {
        if (busy || inventoryLoading || servicesLoading || plan is null || !WindowsDeveloperTools.PublicExecutionAvailable) return;
        var frozen = plan; plan = null; HasActiveMutation = true; SetBusy(true);
        status.Text = text.Get("The package manager is working. Shou will wait for its result before closing.");
        try { result = await service.ExecuteAsync(frozen, frozen.Id, lifetime.Token); inspection = null; inventory = null; inventory = await new WindowsDeveloperToolInventory().ScanAsync(catalog, lifetime.Token); }
        catch (Exception error) { ShowError(error); }
        finally { HasActiveMutation = false; SetBusy(false); Render(); }
    }
    private async Task ToggleFavoriteAsync(string id)
    {
        if (busy) return;
        if (!favorites.Add(id)) favorites.Remove(id);
        try
        {
            await WindowsRecordStore.ForCurrentUser().UpdateAsync(transaction => { transaction.Write("developer_tool_favorites", JsonSerializer.SerializeToUtf8Bytes(favorites.Order(StringComparer.Ordinal))); return true; }, lifetime.Token);
        }
        catch (Exception error) { if (!favorites.Add(id)) favorites.Remove(id); ShowError(error); }
        Render();
        if (collectionIndex == 2) await LoadServicesAsync();
    }
    private void SetBusy(bool value)
    {
        busy = value; scan.IsEnabled = !value && !inventoryLoading; search.IsEnabled = !value;
        foreach (var command in commands) command.IsEnabled = !value;
        foreach (var toggle in switches) toggle.IsEnabled = false;
        progress.Visibility = value && changingServiceId is null ? Visibility.Visible : Visibility.Collapsed; BusyChanged?.Invoke(this, EventArgs.Empty);
    }
    private void ShowError(Exception error) { NativeDiagnostics.Write(error); if (!disposed) status.Text = text.Get("The tool could not be inspected or changed. Use its official guide or inspect again."); }
    private Button Command(string key, Action action, string? id = null)
    {
        var button = new Button { Content = text.Get(key), IsEnabled = !busy };
        if (id is not null) AutomationProperties.SetAutomationId(button, id);
        button.Click += (_, _) => { if (!busy) action(); }; commands.Add(button); return button;
    }
    private Button ManagementCommand(string key, Action action, string? id = null)
    {
        var button = Command(key, action, id); button.IsEnabled = !busy && !inventoryLoading && !servicesLoading; return button;
    }
    private TextBlock Label(string key) => new() { Text = text.Get(key), FontSize = Size("ShouBodyFontSize"), TextWrapping = TextWrapping.Wrap };
    private static TextBlock Caption(string value) { var label = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, FontSize = Size("ShouCaptionFontSize") }; ThemeResources.Apply(label, TextBlock.ForegroundProperty, "Foreground", "ShouSecondaryTextBrush"); return label; }
    private FrameworkElement Fact(string key, string value)
    {
        var row = new Grid { ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new() { Width = new(150) }); row.ColumnDefinitions.Add(new());
        row.Children.Add(Caption(text.Get(key)));
        var detail = new TextBlock { Text = value, FontSize = Size("ShouBodyFontSize"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        Grid.SetColumn(detail, 1); row.Children.Add(detail); return row;
    }
    private static double Size(string key) => (double)Application.Current.Resources[key];
    private static Border Surface(UIElement child)
    {
        var border = new Border { Child = child, Padding = new(18), CornerRadius = (CornerRadius)Application.Current.Resources["ShouCardRadius"] };
        ThemeResources.Apply(border, Border.BackgroundProperty, "Background", "ShouSurfaceBrush"); return border;
    }
    public void Dispose() { disposed = true; logsView?.Dispose(); serviceRead?.Cancel(); serviceRead?.Dispose(); lifetime.Cancel(); lifetime.Dispose(); }
}
