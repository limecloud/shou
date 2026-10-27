using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class SoftwareUpdatesPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly TextBlock reviewNotice;
    private readonly ManagedPackageUpdateService service = new(new WindowsManagedPackageUpdates());
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly ProgressBar progress = new() { Visibility = Visibility.Collapsed };
    private readonly TextBox search = new() { MaxLength = 256 };
    private readonly CheckBox updatesOnly = new() { IsChecked = true };
    private readonly Button selectUpdates = new();
    private readonly Button refresh = new();
    private readonly StackPanel rows = new() { Spacing = 2 };
    private readonly HashSet<string> selection = new(StringComparer.OrdinalIgnoreCase);
    private ManagedPackageSnapshot? snapshot;
    private ManagedPackageUpdatePlan? review;
    private ImmutableArray<ManagedPackageUpdateResult> results = [];
    private CancellationTokenSource? operation;
    private readonly Button primary = new();
    private readonly Button secondary = new();
    private readonly Grid layout;
    private readonly FrameworkElement landing;
    private bool busy;
    private bool closed;
    internal bool IsExecuting { get; private set; }
    internal event EventHandler? ExecutionChanged;

    internal SoftwareUpdatesPage()
    {
        FontSize = (double)Application.Current.Resources["ShouBodyFontSize"];
        primary.Style = (Style)Application.Current.Resources["ShouScanButton"];
        secondary.Style = (Style)Application.Current.Resources["ShouBorderedButton"];
        AutomationProperties.SetAutomationId(this, "updates.page");
        AutomationProperties.SetAutomationId(primary, "updates.confirm");
        AutomationProperties.SetLiveSetting(status, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        search.PlaceholderText = text.Get("Search applications…");
        AutomationProperties.SetName(search, text.Get("Search applications…"));
        updatesOnly.Content = text.Get("Updates only");
        selectUpdates.Content = text.Get("Select available updates");
        refresh.Content = text.Get("Check Updates");
        var tools = new Grid { ColumnSpacing = 12 };
        tools.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        tools.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        tools.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        tools.Children.Add(search); Grid.SetColumn(updatesOnly, 1); tools.Children.Add(updatesOnly); Grid.SetColumn(refresh, 2); tools.Children.Add(refresh);
        var body = layout = new Grid { Margin = new Thickness((double)Application.Current.Resources["ShouWorkspaceInset"]), RowSpacing = 12, Visibility = Visibility.Collapsed };
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var header = new StackPanel { Spacing = 12 };
        header.Children.Add(WorkspaceVisuals.Heading(text.Get("Software Updates"), "", "applications"));
        header.Children.Add(new TextBlock { Text = "WinGet", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        header.Children.Add(tools);
        header.Children.Add(selectUpdates);
        header.Children.Add(progress);
        header.Children.Add(status);
        body.Children.Add(header);
        var list = new ScrollViewer { Content = rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(list, 1); body.Children.Add(list);
        reviewNotice = Label("Installers may request administrator approval, close applications, or change their data. Shou does not restart Windows or restore an upgrade.");
        reviewNotice.Visibility = Visibility.Collapsed;
        var footer = new StackPanel { Spacing = 12 };
        footer.Children.Add(reviewNotice);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(secondary); actions.Children.Add(primary); footer.Children.Add(actions);
        Grid.SetRow(footer, 2); body.Children.Add(footer);
        landing = WorkspaceVisuals.Landing(text, "Software Updates", "Check for updates to installed software.", "applications",
            "Check Software Updates", "updates.check", async (_, _) => await CheckAsync());
        var root = new Grid(); root.Children.Add(landing); root.Children.Add(body); Content = root;
        search.TextChanged += (_, _) => RenderRows();
        updatesOnly.Click += (_, _) => RenderRows();
        selectUpdates.Click += (_, _) =>
        {
            selection.Clear();
            if (snapshot is { Complete: true }) foreach (var package in snapshot.Packages.Where(p => p.CanUpgrade && Matches(p))) selection.Add(package.Id);
            RenderRows();
        };
        refresh.Click += async (_, _) => await CheckAsync();
        primary.Click += async (_, _) => { if (review is null) await ReviewAsync(); else await UpgradeAsync(); };
        secondary.Click += (_, _) =>
        {
            if (busy) RequestStop();
            else { review = null; status.Text = text.Get("Cancelled"); SetBusy(false); RenderRows(); }
        };
        SetBusy(false);

    }

    internal void RequestStop()
    {
        operation?.Cancel();
        if (IsExecuting) status.Text = text.Get("Stop requested. Waiting for the current installer result; keep this window open.");
    }

    private async Task CheckAsync()
    {
        if (busy || closed) return;
        landing.Visibility = Visibility.Collapsed; layout.Visibility = Visibility.Visible;
        using var cancellation = new CancellationTokenSource();
        operation = cancellation;
        SetBusy(true);
        snapshot = null; review = null; selection.Clear(); results = [];
        status.Text = text.Get("Checking for updates…"); RenderRows();
        try
        {
            var observed = await service.ReadAsync(cancellation.Token);
            if (closed || cancellation.IsCancellationRequested) return;
            snapshot = observed;
            status.Text = observed.Complete
                ? text.Format("%lld available application updates", observed.Packages.Count(p => p.CanUpgrade))
                : Reason(observed.Reason);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { if (!closed) status.Text = text.Get("Cancelled"); }
        catch (Exception error) { NativeDiagnostics.Write(error); if (!closed) status.Text = text.Get("Application updates could not be checked. Try again."); }
        finally { operation = null; if (!closed) { SetBusy(false); RenderRows(); } }
    }

    private async Task ReviewAsync()
    {
        if (busy || snapshot is not { Complete: true } current) return;
        var selected = current.Packages.Where(p => selection.Contains(p.Id) && p.CanUpgrade).ToImmutableArray();
        if (selected.IsEmpty) return;
        using var cancellation = new CancellationTokenSource();
        operation = cancellation; SetBusy(true);
        try
        {
            var prepared = await service.PrepareAsync(selected, cancellation.Token);
            if (closed || cancellation.IsCancellationRequested) return;
            review = prepared;
            status.Text = text.Get("Review these software upgrades");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { if (!closed) status.Text = text.Get("Cancelled"); }
        catch (Exception error)
        {
            NativeDiagnostics.Write(error);
            if (!closed) { snapshot = null; selection.Clear(); status.Text = text.Get("The application identity or target version changed. Check updates again before continuing."); }
        }
        finally { operation = null; if (!closed) { SetBusy(false); RenderRows(); } }
    }

    private async Task UpgradeAsync()
    {
        if (busy || review is not { } plan) return;
        using var cancellation = new CancellationTokenSource();
        operation = cancellation;
        IsExecuting = true; SetBusy(true); ExecutionChanged?.Invoke(this, EventArgs.Empty);
        status.Text = text.Get("Updating selected applications. Keep this window open.");
        try
        {
            // This button confirms only the frozen source/version selection displayed in this window.
            results = await service.ExecuteAsync(plan, plan.Id, cancellation.Token);
            status.Text = text.Get("Update attempts finished. Review each result and check again before another update.");
            selection.Clear();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        { status.Text = text.Get("Cancelled"); }
        catch (ShouException error)
        { NativeDiagnostics.Write(error); status.Text = text.Get("The application identity or target version changed. Check updates again before continuing."); }
        catch (Exception error)
        { NativeDiagnostics.Write(error); status.Text = text.Get("The update outcome is uncertain. Check installed versions before trying again."); }
        finally
        {
            operation = null; IsExecuting = false; snapshot = null; review = null;
            SetBusy(false); RenderRows(); ExecutionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void SetBusy(bool value)
    {
        busy = value;
        if (value) foreach (var check in rows.Children.OfType<CheckBox>()) check.IsEnabled = false;
        search.IsEnabled = updatesOnly.IsEnabled = selectUpdates.IsEnabled = refresh.IsEnabled = !value && review is null;
        progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        progress.IsIndeterminate = value && AppearanceSettings.AnimationsEnabled;
        secondary.Content = text.Get(value ? "Stop" : "Cancel");
        secondary.Visibility = value || review is not null ? Visibility.Visible : Visibility.Collapsed;
        UpdateAction();
    }

    private bool Matches(ManagedPackageUpdate package) => package.Name.Contains(search.Text, StringComparison.OrdinalIgnoreCase) || package.Id.Contains(search.Text, StringComparison.OrdinalIgnoreCase);
    private void RenderRows()
    {
        if (closed) return;
        reviewNotice.Visibility = review is null ? Visibility.Collapsed : Visibility.Visible;
        rows.Children.Clear();
        if (review is { } frozen)
        {
            foreach (var package in frozen.Packages)
            {
                rows.Children.Add(new TextBlock { Text = package.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                rows.Children.Add(new TextBlock { Text = package.InstalledVersion + " → " + package.AvailableVersion, TextWrapping = TextWrapping.Wrap });
                rows.Children.Add(new TextBlock { Text = "WinGet, " + package.Id + ", " + text.Get(package.Scope == ManagedPackageScope.User ? "Current-user installation" : "Machine installation"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
            }
        }
        else if (!results.IsEmpty)
        {
            foreach (var result in results)
            {
                rows.Children.Add(new TextBlock { Text = result.Package.Name + ", " + result.Package.InstalledVersion + " → " + result.Package.AvailableVersion, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                rows.Children.Add(Label(result.Outcome switch
                {
                    ManagedPackageUpdateOutcome.Verified => "Updated and verified",
                    ManagedPackageUpdateOutcome.Failed => "Update failed. The installer may have made changes.",
                    ManagedPackageUpdateOutcome.NotStarted => "Update not started",
                    _ => "The update outcome is uncertain. Check installed versions before trying again."
                }));
                if (result.ObservedVersion is { } version) rows.Children.Add(new TextBlock { Text = text.Get("Observed installed version") + ": " + version, TextWrapping = TextWrapping.Wrap });
                if (result.RestartRequired) rows.Children.Add(Label("The installer requested a restart. Shou will not restart Windows automatically."));
            }
        }
        else if (snapshot is { } observed)
        {
            var visible = observed.Packages.Where(p => Matches(p) && (updatesOnly.IsChecked != true || p.CanUpgrade)).ToArray();
            foreach (var package in visible)
            {
                var description = new StackPanel { Spacing = 3 };
                description.Children.Add(new TextBlock { Text = package.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                description.Children.Add(new TextBlock { Text = package.InstalledVersion + " → " + (package.AvailableVersion ?? text.Get("Unknown")), TextWrapping = TextWrapping.Wrap });
                description.Children.Add(new TextBlock { Text = "WinGet, " + package.Id + ", " + text.Get(package.Scope == ManagedPackageScope.User ? "Current-user installation" : "Machine installation"), TextWrapping = TextWrapping.Wrap });
                if (!package.CanUpgrade) description.Children.Add(new TextBlock { Text = Reason(package.Reason), TextWrapping = TextWrapping.Wrap });
                var check = new CheckBox { Content = description, IsChecked = selection.Contains(package.Id), IsEnabled = !busy && observed.Complete && package.CanUpgrade, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 4, 0, 8) };
                AutomationProperties.SetAutomationId(check, "applications.updates.package." + package.Id);
                check.Click += (_, _) => { if (check.IsChecked == true) selection.Add(package.Id); else selection.Remove(package.Id); UpdateAction(); };
                rows.Children.Add(check);
            }
            if (visible.Length == 0) rows.Children.Add(Label("No matching application updates. Applications without a verified WinGet match are not included."));
        }
        UpdateAction();
    }

    private void UpdateAction()
    {
        primary.Content = text.Get(review is not null ? "Confirm Upgrade" : "Review Selected Updates…");
        primary.IsEnabled = !busy && (review is not null || snapshot?.Complete == true && selection.Count > 0);
    }

    private string Reason(string? reason) => text.Get(reason switch
    {
        "package_no_update" => "No newer verified package version",
        "package_identity_unverified" => "The installation identity or scope could not be verified.",
        "package_version_unverified" => "The installed and available versions could not be safely compared.",
        "package_channel_unverified" => "The installed and available versions could not be safely compared.",
        "package_agreement_required" or "package_source_agreement_required" => "Review required agreements in the official package manager before updating here.",
        "package_installer_unavailable" => "No compatible installer is available for this installation scope.",
        "package_inventory_incomplete" => "The package inventory is incomplete. Refresh it before selecting updates.",
        "package_source_unverified" => "The official WinGet source could not be verified. Custom sources are not used.",
        _ => "WinGet is unavailable or its official catalog could not be read. Use the application’s own updater or repair App Installer."
    });

    public void Dispose()
    {
        closed = true; operation?.Cancel(); GC.SuppressFinalize(this);
    }

    private TextBlock Label(string value) => new() { Text = text.Get(value), TextWrapping = TextWrapping.Wrap };
}
