using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record ScanLocationRow(string Id, string Title, string Path, string Origin, string Availability, string? Issue, string? WorkspaceId, bool CanRemove)
{
    public string Source => Origin switch { "automatic" => T("自动发现的项目"), "included" => T("额外包含的文件夹"), "builtin" => T("内置缓存位置"), _ => T("未知来源") };
    public string State => Availability switch { "available" => T("已发现"), "missing" => T("目录已不存在"), _ => T("无法访问") };
    public string Details => Issue ?? (Availability == "missing" ? T("此目录目前不存在。可以停止包含，之后也可重新添加。") : T("位置发现只检查目录信息；实际扫描仍会核验读取权限和保护条件。"));
}

public sealed partial class MainViewModel
{
    private readonly List<ScanLocationRow> allScanLocations = [];
    private string? scanLocationsRevision;
    private string scanLocationQuery = "";
    private int scanLocationScope;
    private ScanLocationRow? selectedScanLocation;
    public ObservableCollection<ScanLocationRow> ScanLocations { get; } = [];
    public ScanLocationRow? SelectedScanLocation { get => selectedScanLocation; set => SetProperty(ref selectedScanLocation, value); }
    public string ScanLocationQuery { get => scanLocationQuery; set { if (SetProperty(ref scanLocationQuery, value)) FilterScanLocations(); } }
    public int ScanLocationScope { get => scanLocationScope; set { if (SetProperty(ref scanLocationScope, Math.Clamp(value, 0, 3))) FilterScanLocations(); } }
    public string ScanLocationsSummary => F("共 {0} 个位置 · 显示 {1} 个 · {2} 个位置需检查",allScanLocations.Count,ScanLocations.Count,allScanLocations.Count(row => row.Availability != "available"));
    public IAsyncRelayCommand ShowScanLocationsCommand { get; private set; } = null!;
    public IAsyncRelayCommand RefreshScanLocationsCommand { get; private set; } = null!;
    public IAsyncRelayCommand StopIncludingLocationCommand { get; private set; } = null!;
    public IRelayCommand CopyScanLocationPathCommand { get; private set; } = null!;

    private void InitializeLocations()
    {
        ShowScanLocationsCommand = new AsyncRelayCommand(() => RunAsync(async () => { SelectedSection = 8; await LoadScanLocationsAsync(); }), () => !IsBusy);
        RefreshScanLocationsCommand = new AsyncRelayCommand(() => RunAsync(LoadScanLocationsAsync), () => !IsBusy);
        StopIncludingLocationCommand = new AsyncRelayCommand(() => RunAsync(async () =>
        {
            var row = SelectedScanLocation!;
            await client.RequestAsync("workspace.remove", new() { ["workspace_id"] = row.WorkspaceId, ["configuration_revision"] = scanLocationsRevision },
                confirm: review => dialogs.ConfirmAsync(review, Token), cancellation: Token);
            ResetCleanupReview(); await LoadConfigurationAsync(); await LoadScanLocationsAsync();
            Status = T("已停止包含此额外文件夹。文件和清理历史保留；再次包含后可重新配置规则。");
        }), () => !IsBusy && scanLocationsRevision is not null && SelectedScanLocation is { CanRemove: true, WorkspaceId: not null });
        CopyScanLocationPathCommand = new RelayCommand(() => System.Windows.Clipboard.SetText(SelectedScanLocation!.Path), () => !IsBusy && SelectedScanLocation is not null);
        commands.AddRange([ShowScanLocationsCommand, RefreshScanLocationsCommand, StopIncludingLocationCommand, CopyScanLocationPathCommand]);
    }
    private async Task LoadScanLocationsAsync()
    {
        var inventory = await client.RequestAsync("locations.scan", cancellation: Token);
        scanLocationsRevision = Text(inventory, "configuration_revision");
        allScanLocations.Clear();
        foreach (var item in Array(inventory["entries"]))
            allScanLocations.Add(new(Text(item, "id"), Text(item, "title"), Text(item, "path"), Text(item, "origin"), Text(item, "availability"),
                item?["issue"]?.GetValue<string>(), item?["workspace_id"]?.GetValue<string>(), item?["can_remove"]?.GetValue<bool>() == true));
        FilterScanLocations();
    }
    private void FilterScanLocations()
    {
        var selectedId = SelectedScanLocation?.Id;
        ScanLocations.Clear();
        var origin = ScanLocationScope switch { 1 => "automatic", 2 => "included", 3 => "builtin", _ => null };
        var query = ScanLocationQuery.Trim();
        foreach (var row in allScanLocations.Where(row => (origin is null || row.Origin == origin) &&
            (query.Length == 0 || new[] { row.Title, row.Path, row.Source }.Any(value => value.Contains(query, StringComparison.CurrentCultureIgnoreCase)))))
            ScanLocations.Add(row);
        SelectedScanLocation = ScanLocations.FirstOrDefault(row => row.Id == selectedId);
        OnPropertyChanged(nameof(ScanLocationsSummary));
    }
}
