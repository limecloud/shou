using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed class CleanupGroupRow(string categoryId, string? groupId, string title, long bytes, int count, int selectable) : ObservableObject
{
    public string CategoryId { get; } = categoryId;
    public string? GroupId { get; } = groupId;
    public string Title { get; } = title;
    public int SelectableCount { get; } = selectable;
    public bool HasSelectable => SelectableCount > 0;
    public string Summary => $"{MainViewModel.Bytes(bytes)} · {count} 个目录 · {SelectableCount} 个可选";
    public ObservableCollection<CleanupGroupRow> Children { get; } = [];
    private bool? selectionState = false;
    public bool? SelectionState { get => selectionState; set => SetProperty(ref selectionState, value); }
}

public sealed partial class MainViewModel
{
    private readonly List<string> cleanupScanIds = [];
    private readonly Dictionary<string, string> cleanupScanWorkspaces = new(StringComparer.Ordinal);
    private readonly JsonArray cleanupRefinements = [];
    private readonly CleanupSelection cleanupSelection = new();
    private CleanupGroupRow? cleanupScope;
    private int? cleanupNextOffset;
    private string cleanupQuery = "", appliedCleanupQuery = "", cleanupQueryDigest = "";
    private string cleanupResultSummary = "扫描后可按分类和规则审阅目录。";
    private string cleanupSelectionSummary = "尚未选择目录";
    private bool updatingCleanupGroups, updatingCleanupSelection;
    private CandidateRow? selectedCleanupCandidate;
    public ObservableCollection<CleanupGroupRow> CleanupGroups { get; } = [];
    public CandidateRow? SelectedCleanupCandidate { get => selectedCleanupCandidate; set { if (SetProperty(ref selectedCleanupCandidate, value)) RefreshCommands(); } }
    public string CleanupQuery { get => cleanupQuery; set => SetProperty(ref cleanupQuery, value); }
    public string CleanupResultSummary { get => cleanupResultSummary; private set => SetProperty(ref cleanupResultSummary, value); }
    public string CleanupSelectionSummary { get => cleanupSelectionSummary; private set => SetProperty(ref cleanupSelectionSummary, value); }
    public string CleanupScopeTitle => cleanupScope?.Title ?? "全部分类";
    public IAsyncRelayCommand ApplyCleanupSearchCommand { get; private set; } = null!;
    public IAsyncRelayCommand SelectRecommendedCleanupCommand { get; private set; } = null!;
    public IAsyncRelayCommand<CleanupGroupRow> ToggleCleanupGroupCommand { get; private set; } = null!;
    public IAsyncRelayCommand ShowAllCleanupCommand { get; private set; } = null!;
    public IRelayCommand ClearCleanupSelectionCommand { get; private set; } = null!;
    public IAsyncRelayCommand<CandidateRow> RevealCleanupCandidateCommand { get; private set; } = null!;
    public IAsyncRelayCommand<CandidateRow> CopyCleanupCandidatePathCommand { get; private set; } = null!;
    public IAsyncRelayCommand<CandidateRow> AnalyzeCleanupCandidateCommand { get; private set; } = null!;
    public IAsyncRelayCommand<CandidateRow> ExcludeCleanupCandidateCommand { get; private set; } = null!;
    public IRelayCommand<CandidateRow> AiFromCleanupCandidateCommand { get; private set; } = null!;

    private void InitializeCleanupReview()
    {
        ApplyCleanupSearchCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            appliedCleanupQuery = CleanupQuery.Trim();
            await LoadCleanupReviewAsync(true);
        }), () => !IsBusy && cleanupScanIds.Count > 0);
        SelectRecommendedCleanupCommand = new AsyncRelayCommand(() => SelectCleanupRangeAsync(true), () => !IsBusy && cleanupScanIds.Count > 0);
        ToggleCleanupGroupCommand = new AsyncRelayCommand<CleanupGroupRow>(group => RunAsync(async () => {
            var selected = group!.SelectionState != true;
            var rows = await FetchCleanupSourcesAsync(group.CategoryId, group.GroupId);
            await SetCleanupChoicesAsync(rows, selected);
        }), group => !IsBusy && group?.HasSelectable == true);
        ShowAllCleanupCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            cleanupScope = null; OnPropertyChanged(nameof(CleanupScopeTitle));
            await LoadCleanupReviewAsync(true);
        }), () => !IsBusy && cleanupScanIds.Count > 0);
        ClearCleanupSelectionCommand = new RelayCommand(() => {
            cleanupSelection.Clear(); SyncCleanupSelection();
        }, () => !IsBusy && cleanupSelection.Count > 0);
        RevealCleanupCandidateCommand = new AsyncRelayCommand<CandidateRow>(row => RunAsync(() => {
            dialogs.RevealItem(row!.AbsolutePath); return Task.CompletedTask;
        }), CanUseCleanupCandidate);
        CopyCleanupCandidatePathCommand = new AsyncRelayCommand<CandidateRow>(row => RunAsync(() => {
            System.Windows.Clipboard.SetText(row!.AbsolutePath); Status = "已复制此候选目录的完整路径。"; return Task.CompletedTask;
        }), CanUseCleanupCandidate);
        AnalyzeCleanupCandidateCommand = new AsyncRelayCommand<CandidateRow>(row => RunAsync(async () => {
            await ScanStorageAsync(row!.AbsolutePath); SelectedSection = 1;
        }), CanUseCleanupCandidate);
        AiFromCleanupCandidateCommand = new RelayCommand<CandidateRow>(row => OpenAi(row!.AbsolutePath), CanUseCleanupCandidate);
        ExcludeCleanupCandidateCommand = new AsyncRelayCommand<CandidateRow>(row => RunAsync(async () => {
            // Scope the literal directory to its source workspace, independent
            // of the workspace currently selected in the page header.
            await client.RequestAsync("exclusions.set", new() { ["workspace_id"] = row!.WorkspaceId, ["project"] = row.Path, ["pattern"] = "**", ["remove"] = false }, cancellation: Token);
            var workspace = row.WorkspaceId;
            ResetCleanupReview(); await LoadConfigurationAsync();
            SelectedWorkspace = Workspaces.FirstOrDefault(item => item.Id == workspace);
            ExclusionScope = 1; SelectedSection = 2;
            Status = "已排除此目录及其内容，文件保持原位。重新扫描后生效，可在当前工作区的排除保护中移除。";
        }), row => CanUseCleanupCandidate(row) && !AiBusy);
        commands.AddRange([ApplyCleanupSearchCommand, SelectRecommendedCleanupCommand, ToggleCleanupGroupCommand,
            ShowAllCleanupCommand, ClearCleanupSelectionCommand, RevealCleanupCandidateCommand, CopyCleanupCandidatePathCommand,
            AnalyzeCleanupCandidateCommand, ExcludeCleanupCandidateCommand, AiFromCleanupCandidateCommand]);
    }

    private bool CanUseCleanupCandidate(CandidateRow? row) => !IsBusy && row is not null && Candidates.Contains(row);

    private void ResetCleanupReview()
    {
        cleanupScanIds.Clear(); cleanupScanWorkspaces.Clear(); cleanupRefinements.Clear(); cleanupSelection.Clear();
        cleanupScope = null; cleanupNextOffset = null; cleanupQueryDigest = "";
        appliedCleanupQuery = ""; CleanupQuery = "";
        SelectedCleanupCandidate = null; Candidates.Clear(); CleanupGroups.Clear();
        CleanupResultSummary = "扫描后可按分类和规则审阅目录。";
        SyncCleanupSelection(); OnPropertyChanged(nameof(CleanupScopeTitle));
    }
    private void RememberCleanupScan(JsonNode page)
    {
        var id = Text(page, "scan_id");
        if (!string.IsNullOrEmpty(id) && !cleanupScanIds.Contains(id)) cleanupScanIds.Add(id);
        if (!string.IsNullOrEmpty(id)) cleanupScanWorkspaces[id] = Text(page, "workspace_id");
    }
    private JsonObject CleanupReviewInput(string? category = null, string? group = null, string query = "", bool recommended = false) => new() {
        ["scan_ids"] = Strings(cleanupScanIds), ["refinements"] = cleanupRefinements.DeepClone(),
        ["category_id"] = category ?? "", ["group_id"] = group ?? "", ["query"] = query, ["recommended_only"] = recommended
    };
    private async Task LoadCleanupReviewAsync(bool first, bool rebuildGroups = false)
    {
        var input = CleanupReviewInput(cleanupScope?.CategoryId, cleanupScope?.GroupId, appliedCleanupQuery);
        if (!first) { input["offset"] = cleanupNextOffset; input["query_digest"] = cleanupQueryDigest; }
        var page = await client.RequestAsync("cleanup.review", input, cancellation: Token);
        // Replace the displayed rows only after a successful query. Selections
        // retain their immutable source keys when another group or page opens.
        if (first) { SelectedCleanupCandidate = null; Candidates.Clear(); }
        cleanupNextOffset = page["next_offset"]?.GetValue<int>();
        cleanupQueryDigest = Text(page, "query_digest");
        if (CleanupGroups.Count == 0 || rebuildGroups) BuildCleanupGroups(page);
        foreach (var source in Array(page["sources"])) {
            var row = CleanupCandidate(source);
            row.IsSelected = cleanupSelection.Contains(row.Choice.Key);
            row.PropertyChanged += (_, e) => {
                if (e.PropertyName != nameof(CandidateRow.IsSelected) || updatingCleanupSelection) return;
                cleanupSelection.Set(row.Choice, row.IsSelected); UpdateCleanupSelectionSummary();
            };
            Candidates.Add(row);
        }
        CleanupResultSummary = $"{CleanupScopeTitle} · 已加载 {Candidates.Count} / {page["total_count"]} 个目录 · 全部分类占用估算 {Bytes(page["bytes"]?.GetValue<long>() ?? 0)}";
        UpdateCleanupSelectionSummary();
        Status = "结果已按分类、规则和目录整理；搜索与分页保留已有选择。";
    }
    private static CandidateRow CleanupCandidate(JsonNode? source)
    {
        var candidate = source?["candidate"];
        var reasons = Array(candidate?["reasons"]).Select(value => value?.GetValue<string>()).ToArray();
        return new(Text(candidate, "id"), Text(candidate, "relative_path"), candidate?["allocated_bytes_estimate"]?.GetValue<long>() ?? 0,
            source?["selectable"]?.GetValue<bool>() == true,
            Text(candidate, "risk") + (reasons.Length == 0 ? "" : " · " + string.Join("、", reasons)),
            Text(source, "scan_id"), Text(source, "workspace_id"), Text(source, "root_path"), reasons.Contains("incomplete_scan"),
            Text(source, "category_id"), Text(source, "group_id"), source?["recommended"]?.GetValue<bool>() == true,
            source?["file_count"]?.GetValue<int>() ?? 0);
    }
    private void BuildCleanupGroups(JsonNode page)
    {
        updatingCleanupGroups = true;
        try {
            CleanupGroups.Clear();
            foreach (var category in Array(page["categories"])) {
                var id = Text(category, "id");
                var groups = Array(category?["groups"]);
                var root = new CleanupGroupRow(id, null, id switch {
                    "userCache" => "用户缓存", "application" => "应用缓存", "browser" => "浏览器缓存",
                    "developer" => "开发工具", "build" => "项目构建产物", "personal" => "个人规则", _ => id
                }, category?["bytes"]?.GetValue<long>() ?? 0, groups.Sum(value => value?["count"]?.GetValue<int>() ?? 0),
                    groups.Sum(value => value?["selectable_count"]?.GetValue<int>() ?? 0));
                foreach (var group in groups) root.Children.Add(new CleanupGroupRow(id, Text(group, "id"), Text(group, "title"),
                    group?["bytes"]?.GetValue<long>() ?? 0, group?["count"]?.GetValue<int>() ?? 0, group?["selectable_count"]?.GetValue<int>() ?? 0));
                CleanupGroups.Add(root);
            }
        } finally { updatingCleanupGroups = false; }
    }
    public Task SelectCleanupGroupAsync(CleanupGroupRow group)
    {
        if (updatingCleanupGroups || IsBusy) return Task.CompletedTask;
        return RunAsync(async () => {
            cleanupScope = group; OnPropertyChanged(nameof(CleanupScopeTitle));
            await LoadCleanupReviewAsync(true);
        });
    }
    private void UpdateCleanupSelectionSummary()
    {
        foreach (var category in CleanupGroups) {
            category.SelectionState = cleanupSelection.State(category.SelectableCount, category.CategoryId);
            foreach (var group in category.Children) group.SelectionState = cleanupSelection.State(group.SelectableCount, group.CategoryId, group.GroupId);
        }
        CleanupSelectionSummary = $"已选择 {cleanupSelection.Count} 个目录 · 占用估算 {Bytes(cleanupSelection.Bytes)}（包括其他页面与分类中的选择）";
        RefreshCommands();
    }
    private void SyncCleanupSelection()
    {
        updatingCleanupSelection = true;
        try { foreach (var row in Candidates) row.IsSelected = cleanupSelection.Contains(row.Choice.Key); }
        finally { updatingCleanupSelection = false; }
        UpdateCleanupSelectionSummary();
    }
    private async Task<List<CandidateRow>> FetchCleanupSourcesAsync(string? category = null, string? group = null, string query = "", bool recommended = false)
    {
        var input = CleanupReviewInput(category, group, query, recommended);
        var rows = new List<CandidateRow>();
        while (true) {
            var page = await client.RequestAsync("cleanup.review", input, cancellation: Token);
            rows.AddRange(Array(page["sources"]).Select(CleanupCandidate).Where(row => row.Eligible));
            if (page["next_offset"]?.GetValue<int>() is not { } offset) return rows;
            input["offset"] = offset; input["query_digest"] = Text(page, "query_digest");
        }
    }
    private Task SetCleanupChoicesAsync(IEnumerable<CandidateRow> rows, bool selected)
    {
        Token.ThrowIfCancellationRequested();
        foreach (var row in rows) cleanupSelection.Set(row.Choice, selected && row.Eligible);
        SyncCleanupSelection();
        return Task.CompletedTask;
    }
    private Task SelectCleanupRangeAsync(bool recommended) => RunAsync(async () => {
        var rows = await FetchCleanupSourcesAsync(cleanupScope?.CategoryId, cleanupScope?.GroupId, appliedCleanupQuery, recommended);
        var selected = recommended || rows.Any(row => !cleanupSelection.Contains(row.Choice.Key));
        await SetCleanupChoicesAsync(rows, selected);
        Status = recommended ? "已选择当前范围内的推荐项目；高风险或未完整测量项目不会自动选中。" : selected ? "已选择当前搜索范围的全部可清理目录，包括其他页面。" : "已取消当前搜索范围的选择。";
    });
}
