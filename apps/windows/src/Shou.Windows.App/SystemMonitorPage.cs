using System.Collections.ObjectModel;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class SystemMonitorPage : Grid, IDisposable
{
    private readonly TextCatalog text = new();
    private readonly SystemMonitorViewModel model = new(new WindowsSystemMonitor());
    private readonly TextBlock status = new();
    private readonly Button pause = new();
    private readonly ToggleSwitch background = new();
    private readonly TextBox search = new();
    private readonly ComboBox sort = new();
    private readonly StackPanel coreDetails = new() { Spacing = 10 };
    private readonly TextBlock coverage = new();
    private readonly ObservableCollection<MonitorProcessRow> rows = [];
    private readonly Dictionary<string, MonitorMetricCard> cards = [];
    private readonly MonitorTrayIcon tray;
    private bool disposed;
    public event Action? OpenRequested;
    public event Action? QuitRequested;

    public SystemMonitorPage(nint window)
    {
        tray = new(window, () => OpenRequested?.Invoke(), () => model.SetPaused(!model.Paused), () => model.SetBackgroundEnabled(false), () => QuitRequested?.Invoke());
        RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new());
        var inset = (double)Application.Current.Resources["ShouWorkspaceInset"];
        var toolbar = new Grid { Margin = new(inset, 12, inset, 12), ColumnSpacing = 16 };
        toolbar.ColumnDefinitions.Add(new()); toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var heading = new StackPanel { Spacing = 3 };
        heading.Children.Add(new TextBlock { Text = T("System Monitor"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 16 });
        status.Style = (Style)Application.Current.Resources["ShouCaption"]; heading.Children.Add(status); toolbar.Children.Add(heading);
        background.Header = T("Tray summary"); background.Toggled += (_, _) => { if (background.IsOn != model.BackgroundEnabled) model.SetBackgroundEnabled(background.IsOn); };
        Grid.SetColumn(background, 1); toolbar.Children.Add(background); AutomationProperties.SetAutomationId(background, "monitor.background");
        pause.VerticalAlignment = VerticalAlignment.Center; pause.Click += (_, _) => model.SetPaused(!model.Paused);
        Grid.SetColumn(pause, 2); toolbar.Children.Add(pause); AutomationProperties.SetAutomationId(pause, "monitor.pause"); Children.Add(toolbar);
        var body = new StackPanel { Spacing = 18, Margin = new(inset, 0, inset, 24) };
        var metrics = new Grid { ColumnSpacing = 14, RowSpacing = 14 };
        for (var i = 0; i < 4; i++) metrics.ColumnDefinitions.Add(new());
        metrics.RowDefinitions.Add(new() { Height = GridLength.Auto }); metrics.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var definitions = new[] { ("overview", "Resource Status"), ("cpu", "CPU"), ("gpu", "GPU"), ("memory", "Memory"), ("battery", "Battery"), ("diskRead", "Disk"), ("networkReceive", "Network"), ("thermal", "Thermals & Fans") };
        for (var i = 0; i < definitions.Length; i++)
        {
            var (key, title) = definitions[i]; var card = new MonitorMetricCard(T(title)); cards.Add(key, card);
            Grid.SetColumn(card, i % 4); Grid.SetRow(card, i / 4); metrics.Children.Add(card); AutomationProperties.SetAutomationId(card, "monitor.metric." + key);
        }
        body.Children.Add(metrics);
        body.Children.Add(new Expander { Header = T("CPU cores and memory details"), Content = coreDetails, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        var filters = new Grid { ColumnSpacing = 14 };
        filters.ColumnDefinitions.Add(new()); filters.ColumnDefinitions.Add(new() { Width = new(260) }); filters.ColumnDefinitions.Add(new() { Width = new(150) });
        filters.Children.Add(new TextBlock { Text = T("Processes"), FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        search.PlaceholderText = T("Search name or PID"); search.TextChanged += (_, _) => RefreshProcesses(); Grid.SetColumn(search, 1); filters.Children.Add(search);
        AutomationProperties.SetAutomationId(search, "monitor.process.search"); AutomationProperties.SetName(search, T("Search name or PID"));
        sort.Items.Add("CPU"); sort.Items.Add(T("Memory")); sort.SelectedIndex = 0; sort.HorizontalAlignment = HorizontalAlignment.Stretch;
        sort.SelectionChanged += (_, _) => RefreshProcesses(); Grid.SetColumn(sort, 2); filters.Children.Add(sort); AutomationProperties.SetName(sort, T("Sort")); body.Children.Add(filters);
        body.Children.Add(Caption(T("Process CPU uses total machine capacity. Memory is resident size; shared pages may repeat.")));
        var header = new Grid { Padding = new(14, 0, 26, 0), ColumnSpacing = 16 };
        foreach (var width in new[] { new GridLength(1, GridUnitType.Star), new GridLength(70), new GridLength(80), new GridLength(110) }) header.ColumnDefinitions.Add(new() { Width = width });
        var names = new[] { T("Process"), "PID", "CPU", T("Memory") };
        for (var i = 0; i < names.Length; i++) { var label = Caption(names[i]); if (i > 0) label.HorizontalAlignment = HorizontalAlignment.Right; Grid.SetColumn(label, i); header.Children.Add(label); }
        body.Children.Add(header);
        var list = new ListView { ItemsSource = rows, Height = 360, SelectionMode = ListViewSelectionMode.None, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            ItemContainerStyle = (Style)Application.Current.Resources["ShouTableItem"] };
        list.ItemTemplate = (DataTemplate)XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Grid Padding="14,12" ColumnSpacing="16">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="70"/><ColumnDefinition Width="80"/><ColumnDefinition Width="110"/></Grid.ColumnDefinitions>
            <TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis"/><TextBlock Grid.Column="1" Text="{Binding Pid}" HorizontalAlignment="Right"/>
            <TextBlock Grid.Column="2" Text="{Binding Cpu}" HorizontalAlignment="Right"/><TextBlock Grid.Column="3" Text="{Binding Memory}" HorizontalAlignment="Right"/>
            </Grid></DataTemplate>
            """);
        AutomationProperties.SetAutomationId(list, "monitor.processes"); AutomationProperties.SetName(list, T("Processes"));
        body.Children.Add(list); body.Children.Add(coverage);
        body.Children.Add(Caption(T("Last 2 minutes · Gaps mean unavailable")));
        body.Children.Add(Caption(T("Read-only · History stays in memory · Leaving this page stops sampling unless the summary is enabled.")));
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1); Children.Add(scroll);
        model.PropertyChanged += ModelChanged;
        Refresh();
    }
    public void SetVisible(bool value) => model.SetVisible(value);
    private string T(string key) => text.Get(key);
    private static TextBlock Caption(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["ShouCaption"] };
    private static string Percent(double? value) => value is { } number ? number.ToString("F1") + "%" : "—";
    private static string Bytes(ulong? value) => value is { } bytes ? StorageRow.FormatBytes((long)Math.Min(bytes, long.MaxValue)) : "—";
    private string Rate(string key) => model.Sample?.Values.GetValueOrDefault(key) is { } value && model.Sample.Values.ContainsKey(key) ? Bytes((ulong)Math.Min(value, long.MaxValue)) + "/s" : "—";
    private double? Value(string key) => model.Sample is { } sample && sample.Values.TryGetValue(key, out var value) ? value : null;
    private void ModelChanged(object? sender, PropertyChangedEventArgs args) => Refresh();
    private void Refresh()
    {
        if (disposed) return;
        var observation = model.Sample?.Observation;
        status.Text = T(model.Paused ? "Monitoring paused" : model.Failed ? "Sampling failed; showing the last observation." : model.Sample is null ? "Collecting rate baseline…" : "Live · Every 2 seconds") + (observation is null ? "" : " · " + observation.Timestamp.ToLocalTime().ToString("T"));
        pause.Content = T(model.Paused ? "Resume Monitoring" : "Pause Monitoring"); background.IsOn = model.BackgroundEnabled;
        if (!tray.Update(model.BackgroundEnabled, "Shou · CPU " + Percent(Value("cpu")) + " · " + T("Memory") + " " + Percent(Value("memory")) + " · " + status.Text,
            T("Open System Monitor"), T(model.Paused ? "Resume Monitoring" : "Pause Monitoring"), T("Disable Summary"), T("Quit Shou"), SummaryLines()))
        { model.SetBackgroundEnabled(false); status.Text = T("The tray summary could not be opened."); }
        var cpu = Value("cpu"); var memory = Value("memory");
        cards["overview"].Update(T(model.Paused || model.Failed || cpu is null || memory is null ? "Observation incomplete" : cpu >= 90 || memory >= 90 ? "High resource usage" : "Observed load normal"),
            (observation?.Hardware ?? "—") + " · " + (observation?.OperatingSystem ?? ""), T("CPU and memory load; not a hardware health score.") + "\n" + text.Format("Uptime: %lld hours", (int)((observation?.Uptime ?? 0) / 3600)));
        foreach (var key in new[] { "cpu", "gpu", "memory", "battery", "networkReceive" })
        {
            var detail = key switch
            {
                "memory" => Bytes(observation?.MemoryUsed) + " / " + Bytes(observation?.MemoryTotal) + " · " + T("Swap Used") + " " + Bytes(observation?.SwapUsed),
                "battery" when Value(key) is not null => T(observation?.PowerSource ?? "Unavailable") + " · " + T("Battery Health") + " " + Percent(observation?.BatteryHealth) + " · " + T("Cycles") + " " + (observation?.BatteryCycles?.ToString() ?? "—"),
                "networkReceive" when Value(key) is not null => "↑ " + Rate("networkSend") + "\n" + T("Active Ethernet / Wi-Fi interfaces"),
                _ when Value(key) is null => T(observation?.Issues.GetValueOrDefault(key) ?? (model.Sample?.Baseline != false ? "Collecting rate baseline…" : "Counter unavailable or source changed.")),
                "cpu" => T("Total machine capacity") + " · " + observation?.LogicalCpuCount + " " + T("Logical cores"),
                _ => T("Busiest GPU engine or device")
            };
            cards[key].Update(key == "networkReceive" ? "↓ " + Rate(key) : Percent(Value(key)), null, detail);
            cards[key].Trend.Update(model.History, key == "networkReceive" ? [key, "networkSend"] : [key]);
            if (key is "cpu" or "gpu") cards[key].Badge.Text = ((key == "cpu" ? observation?.CpuTemperature : observation?.GpuTemperature)?.ToString("F0") ?? "— ") + "°C";
        }
        var disk = cards["diskRead"];
        disk.Update(Bytes(observation?.VolumeAvailable), null, T("System volume available") + " / " + Bytes(observation?.VolumeTotal) + "\n" + T("Read") + " " + Rate("diskRead") + " · " + T("Write") + " " + Rate("diskWrite"));
        disk.SetVolume(observation?.VolumeTotal, observation?.VolumeAvailable);
        cards["thermal"].Update(T(observation?.ThermalState ?? "Unavailable"), T("Fan telemetry unavailable"), T("Windows does not expose these hardware sensors through the supported read-only APIs."));
        coreDetails.Children.Clear();
        if (model.Sample is { } sample)
        {
            var cores = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 140, ItemHeight = 28, MaximumRowsOrColumns = 6 };
            for (var i = 0; i < sample.Cores.Length; i++) cores.Children.Add(Caption("CPU " + (i + 1) + " · " + Percent(sample.Cores[i])));
            coreDetails.Children.Add(cores);
        }
        coreDetails.Children.Add(Caption(T("Compressed") + ": " + Bytes(observation?.MemoryCompressed) + " · " + T("Swap Used") + ": " + Bytes(observation?.SwapUsed) + " · " + T("Memory Pressure") + ": " + T(observation?.MemoryPressure ?? "Unavailable")));
        RefreshProcesses();
    }
    private void RefreshProcesses()
    {
        if (disposed) return;
        var matching = (model.Sample?.Processes ?? []).Where(item => search.Text.Length == 0 || item.Counter.Name.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase) || item.Counter.Pid.ToString().Contains(search.Text, StringComparison.Ordinal)).ToArray();
        var ordered = (sort.SelectedIndex == 1 ? matching.OrderByDescending(item => item.Counter.MemoryBytes) : matching.OrderByDescending(item => item.CpuPercent ?? -1)).ThenBy(item => item.Counter.Pid).Take(100).ToArray();
        var keep = ordered.Select(item => item.Counter.Id).ToHashSet(StringComparer.Ordinal);
        for (var i = rows.Count - 1; i >= 0; i--) if (!keep.Contains(rows[i].Id)) rows.RemoveAt(i);
        for (var i = 0; i < ordered.Length; i++)
        {
            var value = ordered[i]; var existing = rows.FirstOrDefault(row => row.Id == value.Counter.Id);
            if (existing is null) rows.Insert(i, new(value));
            else { var previous = rows.IndexOf(existing); if (previous != i) rows.Move(previous, i); existing.Update(value); }
        }
        coverage.Text = text.Format("Showing %lld of %lld matching processes.", ordered.Length, matching.Length) + " " + T(model.Sample?.Observation.ProcessCoverage ?? "Partial process coverage");
    }
    private string[] SummaryLines()
    {
        var observation = model.Sample?.Observation;
        var values = new List<string> {
            "CPU " + Percent(Value("cpu")) + " · GPU " + Percent(Value("gpu")),
            T("Memory") + " " + Bytes(observation?.MemoryUsed) + " / " + Bytes(observation?.MemoryTotal) + " · " + Percent(Value("memory")),
            T("Disk") + " · " + T("Read") + " " + Rate("diskRead") + " · " + T("Write") + " " + Rate("diskWrite"),
            T("Network") + " · ↓ " + Rate("networkReceive") + " · ↑ " + Rate("networkSend"),
            T("Battery") + " " + Percent(Value("battery")) + " · " + T(observation?.PowerSource ?? "Unavailable"),
            T("Thermals & Fans") + " · " + T(observation?.ThermalState ?? "Unavailable"), T("Top CPU processes")
        };
        values.AddRange((model.Sample?.Processes ?? []).OrderByDescending(item => item.CpuPercent ?? -1).ThenBy(item => item.Counter.Pid).Take(3)
            .Select(item => (item.Counter.Name.Length > 40 ? item.Counter.Name[..40] : item.Counter.Name) + " · " + Percent(item.CpuPercent)));
        return [.. values];
    }
    public void Dispose() { if (disposed) return; disposed = true; model.PropertyChanged -= ModelChanged; model.Dispose(); tray.Dispose(); }
}

internal sealed class MonitorProcessRow(MonitorProcessUsage initial) : INotifyPropertyChanged
{
    private MonitorProcessUsage value = initial;
    public string Id => value.Counter.Id;
    public string Name => value.Counter.Name;
    public string Pid => value.Counter.Pid.ToString();
    public string Cpu => value.CpuPercent?.ToString("F1") + (value.CpuPercent is null ? "—" : "%");
    public string Memory => StorageRow.FormatBytes((long)Math.Min(value.Counter.MemoryBytes, long.MaxValue));
    public event PropertyChangedEventHandler? PropertyChanged;
    public void Update(MonitorProcessUsage next) { value = next; PropertyChanged?.Invoke(this, new(null)); }
}

internal sealed class MonitorMetricCard : UserControl
{
    private readonly TextBlock value = new() { FontSize = (double)Application.Current.Resources["ShouSummaryFigureSize"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock detail = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 3, Height = 54 };
    private readonly TextBlock middle = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 2, Height = 42 };
    public TextBlock Badge { get; } = new();
    public MonitorTrendCanvas Trend { get; } = new() { Height = 42 };
    private readonly ProgressBar meter = new() { Height = 6, MinHeight = 0, Maximum = 100, Visibility = Visibility.Collapsed, Margin = new(0, 18, 0, 18) };
    public MonitorMetricCard(string title)
    {
        var surface = new Border { CornerRadius = (CornerRadius)Application.Current.Resources["ShouCardRadius"], Padding = new(16), BorderThickness = new(1) };
        ThemeResources.Apply(surface, Border.BackgroundProperty, "Background", "ShouSurfaceBrush"); ThemeResources.Apply(surface, Border.BorderBrushProperty, "BorderBrush", "ShouDividerBrush");
        var content = new StackPanel { Spacing = 9 }; var top = new Grid(); top.ColumnDefinitions.Add(new()); top.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        top.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); Grid.SetColumn(Badge, 1); top.Children.Add(Badge);
        content.Children.Add(top); content.Children.Add(value); content.Children.Add(Trend); content.Children.Add(meter); content.Children.Add(middle); content.Children.Add(detail); surface.Child = content; Content = surface;
        ThemeResources.Apply(detail, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush"); ThemeResources.Apply(middle, TextBlock.ForegroundProperty, "Foreground", "TextFillColorSecondaryBrush");
    }
    public void Update(string number, string? description, string footer)
    {
        value.Text = number; value.FontSize = number.Length > 16 ? 18 : (double)Application.Current.Resources["ShouSummaryFigureSize"];
        middle.Text = description ?? ""; middle.Visibility = description is null ? Visibility.Collapsed : Visibility.Visible;
        Trend.Visibility = description is null ? Visibility.Visible : Visibility.Collapsed; detail.Text = footer;
    }
    public void SetVolume(ulong? total, ulong? available)
    {
        if (total is not > 0 || available is null) return;
        Trend.Visibility = Visibility.Collapsed; meter.Visibility = Visibility.Visible;
        meter.Value = (1 - (double)Math.Min(total.Value, available.Value) / total.Value) * 100;
        AutomationProperties.SetName(meter, new TextCatalog().Get("System volume usage"));
    }
}

internal sealed class MonitorTrendCanvas : Canvas
{
    private IReadOnlyList<SystemMonitorSample> history = Array.Empty<SystemMonitorSample>();
    private string[] keys = [];
    public MonitorTrendCanvas() { SizeChanged += (_, _) => Draw(); IsHitTestVisible = false; AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw); }
    public void Update(IReadOnlyList<SystemMonitorSample> samples, string[] series) { history = samples; keys = series; Draw(); }
    private void Draw()
    {
        Children.Clear(); if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var end = history.LastOrDefault()?.Observation.Timestamp ?? DateTimeOffset.UtcNow;
        var maximum = keys.Length == 1 ? 100 : Math.Max(1, history.SelectMany(sample => keys.Where(sample.Values.ContainsKey).Select(key => sample.Values[key])).DefaultIfEmpty(0).Max());
        for (var level = 0; level <= 2; level++)
        {
            var line = new Line { X2 = ActualWidth, Y1 = ActualHeight * level / 2, Y2 = ActualHeight * level / 2, StrokeThickness = 1, Opacity = 0.4 };
            ThemeResources.Apply(line, Shape.StrokeProperty, "Stroke", "ShouDividerBrush"); Children.Add(line);
        }
        for (var index = 0; index < keys.Length; index++)
        {
            Polyline? segment = null; DateTimeOffset? previous = null;
            foreach (var sample in history)
            {
                var timestamp = sample.Observation.Timestamp;
                if (!sample.Values.TryGetValue(keys[index], out var value) || (end - timestamp).TotalSeconds > 120) { segment = null; previous = null; continue; }
                if (segment is null || previous is null || timestamp <= previous || (timestamp - previous.Value).TotalSeconds > 6)
                {
                    segment = new Polyline { StrokeThickness = 2 }; if (index > 0) segment.StrokeDashArray = new DoubleCollection { 4, 3 };
                    ThemeResources.Apply(segment, Shape.StrokeProperty, "Stroke", index == 0 ? "ShouAccentBrush" : "TextFillColorSecondaryBrush"); Children.Add(segment);
                }
                segment.Points.Add(new global::Windows.Foundation.Point(Math.Max(0, 1 - (end - timestamp).TotalSeconds / 120) * ActualWidth, ActualHeight * (1 - Math.Min(1, value / maximum)))); previous = timestamp;
            }
        }
    }
}
