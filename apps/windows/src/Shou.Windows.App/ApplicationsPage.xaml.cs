using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class ApplicationsPage : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);
    private readonly TextCatalog text = new();
    private readonly ApplicationsViewModel model = new(new ApplicationCatalog(new WindowsApplicationInventory()));
    private readonly ApplicationUninstallViewModel uninstall = new(new NativeApplicationOperations());
    private Task? initialLoad;
    private bool disposed;
    private bool initialized;
    private bool rendering;
    private readonly InlineDetails inlineDetails;
    private ApplicationPresentationFilter presentation = ApplicationPresentationFilter.All;
    private string? selectedApplicationId;
    private ApplicationUpdatePanel? updates;
    public bool HasActiveUninstall => uninstall.IsExecuting;
    public event EventHandler? BusyChanged;

    public ApplicationsPage()
    {
        InitializeComponent();
        inlineDetails = new(Inspector, PageLayout);
        LandingHost.Content = WorkspaceVisuals.Landing(text, "Keep the apps you love.",
            "Browse registered applications. Portable apps and other users are not included. Sizes are installer estimates, not measured disk usage.", "applications", "Scan Applications", "applications.start", Refresh);
        PageTitle.Text = text.Get("Applications");
        NameHeading.Text = text.Get("Name"); SizeHeading.Text = text.Get("Registered size"); StateHeading.Text = text.Get("Status");
        FooterNotice.Text = text.Get(uninstall.ExecutionAvailable
            ? "Select an application to view its registration details."
            : "Select an application to inspect its installation. System uninstall is unavailable in this preview.");
        EstimatedLabel.Text = text.Get("Estimated Size");
        CoverageLabel.Text = text.Get("Partial Coverage");
        AutomationProperties.SetName(CoverageButton, text.Get("Partial Coverage"));
        UninstallFooterButton.Content = text.Get("Uninstall Selected…");
        ToolTipService.SetToolTip(UninstallFooterButton, text.Get(uninstall.ExecutionAvailable
            ? "Select an application to view its registration details."
            : "Select an application to inspect its installation. System uninstall is unavailable in this preview."));
        AutomationProperties.SetName(InfoButton, text.Get("Information")); AutomationProperties.SetName(CloseInspectorButton, text.Get("Close Details"));
        Description.Text = text.Get(uninstall.ExecutionAvailable
            ? "Browse registered applications. Portable apps and other users are not included. Sizes are installer estimates, not measured disk usage."
            : "Browse registered applications. Portable apps and other users are not included. Sizes are installer estimates, not measured disk usage. Uninstall is not available yet.");
        SearchBox.PlaceholderText = text.Get("Search applications…");
        AutomationProperties.SetName(SearchBox, text.Get("Search applications…"));
        AutomationProperties.SetName(ApplicationsList, text.Get("Applications"));
        AutomationProperties.SetName(SortBox, text.Get("Sort applications"));
        NameSort.Content = text.Get("Name");
        SizeSort.Content = text.Get("Registered size");
        SortBox.SelectedIndex = 1;
        RefreshButton.Content = text.Get("Refresh");
        CancelButton.Content = text.Get("Stop");
        PreviousButton.Content = text.Get("Previous");
        NextButton.Content = text.Get("Next");
        CoverageNotice.Message = text.Get("Some application registrations could not be read. The list may be incomplete.");
        InspectButton.Content = text.Get("Review Uninstall");
        PreparePlanButton.Content = text.Get("Prepare Uninstall Plan");
        ExecuteButton.Content = text.Get("Uninstall");
        ReadExecutionButton.Content = text.Get("Read Uninstall Record");
        InstallerDataDescription.Text = text.Get("I understand the system installer may remove data it manages. Shou does not include additional residual files in this plan.");
        model.PropertyChanged += Changed;
        uninstall.PropertyChanged += UninstallChanged;
        initialized = true;
        Render();
    }

    public Task EnsureLoadedAsync() => initialLoad ??= model.RefreshAsync();
    private void Changed(object? sender, PropertyChangedEventArgs args) { if (args.PropertyName == nameof(ApplicationsViewModel.Page)) Render(); }
    private void Render()
    {
        if (disposed) return;
        PageDiagnostics.Update(this, "applications", model.State, model.ErrorCode);
        var busy = model.IsBusy || uninstall.IsBusy;
        var landing = model.Page is null && !busy;
        LandingHost.Visibility = landing ? Visibility.Visible : Visibility.Collapsed;
        PageLayout.Visibility = PageToolbar.Visibility = landing ? Visibility.Collapsed : Visibility.Visible;
        RefreshButton.IsEnabled = !busy;
        SearchBox.IsEnabled = SortBox.IsEnabled = ApplicationsList.IsEnabled = !busy;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested || uninstall.IsBusy && !uninstall.StopRequested;
        PreviousButton.IsEnabled = !busy && model.Page?.Offset > 0;
        NextButton.IsEnabled = !busy && model.Page?.HasNext == true;
        PreviousButton.Visibility = NextButton.Visibility = model.Page is { } paging && (paging.Offset > 0 || paging.HasNext)
            ? Visibility.Visible : Visibility.Collapsed;
        Progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        Progress.IsIndeterminate = busy && AppearanceSettings.AnimationsEnabled;
        CancelButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        EmptyContent.Visibility = model.Page?.Items.IsEmpty == false ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Text = text.Get(model.IsBusy ? "Loading…" : model.State == ApplicationsPageState.Failed ? "Application registrations could not be loaded. Try refreshing the list." : "No matching applications.");
        CoverageNotice.IsOpen = model.State == ApplicationsPageState.Partial;
        CoverageButton.Visibility = CoverageNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        ShowStatus(model.ErrorCode is not null ? text.Get("Application registrations could not be loaded. Try refreshing the list.") :
            model.StopRequested ? text.Get("Stopping…") : model.State switch
            {
                ApplicationsPageState.Loading => text.Get("Loading…"),
                ApplicationsPageState.Cancelled => text.Get("Cancelled"),
                _ => ""
            });
        CoverageText.Text = model.Page is { } result ? string.Join(" · ", result.Sources.Select(source =>
            Source(source.Source) + ": " + text.Get(source.State == ApplicationSourceState.Complete ? "Read" : "Incomplete"))) : "";
        var selectedId = (ApplicationsList.SelectedItem as ApplicationDisplay)?.Application.Id;
        ApplicationSummary.Text = model.Page is not null ? text.Format("%lld registered applications", model.CatalogCount) : text.Get("Applications");
        EstimatedBytes.Text = model.Page is null ? "" : StorageRow.FormatBytes(model.RegisteredEstimatedBytes);
        FilterAll.Content = text.Get("All") + " " + model.CatalogCount;
        FilterSystem.Content = text.Get("System package") + " " + model.SystemPackageCount;
        FilterSized.Content = text.Get("Registered size") + " " + model.SizedCount;
        FilterCurrentUser.Content = text.Get("Current-user installation") + " " + model.CurrentUserCount;
        FilterAll.IsChecked = presentation == ApplicationPresentationFilter.All;
        FilterSystem.IsChecked = presentation == ApplicationPresentationFilter.SystemPackage;
        FilterSized.IsChecked = presentation == ApplicationPresentationFilter.HasRegisteredSize;
        FilterCurrentUser.IsChecked = presentation == ApplicationPresentationFilter.CurrentUser;
        foreach (var pill in new[] { FilterAll, FilterSystem, FilterSized, FilterCurrentUser }) pill.IsEnabled = !busy;
        var rows = model.Page?.Items.Select(application => new ApplicationDisplay(application,
            string.Join(" · ", new[] { application.Publisher, application.Version, Source(application.Source) }.Where(value => !string.IsNullOrEmpty(value))),
            Size(application), text.Get(application.IsSystemPackage ? "System package" : "Review"))).ToArray();
        inlineDetails.Hide();
        rendering = true;
        ApplicationsList.ItemsSource = rows;
        ApplicationsList.SelectedItem = rows?.FirstOrDefault(row => row.Application.Id == selectedId);
        rendering = false;
        ReconcileSelection();
        ShowDetails();
        RenderUninstall();
    }

    private string Size(InstalledApplication application) => application.RegisteredEstimatedBytes is { } size
        ? StorageRow.FormatBytes(size) : text.Get("Unknown size");
    private string Source(ApplicationSource source) => text.Get(source switch
    {
        ApplicationSource.CurrentUserRegistry => "Current-user installation",
        ApplicationSource.MachineRegistry64 => "Machine installation (64-bit registry)",
        ApplicationSource.MachineRegistry32 => "Machine installation (32-bit registry)",
        _ => "Current-user MSIX package"
    });

    private void ShowDetails()
    {
        if (ApplicationsList.SelectedItem is not ApplicationDisplay row)
        { Details.Text = text.Get("Select an application to view its registration details."); updates?.Dispose(); updates = null; UpdatesHost.Content = null; return; }
        var app = row.Application;
        if (updates?.Application != app) { updates?.Dispose(); updates = new(app); UpdatesHost.Content = updates; }
        updates.SetBusy(model.IsBusy || uninstall.IsBusy);
        var lines = new List<string> { app.Name, Source(app.Source), app.RegistrationKey };
        if (!string.IsNullOrEmpty(app.Version)) lines.Add(text.Get("Version") + ": " + app.Version);
        if (!string.IsNullOrEmpty(app.Publisher)) lines.Add(text.Get("Publisher") + ": " + app.Publisher);
        lines.Add(text.Get("Registered size") + ": " + Size(app));
        if (app.RegisteredInstallLocation is { } location) lines.Add(text.Get("Registered location (unverified)") + ": " + location.Value);
        if (!app.Issues.IsEmpty) lines.Add(text.Get("The registered installation location is unavailable or invalid."));
        if (app.IsSystemPackage) lines.Add(text.Get("Windows identifies this as a system package."));
        Details.Text = string.Join(Environment.NewLine + Environment.NewLine, lines);
    }

    private void CloseInspector(object sender, RoutedEventArgs args) { if (!uninstall.IsBusy) { inlineDetails.Hide(); ApplicationsList.SelectedItem = null; } }
    private void ExpandApplication(Expander sender, ExpanderExpandingEventArgs args)
    {
        if (uninstall.IsBusy) { sender.IsExpanded = false; return; }
        ApplicationsList.SelectedItem = sender.Tag; inlineDetails.Show(sender); ShowDetails(); RenderUninstall();
    }
    private void CollapseApplication(Expander sender, ExpanderCollapsedEventArgs args) { if (!uninstall.IsBusy) inlineDetails.Hide(); }
    private void LoadRowIcon(object sender, RoutedEventArgs args) { if (sender is ContentControl host) host.Content = ProductIcon.Create("applications", (double)Application.Current.Resources["ShouCatalogIconSize"]); }
    private void ChangeSearch(object sender, TextChangedEventArgs args) => Filter();
    private void ChangePresentationFilter(object sender, RoutedEventArgs args)
    {
        if (disposed) return;
        if (initialized && sender is ToggleButton { Tag: string tag })
        {
            presentation = tag switch
            {
                "system" => ApplicationPresentationFilter.SystemPackage,
                "sized" => ApplicationPresentationFilter.HasRegisteredSize,
                "user" => ApplicationPresentationFilter.CurrentUser,
                _ => ApplicationPresentationFilter.All
            };
            try { model.SetPresentationFilter(presentation); }
            catch (ShouException) { ShowStatus(text.Get("Enter a search without control characters.")); }
        }
        ApplyPresentationPills();
    }
    private void ApplyPresentationPills()
    {
        FilterAll.IsChecked = presentation == ApplicationPresentationFilter.All;
        FilterSystem.IsChecked = presentation == ApplicationPresentationFilter.SystemPackage;
        FilterSized.IsChecked = presentation == ApplicationPresentationFilter.HasRegisteredSize;
        FilterCurrentUser.IsChecked = presentation == ApplicationPresentationFilter.CurrentUser;
    }
    private void ChangeSort(object sender, SelectionChangedEventArgs args) => Filter();
    private void Filter()
    {
        if (!initialized || disposed || uninstall.IsBusy) return;
        try { model.Filter(SearchBox.Text, SortBox.SelectedIndex == 1 ? ApplicationSort.RegisteredSize : ApplicationSort.Name); }
        catch (ShouException) { ShowStatus(text.Get("Enter a search without control characters.")); }
    }
    private void ShowStatus(string message)
    {
        Status.Text = message;
        Status.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
    private void ShowCoverage(object sender, RoutedEventArgs args) => InfoButton.Flyout?.ShowAt((FrameworkElement)sender);
    private async void Refresh(object sender, RoutedEventArgs args)
    {
        if (disposed || uninstall.IsBusy) return;
        try { uninstall.Invalidate(); await model.RefreshAsync(); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private void Cancel(object sender, RoutedEventArgs args) { model.Cancel(); uninstall.Cancel(); }
    private void Previous(object sender, RoutedEventArgs args) { if (!uninstall.IsBusy) model.PreviousPage(); }
    private void Next(object sender, RoutedEventArgs args) { if (!uninstall.IsBusy) model.NextPage(); }
    private void SelectApplication(object sender, SelectionChangedEventArgs args)
    {
        if (!initialized || disposed || rendering || uninstall.IsExecuting) return;
        ReconcileSelection();
        ShowDetails();
        RenderUninstall();
    }
    private void ReconcileSelection()
    {
        var id = (ApplicationsList.SelectedItem as ApplicationDisplay)?.Application.Id;
        if (id == selectedApplicationId) return;
        selectedApplicationId = id;
        uninstall.Invalidate();
    }
    private void UninstallChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName != nameof(ApplicationUninstallViewModel.State) || disposed) return;
        updates?.SetBusy(model.IsBusy || uninstall.IsBusy);
        RefreshButton.IsEnabled = SearchBox.IsEnabled = SortBox.IsEnabled = ApplicationsList.IsEnabled = !model.IsBusy && !uninstall.IsBusy;
        PreviousButton.IsEnabled = !model.IsBusy && !uninstall.IsBusy && model.Page?.Offset > 0;
        NextButton.IsEnabled = !model.IsBusy && !uninstall.IsBusy && model.Page?.HasNext == true;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested || uninstall.IsBusy && !uninstall.StopRequested;
        Progress.Visibility = model.IsBusy || uninstall.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        RenderUninstall();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }
    private void RenderUninstall()
    {
        if (disposed) return;
        var selectedCount = selectedApplicationId is null ? 0 : 1;
        SelectionSummary.Text = text.Format("%lld applications selected", selectedCount);
        AutomationProperties.SetItemStatus(SelectionSummary, selectedCount.ToString(System.Globalization.CultureInfo.InvariantCulture));
        UninstallFooterButton.IsEnabled = uninstall.ExecutionAvailable && selectedApplicationId is not null && !model.IsBusy && !uninstall.IsBusy;
        InspectButton.IsEnabled = selectedApplicationId is not null && !model.IsBusy && !uninstall.IsBusy;
        InstallerDataConsent.Visibility = PreparePlanButton.Visibility = uninstall.Review?.CanPreparePlan == true ? Visibility.Visible : Visibility.Collapsed;
        ExecuteButton.Visibility = uninstall.Plan is null ? Visibility.Collapsed : Visibility.Visible;
        ReadExecutionButton.Visibility = uninstall.CanReadExecution ? Visibility.Visible : Visibility.Collapsed;
        InstallerDataConsent.IsEnabled = uninstall.Review?.CanPreparePlan == true && !uninstall.IsBusy;
        InstallerDataConsent.IsChecked = uninstall.AllowInstallerDataChanges;
        PreparePlanButton.IsEnabled = uninstall.CanPreparePlan;
        ExecuteButton.IsEnabled = uninstall.CanExecute;
        ReadExecutionButton.IsEnabled = uninstall.CanReadExecution;
        if (uninstall.IsBusy)
        { UninstallStatus.Text = uninstall.IsExecuting ? text.Get(uninstall.StopRequested
                ? "Stop requested. Waiting for the system installer result; keep this window open."
                : "Waiting for confirmation or the system installer result. Keep this window open.")
            : text.Get("Loading…"); return; }
        if (uninstall.ErrorCode is not null)
        { UninstallStatus.Text = UninstallError(uninstall.ErrorCode) + RecordReference(); return; }
        if (uninstall.Execution is { } execution)
        { UninstallStatus.Text = ExecutionDescription(execution); return; }
        if (uninstall.Plan is { } plan)
        {
            UninstallStatus.Text = text.Get(uninstall.ExecutionAvailable
                ? "Uninstall plan saved. Review and confirm this installation before it expires."
                : "Uninstall plan saved. Execution is not available yet.") + Environment.NewLine + plan.Id;
            return;
        }
        if (uninstall.State == ApplicationUninstallPageState.Cancelled) { UninstallStatus.Text = text.Get("Cancelled") + RecordReference(); return; }
        if (uninstall.Review is not { } review) { UninstallStatus.Text = ""; return; }
        if (!review.CanPreparePlan)
        {
            UninstallStatus.Text = review.Activity.State == ActivityState.Active
                ? text.Get("This application or one of its files is in use. Close it and review the installation again.")
                : review.BlockingReasons.Contains("application_activity_unknown")
                    ? text.Get("Application activity could not be verified within the installation folder. Close the application and try reviewing it again.")
                    : text.Get("This installation cannot currently be prepared for uninstall. It may be protected, unsupported, or could not be verified.");
            return;
        }
        var identity = review.Installation.Identity!;
        UninstallStatus.Text = (identity.Kind == ApplicationInstallerKind.Msi ? "MSI" : "MSIX") + Environment.NewLine + identity.SystemId +
            Environment.NewLine + text.Get("The system installer may stop managed apps or services and remove data. Shou cannot restore this operation.") +
            Environment.NewLine + text.Get(uninstall.ExecutionAvailable
                ? "Review the installer data changes before preparing an uninstall plan."
                : "Activity checks cover the installation folder; execution is not available yet.");
    }
    private string RecordReference() => uninstall.ExecutionPlanId is { } id
        ? Environment.NewLine + text.Get("Uninstall plan") + ": " + id : "";
    private string UninstallError(string code) => text.Get(code switch
    {
        "journal_write_failed" => "The uninstall record could not be saved. The installer may have made changes. Read the record before reviewing this installation again.",
        "not_found" when uninstall.ExecutionPlanId is not null => "No uninstall record was found for this plan. This does not confirm the current installation state.",
        "confirmation_required" => "Uninstall was not confirmed. Review this installation again to prepare a new plan.",
        "plan_consumed" => "This plan already has an uninstall attempt. Read its record; the plan cannot be run again.",
        "corrupt_record" => "The uninstall record could not be verified. Do not infer success or retry from this record.",
        "unsupported_capability" => "System uninstall is unavailable until native Windows verification is complete.",
        "plan_stale" => "This uninstall plan expired. Review this installation again.",
        "store_busy" => "Another operation is using the local records. Wait for it to finish.",
        "permission_denied" => "Permission was denied while accessing the uninstall plan or record.",
        "io_error" => "The uninstall plan or record could not be accessed. Read the record before taking further action.",
        "internal_error" => "The uninstall result could not be determined. Read the saved record before taking further action.",
        _ => "The installation could not be verified or changed after review. Review it again."
    });
    private string ExecutionDescription(ApplicationUninstallExecution execution)
    {
        var lines = new List<string>
        {
            text.Get("Saved uninstall record; this is not a fresh installation check."),
            text.Get("Recorded at") + ": " + execution.UpdatedAt.ToLocalTime().ToString("g"),
            text.Get(execution.State switch
            {
                ApplicationUninstallState.Completed => "Uninstall completed; the original installation identity was absent when checked.",
                ApplicationUninstallState.Failed => "The uninstall attempt failed. The installer may have made changes.",
                ApplicationUninstallState.Cancelled => "The uninstall attempt was cancelled. The installer may have made changes.",
                _ => "The uninstall outcome is uncertain. Do not rerun this plan. Review the installation state separately."
            })
        };
        if (execution.Result is { } result)
        {
            lines.Add(text.Get(result.Outcome switch
            {
                SystemUninstallOutcome.Succeeded => "Installer result: succeeded.",
                SystemUninstallOutcome.Failed => "Installer result: failed.",
                SystemUninstallOutcome.Cancelled => "Installer result: cancelled.",
                SystemUninstallOutcome.NotStarted => "Installer result: not started.",
                _ => "Installer result: unknown."
            }));
            lines.Add(text.Get(result.Presence switch
            {
                InstallationPresence.Absent => "Original installation identity at the recorded check: absent.",
                InstallationPresence.Present => "Original installation identity at the recorded check: present.",
                InstallationPresence.Changed => "Original installation identity at the recorded check: changed.",
                _ => "Original installation identity at the recorded check: unknown."
            }));
            if (result.NativeCode is { } code) lines.Add(text.Get("Installer code") + ": " + code);
            if (result.RestartRequired) lines.Add(text.Get("The installer requested a restart. Shou will not restart Windows automatically."));
        }
        lines.Add(text.Get("Shou cannot restore a system uninstall and does not automatically clean residual files."));
        lines.Add(text.Get("Uninstall plan") + ": " + execution.PlanId);
        return string.Join(Environment.NewLine + Environment.NewLine, lines);
    }
    private async void InspectUninstall(object sender, RoutedEventArgs args)
    {
        if (selectedApplicationId is not { } id) return;
        try { await uninstall.InspectAsync(id); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private async void ReviewSelectedUninstall(object sender, RoutedEventArgs args)
    {
        if (selectedApplicationId is not { } id || uninstall.IsBusy || model.IsBusy) return;
        try
        {
            var content = new StackPanel { Spacing = 12 };
            await uninstall.InspectAsync(id);
            content.Children.Add(new TextBlock { Text = UninstallStatus.Text, TextWrapping = TextWrapping.Wrap });
            if (uninstall.Review is not { CanPreparePlan: true })
            {
                await new ContentDialog { XamlRoot = XamlRoot, Title = text.Get("Review Uninstall"), Content = content, CloseButtonText = text.Get("Done") }.ShowAsync();
                return;
            }
            var consent = new CheckBox { Content = new TextBlock { Text = InstallerDataDescription.Text, TextWrapping = TextWrapping.Wrap } };
            content.Children.Add(consent);
            var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = text.Get("Review Uninstall"), Content = content, PrimaryButtonText = text.Get("Prepare Uninstall Plan"), CloseButtonText = text.Get("Cancel"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false };
            consent.Checked += (_, _) => dialog.IsPrimaryButtonEnabled = true;
            consent.Unchecked += (_, _) => dialog.IsPrimaryButtonEnabled = false;
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || consent.IsChecked != true || disposed) return;
            uninstall.SetDataConsent(true);
            await uninstall.PreparePlanAsync();
            if (!uninstall.CanExecute) return;
            await uninstall.ExecuteAsync(new WinUIApplicationUninstallConfirmation(this, text));
            if (!disposed && uninstall.Execution?.State == ApplicationUninstallState.Completed) await model.RefreshAsync();
        }
        catch (Exception error) { NativeDiagnostics.Write(error); if (!disposed) UninstallStatus.Text = UninstallError(error is ShouException known ? known.Code : "io_error"); }
    }
    private void ChangeInstallerDataConsent(object sender, RoutedEventArgs args) => uninstall.SetDataConsent(InstallerDataConsent.IsChecked == true);
    private async void PrepareUninstallPlan(object sender, RoutedEventArgs args)
    {
        try { await uninstall.PreparePlanAsync(); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private async void ExecuteUninstall(object sender, RoutedEventArgs args)
    {
        try { await uninstall.ExecuteAsync(new WinUIApplicationUninstallConfirmation(this, text)); }
        catch (Exception error) { NativeDiagnostics.Write(error); if (!disposed) UninstallStatus.Text = UninstallError(error is ShouException known ? known.Code : "io_error"); }
    }
    private async void ReadUninstallExecution(object sender, RoutedEventArgs args)
    {
        try { await uninstall.ReadExecutionAsync(); }
        catch (Exception error) { NativeDiagnostics.Write(error); if (!disposed) UninstallStatus.Text = UninstallError(error is ShouException known ? known.Code : "io_error") + RecordReference(); }
    }
    public void RequestUninstallStop() => uninstall.Cancel();
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        model.PropertyChanged -= Changed;
        model.Dispose();
        uninstall.PropertyChanged -= UninstallChanged;
        uninstall.Dispose();
        updates?.Dispose();
        GC.SuppressFinalize(this);
    }
    [Microsoft.UI.Xaml.Data.Bindable]
    private sealed record ApplicationDisplay(InstalledApplication Application, string Subtitle, string RegisteredSize, string Status)
    {
        public string Name => Application.Name;
        public string Publisher => Application.Publisher ?? "";
    }
}
