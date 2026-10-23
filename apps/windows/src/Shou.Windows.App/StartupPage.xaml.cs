using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

public sealed partial class StartupPage : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly StartupViewModel model = new(new StartupInventoryService(new WindowsStartupInventory()));
    private readonly StartupControlViewModel control = new(new NativeStartupControlOperations());
    private Task? initialLoad;
    private Task? activeControl;
    private bool initialized;
    private bool disposed;
    private bool rendering;
    public event EventHandler? BusyChanged;
    public bool HasActiveStartupChange => activeControl is { IsCompleted: false } || control.IsExecuting;

    public StartupPage()
    {
        InitializeComponent();
        PageTitle.Text = text.Get("Startup Items");
        Description.Text = text.Get("Browse startup registrations and review eligible current-user scheduled tasks.");
        StateNotice.Text = text.Get("Registration alone does not prove an item is enabled or running. Shortcut targets are not resolved.");
        PreviousNotice.Text = text.Get("Showing results from the previous scan.");
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
        var busy = model.IsBusy || control.IsBusy;
        RefreshButton.IsEnabled = SearchBox.IsEnabled = SourceBox.IsEnabled = Registrations.IsEnabled = !busy;
        CancelButton.IsEnabled = model.IsBusy && !model.StopRequested;
        PreviousButton.IsEnabled = !busy && model.Page?.Offset > 0;
        NextButton.IsEnabled = !busy && model.Page?.HasNext == true;
        Progress.Visibility = model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        PreviousNotice.Visibility = model.ShowingPreviousResults ? Visibility.Visible : Visibility.Collapsed;
        CoverageNotice.IsOpen = model.Page?.State == ScanState.Partial;
        Status.Text = model.ErrorCode is not null ? text.Get("Startup registrations could not be loaded. Try refreshing the list.") :
            model.StopRequested ? text.Get("Stopping…") : model.State switch
            {
                StartupPageState.Loading => text.Get("Loading…"),
                StartupPageState.Cancelled => text.Get("Cancelled"),
                _ when model.Page is { } page => text.Format("%lld startup registrations", page.Total),
                _ => ""
            };
        CoverageText.Text = model.Page is { } result ? string.Join(" · ", result.Sources.Select(Coverage)) : "";
        var selected = (Registrations.SelectedItem as StartupDisplay)?.Item.Id;
        var rows = model.Page?.Items.Select(item => new StartupDisplay(item, Source(item.Source),
            item.ExecutablePath?.Value ?? item.DefinitionPath?.Value ?? text.Get("Executable path unknown"))).ToArray();
        rendering = true;
        try
        {
            Registrations.ItemsSource = rows;
            Registrations.SelectedItem = rows?.FirstOrDefault(row => row.Item.Id == selected);
        }
        finally { rendering = false; }
        ShowDetails();
        BindControl();
        RenderControl();
    }
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
            text.Format("Task Scheduler reports: %@ · %@.", text.Get(status.Enabled ? "Enabled" : "Disabled"), text.Get(status.State switch
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
    private void FilterChanged(object sender, TextChangedEventArgs args) => ApplyFilter();
    private void SourceChanged(object sender, SelectionChangedEventArgs args) => ApplyFilter();
    private void ApplyFilter()
    {
        if (!initialized || disposed || model.IsBusy || control.IsBusy) return;
        try { model.Filter(SearchBox.Text, (SourceBox.SelectedItem as StartupSourceOption)?.Source); }
        catch (ShouException) { Status.Text = text.Get("Use a printable search of up to 256 characters."); }
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
public sealed record StartupDisplay(StartupItem Item, string SourceLabel, string Target)
{
    public string Name => Item.Name;
}
