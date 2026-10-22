using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using CommunityToolkit.Mvvm.ComponentModel;
using Shou.Windows.Services;

namespace Shou.Windows;

internal sealed class ApplicationDataDialog : Window
{
    private sealed class Row : ObservableObject
    {
        public required string Id { get; init; }
        public required string Name { get; init; }
        public required string Path { get; init; }
        public required string Owner { get; init; }
        public required string Reason { get; init; }
        public long Bytes { get; init; }
        public string Size => MainViewModel.Bytes(Bytes);
        public bool Eligible { get; init; }
        private bool selected, canSelect;
        public bool Selected { get => selected; set => SetProperty(ref selected, value && CanSelect); }
        public bool CanSelect { get => canSelect; set => SetProperty(ref canSelect, value); }
    }
    private readonly BridgeProcessClient client;
    private readonly WindowsDialogs dialogs;
    private readonly ObservableCollection<Row> rows = [];
    private readonly CheckBox leftovers = new() { Content = T("仅查看未登记应用的残留"), IsChecked = true };
    private readonly CheckBox personal = new() { Content = T("我同意清理所选应用的个人数据") };
    private readonly Button scan = new() { Content = T("重新检查") }, select = new() { Content = T("选择可清理项") }, clear = new() { Content = T("取消选择") };
    private readonly Button clean = new() { Content = T("永久清理所选应用数据…") }, stop = new() { Content = T("停止") };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) };
    private readonly TextBlock selectionSummary = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
    private readonly ProgressBar progress = new() { Height = 3, Visibility = Visibility.Collapsed };
    private CancellationTokenSource? operation;
    private string? reviewId;
    private bool busy, closing, layoutOnly;

    public ApplicationDataDialog(Window? owner, BridgeProcessClient client)
    {
        Owner = owner; this.client = client; dialogs = new WindowsDialogs(this);
        Title = T("应用数据与残留"); Width = 960; Height = 690; MinWidth = 680; MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false;
        var body = new DockPanel { Margin = new Thickness(20) }; Content = body;
        var top = new StackPanel(); DockPanel.SetDock(top, Dock.Top); body.Children.Add(top);
        top.Children.Add(new TextBlock { Text = Title, FontSize = 22, FontWeight = FontWeights.SemiBold });
        top.Children.Add(new TextBlock { Text = T("这些目录可能包含设置、登录状态、浏览器资料和本地数据库。清理无法恢复，也不会卸载应用。未登记的便携或自定义安装仍可能使用这些数据。"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 10) });
        var controls = new WrapPanel(); controls.Children.Add(leftovers); controls.Children.Add(scan); controls.Children.Add(select); controls.Children.Add(clear); top.Children.Add(controls);
        top.Children.Add(personal); top.Children.Add(status); top.Children.Add(progress);
        var bottom = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        DockPanel.SetDock(bottom, Dock.Bottom); body.Children.Add(bottom);
        bottom.Children.Add(selectionSummary); bottom.Children.Add(stop); var close = new Button { Content = T("关闭"), IsCancel = true }; close.Click += (_, _) => Close(); bottom.Children.Add(close); bottom.Children.Add(clean);
        var grid = new DataGrid { ItemsSource = rows, AutoGenerateColumns = false, CanUserAddRows = false, EnableRowVirtualization = true };
        System.Windows.Automation.AutomationProperties.SetName(grid, T("应用数据审阅列表"));
        var style = new Style(typeof(CheckBox)); style.Setters.Add(new Setter(IsEnabledProperty, new Binding(nameof(Row.CanSelect))));
        grid.Columns.Add(new DataGridCheckBoxColumn { Header = T("选择"), Binding = new Binding(nameof(Row.Selected)) { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged }, ElementStyle = style, EditingElementStyle = style, Width = 50 });
        void Column(string header, string property, double width) => grid.Columns.Add(new DataGridTextColumn { Header = header, Binding = new Binding(property), IsReadOnly = true, Width = new DataGridLength(width, DataGridLengthUnitType.Star) });
        Column(T("应用"), nameof(Row.Name), 1); Column(T("登记状态"), nameof(Row.Owner), 1); Column(T("路径"), nameof(Row.Path), 3);
        grid.Columns.Add(new DataGridTextColumn { Header = T("大小"), Binding = new Binding(nameof(Row.Size)), SortMemberPath = nameof(Row.Bytes), IsReadOnly = true, Width = 100 });
        Column(T("保护原因"), nameof(Row.Reason), 1.5); body.Children.Add(grid);
        scan.Click += async (_, _) => await ScanAsync(); select.Click += (_, _) => { foreach (var row in rows) row.Selected = row.CanSelect; Update(); };
        clear.Click += (_, _) => { foreach (var row in rows) row.Selected = false; Update(); };
        clean.Click += async (_, _) => await CleanAsync(); stop.Click += (_, _) => operation?.Cancel();
        personal.Checked += (_, _) => Update(); personal.Unchecked += (_, _) => Update();
        leftovers.Checked += (_, _) => Invalidate(); leftovers.Unchecked += (_, _) => Invalidate();
        Loaded += async (_, _) => { if (!layoutOnly) await ScanAsync(); };
        Closing += ClosingRequested; Closed += (_, _) => { operation?.Cancel(); operation?.Dispose(); };
        Update();
    }
    private void Invalidate() { reviewId = null; rows.Clear(); status.Text = T("扫描条件已变化，请重新检查。"); Update(); }
    private void Update()
    {
        foreach (var row in rows) {
            row.CanSelect = !busy && reviewId is not null && personal.IsChecked == true && row.Eligible;
            if (reviewId is null || personal.IsChecked != true) row.Selected = false;
        }
        var selected = rows.Where(row => row.Selected).ToArray();
        var bytes = selected.Aggregate(0L, (total, row) => total > long.MaxValue - Math.Max(0, row.Bytes) ? long.MaxValue : total + Math.Max(0, row.Bytes));
        selectionSummary.Text = F("已选择 {0} 项 · {1}", selected.Length, MainViewModel.Bytes(bytes));
        scan.IsEnabled = !busy; leftovers.IsEnabled = !busy; personal.IsEnabled = !busy;
        select.IsEnabled = !busy && rows.Any(row => row.CanSelect); clear.IsEnabled = !busy && rows.Any(row => row.Selected);
        clean.IsEnabled = !busy && reviewId is not null && personal.IsChecked == true && rows.Count(row => row.Selected) is > 0 and <= 32;
        stop.IsEnabled = busy; progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        progress.IsIndeterminate = busy && DesktopPresentation.Current.AnimateIndicators;
    }
    private async Task ScanAsync()
    {
        if (busy) return;
        busy = true; reviewId = null; rows.Clear(); personal.IsChecked = false; operation = new(); status.Text = T("正在检查应用登记、活动和数据…"); Update();
        try {
            var result = await client.RequestAsync("applications.data-scan", new() { ["leftovers_only"] = leftovers.IsChecked == true }, cancellation: operation.Token);
            reviewId = result["id"]!.GetValue<string>();
            foreach (var node in (result["components"] as JsonArray) ?? []) {
                if (node is null) continue;
                var reasons = (node["reasons"] as JsonArray)?.Select(value => value?.GetValue<string>() ?? "").ToArray() ?? [];
                var row = new Row { Id = node["id"]!.GetValue<string>(), Name = node["name"]!.GetValue<string>(), Path = node["path"]!.GetValue<string>(),
                    Owner = node["registered"]!.GetValue<bool>() ? T("已登记") : T("声明来源未发现"), Reason = string.Join(" · ", reasons.Select(Reason)),
                    Bytes = node["allocated_bytes_estimate"]!.GetValue<long>(), Eligible = reasons.Length == 0 && node["eligible"]?.GetValue<bool>() == true };
                row.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(Row.Selected)) Update(); }; rows.Add(row);
            }
            status.Text = rows.Count == 0 ? T("未发现声明范围内的应用数据。") : T("仅覆盖维护的默认用户目录；MSIX、其他账户和未声明应用未覆盖。请逐项核对路径，再同意个人数据清理。");
        }
        catch (Exception error) { reviewId = null; rows.Clear(); status.Text = error is OperationCanceledException ? T("检查已停止，未清理文件。") : error.Message; }
        finally { Finish(); }
    }
    private async Task CleanAsync()
    {
        if (!clean.IsEnabled) return;
        var selection = rows.Where(row => row.Selected).Select(row => row.Id).ToArray();
        busy = true; operation = new(); Update(); status.Text = T("正在重新核验所选应用数据…");
        try {
            var result = await client.RequestAsync("applications.data-clean", new() { ["review_id"] = reviewId, ["component_ids"] = new JsonArray(selection.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray()), ["include_user_data"] = true },
                confirm: review => dialogs.ConfirmAsync(review, operation.Token), cancellation: operation.Token);
            var items = (result["items"] as JsonArray) ?? [];
            status.Text = F("已永久清理 {0}/{1} 项应用数据。回执保存在历史记录中，请重新检查后再操作。", items.Count(item => item?["state"]?.GetValue<string>() == "purged"), items.Count);
        }
        catch (Exception error) { status.Text = error.Message + T("\n如已确认，可能已有部分数据被清理。请查看历史记录并重新检查，不会自动重试。"); }
        finally { reviewId = null; foreach (var row in rows) row.Selected = false; Finish(); }
    }
    private void Finish()
    {
        busy = false; operation?.Dispose(); operation = null; Update();
        if (closing) Close();
    }
    private void ClosingRequested(object? sender, CancelEventArgs args)
    {
        if (!busy) return;
        args.Cancel = true; closing = true; operation?.Cancel(); status.Text = T("正在停止并等待当前操作的结果…");
    }
    private static string Reason(string code) => code switch {
        "application_running" => T("应用仍在运行"), "system_application" => T("系统组件"), "incomplete_scan" => T("扫描不完整"),
        "protected_content" => T("包含链接、共享文件或无法验证归属的内容"), "excluded" => T("已被排除规则保护"),
        "resource_limit" => T("已达到扫描预算"), _ => T("无法核验：") + code
    };
    internal void VerifyLayout()
    {
        layoutOnly = true; reviewId = "layout-fixture";
        rows.Add(new Row { Id = "layout", Name = "生成的应用夹具", Path = "C:/layout-fixture/AppData/Roaming/example", Owner = T("声明来源未发现"), Reason = "", Bytes = 8192, Eligible = true });
        personal.IsChecked = true; Update(); rows[0].Selected = true;
        if (!clean.IsEnabled) throw new InvalidOperationException("Separate personal-data consent did not enable generated selection.");
        personal.IsChecked = false;
        if (clean.IsEnabled || rows[0].Selected) throw new InvalidOperationException("Revoked personal-data consent retained a selection.");
        foreach (var size in new[] { new Size(960, 690), new Size(680, 500) }) { Measure(size); Arrange(new Rect(new Point(), size)); UpdateLayout(); }
    }
}
