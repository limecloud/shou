using System.Collections.Immutable;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class DeveloperLogsView : UserControl, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly string toolId;
    private readonly nint windowHandle;
    private readonly Action<bool> mutationChanged;
    private readonly StackPanel body = new() { Spacing = 12 };
    private readonly ComboBox paths = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox log = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 320 };
    private readonly TextBlock feedback = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock review = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button choose = new(), refresh = new(), clear = new(), cancel = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly List<DeveloperLogTarget> targets = [];
    private DeveloperLogCleanup? cleaner;
    private DeveloperLogCleanupPlan? plan;
    private int revision;
    private bool loading, mutating, disposed;

    internal DeveloperLogsView(string toolId, nint windowHandle, Action<bool> mutationChanged)
    {
        this.toolId = toolId; this.windowHandle = windowHandle; this.mutationChanged = mutationChanged;
        FontSize = (double)Application.Current.Resources["ShouBodyFontSize"];
        log.FontSize = (double)Application.Current.Resources["ShouCaptionFontSize"];
        log.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas");
        var toolbar = new Grid { ColumnSpacing = 12 };
        toolbar.ColumnDefinitions.Add(new()); toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        toolbar.Children.Add(paths); choose.Content = text.Get("Choose Log File"); Grid.SetColumn(choose, 1); toolbar.Children.Add(choose);
        refresh.Content = text.Get("Refresh"); Grid.SetColumn(refresh, 2); toolbar.Children.Add(refresh);
        AutomationProperties.SetAutomationId(paths, "developer.logs.paths"); AutomationProperties.SetName(paths, text.Get("Logs"));
        AutomationProperties.SetAutomationId(choose, "developer.logs.choose"); AutomationProperties.SetAutomationId(refresh, "developer.logs.refresh");
        AutomationProperties.SetAutomationId(log, "developer.logs.content"); AutomationProperties.SetAutomationId(feedback, "developer.logs.feedback");
        paths.SelectionChanged += async (_, _) => { if (!loading && !mutating) await ReadAsync(); };
        choose.Click += async (_, _) => await ChooseAsync(); refresh.Click += async (_, _) => await ReadAsync();
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right };
        cancel.Content = text.Get("Cancel"); cancel.Click += (_, _) => { plan = null; Update(); };
        clear.Click += async (_, _) => { if (plan is null) await ReviewAsync(); else await ExecuteAsync(); };
        clear.Style = (Style)Application.Current.Resources["ShouDestructiveButton"];
        actions.Children.Add(cancel); actions.Children.Add(clear);
        body.Children.Add(toolbar); body.Children.Add(log); body.Children.Add(review); body.Children.Add(actions); body.Children.Add(feedback); Content = body; Update();
    }
    internal async Task DiscoverAsync(ImmutableArray<DeveloperToolInstallation> installations, ImmutableArray<DeveloperService> services)
    {
        try
        {
            var found = await WindowsDeveloperLogs.DiscoverAsync(toolId, installations, services, lifetime.Token);
            if (disposed) return;
            foreach (var target in found) Add(target);
            if (paths.SelectedIndex < 0 && targets.Count > 0) paths.SelectedIndex = 0;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { NativeDiagnostics.Write(error); }
    }
    private void Add(DeveloperLogTarget target)
    {
        if (targets.Any(row => row.Path.Equals(target.Path, StringComparison.OrdinalIgnoreCase))) return;
        targets.Add(target); paths.Items.Add(new ComboBoxItem { Content = text.Get(target.Title) + " / " + target.Path, Tag = target });
    }
    private string? SelectedPath => (paths.SelectedItem as ComboBoxItem)?.Tag is DeveloperLogTarget target ? target.Path : null;
    private async Task ChooseAsync()
    {
        if (loading || mutating || plan is not null) return;
        try
        {
            var picker = new FileOpenPicker(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle));
            foreach (var type in new[] { ".log", ".err", ".out" }) picker.FileTypeFilter.Add(type);
            var file = await picker.PickSingleFileAsync(); if (file is null || disposed) return;
            Add(new(file.Path, "Service Log")); paths.SelectedIndex = targets.FindIndex(row => row.Path.Equals(file.Path, StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception error) when (error is not OutOfMemoryException) { NativeDiagnostics.Write(error); feedback.Text = text.Get("Could not open this location."); }
    }
    private async Task ReadAsync()
    {
        if (mutating || plan is not null || SelectedPath is not { } path) return;
        var current = ++revision; loading = true; feedback.Text = ""; Update();
        try
        {
            var value = await WindowsDeveloperLogs.ReadTailAsync(WindowsPath.Parse(path), lifetime.Token);
            if (disposed || current != revision) return;
            log.Text = value; feedback.Text = value.Length == 0 ? text.Get("No log entries yet.") : "";
            cleaner = new(new WindowsDeveloperLogCleanup(toolId, WindowsPath.Parse(path)), WindowsRecordStore.ForCurrentUser);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException)
        { if (!disposed && current == revision) { log.Text = ""; cleaner = null; feedback.Text = text.Get("The log is empty, read-only or has changed. Refresh before clearing it."); } }
        finally { if (!disposed && current == revision) { loading = false; Update(); } }
    }
    private async Task ReviewAsync()
    {
        if (loading || mutating || cleaner is null) return;
        loading = true; feedback.Text = ""; Update();
        try { plan = await cleaner.PrepareAsync(lifetime.Token); }
        catch (Exception error) when (error is not OutOfMemoryException) { feedback.Text = text.Get("The log is empty, read-only or has changed. Refresh before clearing it."); }
        finally { loading = false; if (!disposed) Update(); }
    }
    private async Task ExecuteAsync()
    {
        if (loading || mutating || cleaner is null || plan is not { } frozen) return;
        plan = null; mutating = true; mutationChanged(true); Update();
        try
        {
            var result = await cleaner.ExecuteAsync(frozen, frozen.Id);
            feedback.Text = text.Get(result.State == "succeeded" ? "Log cleared. New entries may be written by the service." : "The log cleanup result needs verification. Refresh before continuing.");
            if (result.State == "succeeded") log.Text = "";
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        { NativeDiagnostics.Write(error); feedback.Text = text.Get("The log changed or cannot be cleared. Refresh and review it again."); }
        finally { cleaner = null; mutating = false; mutationChanged(false); if (!disposed) Update(); }
    }
    private void Update()
    {
        paths.IsEnabled = choose.IsEnabled = refresh.IsEnabled = !loading && !mutating && plan is null;
        cancel.Visibility = plan is null ? Visibility.Collapsed : Visibility.Visible;
        clear.Content = text.Get(mutating ? "Clearing…" : plan is null ? "Clear Log…" : "Permanently Clear");
        AutomationProperties.SetAutomationId(clear, plan is null ? "developer.logs.review-clear" : "developer.logs.confirm-clear");
        clear.IsEnabled = !loading && !mutating && cleaner is not null && log.Text.Length > 0;
        review.Text = plan is null ? "" : plan.Inspection.File.Path.Value + "\n" +
            text.Get("Permanently clear this log's contents? The file will be kept.") + "\n" +
            plan.Inspection.File.AllocatedBytes.ToString("N0", System.Globalization.CultureInfo.CurrentCulture) + " B";
    }
    public void Dispose() { disposed = true; revision++; lifetime.Cancel(); lifetime.Dispose(); }
}
