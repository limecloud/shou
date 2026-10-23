using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class ApplicationsPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly ApplicationsViewModel model = new(new ApplicationCatalog(new WindowsApplicationInventory()));
    private readonly ApplicationUninstallViewModel uninstall = new(new NativeApplicationOperations());
    private Task? initialLoad;
    private bool disposed;
    private bool initialized;
    private bool rendering;
    private string? selectedApplicationId;
    public bool HasActiveUninstall => uninstall.IsExecuting;
    public event EventHandler? BusyChanged;

    public ApplicationsPage()
    {
        InitializeComponent();
        PageTitle.Text = text.Get("Applications");
        Description.Text = text.Get("Browse registered applications. Portable apps and other users are not included. Sizes are installer estimates, not measured disk usage. Uninstall is not available yet.");
        SearchBox.PlaceholderText = text.Get("Search applications…");
        AutomationProperties.SetName(SearchBox, text.Get("Search applications…"));
        AutomationProperties.SetName(ApplicationsList, text.Get("Applications"));
        AutomationProperties.SetName(SortBox, text.Get("Sort applications"));
        NameSort.Content = text.Get("Name");
        SizeSort.Content = text.Get("Registered size");
        SortBox.SelectedIndex = 0;
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
        var busy = model.IsBusy || uninstall.IsBusy;
        RefreshButton.IsEnabled = !busy;
        SearchBox.IsEnabled = SortBox.IsEnabled = ApplicationsList.IsEnabled = !busy;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested || uninstall.IsBusy && !uninstall.StopRequested;
        PreviousButton.IsEnabled = !busy && model.Page?.Offset > 0;
        NextButton.IsEnabled = !busy && model.Page?.HasNext == true;
        Progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        CoverageNotice.IsOpen = model.State == ApplicationsPageState.Partial;
        Status.Text = model.ErrorCode is not null ? text.Get("Application registrations could not be loaded. Try refreshing the list.") :
            model.StopRequested ? text.Get("Stopping…") : model.State switch
            {
                ApplicationsPageState.Loading => text.Get("Loading…"),
                ApplicationsPageState.Cancelled => text.Get("Cancelled"),
                _ when model.Page is { } page => text.Format("%lld registered applications", page.Total),
                _ => ""
            };
        CoverageText.Text = model.Page is { } result ? string.Join(" · ", result.Sources.Select(source =>
            Source(source.Source) + ": " + text.Get(source.State == ApplicationSourceState.Complete ? "Read" : "Incomplete"))) : "";
        var selectedId = (ApplicationsList.SelectedItem as ApplicationDisplay)?.Application.Id;
        var rows = model.Page?.Items.Select(application => new ApplicationDisplay(application,
            string.Join(" · ", new[] { application.Publisher, application.Version, Source(application.Source) }.Where(value => !string.IsNullOrEmpty(value))),
            Size(application))).ToArray();
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
        { Details.Text = text.Get("Select an application to view its registration details."); return; }
        var app = row.Application;
        var lines = new List<string> { app.Name, Source(app.Source), app.RegistrationKey };
        if (!string.IsNullOrEmpty(app.Version)) lines.Add(text.Get("Version") + ": " + app.Version);
        if (!string.IsNullOrEmpty(app.Publisher)) lines.Add(text.Get("Publisher") + ": " + app.Publisher);
        lines.Add(text.Get("Registered size") + ": " + Size(app));
        if (app.RegisteredInstallLocation is { } location) lines.Add(text.Get("Registered location (unverified)") + ": " + location.Value);
        if (!app.Issues.IsEmpty) lines.Add(text.Get("The registered installation location is unavailable or invalid."));
        if (app.IsSystemPackage) lines.Add(text.Get("Windows identifies this as a system package."));
        Details.Text = string.Join(Environment.NewLine + Environment.NewLine, lines);
    }

    private void ChangeSearch(object sender, TextChangedEventArgs args) => Filter();
    private void ChangeSort(object sender, SelectionChangedEventArgs args) => Filter();
    private void Filter()
    {
        if (!initialized || disposed || uninstall.IsBusy) return;
        try { model.Filter(SearchBox.Text, SortBox.SelectedIndex == 1 ? ApplicationSort.RegisteredSize : ApplicationSort.Name); }
        catch (ShouException) { Status.Text = text.Get("Enter a search without control characters."); }
    }
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
        InspectButton.IsEnabled = selectedApplicationId is not null && !model.IsBusy && !uninstall.IsBusy;
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
            Environment.NewLine + text.Get("Activity checks cover the installation folder; execution is not available yet.");
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
        GC.SuppressFinalize(this);
    }
    private sealed record ApplicationDisplay(InstalledApplication Application, string Subtitle, string RegisteredSize)
    {
        public string Name => Application.Name;
    }
}
