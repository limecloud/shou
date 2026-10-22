using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record StorageBreadcrumb(string Path, string Label);

public sealed partial class MainViewModel
{
    private readonly StorageNavigationHistory storageNavigation = new();
    private readonly HashSet<string> storageSelection = new(StringComparer.Ordinal);
    private readonly List<StorageRow> storageDirectoryRows = [], storageTreeRoots = [];
    private readonly Dictionary<string, int> storageChildOffsets = new(StringComparer.Ordinal);
    private int? storageNextOffset;
    private int storageChildCount;
    private long storageSelectedBytes;
    private string storageQuery = "";
    public ObservableCollection<StorageBreadcrumb> StorageBreadcrumbs { get; } = [];
    public string StorageQuery { get => storageQuery; set { if (SetProperty(ref storageQuery, value)) FilterStorageRows(); } }
    public string StorageListSummary => $"显示 {StorageNodes.Count} 项 · 已加载 {storageDirectoryRows.Count} / {storageChildCount} 项";
    public string StorageSelectionSummary => $"已选 {storageSelection.Count} 项 · 占用估算 {Bytes(storageSelectedBytes)}";
    public string StorageProtection => SelectedStorageNode?.Protection ?? "选择项目以查看保护状态。";
    public string StorageCoverageDetails => storageCoverage.Length == 0 ? "扫描未报告覆盖缺口。" : string.Join("\n", storageCoverage.Select(note =>
        $"{Text(note, "path")}：{(note?["system_managed"]?.GetValue<bool>() == true ? "系统管理的位置，无需调整权限" : "未完整读取，可检查访问权限后重新扫描此范围")}（{Text(note, "code")}）"));
    public IAsyncRelayCommand StorageBackCommand { get; private set; } = null!;
    public IAsyncRelayCommand StorageForwardCommand { get; private set; } = null!;
    public IAsyncRelayCommand<StorageBreadcrumb> StorageBreadcrumbCommand { get; private set; } = null!;
    public IAsyncRelayCommand MoreStorageCommand { get; private set; } = null!;
    public IAsyncRelayCommand SelectVisibleStorageCommand { get; private set; } = null!;
    public IRelayCommand ClearStorageSelectionCommand { get; private set; } = null!;
    public IRelayCommand RevealStorageItemCommand { get; private set; } = null!;
    public IRelayCommand CopyStorageItemPathCommand { get; private set; } = null!;

    private void InitializeStorageNavigation()
    {
        StorageBackCommand = new AsyncRelayCommand(() => RunAsync(() => NavigateStorageAsync(storageNavigation.BackTarget!, -1)), () => !IsBusy && storageNavigation.BackTarget is not null);
        StorageForwardCommand = new AsyncRelayCommand(() => RunAsync(() => NavigateStorageAsync(storageNavigation.ForwardTarget!, 1)), () => !IsBusy && storageNavigation.ForwardTarget is not null);
        StorageBreadcrumbCommand = new AsyncRelayCommand<StorageBreadcrumb>(item => RunAsync(() => NavigateStorageAsync(item!.Path)), item => !IsBusy && storageScanId is not null && item is not null && item.Path != StoragePath);
        MoreStorageCommand = new AsyncRelayCommand(() => RunAsync(async () => ShowStoragePage(await client.RequestAsync("storage.browse", new() { ["scan_id"] = storageScanId, ["path"] = StoragePath, ["offset"] = storageNextOffset }, cancellation: Token), true)), () => !IsBusy && storageNextOffset is not null);
        SelectVisibleStorageCommand = new AsyncRelayCommand(() => ChangeStorageSelectionAsync(StorageNodes.Where(row => row.Eligible).Select(row => row.Path).ToArray(), true), () => !IsBusy && StorageNodes.Any(row => row.Eligible));
        ClearStorageSelectionCommand = new RelayCommand(ClearStorageSelection, () => !IsBusy && storageSelection.Count > 0);
        RevealStorageItemCommand = new RelayCommand(() => dialogs.RevealItem(StorageAbsolutePath(SelectedStorageNode!.Path)), () => !IsBusy && SelectedStorageNode is { Kind: "file" or "directory" });
        CopyStorageItemPathCommand = new RelayCommand(() => System.Windows.Clipboard.SetText(StorageAbsolutePath(SelectedStorageNode!.Path)), () => !IsBusy && SelectedStorageNode is { Kind: "file" or "directory" });
        commands.AddRange([StorageBackCommand, StorageForwardCommand, StorageBreadcrumbCommand, MoreStorageCommand, SelectVisibleStorageCommand, ClearStorageSelectionCommand, RevealStorageItemCommand, CopyStorageItemPathCommand]);
        PropertyChanged += (_, change) => { if (change.PropertyName == nameof(SelectedStorageNode)) OnPropertyChanged(nameof(StorageProtection)); };
    }

    private string StorageAbsolutePath(string relative) => Path.Combine(storageRoot!, relative.Replace('/', Path.DirectorySeparatorChar));
    private async Task NavigateStorageAsync(string path, int direction = 0)
    {
        var browse = await client.RequestAsync("storage.browse", new() { ["scan_id"] = storageScanId, ["path"] = path }, cancellation: Token);
        if (direction < 0) storageNavigation.CommitBack(); else if (direction > 0) storageNavigation.CommitForward(); else storageNavigation.Visit(path);
        StorageQuery = ""; SelectedStorageExtension = null; StorageMap = null; ShowStoragePage(browse, false);
        if (StorageDetailed) await LoadStorageMapAsync();
    }

    private void ShowStoragePage(JsonNode browse, bool append)
    {
        var page = browse["directory"]!;
        if (!append) { storageDirectoryRows.Clear(); storageTreeRoots.Clear(); StorageTree.Clear(); SelectedStorageNode = null; }
        StoragePath = Text(page["item"]?["node"], "path");
        storageChildCount = page["total_count"]?.GetValue<int>() ?? 0;
        storageNextOffset = page["next_offset"]?.GetValue<int>();
        foreach (var item in Array(page["children"]).Where(item => !StorageGone(Text(item?["node"], "path"))))
        {
            var row = StorageItem(item!["node"]!);
            row.SetPolicy(browse["removal_reasons"]?[row.Path]?.GetValue<string>());
            if (!storageDirectoryRows.Contains(row)) storageDirectoryRows.Add(row);
            if (append && !storageTreeRoots.Contains(row)) storageTreeRoots.Add(row);
        }
        StorageBreadcrumbs.Clear(); StorageBreadcrumbs.Add(new(".", "扫描根目录"));
        if (StoragePath != ".") {
            var parts = StoragePath.Split('/');
            for (var index = 0; index < parts.Length; index++) StorageBreadcrumbs.Add(new(string.Join('/', parts.Take(index + 1)), parts[index]));
        }
        FilterStorageRows(); OnPropertyChanged(nameof(StorageCoverageDetails));
        Status = page["item"]?["node"]?["is_complete"]?.GetValue<bool>() == true ? "当前文件夹分析完成。双击目录继续查看。" : "此范围存在覆盖缺口，可展开“扫描覆盖详情”查看。";
    }

    private void FilterStorageRows()
    {
        var query = StorageQuery.Trim();
        bool Matches(StorageRow row) => !StorageGone(row.Path) && (query.Length == 0 || row.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase));
        StorageNodes.Clear(); foreach (var row in storageDirectoryRows.Where(Matches)) StorageNodes.Add(row);
        StorageTree.Clear(); foreach (var row in storageTreeRoots.Where(Matches)) StorageTree.Add(row);
        OnPropertyChanged(nameof(StorageListSummary)); RefreshCommands();
    }

    public Task ToggleStorageSelectionAsync(StorageRow row) => row.CanSelect && !IsBusy ? ChangeStorageSelectionAsync([row.Path], row.SelectionState != true) : Task.CompletedTask;
    private async Task ChangeStorageSelectionAsync(string[] targets, bool selected)
    {
        await RunAsync(async () =>
        {
            var summary = await client.RequestAsync("storage.selection", new() { ["scan_id"] = storageScanId, ["paths"] = Strings(storageSelection), ["targets"] = Strings(targets), ["selected"] = selected }, cancellation: Token);
            storageSelection.Clear(); foreach (var path in Array(summary["paths"])) storageSelection.Add(path!.GetValue<string>());
            storageSelectedBytes = summary["allocated_bytes"]?.GetValue<long>() ?? 0;
        });
        RefreshStorageSelection();
    }
    private void ClearStorageSelection() { storageSelection.Clear(); storageSelectedBytes = 0; RefreshStorageSelection(); }
    private void RefreshStorageSelection()
    {
        foreach (var row in storageRows.Values) ApplyStorageSelection(row);
        OnPropertyChanged(nameof(StorageSelectionSummary)); RefreshCommands();
    }
    private void ApplyStorageSelection(StorageRow row) => row.SetSelection(storageSelection.Any(path => row.Path == path || row.Path.StartsWith(path + "/", StringComparison.Ordinal)) ? true :
        storageSelection.Any(path => path.StartsWith(row.Path + "/", StringComparison.Ordinal)) ? null : false);

    internal void VerifyStorageLayout(bool detailed)
    {
        // Populate presentation only: package verification performs no scan,
        // file operation, shell launch or saved preference change.
        storageRoot = "C:/layout-fixture"; storagePath = "."; storageDetailed = detailed;
        var parent = new StorageRow("project 中文", "12 KiB", "directory", 12288);
        var child = new StorageRow("project 中文/target", "8 KiB", "directory", 8192);
        var blocked = new StorageRow("protected", "4 KiB", "directory", 4096);
        parent.SetPolicy(null); child.SetPolicy(null); blocked.SetPolicy("This selection contains excluded content.");
        parent.Children.Add(child);
        storageRows.Clear(); foreach (var row in new[] { parent, child, blocked }) storageRows[row.Path] = row;
        storageDirectoryRows.Clear(); storageDirectoryRows.AddRange([parent, blocked]);
        storageTreeRoots.Clear(); storageTreeRoots.AddRange([parent, blocked]);
        storageChildCount = 205; storageNextOffset = 200;
        storageSelection.Clear(); storageSelection.Add(child.Path); storageSelectedBytes = child.AllocatedBytes;
        StorageBreadcrumbs.Clear(); StorageBreadcrumbs.Add(new(".", "扫描根目录"));
        FilterStorageRows(); RefreshStorageSelection(); SelectedStorageNode = blocked;
        OnPropertyChanged(nameof(StorageSimple)); OnPropertyChanged(nameof(StorageDetailed)); OnPropertyChanged(nameof(StorageDisplayPath));
        if (parent.SelectionState is not null || child.SelectionState != true || blocked.CanSelect)
            throw new InvalidOperationException("Storage fixture selection or protection state is inconsistent.");
    }
}
