using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record WorkspaceRow(string Id, string Path, string RootRef);
public sealed record RuleRow(string Id, string Version, string Title);
public sealed record HistoryItemRow(string Path, string State, string? Error, string? ResultingPath);
public sealed record HistoryRow(string Id, string CreatedAt, string RootPath, string State, string[] RestorableIds, string[] PurgeableIds, HistoryItemRow[] Items);
public sealed record StorageRow(string Path, string Size, string Kind);
public sealed record CleanupItemResultRow(string Path, string State, string? Error);
public sealed record CleanupCompletionRow(string Icon, string Title, string SuccessText, string Message, string Processed, string Skipped, string Failed, string NeedsVerification, bool HasIssues, CleanupItemResultRow[] Items);
public sealed class CandidateRow(string id, string path, long bytes, bool eligible, string description) : ObservableObject
{
    public string Id { get; } = id;
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
    private string? scanId, storageScanId;
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

    public MainViewModel(BridgeProcessClient client, WindowsDialogs dialogs)
    {
        this.client = client; this.dialogs = dialogs;
        ChooseFolderCommand = new AsyncRelayCommand(ChooseFolderAsync, () => !IsBusy);
        ScanCommand = new AsyncRelayCommand(ScanAsync, () => !IsBusy && SelectedWorkspace is not null);
        MoreCommand = new AsyncRelayCommand(MoreAsync, () => !IsBusy && nextOffset is not null);
        CleanCommand = new AsyncRelayCommand(() => CleanAsync("trash"), () => !IsBusy && trashAvailable && Candidates.Any(item => item.IsSelected));
        PermanentDeleteCommand = new AsyncRelayCommand(() => CleanAsync("permanent"), () => !IsBusy && permanentAvailable && Candidates.Any(item => item.IsSelected));
        AnalyzeCommand = new AsyncRelayCommand(AnalyzeAsync, () => !IsBusy);
        StorageUpCommand = new AsyncRelayCommand(StorageUpAsync, () => !IsBusy && storageScanId is not null && StoragePath != ".");
        HistoryCommand = new AsyncRelayCommand(() => RunAsync(LoadHistoryAsync), () => !IsBusy);
        RestoreCommand = new AsyncRelayCommand(() => FollowUpAsync("restore"), () => !IsBusy && trashAvailable && SelectedHistory?.RestorableIds.Length > 0);
        PurgeCommand = new AsyncRelayCommand(() => FollowUpAsync("purge"), () => !IsBusy && permanentAvailable && SelectedHistory?.PurgeableIds.Length > 0);
        DismissCompletionCommand = new RelayCommand(() => Completion = null, () => Completion is not null);
        ViewHistoryFromCompletionCommand = new RelayCommand(() => { Completion = null; SelectedSection = 3; _ = LoadHistoryAsync(); }, () => Completion is not null && !IsBusy);
        RetryCleanupCommand = new AsyncRelayCommand(RetryCleanupAsync, () => !IsBusy && CompletionHasIssues && SelectedWorkspace is not null);
        ImportRuleCommand = new AsyncRelayCommand(ImportRuleAsync, () => !IsBusy);
        EnableRuleCommand = new AsyncRelayCommand(() => SetRuleAsync(true), () => !IsBusy && SelectedWorkspace is not null && SelectedRule is not null);
        DisableRuleCommand = new AsyncRelayCommand(() => SetRuleAsync(false), () => !IsBusy && SelectedWorkspace is not null && SelectedRule is not null);
        AddExclusionCommand = new AsyncRelayCommand(AddExclusionAsync, () => !IsBusy && !string.IsNullOrWhiteSpace(ExclusionPattern));
        RemoveExclusionCommand = new AsyncRelayCommand(RemoveExclusionAsync, () => !IsBusy && SelectedExclusion is not null);
        CancelCommand = new RelayCommand(() => { active?.Cancel(); Status = "正在停止；请等待当前项目写回回执。"; }, () => IsBusy);
        commands = [ChooseFolderCommand, ScanCommand, MoreCommand, CleanCommand, PermanentDeleteCommand, AnalyzeCommand, StorageUpCommand, HistoryCommand, RestoreCommand, PurgeCommand, ImportRuleCommand, EnableRuleCommand, DisableRuleCommand, AddExclusionCommand, RemoveExclusionCommand, CancelCommand, DismissCompletionCommand, ViewHistoryFromCompletionCommand, RetryCleanupCommand];
        PropertyChanged += (_, _) => RefreshCommands();
    }
    public ObservableCollection<WorkspaceRow> Workspaces { get; } = [];
    public ObservableCollection<CandidateRow> Candidates { get; } = [];
    public ObservableCollection<RuleRow> Rules { get; } = [];
    public ObservableCollection<HistoryRow> History { get; } = [];
    public ObservableCollection<HistoryItemRow> HistoryItems { get; } = [];
    public ObservableCollection<StorageRow> StorageNodes { get; } = [];
    public ObservableCollection<string> Exclusions { get; } = [];
    public IAsyncRelayCommand ChooseFolderCommand { get; }
    public IAsyncRelayCommand ScanCommand { get; }
    public IAsyncRelayCommand MoreCommand { get; }
    public IAsyncRelayCommand CleanCommand { get; }
    public IAsyncRelayCommand PermanentDeleteCommand { get; }
    public IAsyncRelayCommand AnalyzeCommand { get; }
    public IAsyncRelayCommand StorageUpCommand { get; }
    public IAsyncRelayCommand HistoryCommand { get; }
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
    public int SelectedSection { get => selectedSection; set => SetProperty(ref selectedSection, value); }
    public CleanupCompletionRow? Completion { get => completion; private set { if (SetProperty(ref completion, value)) { OnPropertyChanged(nameof(CompletionVisible)); OnPropertyChanged(nameof(CompletionHasIssues)); RefreshCommands(); } } }
    public bool CompletionVisible => Completion is not null;
    public bool CompletionHasIssues => Completion?.HasIssues == true;
    public string Status { get => status; private set => SetProperty(ref status, value); }
    public string StoragePath { get => storagePath; private set => SetProperty(ref storagePath, value); }
    public string ExclusionPattern { get => exclusionPattern; set => SetProperty(ref exclusionPattern, value); }
    public string? SelectedExclusion { get => selectedExclusion; set => SetProperty(ref selectedExclusion, value); }
    public WorkspaceRow? SelectedWorkspace
    {
        get => selectedWorkspace;
        set { if (SetProperty(ref selectedWorkspace, value)) { Candidates.Clear(); scanId = null; nextOffset = null; LoadRules(); RefreshCommands(); } }
    }
    public RuleRow? SelectedRule { get => selectedRule; set => SetProperty(ref selectedRule, value); }
    public HistoryRow? SelectedHistory
    {
        get => selectedHistory;
        set { if (SetProperty(ref selectedHistory, value)) { HistoryItems.Clear(); foreach (var item in value?.Items ?? []) HistoryItems.Add(item); } }
    }
    public StorageRow? SelectedStorageNode { get => selectedStorageNode; set => SetProperty(ref selectedStorageNode, value); }
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
        Status = "选择一个目录开始扫描。清理前会审阅具体范围；永久删除无法恢复。";
    });
    private async Task RunAsync(Func<Task> action)
    {
        if (IsBusy) return;
        using var cancellation = new CancellationTokenSource(); active = cancellation;
        idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        IsBusy = true;
        try { await action(); }
        catch (BridgeException error) { Status = error.Code + "：" + error.Message; }
        catch (Exception error) { Status = "操作未完成：" + error.Message; }
        finally { active = null; IsBusy = false; idle.TrySetResult(); }
    }
    private IProgress<JsonObject> Progress() => new Progress<JsonObject>(value =>
        Status = $"{Text(value, "stage")} · {Text(value, "path")} · {value["entry_count"] ?? value["processed_count"]}");
    private async Task LoadConfigurationAsync()
    {
        var selected = SelectedWorkspace?.Id;
        var result = await client.RequestAsync("configuration", cancellation: Token);
        configuration = result as JsonObject;
        Workspaces.Clear();
        foreach (var item in Array(result["configuration"]?["workspaces"])) Workspaces.Add(new(Text(item, "id"), Text(item, "path"), Text(item, "root_ref")));
        Exclusions.Clear(); SelectedExclusion = null;
        foreach (var item in Array(result["configuration"]?["global_exclusions"])) if (item?.GetValue<string>() is { } pattern) Exclusions.Add(pattern);
        SelectedWorkspace = Workspaces.FirstOrDefault(item => item.Id == selected) ?? Workspaces.FirstOrDefault();
        LoadRules();
    }
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
        Candidates.Clear(); nextOffset = null;
        var result = await client.RequestAsync("scan", new() { ["workspace_id"] = SelectedWorkspace!.Id }, Progress(), cancellation: Token);
        scanId = Text(result, "scan_id"); AddCandidates(result);
    });
    private Task MoreAsync() => RunAsync(async () => AddCandidates(await client.RequestAsync("scan.results", new() { ["scan_id"] = scanId, ["offset"] = nextOffset }, cancellation: Token)));
    private void AddCandidates(JsonNode result)
    {
        foreach (var item in Array(result["candidates"]))
        {
            var reasons = string.Join("、", Array(item?["reasons"]).Select(value => value?.GetValue<string>()));
            var row = new CandidateRow(Text(item, "id"), Text(item, "relative_path"), item?["allocated_bytes_estimate"]?.GetValue<long>() ?? 0, item?["eligible"]?.GetValue<bool>() == true, Text(item, "risk") + (reasons.Length == 0 ? "" : " · " + reasons));
            row.PropertyChanged += (_, _) => RefreshCommands(); Candidates.Add(row);
        }
        nextOffset = result["next_offset"]?.GetValue<int>();
        Status = $"扫描{(Text(result, "status") == "complete" ? "完成" : "仅完成部分范围")}，显示 {Candidates.Count} / {result["total_count"]} 个规则命中。";
        if (Array(result["issues"]).Length > 0) Status += " " + string.Join("；", Array(result["issues"]).Take(3).Select(value => value?.GetValue<string>()));
        RefreshCommands();
    }
    private Task CleanAsync(string action) => RunAsync(async () =>
    {
        var selected = Candidates.Where(item => item.IsSelected && item.Eligible).Select(item => item.Id).ToArray();
        var plan = await client.RequestAsync("plan", new() { ["scan_id"] = scanId, ["candidate_ids"] = Strings(selected), ["action"] = action }, cancellation: Token);
        var receipt = await client.RequestAsync("plan.execute", new() { ["plan_id"] = Text(plan, "id") }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        Candidates.Clear(); scanId = null; nextOffset = null;
        Completion = BuildCompletion(receipt, action);
        Status = "清理结果：" + Text(receipt, "state") + (action == "permanent" ? "。永久删除无法恢复，可在历史中查看逐项结果。" : "。可在历史中查看或恢复。移入回收站不会立即释放磁盘空间。");
        if (!Token.IsCancellationRequested) await LoadHistoryAsync();
    });
    private async Task LoadHistoryAsync()
    {
        var result = await client.RequestAsync("history", cancellation: Token);
        History.Clear();
        foreach (var item in Array(result)) History.Add(new(Text(item, "id"), Text(item, "created_at"), Text(item, "root_path"), Text(item, "state"),
            Array(item?["items"]).Where(value => value?["can_restore"]?.GetValue<bool>() == true).Select(value => Text(value, "id")).ToArray(),
            Array(item?["items"]).Where(value => value?["can_purge"]?.GetValue<bool>() == true).Select(value => Text(value, "id")).ToArray(),
            Array(item?["items"]).Select(value => new HistoryItemRow(Text(value, "path"), Text(value, "state"), value?["error"]?.GetValue<string>(), value?["resulting_path"]?.GetValue<string>())).ToArray()));
        SelectedHistory = History.FirstOrDefault();
    }
    private Task FollowUpAsync(string action) => RunAsync(async () =>
    {
        var receipt = SelectedHistory!;
        var result = await client.RequestAsync("history." + action, new() { ["execution_id"] = receipt.Id, ["item_ids"] = Strings(action == "restore" ? receipt.RestorableIds : receipt.PurgeableIds) }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
        Completion = BuildCompletion(result, action);
        Status = (action == "restore" ? "恢复结果：" : "永久删除结果：") + string.Join("、", Array(result).Select(value => Text(value, "state"))) + (action == "restore" ? "。已有同名目标不会被覆盖。" : "。已永久删除的项目无法恢复。");
        if (!Token.IsCancellationRequested) await LoadHistoryAsync();
    });
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
        Candidates.Clear(); scanId = null; nextOffset = null;
        return ScanAsync();
    }

    private static CleanupCompletionRow BuildCompletion(JsonNode value, string action)
    {
        var source = value is JsonArray ? Array(value) : Array(value?["items"]);
        var rows = source.Select(item => new CleanupItemResultRow(Text(item, "path"), Text(item, "state"), item?["error"]?.GetValue<string>())).ToArray();
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
        await RunAsync(async () =>
        {
            var scan = await client.RequestAsync("storage.scan", new() { ["path"] = path }, Progress(), cancellation: Token);
            storageScanId = Text(scan, "scan_id"); ShowDirectory(scan["directory"]!);
            Status = (Text(scan, "status") == "partial" ? "仅完成部分范围，统计不代表全部占用。" : "空间统计按实际分配大小估算。") + "双击目录继续查看。";
        });
    }
    public Task OpenStorageNodeAsync() => SelectedStorageNode is { Kind: "directory" } item ? RunAsync(async () => ShowDirectory(await client.RequestAsync("storage.directory", new() { ["scan_id"] = storageScanId, ["path"] = item.Path }, cancellation: Token))) : Task.CompletedTask;
    private Task StorageUpAsync() => RunAsync(async () =>
    {
        var slash = StoragePath.LastIndexOf('/'); var parent = slash < 0 ? "." : StoragePath[..slash];
        ShowDirectory(await client.RequestAsync("storage.directory", new() { ["scan_id"] = storageScanId, ["path"] = parent }, cancellation: Token));
    });
    private void ShowDirectory(JsonNode directory)
    {
        StoragePath = Text(directory, "path"); StorageNodes.Clear();
        foreach (var item in Array(directory["children"])) StorageNodes.Add(new(Text(item, "path"), Bytes(item?["allocated_bytes"]?.GetValue<long>() ?? 0), Text(item, "kind")));
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
