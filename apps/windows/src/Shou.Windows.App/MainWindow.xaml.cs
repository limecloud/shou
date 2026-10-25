using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation;
using System.Runtime.InteropServices;
using Shou.Windows.Presentation;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

public sealed partial class MainWindow : Window
{
    private readonly TextCatalog text = new();
    private NativeReviewOperations? operations;
    private CleanupPage? cleanup;
    private CleanupPage? projects;
    private ConfigurationPage? configuration;
    private ApplicationsPage? applications;
    private StartupPage? startup;
    private PrivacyPage? privacy;
    private HistoryPage? history;
    private StoragePageView? storage;
    private StoragePageView? largeFiles;
    private SettingsPage? settings;
    private bool initialized, closed;
    private string destination = "cleanup";
    private readonly Dictionary<Button, FrameworkElement> navigationIcons = [];
    private FrameworkElement? languageIcon;
    private FrameworkElement? diskIcon;

    public MainWindow(string initialPage = "cleanup")
    {
        InitializeComponent();
        Title = "Shou";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Shou.ico"));
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleDragRegion);
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96d;
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(area.Width, (int)((double)Application.Current.Resources["ShouWindowWidth"] * scale));
        var height = Math.Min(area.Height, (int)((double)Application.Current.Resources["ShouWindowHeight"] * scale));
        AppWindow.MoveAndResize(new global::Windows.Graphics.RectInt32(
            area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
        foreach (var button in NavigationItems)
        {
            var name = (string)button.Tag;
            var icon = ProductIcon.Create(name, (double)Application.Current.Resources["ShouCompactIconSize"]);
            navigationIcons[button] = icon;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
            if (name is "history" or "settings") button.Content = icon;
            else
            {
                content.Children.Add(icon); content.Children.Add(new TextBlock { Text = PrimaryTitle(button, name), VerticalAlignment = VerticalAlignment.Center });
                button.Content = content;
            }
            AutomationProperties.SetName(button, PrimaryTitle(button, name));
            var detail = ReferenceEquals(button, CleanupDetailNavigation) || ReferenceEquals(button, ApplicationsDetailNavigation) || ReferenceEquals(button, StorageDetailNavigation);
            AutomationProperties.SetAutomationId(button, "nav." + name + (detail ? ".detail" : ""));
        }
        languageIcon = ProductIcon.Create("language", 16);
        LanguageButton.Content = languageIcon;
        diskIcon = ProductIcon.Create("drive", 14);
        DiskIcon.Content = diskIcon;
        SystemLanguageItem.Text = text.Get("Follow System");
        AutomationProperties.SetName(LanguageButton, text.Get("Interface Language"));
        WindowRoot.RequestedTheme = AppearanceSettings.Current.Theme;
        AppWindow.Closing += (_, args) =>
        {
            if (!HasMutation) return;
            args.Cancel = true;
            cleanup?.RequestCleanupStop(); projects?.RequestCleanupStop(); applications?.RequestUninstallStop(); startup?.RequestStartupStop();
            storage?.Cancel(); largeFiles?.Cancel();
            privacy?.CancelCleanup();
            ShowStatus(text.Get("Stopping at a safe boundary…"));
        };
        Closed += (_, _) =>
        {
            closed = true;
            cleanup?.Dispose(); projects?.Dispose(); configuration?.Dispose(); applications?.Dispose(); startup?.Dispose();
            privacy?.Dispose(); history?.Dispose(); storage?.Dispose(); largeFiles?.Dispose();
        };
        WindowRoot.Loaded += (_, _) => UpdateWorkspaceNavigation();
        initialized = true;
        _ = ShowPageAsync(initialPage);
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    private bool HasMutation => cleanup?.HasActiveCleanup == true || projects?.HasActiveCleanup == true || applications?.HasActiveUninstall == true || startup?.HasActiveStartupChange == true || storage?.HasActiveRemoval == true || largeFiles?.HasActiveRemoval == true || privacy?.HasActiveCleanup == true;
    private Button Item(string page) => page switch
    {
        "large" => LargeFilesNavigation, "storage" => StorageNavigation, "configuration" => ConfigurationNavigation,
        "applications" => ApplicationsNavigation, "projects" => ProjectsNavigation, "startup" => StartupNavigation, "privacy" => PrivacyNavigation,
        "history" => HistoryNavigation, "settings" => SettingsNavigation, _ => CleanupNavigation
    };

    private Button[] NavigationItems => [CleanupNavigation, LargeFilesNavigation, StorageNavigation, ConfigurationNavigation,
        ApplicationsNavigation, StartupNavigation, PrivacyNavigation, HistoryNavigation, SettingsNavigation,
        ProjectsNavigation, CleanupDetailNavigation, ApplicationsDetailNavigation, StorageDetailNavigation];
    private string TitleFor(string page) => text.Get(page switch
    {
        "large" => "Large Files", "storage" => "Space Analysis", "configuration" => "Cleanup Rules",
        "startup" => "Startup Items", "applications" => "Applications", "projects" => "Developer Projects", "privacy" => "Privacy",
        "history" => "History", "settings" => "Settings", _ => "Smart Cleanup"
    });
    private async void Navigate(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: string next }) await ShowPageAsync(next);
    }
    private async Task ShowPageAsync(string next)
    {
        if (!initialized || closed || (HasMutation || configuration?.IsBusy == true) && next != destination) return;
        using var diagnostic = Shou.Windows.Core.OperationDiagnostics.Start("navigation." + next);
        if (next != "privacy") privacy?.CancelScan();
        destination = next;
        PageTitle.Text = TitleFor(next);
        UpdateWorkspaceNavigation();
        DiskCapacity.Visibility = next is "cleanup" or "large" ? Visibility.Visible : Visibility.Collapsed;
        if (next is "cleanup" or "large") RefreshDiskCapacity();
        ShowStatus("");
        try
        {
            FrameworkElement page;
            Task load = Task.CompletedTask;
            switch (next)
            {
                case "storage":
                    if (storage is null) { storage = new(WinRT.Interop.WindowNative.GetWindowHandle(this)); storage.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = storage; break;
                case "large":
                    if (largeFiles is null) { largeFiles = new(WinRT.Interop.WindowNative.GetWindowHandle(this), largeFiles: true); largeFiles.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = largeFiles; break;
                case "cleanup":
                    if (cleanup is null)
                    {
                        operations ??= new();
                        cleanup = new(operations, operations, operations.Catalog);
                        cleanup.BusyChanged += (_, _) => UpdateNavigation();
                        cleanup.LocationsPrepared += (_, _) => configuration?.InvalidateConfiguration();
                        cleanup.DestinationRequested += async nextDestination => await ShowPageAsync(nextDestination);
                        cleanup.HistoryRequested += async (_, _) =>
                        {
                            history?.InvalidateHistory();
                            await ShowPageAsync("history");
                        };
                    }
                    page = cleanup; load = cleanup.EnsureLoadedAsync(); break;
                case "configuration":
                    if (configuration is null)
                    {
                        operations ??= new();
                        configuration = new(operations, WinRT.Interop.WindowNative.GetWindowHandle(this), operations.Catalog);
                        configuration.EvidenceInvalidated += (_, _) => { cleanup?.InvalidateConfiguration(); projects?.InvalidateConfiguration(); privacy?.InvalidateConfiguration(); };
                        configuration.BusyChanged += (_, _) => UpdateNavigation();
                    }
                    page = configuration; load = configuration.EnsureLoadedAsync(); break;
                case "projects":
                    if (projects is null)
                    {
                        operations ??= new();
                        projects = new(operations, operations, operations.Catalog, projectsOnly: true);
                        projects.BusyChanged += (_, _) => UpdateNavigation();
                        projects.LocationsPrepared += (_, _) => configuration?.InvalidateConfiguration();
                        projects.HistoryRequested += async (_, _) => { history?.InvalidateHistory(); await ShowPageAsync("history"); };
                    }
                    page = projects; load = projects.EnsureLoadedAsync(); break;
                case "applications":
                    if (applications is null) { applications = new(); applications.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = applications; break;
                case "startup":
                    if (startup is null) { startup = new(); startup.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = startup; break;
                case "privacy":
                    if (privacy is null) { privacy = new(); privacy.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = privacy; load = privacy.LoadHistoryAsync(); break;
                case "history":
                    history ??= new(operations ??= new());
                    history.InvalidateHistory();
                    page = history; load = history.EnsureLoadedAsync(); break;
                default:
                    if (settings is null)
                    {
                        settings = new();
                        settings.AppearanceChanged += (_, _) => { WindowRoot.RequestedTheme = AppearanceSettings.Current.Theme; UpdateWorkspaceNavigation(); };
                        settings.LanguageChanged += (_, _) => ((App)Application.Current).ReloadWindow("settings");
                        settings.ScanLocationsRequested += async (_, _) =>
                        {
                            await ShowPageAsync("configuration");
                            if (destination == "configuration" && WindowStatus.Text.Length == 0) configuration?.ShowScanLocations();
                        };
                        settings.ExclusionsRequested += async (_, _) =>
                        {
                            await ShowPageAsync("configuration");
                            if (destination == "configuration" && WindowStatus.Text.Length == 0) configuration?.ShowExclusions();
                        };
                    }
                    page = settings; break;
            }
            ToolbarHost.Content = null;
            var toolbar = page is IPageChrome chrome ? chrome.Toolbar : null;
            PageHeading.Content = next is "configuration" or "settings" or "history"
                ? WorkspaceVisuals.Heading(TitleFor(next), text.Get(next == "configuration" ? "One set of rules for everyday cleanup and your own projects." : next == "settings" ? "Make Shou work the way you do." : "See what changed and what needs your attention."), next == "configuration" ? "rules" : next)
                : null;
            PageHost.Content = page;
            ToolbarHost.Content = toolbar;
            UpdateNavigation();
            await load;
            diagnostic.Complete("loaded");
        }
        catch (Exception error)
        {
            diagnostic.Fail(error);
            NativeDiagnostics.Write(error);
            if (!closed) ShowStatus(text.Get("The page could not be loaded. Try again."));
        }
    }

    private void UpdateNavigation()
    {
        if (closed) return;
        var locked = HasMutation || configuration?.IsBusy == true;
        DiskCapacity.Visibility = destination == "large" || destination == "cleanup" && cleanup?.ShowingCompletion != true
            ? Visibility.Visible : Visibility.Collapsed;
        LanguageButton.IsEnabled = !locked;
        foreach (var item in NavigationItems)
            item.IsEnabled = !locked || ReferenceEquals(item, Item(destination));
        if (HasMutation) { storage?.CancelScan(); largeFiles?.CancelScan(); }
    }
    private string PrimaryTitle(Button button, string page) => ReferenceEquals(button, CleanupNavigation) ? text.Get("Cleanup") :
        ReferenceEquals(button, ApplicationsNavigation) ? text.Get("Apps & Projects") : ReferenceEquals(button, ConfigurationNavigation) ? text.Get("Rules") : TitleFor(page);
    private static string Family(string page) => page switch
    {
        "privacy" => "cleanup", "projects" or "startup" => "applications", "large" => "storage", _ => page
    };
    private void UpdateWorkspaceNavigation()
    {
        var highContrast = new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
        var system = new global::Windows.UI.ViewManagement.UISettings();
        CleanupTasks.Visibility = Family(destination) == "cleanup" ? Visibility.Visible : Visibility.Collapsed;
        ApplicationTasks.Visibility = Family(destination) == "applications" ? Visibility.Visible : Visibility.Collapsed;
        StorageTasks.Visibility = Family(destination) == "storage" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in NavigationItems)
        {
            var primary = ReferenceEquals(button, CleanupNavigation) || ReferenceEquals(button, ApplicationsNavigation) ||
                ReferenceEquals(button, StorageNavigation) || ReferenceEquals(button, ConfigurationNavigation);
            var selected = (string)button.Tag == (primary ? Family(destination) : destination);
            ThemeResources.Apply(button, Control.BackgroundProperty, "Background", selected ? "ShouNavSelectionBrush" : "ShouTransparentBrush");
            ThemeResources.Apply(button, Control.ForegroundProperty, "Foreground", selected ? "ShouAccentBrush" : "TextFillColorSecondaryBrush");
            if (highContrast) button.Foreground = new SolidColorBrush(system.UIElementColor(selected
                ? global::Windows.UI.ViewManagement.UIElementType.HighlightText : global::Windows.UI.ViewManagement.UIElementType.WindowText));
            if (highContrast) ProductIcon.Select(navigationIcons[button], button.Foreground);
            else ProductIcon.Select(navigationIcons[button], selected ? "ShouAccentBrush" : "TextFillColorSecondaryBrush");
            AutomationProperties.SetItemStatus(button, selected ? text.Get("Selected") : "");
        }
    }
    private async void ChangeLanguage(object sender, RoutedEventArgs args)
    {
        if (HasMutation || configuration?.IsBusy == true || sender is not MenuFlyoutItem { Tag: string language }) return;
        try { await AppearanceSettings.SaveAsync(AppearanceSettings.Preferences with { Language = language }); ((App)Application.Current).ReloadWindow(destination); }
        catch (Exception error) { NativeDiagnostics.Write(error); ShowStatus(text.Get("Settings could not be saved. Try again.")); }
    }
    private void ShowStatus(string value)
    {
        WindowStatus.Text = value;
        WindowStatus.Height = value.Length == 0 ? 1 : double.NaN;
        WindowStatus.Opacity = value.Length == 0 ? 0 : 1;
        WindowStatus.Margin = value.Length == 0 ? new Thickness(0) : new Thickness(28, 6, 28, 6);
    }
    private void RefreshDiskCapacity()
    {
        var volume = WindowsStorageVolumes.Read().FirstOrDefault(value => value.Path.Value.StartsWith(System.IO.Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\", StringComparison.OrdinalIgnoreCase));
        if (volume is null) { DiskCapacity.Visibility = Visibility.Collapsed; return; }
        DiskName.Text = volume.Name;
        DiskFree.Text = StorageRow.FormatBytes(volume.AvailableBytes) + " " + text.Get("Available");
        DiskMeter.Value = volume.TotalBytes > 0 ? (1 - (double)volume.AvailableBytes / volume.TotalBytes) * 100 : 0;
    }

}
