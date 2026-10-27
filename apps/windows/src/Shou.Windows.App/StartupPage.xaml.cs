using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class StartupPage : UserControl, IPageChrome, IDisposable
{
    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this);

    public FrameworkElement Toolbar => PageChrome.Detach(PageToolbar, PageLayout);
    private readonly TextCatalog text = new();
    private readonly StartupViewModel model = new(new StartupInventoryService(new WindowsStartupInventory()));
    private readonly StartupControlViewModel control = new(new NativeStartupControlOperations());
    private Task? initialLoad;
    private Task? activeControl;
    private bool initialized;
    private bool disposed;
    private bool rendering;
    private readonly InlineDetails inlineDetails;
    private StartupPresentationFilter presentation = StartupPresentationFilter.All;
    public event EventHandler? BusyChanged;
    public bool HasActiveStartupChange => activeControl is { IsCompleted: false } || control.IsExecuting;

    public StartupPage()
    {
        InitializeComponent();
        inlineDetails = new(Inspector, PageLayout);
        LandingHost.Content = WorkspaceVisuals.Landing(text, "A calmer start.",
            "Browse startup registrations and review eligible current-user scheduled tasks.", "startup", "Scan Startup Items", "startup.start", Refresh);
        PageTitle.Text = text.Get("Startup Items");
        FooterNotice.Text = text.Get(control.ExecutionAvailable
            ? "Review the exact task and confirm the requested switch before this review expires."
            : "Startup changes are unavailable in this preview. Observed task status is shown where available.");
        AutomationProperties.SetName(InfoButton, text.Get("Information")); AutomationProperties.SetName(CloseInspectorButton, text.Get("Close Details"));
        Description.Text = text.Get("Browse startup registrations and review eligible current-user scheduled tasks.");
        StateNotice.Text = text.Get("Registration alone does not prove an item is enabled or running. Shortcut targets are not resolved.");
        PreviousNotice.Text = text.Get("Showing results from the previous scan.");
        EnabledLabel.Text = text.Get("Enabled");
        CoverageLabel.Text = text.Get("Partial Coverage");
        AutomationProperties.SetName(CoverageButton, text.Get("Partial Coverage"));
        SearchBox.PlaceholderText = text.Get("Search startup items…");
        AutomationProperties.SetName(SearchBox, text.Get("Search startup items…"));
        AutomationProperties.SetName(SourceBox, text.Get("Startup source"));
        AutomationProperties.SetName(Registrations, text.Get("Startup Items"));
        SourceBox.ItemsSource = new[] { new StartupSourceOption(null, text.Get("All")) }.Concat(
            Enum.GetValues<StartupSource>().Select(source => new StartupSourceOption(source, Source(source)))).ToArray();
        SourceBox.SelectedIndex = 0;
        RefreshButton.Content = text.Get("Scan Again");
        CancelButton.Content = text.Get("Stop");
        PreviousButton.Content = text.Get("Previous");
        NextButton.Content = text.Get("Next");
        ReviewEnableButton.Content = text.Get("Review Enable");
        ReviewDisableButton.Content = text.Get("Review Disable");
        ApplyControlButton.Content = text.Get("Confirm Task Change");
        StopControlButton.Content = text.Get("Stop");
        ReadControlButton.Content = text.Get("Read Operation Result");
        CoverageNotice.Message = text.Get("Some startup sources could not be read. The list may be incomplete.");
        model.PropertyChanged += Changed;
        control.PropertyChanged += ControlChanged;
        initialized = true;
        Render();
    }

    public Task EnsureLoadedAsync() => initialLoad ??= model.RefreshAsync();
    private void Changed(object? sender, PropertyChangedEventArgs args) { if (args.PropertyName == nameof(StartupViewModel.Page)) Render(); }
    private void Render()
    {
        if (disposed) return;
        PageDiagnostics.Update(this, "startup", model.State, model.ErrorCode);
        var busy = model.IsBusy || control.IsBusy;
        var landing = model.Page is null && !busy;
        LandingHost.Visibility = landing ? Visibility.Visible : Visibility.Collapsed;
        PageLayout.Visibility = PageToolbar.Visibility = landing ? Visibility.Collapsed : Visibility.Visible;
        RefreshButton.IsEnabled = SearchBox.IsEnabled = SourceBox.IsEnabled = Registrations.IsEnabled = !busy;
        foreach (var pill in new[] { FilterAll, FilterEnabled, FilterDisabled, FilterUnknown }) pill.IsEnabled = !busy;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested;
        PreviousButton.IsEnabled = !busy && model.Page?.Offset > 0;
        NextButton.IsEnabled = !busy && model.Page?.HasNext == true;
        PaginationFooter.Visibility = model.Page is { } paging && (paging.Offset > 0 || paging.HasNext)
            ? Visibility.Visible : Visibility.Collapsed;
        Progress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        Progress.IsIndeterminate = model.IsBusy && AppearanceSettings.AnimationsEnabled;
        CancelButton.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        EmptyContent.Visibility = model.Page?.Items.IsEmpty == false ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Text = text.Get(model.IsBusy ? "Loading…" : model.State == StartupPageState.Failed ? "Startup registrations could not be loaded. Try refreshing the list." : "No matching startup items.");
        PreviousNotice.Visibility = model.ShowingPreviousResults ? Visibility.Visible : Visibility.Collapsed;
        CoverageNotice.IsOpen = model.Page?.State == ScanState.Partial;
        CoverageButton.Visibility = CoverageNotice.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        SummaryText.Text = model.Page is not null ? text.Format("%lld startup registrations", model.ItemCount) : "";
        EnabledCount.Text = model.KnownEnabledCount.ToString(System.Globalization.CultureInfo.CurrentCulture);
        FilterAll.Content = text.Get("All") + " " + model.Count(StartupPresentationFilter.All);
        FilterEnabled.Content = text.Get("Enabled") + " " + model.KnownEnabledCount;
        FilterDisabled.Content = text.Get("Disabled") + " " + model.KnownDisabledCount;
        FilterUnknown.Content = text.Get("Enablement unknown") + " " + model.UnknownEnablementCount;
        FilterAll.IsChecked = presentation == StartupPresentationFilter.All;
        FilterEnabled.IsChecked = presentation == StartupPresentationFilter.Enabled;
        FilterDisabled.IsChecked = presentation == StartupPresentationFilter.Disabled;
        FilterUnknown.IsChecked = presentation == StartupPresentationFilter.Unknown;
        ShowStatus(model.ErrorCode is not null ? text.Get("Startup registrations could not be loaded. Try refreshing the list.") :
            model.StopRequested ? text.Get("Stopping…") : model.State switch
            {
                StartupPageState.Loading => text.Get("Loading…"),
                StartupPageState.Cancelled => text.Get("Cancelled"),
                _ => ""
            });
        CoverageText.Text = model.Page is { } result ? string.Join(", ", result.Sources.Select(Coverage)) : "";
        var selected = (Registrations.SelectedItem as StartupDisplay)?.Item.Id;
        var ordered = model.Page?.Items.OrderBy(item => item.Source).ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ToArray();
        var rows = ordered?.Select(item =>
        {
            var source = Source(item.Source);
            return new StartupDisplay(item, source,
                item.ExecutablePath?.Value ?? item.DefinitionPath?.Value ?? text.Get("Executable path unknown"),
                text.Get(item.ScheduledTask is { } task ? task.Enabled ? "Enabled" : "Disabled" : "Enablement unknown"));
        }).ToArray();
        rendering = true;
        try
        {
            inlineDetails.Hide();
            Registrations.ItemsSource = rows;
            Registrations.SelectedItem = rows?.FirstOrDefault(row => row.Item.Id == selected);
        }
        finally { rendering = false; }
        ShowDetails();
        BindControl();
        RenderControl();
    }
    private void ShowStatus(string message)
    {
        Status.Text = message;
        Status.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
    private void ShowCoverage(object sender, RoutedEventArgs args) => InfoButton.Flyout?.ShowAt((FrameworkElement)sender);
    private void BindControl()
    {
        if (disposed || rendering || control.IsExecuting) return;
        control.Bind((Registrations.SelectedItem as StartupDisplay)?.Item);
        RenderControl();
    }
    private void ControlChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed) return;
        Render();
        BusyChanged?.Invoke(this, EventArgs.Empty);
    }
    private void RenderControl()
    {
        if (disposed) return;
        var selected = control.TaskPath is not null;
        ReviewEnableButton.Visibility = ReviewDisableButton.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        ReviewEnableButton.IsEnabled = ReviewDisableButton.IsEnabled = selected && !model.IsBusy && !control.IsBusy;
        ApplyControlButton.Visibility = control.Review is { CanChange: true } ? Visibility.Visible : Visibility.Collapsed;
        ApplyControlButton.IsEnabled = control.ExecutionAvailable && !control.IsBusy && !model.IsBusy;
        StopControlButton.Visibility = control.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        StopControlButton.IsEnabled = !control.StopRequested;
        ReadControlButton.Visibility = control.OperationId is not null ? Visibility.Visible : Visibility.Collapsed;
        ReadControlButton.IsEnabled = !control.IsBusy && !model.IsBusy;
        var reference = control.OperationId is { } id ? "\n" + id : "";
        ControlStatus.Text = control.IsExecuting ? text.Get(control.StopRequested ? "Stopping; waiting for the task change result…" : "Changing the scheduled task…") :
            control.IsBusy ? text.Get("Loading…") : control.ErrorCode is not null ? text.Get("The task change could not be completed. Review the task and read any recorded result.") + reference :
            control.Execution is { } execution ? text.Get(execution.State switch
            {
                StartupControlState.Completed => "The requested task switch was observed after the change.",
                StartupControlState.Cancelled => "The task change was not started.",
                StartupControlState.Failed => "The task change was not started.",
                _ => "The task change result is unknown. Check the task before taking another action."
            }) + reference : control.Review is { } review ? text.Get(!review.CanChange
                ? "This task is protected, uses an unsupported context, or is already in the requested state."
                : control.ExecutionAvailable ? "Review the exact task and confirm the requested switch before this review expires."
                : "Task changes are not available yet. You can review the task without changing it.") : "";
    }
    private async void ToggleStartup(object sender, RoutedEventArgs args)
    {
        if (disposed || model.IsBusy || control.IsBusy || sender is not ToggleButton { Tag: StartupDisplay row } toggle) return;
        // A click requests a review; keep the observed state until the native result is known.
        toggle.IsChecked = row.TaskEnabled;
        Registrations.SelectedItem = row;
        control.Bind(row.Item);
        try
        {
            await control.InspectAsync(row.TaskEnabled == true ? StartupControlAction.Disable : StartupControlAction.Enable);
            if (disposed) return;
            if (control.Review is not { CanChange: true })
            {
                await new ContentDialog { XamlRoot = XamlRoot, Title = text.Get("Startup Items"), Content = new TextBlock { Text = ControlStatus.Text, TextWrapping = TextWrapping.Wrap }, CloseButtonText = text.Get("Done") }.ShowAsync();
                return;
            }
            var task = control.ExecuteAsync(new WinUIStartupControlConfirmation(this, text));
            activeControl = task;
            await task;
            if (!disposed) await model.RefreshAsync();
        }
        catch (Exception error) { NativeDiagnostics.Write(error); }
        finally { activeControl = null; if (!disposed) { Render(); BusyChanged?.Invoke(this, EventArgs.Empty); } }
    }
    private async void ReviewControl(object sender, RoutedEventArgs args)
    {
        if (disposed || model.IsBusy || control.IsBusy || sender is not Button { Tag: string action }) return;
        await control.InspectAsync(action == "enable" ? StartupControlAction.Enable : StartupControlAction.Disable);
    }
    private async void ApplyControl(object sender, RoutedEventArgs args)
    {
        if (disposed || model.IsBusy || control.IsBusy || !control.ExecutionAvailable) return;
        var task = control.ExecuteAsync(new WinUIStartupControlConfirmation(this, text));
        activeControl = task;
        try { await task; if (!disposed) await model.RefreshAsync(); }
        finally { activeControl = null; if (!disposed) { Render(); BusyChanged?.Invoke(this, EventArgs.Empty); } }
    }
    private void StopControl(object sender, RoutedEventArgs args) => control.Cancel();
    private async void ReadControl(object sender, RoutedEventArgs args) { if (!disposed && !model.IsBusy) await control.ReadAsync(); }
    public void RequestStartupStop() => control.Cancel();
    private void ShowDetails()
    {
        if (disposed) return;
        if (Registrations.SelectedItem is not StartupDisplay row) { Details.Text = ""; return; }
        Details.Text = string.Join("\n", row.Item.Name, row.SourceLabel, row.Item.DefinitionPath?.Value ?? row.Item.RegistrationKey,
            row.Item.ExecutablePath?.Value ?? text.Get("Executable path unknown"),
            row.Item.Source == StartupSource.ScheduledTasks ? ScheduledStatus(row.Item) :
                text.Get("Enablement is unknown. Running state was not checked."));
    }
    private string ScheduledStatus(StartupItem item)
    {
        var status = item.ScheduledTask;
        var description = status is null ? text.Get(item.Issues.Contains("scheduled_task_status_changed")
            ? "Task status changed during scanning. Scan again to check it."
            : "Task status could not be read. Scan again to check it.") :
            text.Format("Task Scheduler reports: %@, %@.", text.Get(status.Enabled ? "Enabled" : "Disabled"), text.Get(status.State switch
            {
                ScheduledTaskState.Disabled => "Disabled", ScheduledTaskState.Queued => "Queued",
                ScheduledTaskState.Ready => "Ready to run", ScheduledTaskState.Running => "Running", _ => "Task Scheduler state unknown"
            }));
        return description + "\n" + text.Get("Task status does not confirm startup conditions or application activity.");
    }
    private string Source(StartupSource source) => text.Get(source switch
    {
        StartupSource.CurrentUserRun => "Current User Run",
        StartupSource.CurrentUserRunOnce => "Current User RunOnce",
        StartupSource.MachineRun64 => "System Run (64-bit)",
        StartupSource.MachineRun32 => "System Run (32-bit)",
        StartupSource.MachineRunOnce64 => "System RunOnce (64-bit)",
        StartupSource.MachineRunOnce32 => "System RunOnce (32-bit)",
        StartupSource.CurrentUserStartup => "Current User Startup Folder",
        StartupSource.ScheduledTasks => "Scheduled Tasks (Boot or Logon)",
        StartupSource.PackagedStartupTasks => "Packaged Startup Tasks",
        _ => "Shared Startup Folder"
    });
    private string Coverage(StartupSourceCoverage source)
    {
        var state = text.Get(source.State switch
        {
            StartupSourceState.Complete => "Read", StartupSourceState.Missing => "Not present",
            StartupSourceState.NotRead => "Not checked", _ => "Incomplete"
        });
        var reasons = source.Issues.Select(issue => text.Get(issue switch
        {
            "entry_limit" => "Startup entry limit reached.",
            "entry_budget_unknown" => "The previous source used an unknown portion of the scan budget.",
            "depth_limit" => "The startup scan reached the maximum folder depth.",
            "time_limit" => "Startup scan time limit reached.",
            "permission_denied" => "Access to this startup source was denied.",
            "invalid_registration_metadata" => "A startup registration could not be read safely.",
            "source_changed" or "registration_changed" => "Startup registrations changed during scanning.",
            "scheduled_task_status_changed" or "scheduled_task_status_unavailable" or "scheduled_task_status_invalid" => "Some scheduled task statuses could not be read.",
            "unsafe_path" or "unsupported_filesystem" or "invalid_path" or "startup_folder_unavailable" => "This startup location is unavailable or unsupported.",
            _ => "Some startup entries could not be read."
        })).Distinct();
        return Source(source.Source) + ": " + state + (source.Issues.IsEmpty ? "" : " — " + string.Join(" ", reasons));
    }
    private async void Refresh(object sender, RoutedEventArgs args) { if (!disposed && !model.IsBusy && !control.IsBusy) await model.RefreshAsync(); }
    private void Stop(object sender, RoutedEventArgs args) => model.Cancel();
    private void CloseInspector(object sender, RoutedEventArgs args) { if (!control.IsBusy) { inlineDetails.Hide(); Registrations.SelectedItem = null; } }
    private void ExpandRegistration(Expander sender, ExpanderExpandingEventArgs args)
    {
        if (control.IsBusy) { sender.IsExpanded = false; return; }
        Registrations.SelectedItem = sender.Tag; inlineDetails.Show(sender); ShowDetails(); BindControl();
    }
    private void CollapseRegistration(Expander sender, ExpanderCollapsedEventArgs args) { if (!control.IsBusy) inlineDetails.Hide(); }
    private void LoadRowIcon(object sender, RoutedEventArgs args) { if (sender is ContentControl host) host.Content = ProductIcon.Create("startup", (double)Application.Current.Resources["ShouCatalogIconSize"]); }
    private void ChangePresentationFilter(object sender, RoutedEventArgs args)
    {
        if (disposed) return;
        if (initialized && sender is ToggleButton { Tag: string tag })
        {
            presentation = tag switch
            {
                "enabled" => StartupPresentationFilter.Enabled,
                "disabled" => StartupPresentationFilter.Disabled,
                "unknown" => StartupPresentationFilter.Unknown,
                _ => StartupPresentationFilter.All
            };
            try { model.SetPresentationFilter(presentation); }
            catch (ShouException) { ShowStatus(text.Get("Use a printable search of up to 256 characters.")); }
        }
        ApplyPresentationPills();
    }
    private void ApplyPresentationPills()
    {
        FilterAll.IsChecked = presentation == StartupPresentationFilter.All;
        FilterEnabled.IsChecked = presentation == StartupPresentationFilter.Enabled;
        FilterDisabled.IsChecked = presentation == StartupPresentationFilter.Disabled;
        FilterUnknown.IsChecked = presentation == StartupPresentationFilter.Unknown;
    }
    private void FilterChanged(object sender, TextChangedEventArgs args) => ApplyFilter();
    private void SourceChanged(object sender, SelectionChangedEventArgs args) => ApplyFilter();
    private void ApplyFilter()
    {
        if (!initialized || disposed || model.IsBusy || control.IsBusy) return;
        try { model.Filter(SearchBox.Text, (SourceBox.SelectedItem as StartupSourceOption)?.Source); }
        catch (ShouException) { ShowStatus(text.Get("Use a printable search of up to 256 characters.")); }
    }
    private void SelectRegistration(object sender, SelectionChangedEventArgs args) { if (!rendering) { ShowDetails(); BindControl(); } }
    private void Previous(object sender, RoutedEventArgs args) => model.PreviousPage();
    private void Next(object sender, RoutedEventArgs args) => model.NextPage();
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        model.PropertyChanged -= Changed;
        control.PropertyChanged -= ControlChanged;
        control.Dispose();
        model.Dispose();
        GC.SuppressFinalize(this);
    }
}

public sealed record StartupSourceOption(StartupSource? Source, string Label);
[Microsoft.UI.Xaml.Data.Bindable]
public sealed class StartupDisplay(StartupItem item, string sourceLabel, string target, string status, bool showGroup = false, string groupTitle = "")
{
    public bool CanReviewSwitch => WindowsStartupControlMutation.PublicExecutionAvailable && Item.Source == StartupSource.ScheduledTasks;
    public bool? TaskEnabled => Item.ScheduledTask?.Enabled;
    public Visibility TaskVisibility => Item.ScheduledTask is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility GroupVisibility => showGroup ? Visibility.Visible : Visibility.Collapsed;
    public string GroupTitle { get; } = groupTitle;
    public StartupItem Item { get; } = item;
    public string SourceLabel { get; } = sourceLabel; public string Target { get; } = target; public string Status { get; } = status;
    public string Name => Item.Name;
}
