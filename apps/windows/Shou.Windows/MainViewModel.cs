using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record WorkspaceRow(string Id, string Path, string RootRef);
public sealed record RuleRow(string Id, string Version, string Title);
public sealed record RulePreviewRow(string Path, string Size, string Decision);
public sealed record HistoryItemRow(string Path, string State, string? Error, string? ResultingPath);
public sealed record HistoryRow(string Id, string CreatedAt, string RootPath, string State, string[] RestorableIds, string[] PurgeableIds, HistoryItemRow[] Items)
{
    public string Label => ProgressPresentation.ShortPath(RootPath);
}
public sealed class StorageRow(string path, string size, string kind, long allocatedBytes=0, long logicalBytes=0, int files=0) : ObservableObject
{
    public string Path { get; } = path;
    public string Name => Path.Split('/').Last();
    public string Size { get; } = size;
    public string Kind { get; } = kind;
    public long AllocatedBytes { get; } = allocatedBytes;
    public string LogicalSize { get; } = MainViewModel.Bytes(logicalBytes);
    public int Files { get; } = files;
    public string Icon => Kind == "directory" ? "📁" : "▤";
    private string share="—";
    public string Share { get=>share; set=>SetProperty(ref share,value); }
    public bool Eligible => Kind is "file" or "directory";
    private bool focused, expanded;
    public bool Focused { get=>focused; set=>SetProperty(ref focused,value); }
    public bool Expanded { get=>expanded; set=>SetProperty(ref expanded,value); }
    private bool selected;
    public bool IsSelected { get => selected; set => SetProperty(ref selected,value && Eligible); }
    public ObservableCollection<StorageRow> Children { get; } = [];
}
public sealed record StorageExtensionRow(string Suffix, string Size, int Files, string Color, string Share, string LogicalSize) { public string Name => Suffix.Length == 0 ? "无扩展名" : "." + Suffix; }

public sealed record CleanupItemResultRow(string Path, string State, string? Error);
public sealed record CleanupCompletionRow(string Icon, string Title, string SuccessText, string Message, string Processed, string Skipped, string Failed, string NeedsVerification, bool HasIssues, CleanupItemResultRow[] Items);
public sealed class CandidateRow(string id, string path, long bytes, bool eligible, string description, string scan = "", string workspace = "", string root = "") : ObservableObject
{
    public string Id { get; } = id;
    public string ScanId { get; } = scan;
    public string WorkspaceId { get; } = workspace;
    public string AbsolutePath { get; } = root.TrimEnd('/', '\\') + "/" + path;
    public string Path { get; } = path;
    public string Size { get; } = MainViewModel.Bytes(bytes);
    public bool Eligible { get; } = eligible;
    public string Description { get; } = description;
    private bool selected;
    public bool IsSelected { get => selected; set => SetProperty(ref selected, value && Eligible); }
}

public sealed class MainViewModel : ObservableObject
{
    private readonly BridgeProcessClient client;
    private readonly WindowsDialogs dialogs;
    private readonly List<IRelayCommand> commands;
    private CancellationTokenSource? active;
    private TaskCompletionSource? idle;
    private JsonObject? configuration;
    private JsonNode? rulePreview;
    private string rulePreviewSummary="", rulePreviewDetails="";
    private string? scanId, storageScanId;
    private bool standardScan = true;
    private readonly Queue<(string Scan, int Offset)> pendingPages = new();
    private readonly List<(string Workspace, string Path)> retryTargets = new();
    private readonly Dictionary<string,StorageRow> storageRows = new();
    private readonly List<string> storageRemovedPaths = new();
    private JsonNode? storageMap;
    private bool storageDetailed;
    private StorageExtensionRow? selectedStorageExtension;
    private static string StoragePreference => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "space-view.txt");
    private string? storageRoot;
    private JsonNode?[] storageCoverage = [];
    private int? nextOffset;
    private bool busy, trashAvailable, permanentAvailable;
    private string status = "正在连接清理核心…", exclusionPattern = "", storagePath = ".";
    private WorkspaceRow? selectedWorkspace;
    private RuleRow? selectedRule;
    private HistoryRow? selectedHistory;
    private StorageRow? selectedStorageNode;
    private string? selectedExclusion;
    private CleanupCompletionRow? completion;
    private int selectedSection;
    private double? progressFraction;
    private string progressPath = "", progressFullPath = "";
    private bool progressVisible;
    private int? historyNextOffset;

    public MainViewModel(BridgeProcessClient client, WindowsDialogs dialogs)
    {
        this.client = client; this.dialogs = dialogs;
        ChooseFolderCommand = new AsyncRelayCommand(ChooseFolderAsync, () => !IsBusy);
        ScanCommand = new AsyncRelayCommand(() => { standardScan = true; return ScanAsync(); }, () => !IsBusy);
        ScanFolderCommand = new AsyncRelayCommand(() => { standardScan = false; return ScanAsync(); }, () => !IsBusy && SelectedWorkspace is not null);
        SelectAllCommand = new RelayCommand(() => { var select = Candidates.Any(item => item.Eligible && !item.IsSelected); foreach (var item in Candidates) item.IsSelected = select; }, () => !IsBusy && Candidates.Any(item => item.Eligible));
        MoreCommand = new AsyncRelayCommand(MoreAsync, () => !IsBusy && (nextOffset is not null || pendingPages.Count > 0));
        CleanCommand = new AsyncRelayCommand(() => CleanAsync("trash"), () => !IsBusy && trashAvailable && Candidates.Any(item => item.IsSelected));
        PermanentDeleteCommand = new AsyncRelayCommand(() => CleanAsync("permanent"), () => !IsBusy && permanentAvailable && Candidates.Any(item => item.IsSelected));
        AnalyzeCommand = new AsyncRelayCommand(AnalyzeAsync, () => !IsBusy);
        StorageUpCommand = new AsyncRelayCommand(StorageUpAsync, () => !IsBusy && storageScanId is not null && StoragePath != ".");
        RescanStorageCommand = new AsyncRelayCommand(() => RunAsync(() => ScanStorageAsync(CurrentStorageFolder!)), () => !IsBusy && CurrentStorageFolder is not null);
        RevealStorageCommand = new RelayCommand(() => dialogs.RevealFolder(CurrentStorageFolder!), () => !IsBusy && CurrentStorageFolder is not null);
        try { storageDetailed = File.Exists(StoragePreference) && File.ReadAllText(StoragePreference) == "detailed"; } catch (Exception error) when(error is IOException or UnauthorizedAccessException) { }
        CopyStorageAnalysisCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var context=await client.RequestAsync("storage.context", new() { ["scan_id"]=storageScanId,["path"]=StoragePath,["focused_path"]=SelectedStorageNode?.Path,["selected_paths"]=Strings(storageRows.Values.Where(row=>row.IsSelected).Select(row=>row.Path)),["removed_paths"]=Strings(storageRemovedPaths),["locale"]="zh-CN" }, cancellation:Token);
            System.Windows.Clipboard.SetText(Text(context,"text")); Status="已复制分析结果，可粘贴给 AI Agent。";
        }), () => !IsBusy && storageScanId is not null);
        RemoveStorageCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var paths=storageRows.Values.Where(row => row.IsSelected).Select(row => row.Path).ToArray();
            var result=await client.RequestAsync("storage.remove",new() { ["scan_id"]=storageScanId,["paths"]=Strings(paths),["action"]="permanent" },Progress(), review => dialogs.ConfirmAsync(review, Token),Token);
            Completion=BuildCompletion(result,"permanent");
            var removed=Array(result["items"]).Where(item=>Text(item,"state")=="purged").Select(item=>Text(item,"path").Replace('\\','/')).ToArray();
            var root=storageRoot!.Replace('\\','/').TrimEnd('/')+"/";
            foreach(var absolute in removed.Where(path=>path.StartsWith(root,StringComparison.OrdinalIgnoreCase))) storageRemovedPaths.Add(absolute[root.Length..]);
            bool Gone(string relative) => StorageGone(relative);
            foreach(var row in storageRows.Values) {
                if(Gone(row.Path)) row.IsSelected=false;
                foreach(var child in row.Children.Where(child=>Gone(child.Path)).ToArray()) row.Children.Remove(child);
            }
            foreach(var row in StorageNodes.Where(row=>Gone(row.Path)).ToArray()) StorageNodes.Remove(row);
            foreach(var row in StorageTree.Where(row=>Gone(row.Path)).ToArray()) StorageTree.Remove(row);
            if(StorageMap?["tiles"] is JsonArray tiles) {
                var updated=StorageMap.DeepClone();
                updated["tiles"]=new JsonArray(tiles.Where(tile=>!Gone(Text(tile,"path"))).Select(tile=>tile!.DeepClone()).ToArray());
                StorageMap=updated;
            }
            StorageExtensions.Clear();
            Status="所选项目处理完毕。当前视图已移除成功项；刷新可重新测量占用和类型统计。";
        }), () => !IsBusy && storageScanId is not null && storageRows.Values.Any(row => row.IsSelected));
        HistoryCommand = new AsyncRelayCommand(() => RunAsync(LoadHistoryAsync), () => !IsBusy);
        MoreHistoryCommand = new AsyncRelayCommand(() => RunAsync(() => LoadHistoryPageAsync(true)), () => !IsBusy && historyNextOffset is not null);
        CollectRecordsCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var result = await client.RequestAsync("records.collect", cancellation: Token);
            Status = $"已回收 {Bytes(result["removable_bytes"]?.GetValue<long>() ?? 0)} 扫描记录，保留活跃计划、历史与恢复数据。";
        }), () => !IsBusy);
        ClearHistoryCommand = new AsyncRelayCommand(() => ClearHistoryAsync(false), () => !IsBusy && History.Count > 0);
        RemoveHistoryCommand = new AsyncRelayCommand(() => ClearHistoryAsync(true), () => !IsBusy && SelectedHistory is not null);
        RestoreCommand = new AsyncRelayCommand(() => FollowUpAsync("restore"), () => !IsBusy && trashAvailable && SelectedHistory?.RestorableIds.Length > 0);
        PurgeCommand = new AsyncRelayCommand(() => FollowUpAsync("purge"), () => !IsBusy && permanentAvailable && SelectedHistory?.PurgeableIds.Length > 0);
        DismissCompletionCommand = new RelayCommand(() => Completion = null, () => Completion is not null);
        ViewHistoryFromCompletionCommand = new RelayCommand(() => { Completion = null; SelectedSection = 3; _ = LoadHistoryAsync(); }, () => Completion is not null && !IsBusy);
        RetryCleanupCommand = new AsyncRelayCommand(RetryCleanupAsync, () => !IsBusy && CompletionHasIssues);
        ImportRuleCommand = new AsyncRelayCommand(ImportRuleAsync, () => !IsBusy);
        PreviewRuleCommand = new AsyncRelayCommand(PreviewRuleAsync, () => !IsBusy && SelectedWorkspace is not null && SelectedRule is not null && !SelectedRule.Id.StartsWith("shou.builtin.",StringComparison.Ordinal));
        EnableAndScanRuleCommand = new AsyncRelayCommand(EnableAndScanRuleAsync, () => !IsBusy && rulePreview is not null);
        ReviewRulesCommand = new AsyncRelayCommand(() => RunAsync(async () => { await LoadConfigurationAsync(); SelectedSection=2; }), () => !IsBusy);
        EnableRuleCommand = new AsyncRelayCommand(() => SetRuleAsync(true), () => !IsBusy && SelectedWorkspace is not null && SelectedRule is not null);
        DisableRuleCommand = new AsyncRelayCommand(() => SetRuleAsync(false), () => !IsBusy && SelectedWorkspace is not null && SelectedRule is not null);
        AddExclusionCommand = new AsyncRelayCommand(AddExclusionAsync, () => !IsBusy && !string.IsNullOrWhiteSpace(ExclusionPattern));
        RemoveExclusionCommand = new AsyncRelayCommand(RemoveExclusionAsync, () => !IsBusy && SelectedExclusion is not null);
        CancelCommand = new RelayCommand(() => { active?.Cancel(); Status = "正在停止；请等待当前项目写回回执。"; }, () => IsBusy);
        commands = [ChooseFolderCommand, ScanCommand, MoreCommand, CleanCommand, PermanentDeleteCommand, AnalyzeCommand, StorageUpCommand, HistoryCommand, RestoreCommand, PurgeCommand, ImportRuleCommand, EnableRuleCommand, DisableRuleCommand, AddExclusionCommand, RemoveExclusionCommand, CancelCommand, DismissCompletionCommand, ViewHistoryFromCompletionCommand, RetryCleanupCommand];
        commands.Add(ScanFolderCommand); commands.Add(SelectAllCommand);
        commands.Add(ClearHistoryCommand); commands.Add(RemoveHistoryCommand);
        commands.Add(MoreHistoryCommand); commands.Add(CollectRecordsCommand);
        commands.Add(CopyStorageAnalysisCommand); commands.Add(RemoveStorageCommand); commands.Add(RescanStorageCommand); commands.Add(RevealStorageCommand);
        commands.Add(PreviewRuleCommand); commands.Add(EnableAndScanRuleCommand); commands.Add(ReviewRulesCommand);
        PropertyChanged += (_, _) => RefreshCommands();
    }
    public ObservableCollection<WorkspaceRow> Workspaces { get; } = [];
    public ObservableCollection<CandidateRow> Candidates { get; } = [];
    public ObservableCollection<RuleRow> Rules { get; } = [];
    public ObservableCollection<RulePreviewRow> RulePreviewRows { get; } = [];
    public IAsyncRelayCommand PreviewRuleCommand { get; }
    public IAsyncRelayCommand EnableAndScanRuleCommand { get; }
    public IAsyncRelayCommand ReviewRulesCommand { get; }
    public string RulePreviewSummary { get=>rulePreviewSummary; private set=>SetProperty(ref rulePreviewSummary,value); }
    public string RulePreviewDetails { get=>rulePreviewDetails; private set=>SetProperty(ref rulePreviewDetails,value); }
    public ObservableCollection<HistoryRow> History { get; } = [];
    public ObservableCollection<HistoryItemRow> HistoryItems { get; } = [];
    public ObservableCollection<StorageRow> StorageTree { get; } = [];
    public ObservableCollection<StorageExtensionRow> StorageExtensions { get; } = [];
    public IAsyncRelayCommand CopyStorageAnalysisCommand { get; }
    public IAsyncRelayCommand RemoveStorageCommand { get; }
    public bool StorageDetailed {
        get => storageDetailed;
        set { if(SetProperty(ref storageDetailed,value)) { OnPropertyChanged(nameof(StorageSimple)); try { Directory.CreateDirectory(Path.GetDirectoryName(StoragePreference)!); File.WriteAllText(StoragePreference,value ? "detailed" : "simple"); } catch(Exception error) when(error is IOException or UnauthorizedAccessException) { } if(value && storageScanId is not null && StorageMap is null && !IsBusy) _ = RunAsync(LoadStorageMapAsync); } }
    }
    public bool StorageSimple { get => !StorageDetailed; set { if(value) StorageDetailed=false; } }
    public JsonNode? StorageMap { get => storageMap; private set => SetProperty(ref storageMap,value); }
    public StorageExtensionRow? SelectedStorageExtension { get=>selectedStorageExtension; set { if(SetProperty(ref selectedStorageExtension,value)) OnPropertyChanged(nameof(StorageExtensionFilter)); } }
    public string? StorageExtensionFilter => SelectedStorageExtension?.Suffix;
    public string? StorageFocusPath => SelectedStorageNode?.Path;
    public ObservableCollection<StorageRow> StorageNodes { get; } = [];
    public ObservableCollection<string> Exclusions { get; } = [];
    public IAsyncRelayCommand ChooseFolderCommand { get; }
    public IAsyncRelayCommand ScanCommand { get; }
    public IAsyncRelayCommand ScanFolderCommand { get; }
    public IRelayCommand SelectAllCommand { get; }
    public IAsyncRelayCommand MoreCommand { get; }
    public IAsyncRelayCommand CleanCommand { get; }
    public IAsyncRelayCommand PermanentDeleteCommand { get; }
    public IAsyncRelayCommand AnalyzeCommand { get; }
    public IAsyncRelayCommand StorageUpCommand { get; }
    public IAsyncRelayCommand RescanStorageCommand { get; }
    public IRelayCommand RevealStorageCommand { get; }
    private string? CurrentStorageFolder => storageRoot is null ? null : StoragePath == "." ? storageRoot : Path.Combine(storageRoot, StoragePath.Replace('/', Path.DirectorySeparatorChar));
    public IAsyncRelayCommand HistoryCommand { get; }
    public IAsyncRelayCommand MoreHistoryCommand { get; }
    public IAsyncRelayCommand CollectRecordsCommand { get; }
    public IAsyncRelayCommand ClearHistoryCommand { get; }
    public IAsyncRelayCommand RemoveHistoryCommand { get; }
    public IAsyncRelayCommand RestoreCommand { get; }
    public IAsyncRelayCommand PurgeCommand { get; }
    public IRelayCommand DismissCompletionCommand { get; }
    public IRelayCommand ViewHistoryFromCompletionCommand { get; }
    public IAsyncRelayCommand RetryCleanupCommand { get; }
    public IAsyncRelayCommand ImportRuleCommand { get; }
    public IAsyncRelayCommand EnableRuleCommand { get; }
    public IAsyncRelayCommand DisableRuleCommand { get; }
    public IAsyncRelayCommand AddExclusionCommand { get; }
    public IAsyncRelayCommand RemoveExclusionCommand { get; }
    public IRelayCommand CancelCommand { get; }
    public bool IsBusy { get => busy; private set => SetProperty(ref busy, value); }
    public bool ProgressIndeterminate => IsBusy && ProgressFraction is null;
    public double? ProgressFraction { get => progressFraction; private set { SetProperty(ref progressFraction, value); OnPropertyChanged(nameof(ProgressIndeterminate)); OnPropertyChanged(nameof(ProgressValue)); OnPropertyChanged(nameof(ProgressPercentage)); } }
    public double ProgressValue => (ProgressFraction ?? 0) * 100;
    public string ProgressPercentage => ProgressFraction is { } value ? $"{value:P0}" : "";
    public string ProgressPath { get => progressPath; private set => SetProperty(ref progressPath, value); }
    public string ProgressFullPath { get => progressFullPath; private set => SetProperty(ref progressFullPath, value); }
    public bool ProgressVisible { get => progressVisible; private set => SetProperty(ref progressVisible, value); }
    public int SelectedSection { get => selectedSection; set => SetProperty(ref selectedSection, value); }
    public CleanupCompletionRow? Completion { get => completion; private set { if (SetProperty(ref completion, value)) { OnPropertyChanged(nameof(CompletionVisible)); OnPropertyChanged(nameof(CompletionHasIssues)); RefreshCommands(); } } }
    public bool CompletionVisible => Completion is not null;
    public bool CompletionHasIssues => Completion?.HasIssues == true;
    public string Status { get => status; private set => SetProperty(ref status, value); }
    public string StoragePath { get => storagePath; private set { SetProperty(ref storagePath, value); OnPropertyChanged(nameof(StorageDisplayPath)); } }
    public string StorageDisplayPath => CurrentStorageFolder ?? "";
    public string ExclusionPattern { get => exclusionPattern; set => SetProperty(ref exclusionPattern, value); }
    public string? SelectedExclusion { get => selectedExclusion; set => SetProperty(ref selectedExclusion, value); }
    public WorkspaceRow? SelectedWorkspace
    {
        get => selectedWorkspace;
        set { if (SetProperty(ref selectedWorkspace, value)) { Candidates.Clear(); scanId = null; nextOffset = null; LoadRules(); RefreshCommands(); } }
    }
    public RuleRow? SelectedRule { get => selectedRule; set { if(SetProperty(ref selectedRule, value)) { rulePreview=null; RulePreviewRows.Clear(); RulePreviewSummary=""; RulePreviewDetails=""; } } }
    public HistoryRow? SelectedHistory
    {
        get => selectedHistory;
        set { if (SetProperty(ref selectedHistory, value)) { HistoryItems.Clear(); foreach (var item in value?.Items ?? []) HistoryItems.Add(item); } }
    }
    public StorageRow? SelectedStorageNode { get => selectedStorageNode; set { if(SetProperty(ref selectedStorageNode, value)) OnPropertyChanged(nameof(StorageFocusPath)); } }
    private CancellationToken Token => active?.Token ?? CancellationToken.None;
    private void RefreshCommands() { foreach (var command in commands) command.NotifyCanExecuteChanged(); }
    public Task WhenIdleAsync() => idle?.Task ?? Task.CompletedTask;
    public Task InitializeAsync() => RunAsync(async () =>
    {
        var capabilities = await client.RequestAsync("capabilities", cancellation: Token);
        if (capabilities["platform"]?.GetValue<string>() != "windows" || capabilities["bridge_version"]?.GetValue<int>() != 1)
            throw new BridgeException("incompatible_engine", "请选择与 Windows 客户端匹配的 Shou 清理核心。");
        trashAvailable = capabilities["features"]?["trash"]?.GetValue<bool>() == true;
        permanentAvailable = capabilities["features"]?["permanent"]?.GetValue<bool>() == true;
        await LoadConfigurationAsync(); await LoadHistoryAsync();
        Status = "一键扫描常用缓存和开发项目，也可以选择自定义目录。";
    });
    private async Task RunAsync(Func<Task> action, bool cleanup = false)
    {
        if (IsBusy) return;
        using var cancellation = new CancellationTokenSource(); active = cancellation;
        idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        ProgressFraction = null; ProgressPath = ""; ProgressFullPath = ""; ProgressVisible = false; IsBusy = true;
        OnPropertyChanged(nameof(ProgressIndeterminate));
        try { await action(); }
        catch (BridgeException error) { ReportFailure(error.Code + "：" + error.Message, cleanup); }
        catch (Exception error) { ReportFailure("操作未完成：" + error.Message, cleanup); }
        finally { active = null; ProgressVisible = false; IsBusy = false; OnPropertyChanged(nameof(ProgressIndeterminate)); idle.TrySetResult(); }
    }
    private void ReportFailure(string message, bool cleanup)
    {
        Status = message;
        if (cleanup) Completion = new("!", "清理未能完成", "", message, "0", "0", "0", "0", true, []);
    }
    private IProgress<JsonObject> Progress() => new Progress<JsonObject>(value =>
    {
        if (!IsBusy) return;
        var stage = Text(value, "stage");
        var title = stage switch { "scanning" => "正在扫描", "analysis" => "正在整理结果", "saving" => "正在保存结果", "loading" or "transferring" or "validating" => "正在读取结果", "moving" => "正在移入回收站", "purging" => "正在永久清理", "restoring" => "正在恢复", "finalizing" => "正在完成清理", _ => "正在核验所选项目" };
        var completed = value["completed_unit_count"]?.GetValue<long>() ?? value["processed_count"]?.GetValue<long>();
        var total = value["total_unit_count"]?.GetValue<long>() ?? value["item_count"]?.GetValue<long>();
        ProgressFraction = completed is >= 0 && total is > 0 && completed <= total ? (double)completed.Value / total.Value : null;
        var itemDone = value["current_item_processed_count"]?.GetValue<long>();
        var itemTotal = value["current_item_count"]?.GetValue<long>();
        if (ProgressFraction is not null && itemDone is >= 0 && itemTotal is > 0 && itemDone <= itemTotal && total is > 0 && completed < total)
            ProgressFraction = Math.Min(1, (completed!.Value + (double)itemDone.Value / itemTotal.Value) / total.Value);
        ProgressVisible = true;
        ProgressFullPath = Text(value, "path");
        ProgressPath = ProgressPresentation.ShortPath(ProgressFullPath);
        Status = $"{title} · 已处理 {value["entry_count"] ?? value["processed_count"]} 项";
    });
    private async Task LoadConfigurationAsync()
    {
        var selected = SelectedWorkspace?.Id;
        var result = await client.RequestAsync("configuration", cancellation: Token);
        if(configuration?["configuration"]?["revision"]?.GetValue<string>() == result["configuration"]?["revision"]?.GetValue<string>()) return;
        configuration = result as JsonObject;
        Workspaces.Clear();
        foreach (var item in Array(result["configuration"]?["workspaces"])) Workspaces.Add(new(Text(item, "id"), Text(item, "path"), Text(item, "root_ref")));
        Exclusions.Clear(); SelectedExclusion = null;
        foreach (var item in Array(result["configuration"]?["global_exclusions"])) if (item?.GetValue<string>() is { } pattern) Exclusions.Add(pattern);
        SelectedWorkspace = Workspaces.FirstOrDefault(item => item.Id == selected) ?? Workspaces.FirstOrDefault();
        LoadRules();
    }
    public Task RefreshExternalChangesAsync() => RunAsync(async () => {
        var revision=configuration?["configuration"]?["revision"]?.GetValue<string>();
        await LoadConfigurationAsync();
        if(revision is not null && revision != configuration?["configuration"]?["revision"]?.GetValue<string>()) {
            Candidates.Clear(); scanId=null; nextOffset=null; pendingPages.Clear();
            Status="外部规则或配置已更新。到“规则与排除”逐条预览，再启用并扫描所选规则。";
        }
    });
    private Task PreviewRuleAsync() => RunAsync(async () => {
        rulePreview=null; RulePreviewRows.Clear(); RulePreviewSummary=""; RulePreviewDetails="";
        var result=await client.RequestAsync("rules.preview",new() { ["workspace_id"]=SelectedWorkspace!.Id,["rule_id"]=SelectedRule!.Id,["version"]=SelectedRule.Version },Progress(),cancellation:Token);
        rulePreview=result;
        RulePreviewSummary=$"{SelectedRule.Title} · 新增可清理估计 {Bytes(result["benefits"]?["additional_allocated_bytes_estimate"]?.GetValue<long>() ?? 0)}";
        RulePreviewDetails=Text(result["rule"],"description")+"\n"+Text(result["rule"]?["risk"],"rebuild_note")+"\n"+string.Join("；",Array(result["rule"]?["risk"]?["limitations"]).Select(value=>value?.GetValue<string>()))+"\n保留条件："+string.Join("、",Array(result["rule"]?["exclude"]?["relative_patterns"]).Select(value=>value?.GetValue<string>()));
        foreach(var row in Array(result["rows"]).Take(200)) RulePreviewRows.Add(new(Text(row,"path"),Bytes(row?["allocated_bytes"]?.GetValue<long>() ?? 0),Text(row,"status")=="matched" ? "条件匹配，待确认" : string.Join("、",Array(row?["reasons"]).Select(value=>value?.GetValue<string>()))));
        Status=Text(result,"status")=="complete" ? "预览完成；仅启用所选规则，其他规则保持原选择。" : "预览部分完成；不可读取的位置不计为完整覆盖。";
    });
    private Task EnableAndScanRuleAsync() => RunAsync(async () => {
        var preview=rulePreview ?? throw new InvalidOperationException("请先预览所选规则。");
        var current=await client.RequestAsync("configuration",cancellation:Token);
        if(Text(current["configuration"],"revision") != Text(preview,"configuration_revision")) throw new InvalidOperationException("配置已更新，请重新预览此规则。");
        var id=Text(preview["rule"],"id");
        var version=Text(preview["rule"],"version");
        var workspace=SelectedWorkspace!.Id;
        await client.RequestAsync("rules.set",new() { ["workspace_id"]=workspace,["rule_id"]=id,["version"]=version,["enabled"]=true },cancellation:Token);
        Candidates.Clear(); nextOffset=null; pendingPages.Clear();
        var result=await client.RequestAsync("scan",new() { ["workspace_id"]=workspace,["rule_ids"]=Strings([id]) },Progress(),cancellation:Token);
        scanId=Text(result,"scan_id"); AddCandidates(result);
        foreach(var row in Candidates.Where(row=>row.Eligible)) row.IsSelected=true;
        await LoadConfigurationAsync(); SelectedSection=0;
        Status="仅所选规则已启用并重新扫描。可调整文件选择，再确认永久删除或移入回收站。";
    });
    private void LoadRules()
    {
        Rules.Clear(); SelectedRule = null;
        if (configuration is null || SelectedWorkspace is null) return;
        var bindings = Array(configuration["configuration"]?["bindings"]);
        foreach (var item in Array(configuration["templates"]).Concat(Array(configuration["configuration"]?["rules"]).Select(item => item?["rule"])))
        {
            if (item is null) continue;
            if (item["location"] is JsonValue location && location.GetValue<string>() != "projects") continue;
            if (item["scope"] is JsonObject scope && Text(scope, "root_ref") != SelectedWorkspace.RootRef) continue;
            if (item["platforms"] is JsonArray platforms && !platforms.Any(value => value?.GetValue<string>() == "windows")) continue;
            var id = Text(item, "id"); var version = item["version"]?.GetValue<string>() ?? "1.0.0";
            var builtin = id.StartsWith("shou.builtin.", StringComparison.Ordinal);
            var binding = bindings.FirstOrDefault(value => Text(value, "rule_id") == id && Text(value, "workspace_id") == SelectedWorkspace.Id && (builtin || Text(value, "version") == version));
            var enabled = binding?["enabled"]?.GetValue<bool>() ?? builtin;
            Rules.Add(new(id, version, $"{Text(item, "name")} · {version} · {(enabled ? "已启用" : "已停用 / 草稿")}"));
        }
    }
    private async Task ChooseFolderAsync()
    {
        var folder = dialogs.ChooseFolder(); if (folder is null) return;
        await RunAsync(async () =>
        {
            var existing = Workspaces.FirstOrDefault(item => item.Path.Replace('/', '\\').Equals(folder, StringComparison.OrdinalIgnoreCase));
            if (existing is not null) { SelectedWorkspace = existing; return; }
            var result = await client.RequestAsync("workspace.add", new() { ["path"] = folder, ["root_ref"] = "project-" + Guid.NewGuid().ToString("N") }, cancellation: Token);
            await LoadConfigurationAsync(); SelectedWorkspace = Workspaces.FirstOrDefault(item => item.Id == Text(result, "id"));
            Status = "已选择目录，可以开始扫描。";
        });
    }
    private Task ScanAsync() => RunAsync(async () =>
    {
        Candidates.Clear(); nextOffset = null; pendingPages.Clear();
        if (standardScan)
        {
            var batch = await client.RequestAsync("system.scan", progress: Progress(), cancellation: Token);
            await LoadConfigurationAsync();
            foreach (var page in Array(batch["scans"]))
            {
                if (page is null) continue;
                AddCandidates(page);
                if (page["next_offset"]?.GetValue<int>() is { } offset) pendingPages.Enqueue((Text(page, "scan_id"), offset));
            }
            nextOffset = null;
            Status = $"标准扫描{(Text(batch, "status") == "complete" ? "完成" : "部分完成")}，已发现 {Candidates.Count} 个清理项目。";
            if (Array(batch["issues"]).Length > 0) Status += " 部分目录未完成；已验证的项目可继续清理。";
            return;
        }
        var result = await client.RequestAsync("scan", new() { ["workspace_id"] = SelectedWorkspace!.Id }, Progress(), cancellation: Token);
        scanId = Text(result, "scan_id"); AddCandidates(result);
    });
    private Task MoreAsync() => RunAsync(async () => {
        if (pendingPages.TryDequeue(out var page)) {
            var result = await client.RequestAsync("scan.results", new() { ["scan_id"] = page.Scan, ["offset"] = page.Offset }, cancellation: Token);
            AddCandidates(result);
            if (nextOffset is { } offset) pendingPages.Enqueue((page.Scan, offset));
            nextOffset = null;
        } else AddCandidates(await client.RequestAsync("scan.results", new() { ["scan_id"] = scanId, ["offset"] = nextOffset }, cancellation: Token));
    });
    private void AddCandidates(JsonNode result)
    {
        foreach (var item in Array(result["candidates"]))
        {
            var reasons = string.Join("、", Array(item?["reasons"]).Select(value => value?.GetValue<string>()));
            var row = new CandidateRow(Text(item, "id"), Text(item, "relative_path"), item?["allocated_bytes_estimate"]?.GetValue<long>() ?? 0, item?["eligible"]?.GetValue<bool>() == true, Text(result, "root_ref").Replace("shou-location-", "") + " · " + Text(item, "risk") + (reasons.Length == 0 ? "" : " · " + reasons), Text(result, "scan_id"), Text(result, "workspace_id"), Text(result, "root_path"));
            row.PropertyChanged += (_, _) => RefreshCommands(); Candidates.Add(row);
        }
        nextOffset = result["next_offset"]?.GetValue<int>();
        Status = $"扫描{(Text(result, "status") == "complete" ? "完成" : "仅完成部分范围")}，显示 {Candidates.Count} / {result["total_count"]} 个规则命中。";
        if (Array(result["issues"]).Length > 0) Status += " " + string.Join("；", Array(result["issues"]).Take(3).Select(value => value?.GetValue<string>()));
        RefreshCommands();
    }
    private Task CleanAsync(string action) => RunAsync(async () =>
    {
        var chosen = Candidates.Where(item => item.IsSelected && item.Eligible).ToArray();
        var selected = chosen.GroupBy(item => item.ScanId);
        var selections = new JsonArray(selected.Select(group => (JsonNode?)new JsonObject { ["scan_id"] = group.Key, ["candidate_ids"] = Strings(group.Select(item => item.Id)) }).ToArray());
        var receipt = await client.RequestAsync("system.clean", new() { ["selections"] = selections, ["action"] = action }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        var successful = Array(receipt["items"]).Where(item => Text(item, "state") is "purged" or "trashed").Select(item => Text(item, "path").Replace('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
        retryTargets.Clear();
        retryTargets.AddRange(chosen.Where(item => !successful.Contains(item.AbsolutePath.Replace('\\', '/'))).Select(item => (item.WorkspaceId, item.AbsolutePath)));
        Candidates.Clear(); scanId = null; nextOffset = null; pendingPages.Clear();
        Completion = BuildCompletion(receipt, action);
        Status = "清理结果：" + Text(receipt, "state") + (action == "permanent" ? "。永久删除无法恢复，可在历史中查看逐项结果。" : "。可在历史中查看或恢复。移入回收站不会立即释放磁盘空间。");
        if (!Token.IsCancellationRequested) await LoadHistoryAsync();
    }, cleanup: true);
    private async Task LoadHistoryAsync()
    {
        await LoadHistoryPageAsync(false);
    }
    private async Task LoadHistoryPageAsync(bool append)
    {
        var result = await client.RequestAsync("history.page", new() { ["offset"] = append ? historyNextOffset ?? 0 : 0 }, cancellation: Token);
        if (!append) History.Clear();
        historyNextOffset = result["next_offset"]?.GetValue<int>();
        foreach (var item in Array(result["receipts"]).Where(item => !History.Any(existing => existing.Id == Text(item, "id")))) History.Add(new(Text(item, "id"), Text(item, "created_at"), Text(item, "root_path"), Text(item, "state"),
            Array(item?["items"]).Where(value => value?["can_restore"]?.GetValue<bool>() == true).Select(value => Text(value, "id")).ToArray(),
            Array(item?["items"]).Where(value => value?["can_purge"]?.GetValue<bool>() == true).Select(value => Text(value, "id")).ToArray(),
            Array(item?["items"]).Select(value => new HistoryItemRow(Text(value, "path"), Text(value, "state"), value?["error"]?.GetValue<string>(), value?["resulting_path"]?.GetValue<string>())).ToArray()));
        SelectedHistory = History.FirstOrDefault();
    }
    private Task ClearHistoryAsync(bool selectedOnly) => RunAsync(async () =>
    {
        var input = new JsonObject { ["include_recoverable"] = selectedOnly };
        if (selectedOnly) input["execution_ids"] = Strings([SelectedHistory!.Id]);
        var result = await client.RequestAsync("history.clear", input, confirm: review => dialogs.ConfirmAsync(review, Token), cancellation: Token);
        await LoadHistoryAsync();
        Status = $"已清理 {Array(result["execution_ids"]).Length} 条操作记录。文件保持原位。";
    });
    private Task FollowUpAsync(string action) => RunAsync(async () =>
    {
        var receipt = SelectedHistory!;
        var result = await client.RequestAsync("history." + action, new() { ["execution_id"] = receipt.Id, ["item_ids"] = Strings(action == "restore" ? receipt.RestorableIds : receipt.PurgeableIds) }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        Completion = BuildCompletion(result, action);
        Status = (action == "restore" ? "恢复结果：" : "永久删除结果：") + string.Join("、", Array(result).Select(value => Text(value, "state"))) + (action == "restore" ? "。已有同名目标不会被覆盖。" : "。已永久删除的项目无法恢复。");
        if (!Token.IsCancellationRequested) await LoadHistoryAsync();
    }, cleanup: true);
    private async Task ImportRuleAsync()
    {
        var path = dialogs.ChooseRule(); if (path is null) return;
        await RunAsync(async () =>
        {
            if (new FileInfo(path).Length > 262144) throw new BridgeException("resource_limit", "规则文件超过 256 KiB。");
            await client.RequestAsync("rules.import", new() { ["json"] = await File.ReadAllTextAsync(path, Token) }, cancellation: Token);
            await LoadConfigurationAsync(); Status = "规则已作为停用草稿导入；启用后重新扫描。";
        });
    }
    private Task SetRuleAsync(bool enabled) => RunAsync(async () =>
    {
        await client.RequestAsync("rules.set", new() { ["workspace_id"] = SelectedWorkspace!.Id, ["rule_id"] = SelectedRule!.Id, ["version"] = SelectedRule.Version, ["enabled"] = enabled }, cancellation: Token);
        Candidates.Clear(); scanId = null; nextOffset = null; await LoadConfigurationAsync(); Status = "规则设置已保存，请重新扫描。";
    });
    private Task AddExclusionAsync() => RunAsync(async () =>
    {
        await client.RequestAsync("exclusions.set", new() { ["pattern"] = ExclusionPattern, ["remove"] = false }, cancellation: Token);
        Candidates.Clear(); scanId = null; nextOffset = null; await LoadConfigurationAsync(); Status = "全局排除已保存，请重新扫描。";
    });
    private Task RemoveExclusionAsync() => RunAsync(async () =>
    {
        await client.RequestAsync("exclusions.set", new() { ["pattern"] = SelectedExclusion, ["remove"] = true }, cancellation: Token);
        Candidates.Clear(); scanId = null; nextOffset = null; await LoadConfigurationAsync(); Status = "全局排除已移除，请重新扫描。";
    });
    private Task RetryCleanupAsync()
    {
        Completion = null;
        Candidates.Clear(); scanId = null; nextOffset = null; pendingPages.Clear();
        if (retryTargets.Count == 0) return ScanAsync();
        var affected = retryTargets.ToArray();
        return RunAsync(async () => {
            foreach (var group in affected.GroupBy(item => item.Workspace)) {
                var page = await client.RequestAsync("scan", new() { ["workspace_id"] = group.Key }, Progress(), cancellation: Token);
                AddCandidates(page);
                var currentScan = Text(page, "scan_id");
                while (nextOffset is { } offset) {
                    page = await client.RequestAsync("scan.results", new() { ["scan_id"] = currentScan, ["offset"] = offset }, cancellation: Token);
                    AddCandidates(page);
                }
            }
            var paths = affected.Select(item => item.Path.Replace('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
            foreach (var row in Candidates) row.IsSelected = row.Eligible && paths.Contains(row.AbsolutePath.Replace('\\', '/'));
            Status = "已刷新未完成的清理范围；成功项目保持完成，请检查选择后继续。";
        });
    }

    private static CleanupCompletionRow BuildCompletion(JsonNode value, string action)
    {
        var source = value is JsonArray ? Array(value) : Array(value?["items"]);
        var executionState = value is JsonObject ? Text(value, "state") : "";
        var rows = source.Select(item => new CleanupItemResultRow(Text(item, "path"),
            Text(item, "state") == "pending" && (executionState is "partial" or "cancelled" or "completed") ? "skipped" : Text(item, "state"),
            item?["error"]?.GetValue<string>())).ToArray();
        var processed = rows.Count(item => new[] { "trashed", "purged", "restored" }.Contains(item.State));
        var skipped = rows.Count(item => item.State is "skipped" or "cancelled");
        var failed = rows.Count(item => item.State == "failed");
        var needs = rows.Count(item => new[] { "unknown", "pending", "moving", "purging", "needs_verification" }.Contains(item.State));
        var resultState = value is JsonObject ? Text(value, "state") : (failed + needs > 0 ? "partial" : "completed");
        var issues = failed + needs > 0 || resultState is "partial" or "cancelled";
        var title = !issues ? action switch { "restore" => "恢复完成", "purge" => "永久删除完成", _ => "清理完成" } : resultState == "cancelled" ? "清理已停止" : "清理已结束，部分项目需处理";
        var message = action switch
        {
            "restore" => issues ? "部分项目未能恢复，请查看操作记录。" : "所选项目已恢复。",
            "purge" or "permanent" => issues ? "部分项目未能永久删除，请查看操作记录。" : "已永久删除，无法恢复。",
            _ => issues ? "部分项目未能移入回收站，请查看操作记录。" : "已移入回收站，可在操作记录中恢复。"
        };
        var bytes = source.Where(item => new[] { "trashed", "purged" }.Contains(Text(item, "state")))
            .Sum(item => item?["bytes"]?.GetValue<long>() ?? 0);
        var successText = bytes > 0 && (action is "trash" or "permanent") ? Bytes(bytes) : $"{processed} 项";
        return new(action == "restore" ? "✓" : issues ? "!" : "✓", title, successText, message, processed.ToString(), skipped.ToString(), failed.ToString(), needs.ToString(), issues, rows);
    }
    private async Task AnalyzeAsync()
    {
        var path = dialogs.ChooseFolder(); if (path is null) return;
        await RunAsync(() => ScanStorageAsync(path));
    }
    private async Task ScanStorageAsync(string path)
    {
        var scan = await client.RequestAsync("storage.scan", new() { ["path"] = path }, Progress(), cancellation: Token);
        storageScanId = Text(scan, "scan_id"); storageRoot = Text(scan, "root_path");
        storageRows.Clear(); storageRemovedPaths.Clear(); storageCoverage = Array(scan["coverage_notes"]); StorageMap=null; ShowDirectory(scan["directory"]!); if(StorageDetailed) await LoadStorageMapAsync();
    }
    public Task OpenStorageNodeAsync() => SelectedStorageNode is { Kind: "directory" } item ? RunAsync(async () => {
        ShowDirectory(await client.RequestAsync("storage.directory",new() { ["scan_id"]=storageScanId,["path"]=item.Path },cancellation:Token)); StorageMap=null; if(StorageDetailed) await LoadStorageMapAsync();
    }) : Task.CompletedTask;
    public async Task FocusStorageAsync(string path,bool open) {
        if(storageRows.TryGetValue(path,out var row)) {
            foreach(var other in storageRows.Values) other.Focused=other==row;
            var parent=path;
            while(parent.Contains('/')) { parent=parent[..parent.LastIndexOf('/')]; if(storageRows.TryGetValue(parent,out var ancestor)) ancestor.Expanded=true; }
            SelectedStorageNode=row; if(open) await OpenStorageNodeAsync();
        }
    }
    public Task LoadStorageChildrenAsync(StorageRow row, bool more=false) => row.Kind != "directory" ? Task.CompletedTask : RunAsync(async () => {
        var offset=more ? row.Children.Count(child=>child.Eligible) : 0;
        var page=await client.RequestAsync("storage.page",new() { ["scan_id"]=storageScanId,["path"]=row.Path,["offset"]=offset },cancellation:Token);
        if(!more) row.Children.Clear();
        else { foreach(var placeholder in row.Children.Where(child=>!child.Eligible).ToArray()) row.Children.Remove(placeholder); }
        foreach(var item in Array(page["children"]).Where(item=>!StorageGone(Text(item?["node"],"path")))) {
            var child=StorageItem(item!["node"]!); row.Children.Add(child);
            if(child.Kind=="directory" && child.Children.Count==0) child.Children.Add(new StorageRow(child.Path+"/","…","loading"));
        }
        if(page["next_offset"] is not null) row.Children.Add(new StorageRow(row.Path+"/","加载更多…","more"));
    });
    private bool StorageGone(string path) => storageRemovedPaths.Any(removed=>path==removed || path.StartsWith(removed+"/",StringComparison.Ordinal));
    private StorageRow StorageItem(JsonNode item) {
        var path=Text(item,"path");
        if(storageRows.TryGetValue(path,out var existing)) return existing;
        var allocated=item["allocated_bytes"]?.GetValue<long>() ?? 0;
        var row=new StorageRow(path,Bytes(allocated),Text(item,"kind"),allocated,item["logical_bytes"]?.GetValue<long>() ?? 0,item["file_count"]?.GetValue<int>() ?? 0);
        row.PropertyChanged += (_,_)=>RemoveStorageCommand.NotifyCanExecuteChanged(); storageRows[path]=row; return row;
    }
    private async Task LoadStorageMapAsync() {
        StorageMap=await client.RequestAsync("storage.map",new() { ["scan_id"]=storageScanId,["path"]=StoragePath },cancellation:Token);
        var presentation=StorageMap["presentation"]!;
        var totals=Array(presentation["items"]).Select(item=>item!["node"]!).Append(presentation["scope"]!["node"]!).ToDictionary(item=>Text(item,"path"),item=>item["allocated_bytes"]?.GetValue<long>() ?? 0);
        var nodes=Array(presentation["items"]).Where(item=>!StorageGone(Text(item?["node"],"path"))).Select(item=>StorageItem(item!["node"]!)).ToArray();
        foreach(var row in storageRows.Values) row.Children.Clear();
        StorageTree.Clear();
        foreach(var row in nodes) { var slash=row.Path.LastIndexOf('/'); var parent=slash<0 ? "." : row.Path[..slash]; row.Share=totals.TryGetValue(parent,out var parentBytes) && parentBytes>0 ? ((double)row.AllocatedBytes/parentBytes).ToString("P1") : "—"; if(parent==StoragePath) StorageTree.Add(row); else if(storageRows.TryGetValue(parent,out var ancestor)) ancestor.Children.Add(row); }
        foreach(var row in StorageNodes.Where(row=>!StorageTree.Contains(row))) StorageTree.Add(row);
        foreach(var row in nodes.Where(row=>row.Kind=="directory" && row.Children.Count==0)) row.Children.Add(new StorageRow(row.Path+"/","…","loading"));
        StorageExtensions.Clear();
        if(StorageMap?["tiles"] is JsonArray originalTiles && storageRemovedPaths.Count > 0) {
            var updated=StorageMap.DeepClone();
            updated["tiles"]=new JsonArray(originalTiles.Where(tile=>!StorageGone(Text(tile,"path"))).Select(tile=>tile!.DeepClone()).ToArray());
            StorageMap=updated;
        }
        var scopeBytes=presentation["scope"]?["node"]?["allocated_bytes"]?.GetValue<long>() ?? 0;
        if(storageRemovedPaths.Count == 0) foreach(var item in Array(presentation["extensions"]?["items"])) {
            var suffix=Text(item,"suffix"); var allocated=item?["allocated_bytes"]?.GetValue<long>() ?? 0;
            StorageExtensions.Add(new(suffix,Bytes(allocated),item?["file_count"]?.GetValue<int>() ?? 0,StorageMap?["colors"]?[suffix]?.GetValue<string>() ?? "#76877E",scopeBytes>0 ? ((double)allocated/scopeBytes).ToString("P1") : "—",Bytes(item?["logical_bytes"]?.GetValue<long>() ?? 0)));
        }
    }

    private Task StorageUpAsync() => RunAsync(async () =>
    {
        var slash = StoragePath.LastIndexOf('/'); var parent = slash < 0 ? "." : StoragePath[..slash];
        ShowDirectory(await client.RequestAsync("storage.directory", new() { ["scan_id"] = storageScanId, ["path"] = parent }, cancellation: Token)); StorageMap=null; if(StorageDetailed) await LoadStorageMapAsync();
    });
    private void ShowDirectory(JsonNode directory)
    {
        StoragePath = Text(directory, "path"); StorageNodes.Clear();
        foreach (var item in Array(directory["children"]).Where(item=>!StorageGone(Text(item,"path")))) StorageNodes.Add(StorageItem(item!));
        var actionable = storageCoverage.Any(note => note?["system_managed"]?.GetValue<bool>() != true &&
            (StoragePath == "." || Text(note, "path") is "" or "." || Text(note, "path") == StoragePath ||
             Text(note, "path").StartsWith(StoragePath + "/", StringComparison.Ordinal) || StoragePath.StartsWith(Text(note, "path") + "/", StringComparison.Ordinal)));
        Status = directory["complete"]?.GetValue<bool>() == true ? "当前文件夹分析完成。双击目录继续查看。" : actionable ?
            "当前文件夹部分位置需处理：打开文件夹检查访问权限，处理后重新扫描当前文件夹。其余已完成的目录可继续查看。" :
            "系统管理的位置不计入分析范围，无需更改权限。双击目录继续查看。";
    }
    private static JsonNode?[] Array(JsonNode? value) => value is JsonArray array ? array.ToArray() : [];
    private static string Text(JsonNode? node, string field) => node?[field]?.GetValue<string>() ?? "";
    private static JsonArray Strings(IEnumerable<string> values) => new(values.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());
    public static string Bytes(long value)
    {
        string[] units = ["B", "KiB", "MiB", "GiB", "TiB"];
        var number = (double)value; var index = 0; while (number >= 1024 && index < units.Length - 1) { number /= 1024; index++; }
        return $"{number:0.#} {units[index]}";
    }
}
