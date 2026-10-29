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
    private readonly ApplicationSelectionViewModel selection = new(() => new(new NativeApplicationOperations(), authorization: WindowsSystemAuthorization.Shared));
    private readonly ApplicationUninstallViewModel emptyReview = new(new NativeApplicationOperations());
    private ApplicationUninstallViewModel uninstall => selectedApplicationId is { } id ? selection.Item(id).Review : emptyReview;
    private Task? initialLoad;
    private bool disposed;
    private bool initialized;
    private bool rendering;
    private readonly InlineDetails inlineDetails;
    private ApplicationPresentationFilter presentation = ApplicationPresentationFilter.All;
    private string? selectedApplicationId;
    private ApplicationUpdatePanel? updates;
    public bool HasActiveUninstall => selection.IsExecuting || selection.IsPreparing || selection.IsClosing;
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
        UninstallFooterButton.Content = text.Get("Uninstall Permanently");
        ToolTipService.SetToolTip(UninstallFooterButton, text.Get("Permanent deletion cannot be undone."));
        AutomationProperties.SetHelpText(UninstallFooterButton, text.Get("Permanent deletion cannot be undone."));
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
        InspectButton.Content = text.Get("Check Again");
        AuthorizeButton.Content = text.Get("Authorize…");
        QuitSelectedButton.Content = text.Get("Quit Selected Apps and Check Again");
        ShortcutsButton.Content = text.Get("Broken Shortcuts");
        ClearSelectionButton.Content = text.Get("Clear Selection");
        ReadExecutionButton.Content = text.Get("Read Uninstall Record");
        InstallerDataDescription.Text = text.Get("I understand the system installer may remove data it manages. Shou does not include additional residual files in this plan.");
        model.PropertyChanged += Changed;
        selection.Changed += SelectionChanged;
        initialized = true;
        Render();
    }

    public Task EnsureLoadedAsync() => initialLoad ??= model.RefreshAsync();
    private void Changed(object? sender, PropertyChangedEventArgs args) { if (args.PropertyName == nameof(ApplicationsViewModel.Page)) Render(); }
    private void Render()
    {
        if (disposed) return;
        PageDiagnostics.Update(this, "applications", model.State, model.ErrorCode);
        var busy = model.IsBusy || !selection.CanChangeSelection;
        var landing = model.Page is null && !busy;
        LandingHost.Visibility = landing ? Visibility.Visible : Visibility.Collapsed;
        PageLayout.Visibility = landing ? Visibility.Collapsed : Visibility.Visible;
        PageToolbar.Visibility = Visibility.Visible;
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
        EmptyContent.Visibility = busy || model.Page?.Items.IsEmpty == false ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Text = text.Get(model.State == ApplicationsPageState.Failed ? "Application registrations could not be loaded. Try refreshing the list." : "No matching applications.");
        CoverageNotice.IsOpen = model.State == ApplicationsPageState.Partial;
        CoverageNotice.Content = model.Page?.Sources.Any(source => source.Issues.Any(AdministratorAccessButton.Required)) == true ? new AdministratorAccessButton() : null;
        CoverageButton.Visibility = CoverageNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        ShowStatus(model.ErrorCode is not null ? text.Get("Application registrations could not be loaded. Try refreshing the list.") :
            model.StopRequested ? text.Get("Stopping…") : model.State switch
            {
                ApplicationsPageState.Loading => text.Get("Loading…"),
                ApplicationsPageState.Cancelled => text.Get("Cancelled"),
                _ => ""
            });
        CoverageText.Text = model.Page is { } result ? string.Join(", ", result.Sources.Select(source =>
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
        var rows = model.Page?.Items.Select(application => new ApplicationDisplay(application, selection.Item(application.Id),
            string.Join(", ", new[] { application.Publisher, application.Version, Source(application.Source) }.Where(value => !string.IsNullOrEmpty(value))),
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
        updates.SetBusy(model.IsBusy || !selection.CanChangeSelection);
        var lines = new List<string> { app.Name, Source(app.Source), app.RegistrationKey };
        if (!string.IsNullOrEmpty(app.Version)) lines.Add(text.Get("Version") + ": " + app.Version);
        if (!string.IsNullOrEmpty(app.Publisher)) lines.Add(text.Get("Publisher") + ": " + app.Publisher);
        lines.Add(text.Get("Registered size") + ": " + Size(app));
        if (app.RegisteredInstallLocation is { } location) lines.Add(text.Get("Registered location (unverified)") + ": " + location.Value);
        if (!app.Issues.IsEmpty) lines.Add(text.Get("The registered installation location is unavailable or invalid."));
        if (app.IsSystemPackage) lines.Add(text.Get("Windows identifies this as a system package."));
        Details.Text = string.Join(Environment.NewLine + Environment.NewLine, lines);
    }

    private void CloseInspector(object sender, RoutedEventArgs args) { if (selection.CanChangeSelection) { inlineDetails.Hide(); ApplicationsList.SelectedItem = null; } }
    private void ExpandApplication(Expander sender, ExpanderExpandingEventArgs args)
    {
        if (!selection.CanChangeSelection) { sender.IsExpanded = false; return; }
        ApplicationsList.SelectedItem = sender.Tag; inlineDetails.Show(sender); ShowDetails(); RenderUninstall();
    }
    private void CollapseApplication(Expander sender, ExpanderCollapsedEventArgs args) { if (selection.CanChangeSelection) inlineDetails.Hide(); }
    private void LoadRowIcon(object sender, RoutedEventArgs args) { if (sender is ContentControl host) host.Content = ProductIcon.Create("applications", (double)Application.Current.Resources["ShouCatalogIconSize"]); }
    private void ChangeSearch(object sender, TextChangedEventArgs args) => Filter();
    private void ChangePresentationFilter(object sender, RoutedEventArgs args)
    {
        if (disposed || !selection.CanChangeSelection) return;
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
        if (!initialized || disposed || !selection.CanChangeSelection) return;
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
        if (disposed || !selection.CanChangeSelection || selection.IsReviewing) return;
        try { selectedApplicationId = null; selection.Reset(); await model.RefreshAsync(); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private void Cancel(object sender, RoutedEventArgs args) { model.Cancel(); selection.Stop(); }
    private void Previous(object sender, RoutedEventArgs args) { if (selection.CanChangeSelection) model.PreviousPage(); }
    private void Next(object sender, RoutedEventArgs args) { if (selection.CanChangeSelection) model.NextPage(); }
    private void SelectApplication(object sender, SelectionChangedEventArgs args)
    {
        if (!initialized || disposed || rendering || !selection.CanChangeSelection) return;
        ReconcileSelection();
        ShowDetails();
        RenderUninstall();
    }
    private void ReconcileSelection()
    {
        var id = (ApplicationsList.SelectedItem as ApplicationDisplay)?.Application.Id;
        if (id == selectedApplicationId) return;
        selectedApplicationId = id;
        if (id is not null) _ = selection.InspectAsync(id, refresh: false);
    }
    private void SelectionChanged(object? sender, EventArgs args)
    {
        if (disposed) return;
        var available = !model.IsBusy && selection.CanChangeSelection;
        updates?.SetBusy(!available);
        RefreshButton.IsEnabled = available && !selection.IsReviewing;
        SearchBox.IsEnabled = SortBox.IsEnabled = ApplicationsList.IsEnabled = available;
        foreach (var pill in new[] { FilterAll, FilterSystem, FilterSized, FilterCurrentUser }) pill.IsEnabled = available;
        ShortcutsButton.IsEnabled = available;
        PreviousButton.IsEnabled = available && model.Page?.Offset > 0;
        NextButton.IsEnabled = available && model.Page?.HasNext == true;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested || selection.IsReviewing || selection.IsExecuting || selection.IsPreparing || selection.IsClosing;
        CancelButton.Visibility = CancelButton.IsEnabled ? Visibility.Visible : Visibility.Collapsed;
        Progress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        if (ApplicationsList.ItemsSource is ApplicationDisplay[] rows) foreach (var row in rows) row.Refresh(available);
        RenderUninstall();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }
    private void RenderUninstall()
    {
        if (disposed) return;
        var selectedCount = selection.SelectedCount;
        SelectionSummary.Text = text.Format("%lld applications selected", selectedCount);
        AutomationProperties.SetItemStatus(SelectionSummary, selectedCount.ToString(System.Globalization.CultureInfo.InvariantCulture));
        UninstallFooterButton.IsEnabled = selection.CanExecute && !model.IsBusy;
        InspectButton.IsEnabled = selectedApplicationId is not null && !model.IsBusy && !uninstall.IsBusy;
        InstallerDataConsent.Visibility = uninstall.Review?.CanPreparePlan == true ? Visibility.Visible : Visibility.Collapsed;
        ReadExecutionButton.Visibility = uninstall.CanReadExecution ? Visibility.Visible : Visibility.Collapsed;
        InstallerDataConsent.IsEnabled = uninstall.Review?.CanPreparePlan == true && !uninstall.IsBusy;
        InstallerDataConsent.IsChecked = uninstall.AllowInstallerDataChanges;
        ReadExecutionButton.IsEnabled = uninstall.CanReadExecution;
        AuthorizeButton.Visibility = uninstall.RequiresAuthorization ? Visibility.Visible : Visibility.Collapsed;
        AuthorizeButton.IsEnabled = !uninstall.IsBusy && selection.CanChangeSelection;
        QuitSelectedButton.Visibility = selection.CanCloseSelected || selection.IsClosing ? Visibility.Visible : Visibility.Collapsed;
        QuitSelectedButton.IsEnabled = selection.CanCloseSelected;
        ClearSelectionButton.Visibility = selectedCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearSelectionButton.IsEnabled = selection.CanChangeSelection;
        FooterNotice.Text = text.Get(selection.IsReviewing ? "Selection is being checked…" : selection.Selected.Any(item => item.Review.Review?.Activity.State == ActivityState.Active)
            ? "Save your work before quitting. Apps that remain open must be closed manually." : uninstall.ExecutionAvailable
                ? "Review the installer data changes before preparing an uninstall plan."
                : "System uninstall is unavailable until native Windows verification is complete.");
        if (uninstall.IsBusy)
        { UninstallStatus.Text = uninstall.IsExecuting ? text.Get(uninstall.StopRequested
                ? "Stop requested. Waiting for the system installer result; keep this window open."
                : "Waiting for confirmation or the system installer result. Keep this window open.")
            : text.Get(uninstall.State == ApplicationUninstallPageState.Authorizing ? "Waiting for administrator authorization…"
                : uninstall.State == ApplicationUninstallPageState.Closing ? "Requesting applications to quit…" : "Selection is being checked…"); return; }
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
        if (uninstall.RequiresAuthorization) { UninstallStatus.Text = text.Get("Administrator authorization required"); return; }
        if (!review.CanPreparePlan)
        {
            UninstallStatus.Text = review.Activity.State == ActivityState.Active
                ? text.Get("This application or one of its files is in use. Close it and review the installation again.")
                : review.BlockingReasons.Contains("application_activity_unknown")
                    ? text.Get("Application activity could not be verified within the installation folder. Close the application and try reviewing it again.")
                    : text.Get(review.BlockingReasons.Contains("protected_application") ? "This application is protected and cannot be uninstalled."
                        : review.BlockingReasons.Contains("unsupported_installer") ? "This installer is not supported. Use Windows Settings to uninstall this application."
                        : "The installation could not be verified or changed after review. Review it again.");
            return;
        }
        var identity = review.Installation.Identity!;
        UninstallStatus.Text = string.Join(Environment.NewLine, new[]
            { review.Installation.Name, review.Installation.Version, review.Installation.Publisher, review.Installation.InstalledRoot?.Path.Value }
            .Where(value => !string.IsNullOrEmpty(value))) + Environment.NewLine +
            (identity.Kind == ApplicationInstallerKind.Msi ? "MSI" : "MSIX") + Environment.NewLine + identity.SystemId +
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
        "application_running" or "application_activity_unknown" => "Save your work before quitting. Apps that remain open must be closed manually.",
        "authorization_cancelled" => "Administrator authorization was not completed. Your selection is kept.",
        "authorization_unavailable" or "authorization_channel_lost" => "Administrator authorization could not be completed. Try again.",
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
        try { await selection.InspectAsync(id); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private void ChangeInstallerDataConsent(object sender, RoutedEventArgs args) => uninstall.SetDataConsent(InstallerDataConsent.IsChecked == true);
    private void ClearApplicationSelection(object sender, RoutedEventArgs args) => selection.Clear();
    private async void QuitSelectedApplications(object sender, RoutedEventArgs args)
    {
        try { await selection.CloseSelectedAndRecheckAsync(); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private async void ReviewShortcuts(object sender, RoutedEventArgs args)
    {
        if (!selection.CanChangeSelection || disposed) return;
        try { await ApplicationShortcutsPanel.ShowAsync(this); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private async void AuthorizeApplication(object sender, RoutedEventArgs args)
    {
        try { await uninstall.AuthorizeAsync(selectedApplicationId); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
    }
    private async void ToggleApplication(object sender, RoutedEventArgs args)
    {
        if (sender is not CheckBox { Tag: ApplicationDisplay row } check || disposed) return;
        try { await selection.SelectAsync(row.Application.Id, check.IsChecked == true); }
        catch (Exception error) { NativeDiagnostics.Write(error); }
        finally { if (!disposed) row.Refresh(!model.IsBusy && selection.CanChangeSelection); }
    }
    private async void ExecuteUninstall(object sender, RoutedEventArgs args)
    {
        if (disposed || model.IsBusy || !selection.CanExecute) return;
        try
        {
            await selection.ExecuteSelectedAsync(plan => WinUIApplicationUninstallConfirmation.Create(this, plan));
            if (!disposed) await model.RefreshAsync();
        }
        catch (Exception error) { NativeDiagnostics.Write(error); if (!disposed) UninstallStatus.Text = UninstallError(error is ShouException known ? known.Code : "io_error"); }
    }
    private async void ReadUninstallExecution(object sender, RoutedEventArgs args)
    {
        try { await uninstall.ReadExecutionAsync(); }
        catch (Exception error) { NativeDiagnostics.Write(error); if (!disposed) UninstallStatus.Text = UninstallError(error is ShouException known ? known.Code : "io_error") + RecordReference(); }
    }
    public void RequestUninstallStop() { selection.Stop(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        model.PropertyChanged -= Changed;
        model.Dispose();
        selection.Changed -= SelectionChanged;
        selection.Dispose(); emptyReview.Dispose();
        updates?.Dispose();
        GC.SuppressFinalize(this);
    }
    [Microsoft.UI.Xaml.Data.Bindable]
    private sealed class ApplicationDisplay(InstalledApplication application, ApplicationSelectionItem selection, string subtitle, string registeredSize, string initialStatus) : INotifyPropertyChanged
    {
        public InstalledApplication Application => application;
        public ApplicationSelectionItem Selection => selection;
        public string Subtitle => subtitle;
        public string RegisteredSize => registeredSize;
        public bool Selectable { get; private set; } = !application.IsSystemPackage;
        public string Status => new TextCatalog().Get(selection.IsQueued ? "Queued for review" : selection.Review.IsBusy
            ? selection.Review.State == ApplicationUninstallPageState.Authorizing ? "Waiting for administrator authorization…" : "Selection is being checked…"
            : selection.Review.RequiresAuthorization ? "Administrator Access" : selection.Review.Review is { } review
                ? review.Activity.State == ActivityState.Active ? "Quit Application First" : review.BlockingReasons.Contains("protected_application") ? "Protected"
                    : review.CanPreparePlan ? "Ready to Uninstall" : "Cannot Uninstall" : initialStatus);
        public event PropertyChangedEventHandler? PropertyChanged;
        public void Refresh(bool available)
        { Selectable = available && !application.IsSystemPackage; PropertyChanged?.Invoke(this, new(nameof(Selectable))); PropertyChanged?.Invoke(this, new(nameof(Status))); }
        public string Name => Application.Name;
        public string Publisher => Application.Publisher ?? "";
    }
}
