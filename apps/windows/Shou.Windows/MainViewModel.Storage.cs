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
    private string storageAppliedQuery = "";
    private string? storageQueryDigest;
    public ObservableCollection<StorageBreadcrumb> StorageBreadcrumbs { get; } = [];
    public string StorageQuery { get => storageQuery; set { if (SetProperty(ref storageQuery, value)) { UpdateStorageSelectionEnabled(); OnPropertyChanged(nameof(StorageListSummary)); RefreshCommands(); } } }
    private bool StorageQueryCurrent => StorageQuery.Trim() == storageAppliedQuery;
    public string StorageListSummary => F("列表 {0} 项 · {1}已加载 {2} / {3} 项",(StorageDetailed ? StorageTree.Count : StorageNodes.Count) ,(storageAppliedQuery.Length == 0 ? T("目录") : T("匹配")),storageDirectoryRows.Count,storageChildCount) + (StorageQueryCurrent ? "" : T(" · 按搜索更新结果"));
    public string StorageSelectionSummary => F("已选 {0} 项 · 占用估算 {1}",storageSelection.Count,Bytes(storageSelectedBytes));
    public string StorageProtection => SelectedStorageNode?.Protection ?? T("选择项目以查看保护状态。");
    public IAsyncRelayCommand StorageBackCommand { get; private set; } = null!;
    public IAsyncRelayCommand StorageForwardCommand { get; private set; } = null!;
    public IAsyncRelayCommand<StorageBreadcrumb> StorageBreadcrumbCommand { get; private set; } = null!;
    public IAsyncRelayCommand MoreStorageCommand { get; private set; } = null!;
    public IAsyncRelayCommand SearchStorageCommand { get; private set; } = null!;
    public IAsyncRelayCommand SelectVisibleStorageCommand { get; private set; } = null!;
    public IRelayCommand ClearStorageSelectionCommand { get; private set; } = null!;
    public IRelayCommand RevealStorageItemCommand { get; private set; } = null!;
    public IRelayCommand CopyStorageItemPathCommand { get; private set; } = null!;
    public IRelayCommand PreviewStorageItemCommand { get; private set; } = null!;
    public IAsyncRelayCommand TrashStorageCommand { get; }

    private Task RemoveStorageAsync(string action) => RunAsync(async () => {
        var result = await client.RequestAsync("storage.remove", new() { ["scan_id"] = storageScanId, ["paths"] = Strings(storageSelection), ["action"] = action }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        Completion = BuildCompletion(result, action);
        var completedState = action == "trash" ? "trashed" : "purged";
        var removed = Array(result["items"]).Where(item => Text(item, "state") == completedState).Select(item => Text(item, "path").Replace('\\', '/'));
        var root = storageRoot!.Replace('\\', '/').TrimEnd('/') + "/";
        foreach (var absolute in removed.Where(path => path.StartsWith(root, StringComparison.OrdinalIgnoreCase))) storageRemovedPaths.Add(absolute[root.Length..]);
        foreach (var row in storageRows.Values)
            foreach (var child in row.Children.Where(child => StorageGone(child.Path)).ToArray()) row.Children.Remove(child);
        foreach (var row in StorageNodes.Where(row => StorageGone(row.Path)).ToArray()) StorageNodes.Remove(row);
        foreach (var row in StorageTree.Where(row => StorageGone(row.Path)).ToArray()) StorageTree.Remove(row);
        if (StorageMap?["tiles"] is JsonArray tiles) {
            var updated = StorageMap.DeepClone();
            updated["tiles"] = new JsonArray(tiles.Where(tile => !StorageGone(Text(tile, "path"))).Select(tile => tile!.DeepClone()).ToArray());
            StorageMap = updated;
        }
        StorageExtensions.Clear(); ClearStorageSelection(); FilterStorageRows();
        Status = action == "trash" ? T("本次处理已结束，视图仅移除成功项；可在历史中恢复回收站项目。移入回收站不会立即释放空间。") : T("所选项目处理完毕。当前视图已移除成功项；刷新可重新测量占用和类型统计。");
    });

    private void InitializeStorageNavigation()
    {
        InitializeStorageCoverage();
        StorageBackCommand = new AsyncRelayCommand(() => RunAsync(() => NavigateStorageAsync(storageNavigation.BackTarget!, -1)), () => !IsBusy && storageNavigation.BackTarget is not null);
        StorageForwardCommand = new AsyncRelayCommand(() => RunAsync(() => NavigateStorageAsync(storageNavigation.ForwardTarget!, 1)), () => !IsBusy && storageNavigation.ForwardTarget is not null);
        StorageBreadcrumbCommand = new AsyncRelayCommand<StorageBreadcrumb>(item => RunAsync(() => NavigateStorageAsync(item!.Path)), item => !IsBusy && storageScanId is not null && item is not null && item.Path != StoragePath);
        MoreStorageCommand = new AsyncRelayCommand(() => RunAsync(async () => ShowStoragePage(await client.RequestAsync("storage.browse", new() { ["scan_id"] = storageScanId, ["path"] = StoragePath, ["offset"] = storageNextOffset, ["query"] = storageAppliedQuery, ["query_digest"] = storageQueryDigest }, cancellation: Token), true)), () => !IsBusy && StorageQueryCurrent && storageNextOffset is not null);
        SearchStorageCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var browse = await client.RequestAsync("storage.browse", new() { ["scan_id"] = storageScanId, ["path"] = StoragePath, ["query"] = StorageQuery }, cancellation: Token);
            ShowStoragePage(browse, false);
            if (StorageDetailed && StorageMap is not null) await LoadStorageMapAsync();
        }), () => !IsBusy && storageScanId is not null);
        SelectVisibleStorageCommand = new AsyncRelayCommand(() => ChangeStorageSelectionAsync(VisibleStorageRows().Where(row => row.Eligible).Select(row => row.Path).ToArray(), true), () => !IsBusy && StorageQueryCurrent && VisibleStorageRows().Any(row => row.Eligible));
        ClearStorageSelectionCommand = new RelayCommand(ClearStorageSelection, () => !IsBusy && storageSelection.Count > 0);
        RevealStorageItemCommand = new RelayCommand(() => dialogs.RevealItem(StorageAbsolutePath(SelectedStorageNode!.Path)), () => !IsBusy && SelectedStorageNode is { Kind: "file" or "directory" });
        CopyStorageItemPathCommand = new RelayCommand(() => System.Windows.Clipboard.SetText(StorageAbsolutePath(SelectedStorageNode!.Path)), () => !IsBusy && SelectedStorageNode is { Kind: "file" or "directory" });
        PreviewStorageItemCommand = new RelayCommand(() => dialogs.PreviewFile(client, storageScanId!, SelectedStorageNode!.Path), () => !IsBusy && storageScanId is not null && SelectedStorageNode is { Kind: "file" or "directory" });
        commands.Add(PreviewStorageItemCommand);
        commands.AddRange([StorageBackCommand, StorageForwardCommand, StorageBreadcrumbCommand, MoreStorageCommand, SearchStorageCommand, SelectVisibleStorageCommand, ClearStorageSelectionCommand, RevealStorageItemCommand, CopyStorageItemPathCommand]);
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
        storageAppliedQuery = Text(browse, "query"); storageQueryDigest = Text(browse, "query_digest");
        if (!append) { storageDirectoryRows.Clear(); storageTreeRoots.Clear(); StorageTree.Clear(); SelectedStorageNode = null; }
        StoragePath = Text(page["item"]?["node"], "path");
        storageChildCount = page["total_count"]?.GetValue<int>() ?? 0;
        storageNextOffset = page["next_offset"]?.GetValue<int>();
        foreach (var item in Array(page["children"]).Where(item => !StorageGone(Text(item?["node"], "path"))))
        {
            var row = StorageItem(item!["node"]!);
            row.SetPolicy(browse["removal_reasons"]?[row.Path]?.GetValue<string>());
            if (row.Kind == "directory" && row.Children.Count == 0) row.Children.Add(new StorageRow(row.Path + "/", "…", "loading"));
            if (!storageDirectoryRows.Contains(row)) storageDirectoryRows.Add(row);
            if (!storageTreeRoots.Contains(row)) storageTreeRoots.Add(row);
        }
        StorageBreadcrumbs.Clear(); StorageBreadcrumbs.Add(new(".", T("扫描根目录")));
        if (StoragePath != ".") {
            var parts = StoragePath.Split('/');
            for (var index = 0; index < parts.Length; index++) StorageBreadcrumbs.Add(new(string.Join('/', parts.Take(index + 1)), parts[index]));
        }
        FilterStorageRows();
        Status = page["item"]?["node"]?["is_complete"]?.GetValue<bool>() == true ? T("当前文件夹分析完成。双击目录继续查看。") : T("此范围存在覆盖缺口，可打开“扫描覆盖详情”查看。");
    }

    private void FilterStorageRows()
    {
        var query = storageAppliedQuery;
        StorageNodes.Clear(); foreach (var row in storageDirectoryRows.Where(row => !StorageGone(row.Path))) StorageNodes.Add(row);
        StorageTree.Clear(); foreach (var row in storageTreeRoots.Where(row => !StorageGone(row.Path) && (query.Length == 0 || storageDirectoryRows.Contains(row)))) StorageTree.Add(row);
        OnPropertyChanged(nameof(StorageListSummary)); RefreshCommands();
    }

    private void UpdateStorageSelectionEnabled() { foreach (var row in storageRows.Values) row.SetSelectionEnabled(!IsBusy && StorageQueryCurrent); }

    private IEnumerable<StorageRow> VisibleStorageRows()
    {
        if (!StorageDetailed) return StorageNodes;
        static IEnumerable<StorageRow> ExpandedRows(IEnumerable<StorageRow> rows)
        {
            foreach (var row in rows) {
                yield return row;
                if (row.Expanded) foreach (var child in ExpandedRows(row.Children)) yield return child;
            }
        }
        return ExpandedRows(StorageTree);
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
