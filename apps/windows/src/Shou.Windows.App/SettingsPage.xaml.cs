using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

public sealed partial class SettingsPage : UserControl
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    private readonly TextCatalog text = new();
    private bool initialized, saving;
    public event EventHandler? AppearanceChanged;
    public event EventHandler? LanguageChanged;
    public event EventHandler? ScanLocationsRequested;
    public event EventHandler? ExclusionsRequested;
    public SettingsPage()
    {
        InitializeComponent();
        PageDiagnostics.Update(this, "settings", "ready");
        GeneralHeading.Text = text.Get("General");
        LanguageTitle.Text = text.Get("Interface Language");
        LanguageDescription.Visibility = Visibility.Collapsed;
        ThemeTitle.Text = text.Get("Appearance");
        ThemeDescription.Visibility = Visibility.Collapsed;
        MotionTitle.Text = text.Get("Reduce Motion");
        MotionDescription.Text = text.Get("Use static indicators and immediate transitions. Otherwise, follow Windows animation settings.");
        AboutHeading.Text = text.Get("About Shou"); UpdateButton.Content = text.Get("Check for Updates…");
        ToolTipService.SetToolTip(UpdateButton, text.Get("Checks the official GitHub release. Downloads open only when you choose."));
        ScanningHeading.Text = text.Get("Scanning and Privacy");
        LocationsTitle.Text = text.Get("Scan Locations");
        LocationsDescription.Text = text.Get("App caches and developer projects are discovered automatically. Extra folders are remembered.");
        ExclusionsTitle.Text = text.Get("Exclusions");
        ExclusionsDescription.Text = text.Get("Keep chosen files and projects out of cleanup.");
        LocationsButton.Content = text.Get("View…"); ExclusionsButton.Content = text.Get("Manage…");
        LocalDataTitle.Text = text.Get("Local data");
        OpenDataButton.Content = text.Get("Open Folder…");
        SupportHeading.Text = text.Get("Support");
        DiagnosticsTitle.Text = text.Get("Diagnostics");
        DiagnosticsDescription.Text = text.Get("This report contains bounded system facts, not personal paths or file contents. Nothing is uploaded.");
        DiagnosticsButton.Content = text.Get("Run Diagnostics…");
        DiagnosticsIcon.Content = ProductIcon.Create("configuration", (double)Application.Current.Resources["ShouSettingsIconSize"]);
        FeedbackTitle.Text = text.Get("Report an Issue");
        FeedbackDescription.Visibility = Visibility.Collapsed;
        FeedbackLink.Content = text.Get("Send Feedback…");
        SourceTitle.Text = text.Get("Open Source");
        SourceDescription.Text = text.Get("Shou is available under the Apache License 2.0.");
        SourceLink.Content = text.Get("GitHub");
        ConfirmationCaption.Visibility = Visibility.Collapsed;
        try { LocalDataDescription.Text = WindowsRecordStore.ForCurrentUser().Directory.Value; }
        catch (Exception error) { NativeDiagnostics.Write(error); LocalDataDescription.Text = text.Get("Local data"); OpenDataButton.IsEnabled = false; }
        AiHeading.Text = text.Get("AI Investigation"); AiTitle.Text = text.Get("Enable AI Investigation");
        AiNotice.Text = text.Get("AI investigation is not available in this Windows preview."); AutomationProperties.SetName(AiToggle, AiTitle.Text);
        foreach (var (host, name) in new[] { (LanguageIcon, "language"), (ThemeIcon, "appearance"), (MotionIcon, "motion"), (LocationsIcon, "configuration"), (ExclusionsIcon, "privacy"), (LocalDataIcon, "drive"), (FeedbackIcon, "history"), (SourceIcon, "configuration") })
        {
            var icon = ProductIcon.Create(name, (double)Application.Current.Resources["ShouSettingsIconSize"]);
            ProductIcon.Select(icon, "TextFillColorSecondaryBrush"); host.Content = icon;
        }
        var brandSize = (double)Application.Current.Resources["ShouBrandIconSize"];
        PackageIcon.Content = WorkspaceVisuals.Artwork("brand-icon", brandSize, brandSize);
        VersionText.Text = "Shou " + typeof(SettingsPage).Assembly.GetName().Version?.ToString(3);
        PreviewNotice.Text = text.Get("Windows portable preview. Native operations require review and current confirmation. Full Windows acceptance is not complete.");
        LanguageBox.ItemsSource = new[] { text.Get("Follow System"), "简体中文", "English" };
        ThemeBox.ItemsSource = new[] { text.Get("Follow System"), text.Get("Light"), text.Get("Dark") };
        LanguageBox.SelectedIndex = AppearanceSettings.Preferences.Language switch { "zh-CN" => 1, "en-US" => 2, _ => 0 };
        ThemeBox.SelectedIndex = AppearanceSettings.Preferences.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        MotionToggle.IsChecked = AppearanceSettings.Preferences.ReduceMotion;
        AutomationProperties.SetName(LanguageBox, LanguageTitle.Text); AutomationProperties.SetName(ThemeBox, ThemeTitle.Text);
        AutomationProperties.SetName(MotionToggle, MotionTitle.Text);
        initialized = true;
    }
    private void ViewScanLocations(object sender, RoutedEventArgs args) => ScanLocationsRequested?.Invoke(this, EventArgs.Empty);
    private async void CheckDesktopUpdate(object sender, RoutedEventArgs args)
    {
        UpdateButton.IsEnabled = false;
        try { await new DesktopUpdateDialog(XamlRoot).ShowAsync(); }
        finally { UpdateButton.IsEnabled = true; }
    }
    private async void RunDiagnostics(object sender, RoutedEventArgs args)
    {
        DiagnosticsButton.IsEnabled = false;
        try { await new UserDiagnosticsDialog(XamlRoot).ShowAsync(); }
        finally { DiagnosticsButton.IsEnabled = true; }
    }
    private void ManageExclusions(object sender, RoutedEventArgs args) => ExclusionsRequested?.Invoke(this, EventArgs.Empty);
    private async void OpenLocalData(object sender, RoutedEventArgs args)
    {
        try
        {
            var path = WindowsRecordStore.ForCurrentUser().Directory.Value;
            await global::Windows.System.Launcher.LaunchFolderPathAsync(path);
        }
        catch (Exception error) { NativeDiagnostics.Write(error); SaveError.Message = text.Get("Settings could not be saved. Try again."); SaveError.IsOpen = true; }
    }
    private async void ChangePreference(object sender, SelectionChangedEventArgs args) => await SaveAsync();
    private async void ChangeMotion(object sender, RoutedEventArgs args) => await SaveAsync();
    private async Task SaveAsync()
    {
        if (!initialized || saving) return;
        saving = true;
        LanguageBox.IsEnabled = ThemeBox.IsEnabled = MotionToggle.IsEnabled = false;
        try
        {
            var previous = AppearanceSettings.Preferences;
            var value = new DesktopPreferences(LanguageBox.SelectedIndex switch { 1 => "zh-CN", 2 => "en-US", _ => "system" },
                ThemeBox.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" }, MotionToggle.IsChecked == true);
            await AppearanceSettings.SaveAsync(value);
            SaveError.IsOpen = false;
            if (previous.Language != value.Language) LanguageChanged?.Invoke(this, EventArgs.Empty);
            else AppearanceChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception error) { NativeDiagnostics.Write(error); SaveError.Message = text.Get("Settings could not be saved. Try again."); SaveError.IsOpen = true; }
        finally { saving = false; LanguageBox.IsEnabled = ThemeBox.IsEnabled = MotionToggle.IsEnabled = true; }
    }
}
