using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record WorkspaceRow(string Id, string Path, string RootRef);
public sealed record RuleRow(string Id, string Version, string Title, string Location = "projects", string? WorkspaceId = null, string Details = "", bool IsBuiltin = false, bool Available = true)
{
    public bool CanToggle => WorkspaceId is not null || (IsBuiltin && Location != "projects" && Available);
}
public sealed record RulePreviewRow(string Path, string Size, string Decision);
public sealed record HistoryRow(string Id, string CreatedAt, string RootPath, string State, HistoryItemRow[] Items)
{
    public string Label => ProgressPresentation.ShortPath(RootPath);
}
public sealed class StorageRow(string path, string size, string kind, long allocatedBytes=0, long logicalBytes=0, int files=0) : ObservableObject
{
    public string Path { get; } = path;
    public string Name => Kind switch { "loading" => T("正在加载…"), "more" => T("加载更多…"), _ => Path.Split('/').Last() };
    public string Size { get; } = size;
    public string Kind { get; } = kind;
    public long AllocatedBytes { get; } = allocatedBytes;
    public long LogicalBytes { get; } = logicalBytes;
    public string LogicalSize => MainViewModel.Bytes(LogicalBytes);
    public int Files { get; } = files;
    public string Icon => Kind == "directory" ? "📁" : "▤";
    private string share="—";
    public string Share { get=>share; set=>SetProperty(ref share,value); }
    private bool policyVerified, selectionEnabled = true;
    private string? removalReason;
    public bool Eligible => policyVerified && removalReason is null && Kind is ("file" or "directory");
    public string Protection => RemovalReason switch {
        null => T("可加入选择；删除前会重新核验当前内容、排除和权限。"),
        "Item is absent from this analysis." => T("此项目不在当前分析中，请重新扫描。"),
        "This item is not owned by the current user." => T("此项目不属于当前用户。"),
        "Links, special files and the scan root cannot be removed here." => T("链接、特殊文件及扫描根目录不可在此删除。"),
        "This system location is protected." => T("此系统位置受到保护。"),
        "This location contains protected data." => T("此位置包含受保护的数据。"),
        "Cleanup exclusions could not be verified." => T("无法核验清理排除，请重新读取配置。"),
        "This selection contains excluded content." => T("此范围包含已排除的内容。"),
        var message => T(message ?? "")
    };
    public string? RemovalReason => policyVerified ? removalReason : T("请进入所在目录核验保护状态。");
    public bool CanSelect => Eligible && selectionEnabled;
    public void SetPolicy(string? reason) { policyVerified = true; removalReason = reason; OnPropertyChanged(nameof(RemovalReason)); OnPropertyChanged(nameof(Protection)); OnPropertyChanged(nameof(Eligible)); OnPropertyChanged(nameof(CanSelect)); }
    public void SetSelectionEnabled(bool enabled) { selectionEnabled = enabled; OnPropertyChanged(nameof(CanSelect)); }
    private bool focused, expanded;
    public bool Focused { get=>focused; set=>SetProperty(ref focused,value); }
    public bool Expanded { get=>expanded; set=>SetProperty(ref expanded,value); }
    private bool? selectionState = false;
    public bool? SelectionState => selectionState;
    public void SetSelection(bool? value) { selectionState = value; OnPropertyChanged(nameof(SelectionState)); }
    public ObservableCollection<StorageRow> Children { get; } = [];
}
public sealed record StorageExtensionRow(string Suffix, long AllocatedBytes, int Files, string Color, double ShareRatio, long LogicalBytes)
{
    public string Name => Suffix.Length == 0 ? T("无扩展名") : "." + Suffix;
    public string Size => MainViewModel.Bytes(AllocatedBytes);
    public string LogicalSize => MainViewModel.Bytes(LogicalBytes);
    public string Share => ShareRatio >= 0 ? ShareRatio.ToString("P1") : "—";
}

public sealed record CleanupItemResultRow(string Path, string State, string? Error);
public sealed record CleanupCompletionRow(string Icon, string Title, string SuccessText, string Message, string Processed, string Skipped, string Failed, string NeedsVerification, bool HasIssues, CleanupItemResultRow[] Items);
public sealed class CandidateRow(string id, string path, long bytes, bool eligible, string description, string scan, string workspace, string root,
    bool incomplete, string category, string group, bool recommended, int files) : ObservableObject
{
    public string Id { get; } = id;
    public string ScanId { get; } = scan;
    public string WorkspaceId { get; } = workspace;
    public string AbsolutePath { get; } = root.TrimEnd('/', '\\') + "/" + path;
    public string Path { get; } = path;
    public CleanupChoice Choice { get; } = new(scan + ":" + id, scan, id, workspace, root.TrimEnd('/', '\\') + "/" + path, category, group, bytes);
    public bool Recommended { get; } = recommended;
    public int Files { get; } = files;
    public long AllocatedBytes => Choice.Bytes;
    public string Size { get; } = MainViewModel.Bytes(bytes);
    public bool Eligible { get; } = eligible;
    public string Description { get; } = description;
    public bool CanContinue { get; } = incomplete;
    private bool selected;
    public bool IsSelected { get => selected; set => SetProperty(ref selected, value && Eligible); }
}

public sealed partial class MainViewModel : ObservableObject
{
    private readonly BridgeProcessClient client;
    private readonly WindowsDialogs dialogs;
    private readonly List<IRelayCommand> commands;
    private CancellationTokenSource? active;
    private TaskCompletionSource? idle;
    private JsonObject? configuration;
    private JsonNode? rulePreview;
    private string rulePreviewSummary="", rulePreviewDetails="";
    private string? storageScanId;
    private bool standardScan = true;
    private readonly List<(string Workspace, string Path)> retryTargets = new();
    private readonly Dictionary<string,StorageRow> storageRows = new();
    private readonly List<string> storageRemovedPaths = new();
    private JsonNode? storageMap;
    private bool storageDetailed;
    private readonly bool persistUserPreferences;
    private StorageExtensionRow? selectedStorageExtension;
    private static string StoragePreference => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "space-view.txt");
    private string? storageRoot;
    private JsonNode?[] storageCoverage = [];
    private bool busy, trashAvailable, permanentAvailable;
    private string status = T("正在连接清理核心…"), exclusionPattern = "", storagePath = ".";
    private WorkspaceRow? selectedWorkspace;
    private bool updatingWorkspaces;
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

    public MainViewModel(BridgeProcessClient client, WindowsDialogs dialogs, DesktopPreferenceStore? preferenceStore = null, DesktopPreferences? preferences = null, string? preferenceIssue = null, bool persistUserPreferences = true)
    {
        this.client = client; this.dialogs = dialogs;
        this.persistUserPreferences = persistUserPreferences;
        ChooseFolderCommand = new AsyncRelayCommand(ChooseFolderAsync, () => !IsBusy);
        ScanCommand = new AsyncRelayCommand(() => { standardScan = true; return ScanAsync(); }, () => !IsBusy);
        ScanFolderCommand = new AsyncRelayCommand(() => { standardScan = false; return ScanAsync(); }, () => !IsBusy && SelectedWorkspace is not null);
        SelectAllCommand = new AsyncRelayCommand(() => SelectCleanupRangeAsync(false), () => !IsBusy && cleanupScanIds.Count > 0);
        MoreCommand = new AsyncRelayCommand(() => RunAsync(() => LoadCleanupReviewAsync(false)), () => !IsBusy && cleanupNextOffset is not null);
        ContinueScanCommand = new AsyncRelayCommand<CandidateRow>(row => ContinueScanAsync(row!), row => !IsBusy && row?.CanContinue == true);
        CleanCommand = new AsyncRelayCommand(() => CleanAsync("trash"), () => !IsBusy && trashAvailable && cleanupSelection.Count > 0);
        PermanentDeleteCommand = new AsyncRelayCommand(() => CleanAsync("permanent"), () => !IsBusy && permanentAvailable && cleanupSelection.Count > 0);
        AnalyzeCommand = new AsyncRelayCommand(AnalyzeAsync, () => !IsBusy);
        StorageUpCommand = new AsyncRelayCommand(StorageUpAsync, () => !IsBusy && storageScanId is not null && StoragePath != ".");
        RescanStorageCommand = new AsyncRelayCommand(() => RunAsync(() => ScanStorageAsync(CurrentStorageFolder!)), () => !IsBusy && CurrentStorageFolder is not null);
        RevealStorageCommand = new RelayCommand(() => dialogs.RevealFolder(CurrentStorageFolder!), () => !IsBusy && CurrentStorageFolder is not null);
        try { storageDetailed = persistUserPreferences && File.Exists(StoragePreference) && File.ReadAllText(StoragePreference) == "detailed"; } catch (Exception error) when(error is IOException or UnauthorizedAccessException) { }
        CopyStorageAnalysisCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            var context=await client.RequestAsync("storage.context", new() { ["scan_id"]=storageScanId,["path"]=StoragePath,["focused_path"]=SelectedStorageNode?.Path,["selected_paths"]=Strings(storageSelection),["removed_paths"]=Strings(storageRemovedPaths),["name_filter"]=storageAppliedQuery,["extension_filter"]=StorageExtensionFilter,["locale"]=UiText.Language }, cancellation:Token);
            System.Windows.Clipboard.SetText(Text(context,"text")); Status=T("已复制分析结果，可粘贴给 AI Agent。");
        }), () => !IsBusy && storageScanId is not null);
        RemoveStorageCommand = new AsyncRelayCommand(() => RemoveStorageAsync("permanent"), () => !IsBusy && permanentAvailable && storageScanId is not null && storageSelection.Count > 0);
        TrashStorageCommand = new AsyncRelayCommand(() => RemoveStorageAsync("trash"), () => !IsBusy && trashAvailable && storageScanId is not null && storageSelection.Count > 0);
        HistoryCommand = new AsyncRelayCommand(() => RunAsync(LoadHistoryAsync), () => !IsBusy);
        MoreHistoryCommand = new AsyncRelayCommand(() => RunAsync(() => LoadHistoryPageAsync(true)), () => !IsBusy && historyNextOffset is not null);
        CollectRecordsCommand = new AsyncRelayCommand(CollectRecordsAsync, () => !IsBusy);
        ClearHistoryCommand = new AsyncRelayCommand(() => ClearHistoryAsync(false), () => !IsBusy && History.Count > 0);
        RemoveHistoryCommand = new AsyncRelayCommand(() => ClearHistoryAsync(true), () => !IsBusy && SelectedHistory is not null);
        RestoreCommand = new AsyncRelayCommand(() => FollowUpAsync("restore"), () => !IsBusy && trashAvailable && CanFollowUpHistory("restore"));
        PurgeCommand = new AsyncRelayCommand(() => FollowUpAsync("purge"), () => !IsBusy && permanentAvailable && CanFollowUpHistory("purge"));
        DismissCompletionCommand = new RelayCommand(() => Completion = null, () => Completion is not null);
        ViewHistoryFromCompletionCommand = new RelayCommand(() => { Completion = null; SelectedSection = 3; _ = LoadHistoryAsync(); }, () => Completion is not null && !IsBusy);
        RetryCleanupCommand = new AsyncRelayCommand(RetryCleanupAsync, () => !IsBusy && CompletionHasIssues);
        ImportRuleCommand = new AsyncRelayCommand(ImportRuleAsync, () => !IsBusy);
        PreviewRuleCommand = new AsyncRelayCommand(PreviewRuleAsync, () => !IsBusy && SelectedRule is { IsBuiltin: false, WorkspaceId: not null });
        EnableAndScanRuleCommand = new AsyncRelayCommand(EnableAndScanRuleAsync, () => !IsBusy && rulePreview is not null);
        ReviewRulesCommand = new AsyncRelayCommand(() => RunAsync(async () => { await LoadConfigurationAsync(); SelectedSection=2; }), () => !IsBusy);
        EnableRuleCommand = new AsyncRelayCommand(() => SetRuleAsync(true), () => !IsBusy && SelectedRule?.CanToggle == true);
        DisableRuleCommand = new AsyncRelayCommand(() => SetRuleAsync(false), () => !IsBusy && SelectedRule?.CanToggle == true);
        AddExclusionCommand = new AsyncRelayCommand(() => SetScopedExclusionAsync(false), () => CanEditRuleSettings && (ExclusionScope==0 || SelectedWorkspace is not null) && (ProjectExclusionScope ? !string.IsNullOrWhiteSpace(ExclusionProject) : !string.IsNullOrWhiteSpace(ExclusionPattern)));
        RemoveExclusionCommand = new AsyncRelayCommand(() => SetScopedExclusionAsync(true), () => CanEditRuleSettings && SelectedExclusion is not null && (ExclusionScope==0 || SelectedWorkspace is not null));
        CancelCommand = new RelayCommand(() => { active?.Cancel(); Status = T("正在停止；请等待当前项目写回回执。"); }, () => IsBusy);
        commands = [ChooseFolderCommand, ScanCommand, MoreCommand, CleanCommand, PermanentDeleteCommand, AnalyzeCommand, StorageUpCommand, HistoryCommand, RestoreCommand, PurgeCommand, ImportRuleCommand, EnableRuleCommand, DisableRuleCommand, AddExclusionCommand, RemoveExclusionCommand, CancelCommand, DismissCompletionCommand, ViewHistoryFromCompletionCommand, RetryCleanupCommand];
        commands.Add(ScanFolderCommand); commands.Add(SelectAllCommand);
        commands.Add(ContinueScanCommand);
        commands.Add(ClearHistoryCommand); commands.Add(RemoveHistoryCommand);
        commands.Add(MoreHistoryCommand); commands.Add(CollectRecordsCommand);
        commands.Add(CopyStorageAnalysisCommand); commands.Add(RemoveStorageCommand); commands.Add(TrashStorageCommand); commands.Add(RescanStorageCommand); commands.Add(RevealStorageCommand);
        InitializeHistory();
        InitializeLocations();
        InitializeLargeFiles();
        InitializeAI();
        InitializeCleanupReview();
        InitializeCleanupClosing();
        InitializeTools();
        InitializeStartup();
        InitializeRuleAuthoring();
        InitializeApplications();
        InitializeStorageNavigation();
        InitializePrivacy();
        InitializeSettings(preferenceStore ?? new DesktopPreferenceStore(DesktopPreferenceStore.DefaultPath), preferences ?? new DesktopPreferences(), preferenceIssue);
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
        set { if(SetProperty(ref storageDetailed,value)) { OnPropertyChanged(nameof(StorageSimple)); OnPropertyChanged(nameof(StorageListSummary)); try { if (persistUserPreferences) { Directory.CreateDirectory(Path.GetDirectoryName(StoragePreference)!); File.WriteAllText(StoragePreference,value ? "detailed" : "simple"); } } catch(Exception error) when(error is IOException or UnauthorizedAccessException) { } if(value && storageScanId is not null && StorageMap is null && !IsBusy) _ = RunAsync(LoadStorageMapAsync); } }
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
    public IAsyncRelayCommand SelectAllCommand { get; }
    public IAsyncRelayCommand MoreCommand { get; }
    public IAsyncRelayCommand<CandidateRow> ContinueScanCommand { get; }
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
    public bool IsBusy { get => busy; private set { if (SetProperty(ref busy, value)) { OnPropertyChanged(nameof(HistorySelectionEnabled)); OnPropertyChanged(nameof(PrivacyCanEdit)); UpdateStorageSelectionEnabled(); } } }
    public bool ProgressIndeterminate => IsBusy && ProgressFraction is null && DesktopPresentation.Current.AnimateIndicators;
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
    public string StoragePath { get => storagePath; private set { SetProperty(ref storagePath, value); OnPropertyChanged(nameof(StorageDisplayPath)); OnPropertyChanged(nameof(StorageCapacityPath)); } }
    public string StorageDisplayPath => CurrentStorageFolder ?? "";
    public string ExclusionPattern { get => exclusionPattern; set => SetProperty(ref exclusionPattern, value); }
    public string? SelectedExclusion { get => selectedExclusion; set => SetProperty(ref selectedExclusion, value); }
    public WorkspaceRow? SelectedWorkspace
    {
        get => selectedWorkspace;
        set { if (!updatingWorkspaces && SetProperty(ref selectedWorkspace, value)) { ResetCleanupReview(); LoadRules();ExclusionProject="";ExclusionPattern="";LoadExclusionScope(); OnPropertyChanged(nameof(CleanupCapacityPath)); RefreshCommands(); } }
    }
    public RuleRow? SelectedRule { get => selectedRule; set { if(SetProperty(ref selectedRule, value)) { rulePreview=null; RulePreviewRows.Clear(); RulePreviewSummary=value?.Title ?? ""; RulePreviewDetails=value?.Details ?? ""; RefreshCommands(); } } }
    public HistoryRow? SelectedHistory
    {
        get => selectedHistory;
        set { if (SetProperty(ref selectedHistory, value)) ResetHistoryItems(value); }
    }
    public StorageRow? SelectedStorageNode { get => selectedStorageNode; set { if(SetProperty(ref selectedStorageNode, value)) OnPropertyChanged(nameof(StorageFocusPath)); } }
    private CancellationToken Token => active?.Token ?? CancellationToken.None;
    private void RefreshCommands() { foreach (var command in commands) command.NotifyCanExecuteChanged(); }
    public Task WhenIdleAsync() => idle?.Task ?? Task.CompletedTask;
    public Task InitializeAsync() => RunAsync(async () =>
    {
        var capabilities = await client.RequestAsync("capabilities", cancellation: Token);
        if (capabilities["platform"]?.GetValue<string>() != "windows" || capabilities["bridge_version"]?.GetValue<int>() != 1)
            throw new BridgeException("incompatible_engine", T("请选择与 Windows 客户端匹配的 Shou 清理核心。"));
        trashAvailable = capabilities["features"]?["trash"]?.GetValue<bool>() == true;
        permanentAvailable = capabilities["features"]?["permanent"]?.GetValue<bool>() == true;
        startupAvailable = capabilities["features"]?["startup"]?.GetValue<bool>() == true;
        ruleAuthoringAvailable = capabilities["features"]?["rule_authoring"]?.GetValue<bool>() == true;
        applicationInventoryAvailable = capabilities["features"]?["application_inventory"]?.GetValue<bool>() == true;
        applicationUninstallAvailable = capabilities["features"]?["application_uninstall"]?.GetValue<bool>() == true;
        applicationDataAvailable = capabilities["features"]?["application_data"]?.GetValue<bool>() == true;
        packageDataAvailable = capabilities["features"]?["application_package_data"]?.GetValue<bool>() == true;
        privacyAvailable = capabilities["features"]?["privacy"]?.GetValue<bool>() == true;
        cleanupClosingAvailable = capabilities["features"]?["close_cleanup_owners"]?.GetValue<bool>() == true;
        toolsAvailable = capabilities["features"]?["tool_cleanup"]?.GetValue<bool>() == true;
        SettingsVersion = "Shou " + Text(capabilities, "application_version");
        await LoadConfigurationAsync(); await LoadHistoryAsync(); await LoadAIAsync(capabilities);
        if (privacyAvailable) await LoadPrivacyHistoryAsync();
        Status = T("一键扫描常用缓存和开发项目，也可以选择自定义目录。");
    });
    private async Task RunAsync(Func<Task> action, bool cleanup = false)
    {
        if (IsBusy) return;
        using var cancellation = new CancellationTokenSource(); active = cancellation;
        idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        ProgressFraction = null; ProgressPath = ""; ProgressFullPath = ""; ProgressVisible = false; IsBusy = true;
        OnPropertyChanged(nameof(ProgressIndeterminate));
        try { await action(); }
        catch (BridgeException error) { ReportFailure(error.Code + T("：") + error.Message, cleanup); }
        catch (Exception error) { ReportFailure(T("操作未完成：") + error.Message, cleanup); }
        finally { active = null; ProgressVisible = false; IsBusy = false; OnPropertyChanged(nameof(ProgressIndeterminate)); idle.TrySetResult(); }
    }
    private void ReportFailure(string message, bool cleanup)
    {
        Status = message;
        if (cleanup) Completion = new("!", T("清理未能完成"), "", message, "0", "0", "0", "0", true, []);
    }
    private IProgress<JsonObject> Progress() => new Progress<JsonObject>(value =>
    {
        if (!IsBusy) return;
        var stage = Text(value, "stage");
        var title = stage switch { "privacy-scanning" => T("正在统计隐私来源"), "privacy-cleaning" => T("正在清理隐私记录"), "scanning" => T("正在扫描"), "analysis" => T("正在整理结果"), "saving" => T("正在保存结果"), "loading" or "transferring" or "validating" => T("正在读取结果"), "moving" => T("正在移入回收站"), "purging" => T("正在永久清理"), "restoring" => T("正在恢复"), "finalizing" => T("正在完成清理"), _ => T("正在核验所选项目") };
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
        Status = F("{0} · 已处理 {1} 项",title,value["entry_count"] ?? value["processed_count"]);
    });
    private async Task LoadConfigurationAsync()
    {
        var selected = SelectedWorkspace?.Id;
        var result = await client.RequestAsync("configuration", cancellation: Token);
        if(configuration?["configuration"]?["revision"]?.GetValue<string>() == result["configuration"]?["revision"]?.GetValue<string>()) return;
        configuration = result as JsonObject;
        SettingsDataDirectory = Text(result, "data_directory");
        // ComboBox clears its selection while the source collection reloads.
        // Keep that transient state from erasing the current exclusion scope.
        updatingWorkspaces=true;
        try {
            Workspaces.Clear();
            foreach (var item in Array(result["configuration"]?["workspaces"])) Workspaces.Add(new(Text(item, "id"), Text(item, "path"), Text(item, "root_ref")));
        } finally { updatingWorkspaces=false; }
        SelectedWorkspace = Workspaces.FirstOrDefault(item => item.Id == selected) ?? Workspaces.FirstOrDefault();
        OnPropertyChanged(nameof(SelectedWorkspace));
        LoadRules();LoadRuleSettings();
    }
    public Task RefreshExternalChangesAsync() => RunAsync(async () => {
        var revision=configuration?["configuration"]?["revision"]?.GetValue<string>();
        await LoadConfigurationAsync();
        if(revision is not null && revision != configuration?["configuration"]?["revision"]?.GetValue<string>()) {
            ResetCleanupReview();
            if (SelectedSection == 8) await LoadScanLocationsAsync();
            Status=T("外部规则或配置已更新。到“规则与排除”逐条预览，再启用并扫描所选规则。");
        }
    });
    private Task PreviewRuleAsync() => RunAsync(async () => {
        rulePreview=null; RulePreviewRows.Clear(); RulePreviewSummary=""; RulePreviewDetails="";
        var result=await client.RequestAsync("rules.preview",new() { ["workspace_id"]=SelectedRule!.WorkspaceId,["rule_id"]=SelectedRule.Id,["version"]=SelectedRule.Version },Progress(),cancellation:Token);
        rulePreview=result;
        RulePreviewSummary=F("{0} · 新增可清理估计 {1}",SelectedRule.Title,Bytes(result["benefits"]?["additional_allocated_bytes_estimate"]?.GetValue<long>() ?? 0));
        RulePreviewDetails=Text(result["rule"],"description")+"\n"+Text(result["rule"]?["risk"],"rebuild_note")+"\n"+string.Join(T("；"),Array(result["rule"]?["risk"]?["limitations"]).Select(value=>value?.GetValue<string>()))+T("\n保留条件：")+string.Join(T("、"),Array(result["rule"]?["exclude"]?["relative_patterns"]).Select(value=>value?.GetValue<string>()));
        foreach(var row in Array(result["rows"]).Take(200)) RulePreviewRows.Add(new(Text(row,"path"),Bytes(row?["allocated_bytes"]?.GetValue<long>() ?? 0),Text(row,"status")=="matched" ? T("条件匹配，待确认") : string.Join(T("、"),Array(row?["reasons"]).Select(value=>value?.GetValue<string>()))));
        Status=Text(result,"status")=="complete" ? T("预览完成；仅启用所选规则，其他规则保持原选择。") : T("预览部分完成；不可读取的位置不计为完整覆盖。");
    });
    private Task EnableAndScanRuleAsync() => RunAsync(async () => {
        var preview=rulePreview ?? throw new InvalidOperationException(T("请先预览所选规则。"));
        var current=await client.RequestAsync("configuration",cancellation:Token);
        if(Text(current["configuration"],"revision") != Text(preview,"configuration_revision")) throw new InvalidOperationException(T("配置已更新，请重新预览此规则。"));
        var id=Text(preview["rule"],"id");
        var version=Text(preview["rule"],"version");
        var workspace=SelectedRule!.WorkspaceId;
        await client.RequestAsync("rules.set",new() { ["workspace_id"]=workspace,["rule_id"]=id,["version"]=version,["enabled"]=true },cancellation:Token);
        ResetCleanupReview();
        var result=await client.RequestAsync("scan",new() { ["workspace_id"]=workspace,["rule_ids"]=Strings([id]) },Progress(),cancellation:Token);
        await LoadConfigurationAsync(); SelectedSection=0;
        RememberCleanupScan(result);
        await LoadCleanupReviewAsync(true);
        await SetCleanupChoicesAsync(await FetchCleanupSourcesAsync(), true);
        Status=T("仅所选规则已启用并重新扫描。可调整文件选择，再确认永久删除或移入回收站。");
    });
    private void LoadRules()
    {
        Rules.Clear(); SelectedRule = null;
        if (configuration is null) return;
        var bindings = Array(configuration["configuration"]?["bindings"]);
        var locations = Array(configuration["locations"]);
        foreach (var item in Array(configuration["templates"]).Concat(Array(configuration["configuration"]?["rules"]).Select(item => item?["rule"])))
        {
            if (item is null) continue;
            if (item["platforms"] is JsonArray platforms && !platforms.Any(value => value?.GetValue<string>() == "windows")) continue;
            var id = Text(item, "id"); var version = item["version"]?.GetValue<string>() ?? "1.0.0";
            var builtin = id.StartsWith("shou.builtin.", StringComparison.Ordinal);
            if(RuleSource==1 && !builtin || RuleSource==2 && builtin)continue;
            var location = Text(item, "location");
            var knownLocation = locations.FirstOrDefault(value => Text(value,"id") == location);
            WorkspaceRow? workspace;
            if(builtin && location != "projects") workspace=Workspaces.FirstOrDefault(value => SamePath(value.Path,Text(knownLocation,"path")));
            else if(builtin) workspace=SelectedWorkspace is { } selected && !locations.Any(value=>SamePath(selected.Path,Text(value,"path"))) ? selected : null;
            else workspace=Workspaces.FirstOrDefault(value => value.RootRef==Text(item["scope"],"root_ref"));
            var binding = bindings.FirstOrDefault(value => Text(value, "rule_id") == id && Text(value, "workspace_id") == workspace?.Id && (builtin || Text(value, "version") == version));
            var enabled = binding?["enabled"]?.GetValue<bool>() ?? builtin;
            var available = location == "projects" || !builtin || knownLocation?["exists"]?.GetValue<bool>() == true;
            var scopeLabel = builtin ? location == "projects" ? workspace is null ? T("选择项目目录后配置") : T("项目内置") : T("缓存内置") : T("个人规则");
            var state = !available ? T("位置不存在或不可访问") : enabled ? T("已启用") : T("已停用 / 草稿");
            var patterns = string.Join("\n",Array(item["patterns"] ?? item["match"]?["relative_patterns"]).Select(value=>value?.GetValue<string>()));
            var details = (builtin ? T(Text(item,"rebuild_note")) : Text(item,"description"))+"\n"+(builtin ? T(Text(item,"limitation")) : T("个人规则默认停用；预览并审阅后启用。\n工作区：")+(workspace?.Path ?? Text(item["scope"],"root_ref")))+T("\n\n匹配目录：\n")+patterns;
            Rules.Add(new(id, version, $"{(builtin ? T(Text(item, "name")) : Text(item, "name"))} · {scopeLabel} · {state}", location, workspace?.Id, details, builtin, available));
        }
    }
    private static bool SamePath(string first,string second) => first.Replace('\\','/').TrimEnd('/').Equals(second.Replace('\\','/').TrimEnd('/'),StringComparison.OrdinalIgnoreCase);
    private async Task ChooseFolderAsync()
    {
        var folder = dialogs.ChooseFolder(); if (folder is null) return;
        await RunAsync(async () =>
        {
            var existing = Workspaces.FirstOrDefault(item => item.Path.Replace('/', '\\').Equals(folder, StringComparison.OrdinalIgnoreCase));
            if (existing is not null) { SelectedWorkspace = existing; return; }
            var result = await client.RequestAsync("workspace.add", new() { ["path"] = folder, ["root_ref"] = "project-" + Guid.NewGuid().ToString("N") }, cancellation: Token);
            await LoadConfigurationAsync(); SelectedWorkspace = Workspaces.FirstOrDefault(item => item.Id == Text(result, "id"));
            if (SelectedSection == 8) await LoadScanLocationsAsync();
            Status = T("已选择目录，可以开始扫描。");
        });
    }
    private Task ScanAsync() => RunAsync(async () =>
    {
        ResetCleanupReview();
        if (standardScan)
        {
            var batch = await client.RequestAsync("system.scan", progress: Progress(), cancellation: Token);
            await LoadConfigurationAsync();
            foreach (var page in Array(batch["scans"]))
            {
                if (page is null) continue;
                RememberCleanupScan(page);
            }
            if (cleanupScanIds.Count > 0) await LoadCleanupReviewAsync(true);
            Status = F("标准扫描{0}，已发现 {1} 个清理项目。",(Text(batch, "status") == "complete" ? T("完成") : T("部分完成")),Candidates.Count);
            if (Array(batch["issues"]).Length > 0) Status += T(" 部分目录未完成；已验证的项目可继续清理。");
            return;
        }
        var result = await client.RequestAsync("scan", new() { ["workspace_id"] = SelectedWorkspace!.Id }, Progress(), cancellation: Token);
        RememberCleanupScan(result);
        await LoadCleanupReviewAsync(true);
    });
    private Task ContinueScanAsync(CandidateRow row) => RunAsync(async () =>
    {
        var result=await client.RequestAsync("scan.target",new() { ["scan_id"]=row.ScanId,["candidate_id"]=row.Id },Progress(),cancellation:Token);
        var updated=Array(result["candidates"]).SingleOrDefault(item=>Text(item,"relative_path")==row.Path)
            ?? throw new BridgeException("invalid_protocol",T("补扫结果缺少所选目录；请重新扫描。"));
        RememberCleanupScan(result);
        var previous=cleanupRefinements.OfType<JsonObject>().FirstOrDefault(value=>Text(value,"scan_id")==row.ScanId);
        if (previous is not null) {
            previous["scan_id"]=Text(result,"scan_id"); cleanupScanIds.Remove(row.ScanId);
        } else cleanupRefinements.Add(new JsonObject { ["original_scan_id"]=row.ScanId,["candidate_id"]=row.Id,["scan_id"]=Text(result,"scan_id") });
        cleanupSelection.RemoveWhere(choice => choice.AbsolutePath.Equals(row.AbsolutePath,StringComparison.OrdinalIgnoreCase) || choice.AbsolutePath.StartsWith(row.AbsolutePath+"/",StringComparison.OrdinalIgnoreCase));
        await LoadCleanupReviewAsync(true, rebuildGroups:true);
        Status=Array(updated["reasons"]).Any(value=>value?.GetValue<string>()=="incomplete_scan") ? T("此目录仍未完整测量，可再次继续扫描。") : updated["eligible"]?.GetValue<bool>()==true ? T("所选目录测量完成，可以勾选后清理。") : T("所选目录测量完成，请查看保护条件。");
        RefreshCommands();
    });
    private Task CleanAsync(string action) => RunAsync(async () =>
    {
        var chosen = cleanupSelection.Items.ToArray();
        var selected = chosen.GroupBy(item => item.ScanId);
        var selections = new JsonArray(selected.Select(group => (JsonNode?)new JsonObject { ["scan_id"] = group.Key, ["candidate_ids"] = Strings(group.Select(item => item.CandidateId)) }).ToArray());
        var receipt = await client.RequestAsync("system.clean", new() { ["selections"] = selections, ["action"] = action }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        var successful = Array(receipt["items"]).Where(item => Text(item, "state") is "purged" or "trashed").Select(item => Text(item, "path").Replace('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
        retryTargets.Clear();
        retryTargets.AddRange(chosen.Where(item => !successful.Contains(item.AbsolutePath.Replace('\\', '/'))).Select(item => (item.WorkspaceId, item.AbsolutePath)));
        ResetCleanupReview();
        Completion = BuildCompletion(receipt, action);
        Status = T("清理结果：") + Text(receipt, "state") + (action == "permanent" ? T("。永久删除无法恢复，可在历史中查看逐项结果。") : T("。可在历史中查看或恢复。移入回收站不会立即释放磁盘空间。"));
        if (!Token.IsCancellationRequested) await LoadHistoryAsync();
    }, cleanup: true);
    private async Task LoadHistoryAsync()
    {
        await LoadHistoryPageAsync(false);
    }
    private async Task LoadHistoryPageAsync(bool append)
    {
        var selectedId = SelectedHistory?.Id;
        var result = await client.RequestAsync("history.page", new() { ["offset"] = append ? historyNextOffset ?? 0 : 0 }, cancellation: Token);
        if (!append) { SelectedHistory = null; History.Clear(); }
        historyNextOffset = result["next_offset"]?.GetValue<int>();
        foreach (var item in Array(result["receipts"]).Where(item => !History.Any(existing => existing.Id == Text(item, "id")))) History.Add(new(Text(item, "id"), Text(item, "created_at"), Text(item, "root_path"), Text(item, "state"),
            Array(item?["items"]).Select(value => new HistoryItemRow(Text(value, "id"), Text(value, "path"), Text(value, "state"), value?["bytes"]?.GetValue<long>() ?? 0,
                value?["can_restore"]?.GetValue<bool>() == true, value?["can_purge"]?.GetValue<bool>() == true,
                value?["error"]?.GetValue<string>(), value?["resulting_path"]?.GetValue<string>())).ToArray()));
        SelectedHistory = History.FirstOrDefault(item => item.Id == selectedId) ?? History.FirstOrDefault();
    }
    private Task ClearHistoryAsync(bool selectedOnly) => RunAsync(async () =>
    {
        var input = new JsonObject { ["include_recoverable"] = selectedOnly };
        if (selectedOnly) input["execution_ids"] = Strings([SelectedHistory!.Id]);
        var result = await client.RequestAsync("history.clear", input, confirm: review => dialogs.ConfirmAsync(review, Token), cancellation: Token);
        await LoadHistoryAsync();
        Status = F("已清理 {0} 条操作记录。文件保持原位。",Array(result["execution_ids"]).Length);
    });
    private Task FollowUpAsync(string action) => RunAsync(async () =>
    {
        var receipt = SelectedHistory!;
        var itemIds = HistoryFollowUpSelection.ItemIds(action, SelectedHistoryChoices());
        var result = await client.RequestAsync("history." + action, new() { ["execution_id"] = receipt.Id, ["item_ids"] = Strings(itemIds) }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        Completion = BuildCompletion(result, action);
        Status = (action == "restore" ? T("恢复结果：") : T("永久删除结果：")) + string.Join(T("、"), Array(result).Select(value => Text(value, "state"))) + (action == "restore" ? T("。已有同名目标不会被覆盖。") : T("。已永久删除的项目无法恢复。"));
        if (!Token.IsCancellationRequested) await LoadHistoryAsync();
    }, cleanup: true);
    private async Task ImportRuleAsync()
    {
        var path = dialogs.ChooseRule(); if (path is null) return;
        await RunAsync(async () =>
        {
            if (new FileInfo(path).Length > 262144) throw new BridgeException("resource_limit", T("规则文件超过 256 KiB。"));
            await client.RequestAsync("rules.import", new() { ["json"] = await File.ReadAllTextAsync(path, Token) }, cancellation: Token);
            await LoadConfigurationAsync(); Status = T("规则已作为停用草稿导入；启用后重新扫描。");
        });
    }
    private Task SetRuleAsync(bool enabled) => RunAsync(async () =>
    {
        var rule=SelectedRule ?? throw new InvalidOperationException(T("请选择规则。"));
        if(rule.IsBuiltin && rule.Location != "projects" && rule.WorkspaceId is null)
            await client.RequestAsync("rules.location-set",new() { ["location_id"]=rule.Location,["rule_id"]=rule.Id,["enabled"]=enabled },cancellation:Token);
        else
            await client.RequestAsync("rules.set", new() { ["workspace_id"] = rule.WorkspaceId, ["rule_id"] = rule.Id, ["version"] = rule.Version, ["enabled"] = enabled }, cancellation: Token);
        ResetCleanupReview(); await LoadConfigurationAsync(); Status = T("规则设置已保存，请重新扫描。");
    });
    private Task RetryCleanupAsync()
    {
        Completion = null;
        ResetCleanupReview();
        if (retryTargets.Count == 0) return ScanAsync();
        var affected = retryTargets.ToArray();
        return RunAsync(async () => {
            foreach (var group in affected.GroupBy(item => item.Workspace)) {
                var page = await client.RequestAsync("scan", new() { ["workspace_id"] = group.Key }, Progress(), cancellation: Token);
                RememberCleanupScan(page);
            }
            await LoadCleanupReviewAsync(true);
            var paths = affected.Select(item => item.Path.Replace('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
            await SetCleanupChoicesAsync((await FetchCleanupSourcesAsync()).Where(row => paths.Contains(row.AbsolutePath.Replace('\\', '/'))), true);
            Status = T("已刷新未完成的清理范围；成功项目保持完成，请检查选择后继续。");
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
        var title = !issues ? action switch { "restore" => T("恢复完成"), "purge" => T("永久删除完成"), _ => T("清理完成") } : resultState == "cancelled" ? T("清理已停止") : T("清理已结束，部分项目需处理");
        var message = action switch
        {
            "restore" => issues ? T("部分项目未能恢复，请查看操作记录。") : T("所选项目已恢复。"),
            "purge" or "permanent" => issues ? T("部分项目未能永久删除，请查看操作记录。") : T("已永久删除，无法恢复。"),
            _ => issues ? T("部分项目未能移入回收站，请查看操作记录。") : T("已移入回收站，可在操作记录中恢复。")
        };
        var bytes = source.Where(item => new[] { "trashed", "purged" }.Contains(Text(item, "state")))
            .Sum(item => item?["bytes"]?.GetValue<long>() ?? 0);
        var successText = bytes > 0 && (action is "trash" or "permanent") ? Bytes(bytes) : F("{0} 项",processed);
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
        var browse = await client.RequestAsync("storage.browse", new() { ["scan_id"] = Text(scan, "scan_id"), ["path"] = "." }, cancellation: Token);
        storageScanId = Text(scan, "scan_id"); storageRoot = Text(scan, "root_path");
        storageRows.Clear(); storageRemovedPaths.Clear(); storageChildOffsets.Clear(); storageCoverage = Array(scan["coverage_notes"]);
        storageNavigation.Reset(); ClearStorageSelection(); StorageQuery=""; SelectedStorageExtension=null; StorageMap=null;
        ShowStoragePage(browse, false); if(StorageDetailed) await LoadStorageMapAsync();
    }
    public Task OpenStorageNodeAsync() => SelectedStorageNode is { Kind: "directory" } item ? RunAsync(() => NavigateStorageAsync(item.Path)) : Task.CompletedTask;
    public async Task FocusStorageAsync(string path,bool open) {
        if(storageRows.TryGetValue(path,out var row)) {
            foreach(var other in storageRows.Values) other.Focused=other==row;
            var parent=path;
            while(parent.Contains('/')) { parent=parent[..parent.LastIndexOf('/')]; if(storageRows.TryGetValue(parent,out var ancestor)) ancestor.Expanded=true; }
            SelectedStorageNode=row; if(open) await OpenStorageNodeAsync();
        }
    }
    public Task LoadStorageChildrenAsync(StorageRow row, bool more=false) => row.Kind != "directory" ? Task.CompletedTask : RunAsync(async () => {
        if(more && !storageChildOffsets.ContainsKey(row.Path)) return;
        var offset=more ? storageChildOffsets[row.Path] : 0;
        var browse=await client.RequestAsync("storage.browse",new() { ["scan_id"]=storageScanId,["path"]=row.Path,["offset"]=offset },cancellation:Token);
        var page=browse["directory"]!;
        if(!more) row.Children.Clear();
        else { foreach(var placeholder in row.Children.Where(child=>child.Kind is "loading" or "more").ToArray()) row.Children.Remove(placeholder); }
        foreach(var item in Array(page["children"]).Where(item=>!StorageGone(Text(item?["node"],"path")))) {
            var child=StorageItem(item!["node"]!); child.SetPolicy(browse["removal_reasons"]?[child.Path]?.GetValue<string>()); row.Children.Add(child);
            if(child.Kind=="directory" && child.Children.Count==0) child.Children.Add(new StorageRow(child.Path+"/","…","loading"));
        }
        if(page["next_offset"] is not null) { storageChildOffsets[row.Path]=page["next_offset"]!.GetValue<int>(); row.Children.Add(new StorageRow(row.Path+"/",T("加载更多…"),"more")); }
        else storageChildOffsets.Remove(row.Path);
    });
    private bool StorageGone(string path) => storageRemovedPaths.Any(removed=>path==removed || path.StartsWith(removed+"/",StringComparison.Ordinal));
    private StorageRow StorageItem(JsonNode item) {
        var path=Text(item,"path");
        if(storageRows.TryGetValue(path,out var existing)) return existing;
        var allocated=item["allocated_bytes"]?.GetValue<long>() ?? 0;
        var row=new StorageRow(path,Bytes(allocated),Text(item,"kind"),allocated,item["logical_bytes"]?.GetValue<long>() ?? 0,item["file_count"]?.GetValue<int>() ?? 0);
        row.SetSelectionEnabled(!IsBusy && StorageQueryCurrent); storageRows[path]=row; ApplyStorageSelection(row); return row;
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
        storageTreeRoots.Clear(); storageTreeRoots.AddRange(StorageTree); FilterStorageRows();
        foreach(var row in storageRows.Values.Where(row=>row.Kind=="directory" && row.Children.Count==0 && !StorageGone(row.Path))) row.Children.Add(new StorageRow(row.Path+"/","…","loading"));
        StorageExtensions.Clear();
        if(StorageMap?["tiles"] is JsonArray originalTiles && storageRemovedPaths.Count > 0) {
            var updated=StorageMap.DeepClone();
            updated["tiles"]=new JsonArray(originalTiles.Where(tile=>!StorageGone(Text(tile,"path"))).Select(tile=>tile!.DeepClone()).ToArray());
            StorageMap=updated;
        }
        var scopeBytes=presentation["scope"]?["node"]?["allocated_bytes"]?.GetValue<long>() ?? 0;
        if(storageRemovedPaths.Count == 0) foreach(var item in Array(presentation["extensions"]?["items"])) {
            var suffix=Text(item,"suffix"); var allocated=item?["allocated_bytes"]?.GetValue<long>() ?? 0;
            StorageExtensions.Add(new(suffix,allocated,item?["file_count"]?.GetValue<int>() ?? 0,StorageMap?["colors"]?[suffix]?.GetValue<string>() ?? "#76877E",scopeBytes>0 ? (double)allocated/scopeBytes : -1,item?["logical_bytes"]?.GetValue<long>() ?? 0));
        }
    }

    private Task StorageUpAsync() => RunAsync(() => NavigateStorageAsync(StoragePath.Contains('/') ? StoragePath[..StoragePath.LastIndexOf('/')] : "."));
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
