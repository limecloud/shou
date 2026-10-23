using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;
using Windows.Storage.Pickers;

namespace Shou.Windows.App;

public sealed partial class MainWindow : Window
{
    private readonly TextCatalog text = new();
    private readonly StorageViewModel model = new(new StorageScanner(new WindowsFileSystem()));
    private WindowsPath? root;
    private StorageBrowser? browser;
    private StoragePage? page;
    private NativeReviewOperations? reviewOperations;
    private CleanupPage? cleanupPage;
    private HistoryPage? historyPage;
    private ConfigurationPage? configurationPage;
    private ApplicationsPage? applicationsPage;
    private StartupPage? startupPage;
    private PrivacyPage? privacyPage;
    private bool closed;
    private bool initialized;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Shou";
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1160, 780));
        PageTitle.Text = text.Get("Space Analysis");
        PageDescription.Text = text.Get("Select a folder to see its storage usage.");
        ScopeBox.PlaceholderText = text.Get("Choose Folder…");
        AutomationProperties.SetName(ScopeBox, text.Get("Space Analysis"));
        ChooseButton.Content = text.Get("Choose Folder…");
        ScanButton.Content = text.Get("Scan");
        CancelButton.Content = text.Get("Stop");
        UpButton.Content = text.Get("Up");
        PreviousButton.Content = text.Get("Previous");
        NextButton.Content = text.Get("Next");
        CleanupNavigation.Content = text.Get("Smart Cleanup");
        StorageNavigation.Content = text.Get("Space Analysis");
        ApplicationsNavigation.Content = text.Get("Applications");
        StartupNavigation.Content = text.Get("Startup Items");
        PrivacyNavigation.Content = text.Get("Privacy");
        ConfigurationNavigation.Content = text.Get("Cleanup Rules");
        HistoryNavigation.Content = text.Get("History");
        CoverageNotice.Message = text.Get("Some locations could not be read. Sizes show only measured data.");
        model.PropertyChanged += ModelChanged;
        AppWindow.Closing += (_, args) =>
        {
            if (startupPage?.HasActiveStartupChange == true)
            {
                args.Cancel = true;
                startupPage.RequestStartupStop();
                return;
            }
            if (cleanupPage?.HasActiveCleanup == true)
            {
                args.Cancel = true;
                cleanupPage.RequestCleanupStop();
                return;
            }
            if (applicationsPage?.HasActiveUninstall != true) return;
            args.Cancel = true;
            applicationsPage.RequestUninstallStop();
        };
        Closed += (_, _) =>
        {
            closed = true;
            model.PropertyChanged -= ModelChanged;
            model.Dispose();
            cleanupPage?.Dispose();
            historyPage?.Dispose();
            configurationPage?.Dispose();
            applicationsPage?.Dispose();
            startupPage?.Dispose();
            privacyPage?.Dispose();
        };
        UpdateState();
        RenderPage();
        initialized = true;
        Navigation.SelectedItem = StorageNavigation;
    }

    private async void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!initialized || closed || args.SelectedItem is not NavigationViewItem { Tag: string destination }) return;
        if (configurationPage?.IsBusy == true && destination != "configuration") { Navigation.SelectedItem = ConfigurationNavigation; return; }
        if (applicationsPage?.HasActiveUninstall == true && destination != "applications") { Navigation.SelectedItem = ApplicationsNavigation; return; }
        if (cleanupPage?.HasActiveCleanup == true && destination != "cleanup") { Navigation.SelectedItem = CleanupNavigation; return; }
        if (startupPage?.HasActiveStartupChange == true && destination != "startup") { Navigation.SelectedItem = StartupNavigation; return; }
        if (destination != "privacy") privacyPage?.CancelScan();
        StorageContent.Visibility = destination == "storage" ? Visibility.Visible : Visibility.Collapsed;
        ApplicationsHost.Visibility = destination == "applications" ? Visibility.Visible : Visibility.Collapsed;
        StartupHost.Visibility = destination == "startup" ? Visibility.Visible : Visibility.Collapsed;
        PrivacyHost.Visibility = destination == "privacy" ? Visibility.Visible : Visibility.Collapsed;
        CleanupHost.Visibility = destination == "cleanup" ? Visibility.Visible : Visibility.Collapsed;
        HistoryHost.Visibility = destination == "history" ? Visibility.Visible : Visibility.Collapsed;
        ConfigurationHost.Visibility = destination == "configuration" ? Visibility.Visible : Visibility.Collapsed;
        try
        {
            if (destination == "privacy")
            {
                privacyPage ??= new();
                PrivacyHost.Content = privacyPage;
            }
            else if (destination == "startup")
            {
                if (startupPage is null)
                {
                    startupPage = new();
                    startupPage.BusyChanged += (_, _) =>
                    {
                        if (startupPage.HasActiveStartupChange) model.Cancel();
                        UpdateNavigation();
                    };
                }
                StartupHost.Content = startupPage;
                await startupPage.EnsureLoadedAsync();
            }
            else if (destination == "applications")
            {
                if (applicationsPage is null)
                {
                    applicationsPage = new();
                    applicationsPage.BusyChanged += (_, _) => UpdateNavigation();
                }
                ApplicationsHost.Content = applicationsPage;
                await applicationsPage.EnsureLoadedAsync();
            }
            else if (destination == "cleanup")
            {
                if (cleanupPage is null)
                {
                    reviewOperations ??= new();
                    cleanupPage = new(reviewOperations, reviewOperations, reviewOperations.Catalog);
                    cleanupPage.BusyChanged += (_, _) =>
                    {
                        if (cleanupPage.HasActiveCleanup) model.Cancel();
                        UpdateNavigation();
                    };
                    cleanupPage.LocationsPrepared += async (_, _) =>
                    {
                        configurationPage?.InvalidateConfiguration();
                        if (closed || configurationPage is null || configurationPage.IsBusy || ConfigurationHost.Visibility != Visibility.Visible) return;
                        try { await configurationPage.EnsureLoadedAsync(); }
                        catch (Exception error) { ReportError(error); }
                    };
                }
                CleanupHost.Content = cleanupPage;
                await cleanupPage.EnsureLoadedAsync();
            }
            else if (destination == "history")
            {
                historyPage ??= new(reviewOperations ??= new());
                HistoryHost.Content = historyPage;
                await historyPage.EnsureLoadedAsync();
            }
            else if (destination == "configuration")
            {
                if (configurationPage is null)
                {
                    reviewOperations ??= new();
                    configurationPage = new(reviewOperations, WinRT.Interop.WindowNative.GetWindowHandle(this), reviewOperations.Catalog);
                    configurationPage.EvidenceInvalidated += (_, _) => { cleanupPage?.InvalidateConfiguration(); privacyPage?.InvalidateConfiguration(); };
                    configurationPage.BusyChanged += (_, _) => UpdateNavigation();
                }
                ConfigurationHost.Content = configurationPage;
                await configurationPage.EnsureLoadedAsync();
            }
        }
        catch (Exception error)
        {
            if (!closed) Navigation.SelectedItem = StorageNavigation;
            ReportError(error);
        }
    }

    private void UpdateNavigation()
    {
        if (closed) return;
        var configuring = configurationPage?.IsBusy == true;
        var uninstalling = applicationsPage?.HasActiveUninstall == true;
        var cleaning = cleanupPage?.HasActiveCleanup == true;
        var startupChanging = startupPage?.HasActiveStartupChange == true;
        CleanupNavigation.IsEnabled = !configuring && !uninstalling && !startupChanging;
        StorageNavigation.IsEnabled = HistoryNavigation.IsEnabled = !configuring && !uninstalling && !cleaning && !startupChanging;
        PrivacyNavigation.IsEnabled = !configuring && !uninstalling && !cleaning && !startupChanging;
        StartupNavigation.IsEnabled = !configuring && !uninstalling && !cleaning;
        ConfigurationNavigation.IsEnabled = !uninstalling && !cleaning && !startupChanging;
        ApplicationsNavigation.IsEnabled = !configuring && !cleaning && !startupChanging;
        UpdateState();
    }

    private async void ChooseFolder(object sender, RoutedEventArgs args)
    {
        if (applicationsPage?.HasActiveUninstall == true || cleanupPage?.HasActiveCleanup == true || startupPage?.HasActiveStartupChange == true) return;
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (closed || folder is null || applicationsPage?.HasActiveUninstall == true || cleanupPage?.HasActiveCleanup == true || startupPage?.HasActiveStartupChange == true) return;
            root = WindowsPath.Parse(folder.Path);
            ScopeBox.Text = root.Value;
            await ScanAsync();
        }
        catch (Exception error) { ReportError(error); }
    }

    private async void ScanFolder(object sender, RoutedEventArgs args)
    {
        try { await ScanAsync(); }
        catch (Exception error) { ReportError(error); }
    }

    private async Task ScanAsync()
    {
        if (root is null || model.IsBusy || applicationsPage?.HasActiveUninstall == true || cleanupPage?.HasActiveCleanup == true || startupPage?.HasActiveStartupChange == true) return;
        browser = null;
        page = null;
        RenderPage();
        await model.ScanAsync(root);
        if (closed) return;
        if (model.Snapshot is { } snapshot && snapshot.Entries.Any(item => item.Entry.Path == root))
        {
            browser = new(snapshot);
            page = browser.GetPage(root);
            TotalSize.Text = StorageRow.FormatBytes(snapshot.AllocatedBytes);
        }
        RenderPage();
    }

    private void CancelScan(object sender, RoutedEventArgs args) => model.Cancel();
    private void ModelChanged(object? sender, PropertyChangedEventArgs args) => UpdateState();

    private void UpdateState()
    {
        if (closed) return;
        ChooseButton.IsEnabled = !model.IsBusy && applicationsPage?.HasActiveUninstall != true && cleanupPage?.HasActiveCleanup != true && startupPage?.HasActiveStartupChange != true;
        ScanButton.IsEnabled = root is not null && !model.IsBusy && applicationsPage?.HasActiveUninstall != true && cleanupPage?.HasActiveCleanup != true && startupPage?.HasActiveStartupChange != true;
        CancelButton.IsEnabled = model.IsBusy;
        ScanProgress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CoverageNotice.IsOpen = model.State == StoragePageState.Partial;
        StatusText.Text = model.State switch
        {
            StoragePageState.Scanning => text.Get("Scanning…"),
            StoragePageState.Ready => text.Get("Scan complete"),
            StoragePageState.Cancelled => text.Get("Scan cancelled"),
            StoragePageState.Failed => text.Get("The scan could not be completed. Try another folder."),
            _ => ""
        };
        if (model.IsBusy) TotalSize.Text = "";
    }

    private void RenderPage()
    {
        ResultsList.ItemsSource = page?.Items;
        CurrentPath.Text = page?.Directory.Value ?? "";
        UpButton.IsEnabled = page is not null && root is not null && page.Directory != root;
        PreviousButton.IsEnabled = page?.HasPrevious == true;
        NextButton.IsEnabled = page?.HasNext == true;
    }

    private void OpenDirectory(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is StorageRow { IsDirectory: true } row && browser is not null)
        {
            page = browser.GetPage(row.Path);
            RenderPage();
        }
    }

    private void GoUp(object sender, RoutedEventArgs args)
    {
        if (page?.Directory.Parent is { } parent && root is not null && parent.IsWithin(root, caseSensitive: true) && browser is not null)
        {
            page = browser.GetPage(parent);
            RenderPage();
        }
    }

    private void PreviousPage(object sender, RoutedEventArgs args)
    {
        if (page is not null && browser is not null)
        {
            page = browser.GetPage(page.Directory, Math.Max(0, page.Offset - 200));
            RenderPage();
        }
    }

    private void NextPage(object sender, RoutedEventArgs args)
    {
        if (page?.HasNext == true && browser is not null)
        {
            page = browser.GetPage(page.Directory, page.Offset + page.Items.Length);
            RenderPage();
        }
    }

    private void ReportError(Exception error)
    {
        NativeDiagnostics.Write(error);
        if (closed) return;
        StatusText.Text = text.Get("The scan could not be completed. Try another folder.");
    }
}
