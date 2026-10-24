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
    private bool sidebarOpen = true;

    public MainWindow(string initialPage = "cleanup")
    {
        InitializeComponent();
        SidebarColumn.Width = new GridLength((double)Application.Current.Resources["ShouSidebarWidth"]);
        SidebarHeaderRow.Height = TitlebarRow.Height = new GridLength((double)Application.Current.Resources["ShouTitlebarHeight"]);
        FooterRow.Height = new GridLength((double)Application.Current.Resources["ShouFooterHeight"]);
        Title = "Shou";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Shou.ico"));
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleDragRegion);
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96d;
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(Math.Min(area.Width, (int)((double)Application.Current.Resources["ShouWindowWidth"] * scale)),
            Math.Min(area.Height, (int)((double)Application.Current.Resources["ShouWindowHeight"] * scale))));
        StorageHeading.Text = text.Get("Storage");
        ToolsHeading.Text = text.Get("Tools");
        foreach (var button in NavigationItems)
        {
            var name = (string)button.Tag;
            var icon = ProductIcon.Create(name, (double)Application.Current.Resources["ShouCompactIconSize"]);
            navigationIcons[button] = icon;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
            content.Children.Add(icon); content.Children.Add(new TextBlock { Text = TitleFor(name), VerticalAlignment = VerticalAlignment.Center });
            button.Content = content;
            AutomationProperties.SetName(button, TitleFor(name));
            AutomationProperties.SetAutomationId(button, "nav." + name);
        }
        languageIcon = ProductIcon.Create("language", 16);
        LanguageButton.Content = languageIcon;
        diskIcon = ProductIcon.Create("drive", 14);
        DiskIcon.Content = diskIcon;
        SystemLanguageItem.Text = text.Get("Follow System");
        AutomationProperties.SetName(LanguageButton, text.Get("Interface Language"));
        AutomationProperties.SetName(PaneButton, text.Get("Sidebar"));
        AutomationProperties.SetName(ShowSidebarButton, text.Get("Sidebar"));
        VersionText.Text = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "";
        WindowRoot.RequestedTheme = AppearanceSettings.Current.Theme;
        AppWindow.Closing += (_, args) =>
        {
            if (!HasMutation) return;
            args.Cancel = true;
            cleanup?.RequestCleanupStop(); applications?.RequestUninstallStop(); startup?.RequestStartupStop();
            storage?.Cancel(); largeFiles?.Cancel();
            privacy?.CancelCleanup();
            WindowStatus.Text = text.Get("Stopping at a safe boundary…");
        };
        Closed += (_, _) =>
        {
            closed = true;
            cleanup?.Dispose(); configuration?.Dispose(); applications?.Dispose(); startup?.Dispose();
            privacy?.Dispose(); history?.Dispose(); storage?.Dispose(); largeFiles?.Dispose();
        };
        WindowRoot.Loaded += (_, _) => UpdateSidebar();
        initialized = true;
        _ = ShowPageAsync(initialPage);
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    private bool HasMutation => cleanup?.HasActiveCleanup == true || applications?.HasActiveUninstall == true || startup?.HasActiveStartupChange == true || storage?.HasActiveRemoval == true || largeFiles?.HasActiveRemoval == true || privacy?.HasActiveCleanup == true;
    private Button Item(string page) => page switch
    {
        "large" => LargeFilesNavigation, "storage" => StorageNavigation, "configuration" => ConfigurationNavigation,
        "applications" => ApplicationsNavigation, "startup" => StartupNavigation, "privacy" => PrivacyNavigation,
        "history" => HistoryNavigation, "settings" => SettingsNavigation, _ => CleanupNavigation
    };

    private Button[] NavigationItems => [CleanupNavigation, LargeFilesNavigation, StorageNavigation, ConfigurationNavigation,
        ApplicationsNavigation, StartupNavigation, PrivacyNavigation, HistoryNavigation, SettingsNavigation];
    private string TitleFor(string page) => text.Get(page switch
    {
        "large" => "Large Files", "storage" => "Space Analysis", "configuration" => "Cleanup Rules",
        "startup" => "Startup Items", "applications" => "Application Uninstall", "privacy" => "Privacy",
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
        UpdateSidebar();
        DiskCapacity.Visibility = next is "cleanup" or "large" ? Visibility.Visible : Visibility.Collapsed;
        if (next is "cleanup" or "large") RefreshDiskCapacity();
        WindowStatus.Text = "";
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
                        configuration.EvidenceInvalidated += (_, _) => { cleanup?.InvalidateConfiguration(); privacy?.InvalidateConfiguration(); };
                        configuration.BusyChanged += (_, _) => UpdateNavigation();
                    }
                    page = configuration; load = configuration.EnsureLoadedAsync(); break;
                case "applications":
                    if (applications is null) { applications = new(); applications.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = applications; load = applications.EnsureLoadedAsync(); break;
                case "startup":
                    if (startup is null) { startup = new(); startup.BusyChanged += (_, _) => UpdateNavigation(); }
                    page = startup; load = startup.EnsureLoadedAsync(); break;
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
                        settings.AppearanceChanged += (_, _) => { WindowRoot.RequestedTheme = AppearanceSettings.Current.Theme; UpdateSidebar(); };
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
            if (!closed) WindowStatus.Text = text.Get("The page could not be loaded. Try again.");
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
    private void UpdateSidebar()
    {
        var highContrast = new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
        var system = new global::Windows.UI.ViewManagement.UISettings();
        foreach (var button in NavigationItems)
        {
            var selected = ReferenceEquals(button, Item(destination));
            button.ClearValue(Control.BackgroundProperty);
            if (highContrast)
            {
                var text = system.UIElementColor(selected ? global::Windows.UI.ViewManagement.UIElementType.HighlightText : global::Windows.UI.ViewManagement.UIElementType.WindowText);
                button.Foreground = new SolidColorBrush(text);
                ProductIcon.Select(navigationIcons[button], button.Foreground);
            }
            else
            {
                var footer = button.Tag is "history" or "settings";
                if (selected && !footer)
                {
                    button.Foreground = (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"];
                    ProductIcon.Select(navigationIcons[button], button.Foreground);
                }
                else
                {
                    button.ClearValue(Control.ForegroundProperty);
                    ProductIcon.Select(navigationIcons[button], (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]);
                }
            }
            if (button.Content is StackPanel panel && panel.Children.Count > 1 && panel.Children[1] is TextBlock label)
                label.FontWeight = Microsoft.UI.Text.FontWeights.Normal;
            VisualStateManager.GoToState(button, selected ? "Selected" : "Unselected", true);
        }
        var chrome = highContrast
            ? new SolidColorBrush(system.UIElementColor(global::Windows.UI.ViewManagement.UIElementType.WindowText))
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        if (languageIcon is not null) ProductIcon.Select(languageIcon, chrome);
        if (diskIcon is not null) ProductIcon.Select(diskIcon, chrome);
    }
    private void ToggleSidebar(object sender, RoutedEventArgs args)
    {
        sidebarOpen = !sidebarOpen;
        SidebarColumn.Width = new GridLength(sidebarOpen ? (double)Application.Current.Resources["ShouSidebarWidth"] : 0);
        Sidebar.Visibility = sidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        ShowSidebarButton.Visibility = sidebarOpen ? Visibility.Collapsed : Visibility.Visible;
    }
    private async void ChangeLanguage(object sender, RoutedEventArgs args)
    {
        if (HasMutation || configuration?.IsBusy == true || sender is not MenuFlyoutItem { Tag: string language }) return;
        try { await AppearanceSettings.SaveAsync(AppearanceSettings.Preferences with { Language = language }); ((App)Application.Current).ReloadWindow(destination); }
        catch (Exception error) { NativeDiagnostics.Write(error); WindowStatus.Text = text.Get("Settings could not be saved. Try again."); }
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
