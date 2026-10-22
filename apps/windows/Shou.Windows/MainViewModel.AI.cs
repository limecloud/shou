using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record AiConnectionRow(string Id, string Name, JsonObject Profile)
{
    public bool HasMainModel => Profile["main_model_enabled"]?.GetValue<bool>()!=false;
    public bool UsesDecision => Profile["decision"] is JsonObject && Profile["routing_strategy"]?.GetValue<string>()!="main_only";
    public string ServiceSummary {
        get {
            var main=Profile["main_model_enabled"]?.GetValue<bool>()!=false;
            var model=Profile["model"]?.GetValue<string>() ?? "";
            var provider=Profile["decision"]?["provider"]?.GetValue<string>() ?? "jev";
            var name=provider=="jev" ? "Jev" : provider;
            return UsesDecision ? name+(main ? " + "+model : " · "+(Profile["decision"]?["model"]?.GetValue<string>() ?? "")) : model;
        }
    }
    public string DisplayName => Name+" · "+ServiceSummary;
}
public sealed record AiGoalRow(string Id, string Name);
public sealed record AiHistoryRow(string Id, string Label);
public sealed record AiAdviceRow(string Id, string Path, string Explanation, string Conditions);
public sealed class AiQuestionRow(string id, string text, string[] choices) : ObservableObject
{
    public string Id { get; } = id;
    public string Text { get; } = text;
    public string[] Choices { get; } = choices;
    private string answer = "";
    public string Answer { get => answer; set => SetProperty(ref answer, value); }
}

public sealed partial class MainViewModel
{
    private bool aiEnabled, aiBusy, aiAvailable;
    private string aiFolder = "", aiRequest = "", aiStatus = "AI 默认关闭。启用并选择连接后，点击开始才会发送所选目录的相对元数据。";
    private string aiSummary = "", aiUsage = "", aiEvidence = "", aiDecisions = "", aiConnectionDisclosure = "尚未选择连接。";
    private string? aiId, aiSavedScan, aiSavedScope, aiRoot;
    private JsonObject? aiState;
    private AiConnectionRow? selectedAiConnection;
    private AiGoalRow? selectedAiGoal;
    private AiHistoryRow? selectedAiHistory;
    private CancellationTokenSource? aiCancellation;
    private TaskCompletionSource? aiIdle;
    private JsonNode?[] aiProviders = [];
    private int aiGeneration;
    private static string AiPreference => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "ai-enabled.txt");
    private static string AiConnectionPreference => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "ai-connection.txt");

    public ObservableCollection<AiConnectionRow> AiConnections { get; } = [];
    public ObservableCollection<AiConnectionRow> AiDeletedConnections { get; } = [];
    private AiConnectionRow? selectedAiDeletedConnection;
    public AiConnectionRow? SelectedAiDeletedConnection { get => selectedAiDeletedConnection; set => SetProperty(ref selectedAiDeletedConnection,value); }
    public ObservableCollection<AiGoalRow> AiGoals { get; } = [new("investigate", "调查所选目录"), new("space", "解释空间占用（仅本地）"), new("rules", "生成规则草稿")];
    public ObservableCollection<AiQuestionRow> AiQuestions { get; } = [];
    public ObservableCollection<AiAdviceRow> AiAdvice { get; } = [];
    public ObservableCollection<AiHistoryRow> AiHistory { get; } = [];
    public IAsyncRelayCommand AiChooseFolderCommand { get; private set; } = null!;
    public IRelayCommand AiAllScannedCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiEditConnectionCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiNewConnectionCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiDeleteConnectionCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiRestoreConnectionCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiTestCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiStartCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiResumeCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiStopCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiNewCommand { get; private set; } = null!;
    public IAsyncRelayCommand<AiAdviceRow> AiPreviewCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiLoadCommand { get; private set; } = null!;
    public IRelayCommand AiFromCleanupCommand { get; private set; } = null!;
    public IRelayCommand AiFromStorageCommand { get; private set; } = null!;
    public IRelayCommand AiFromRulesCommand { get; private set; } = null!;
    public IRelayCommand<LargeFileRow> AiFromLargeFileCommand { get; private set; } = null!;
    public bool AiEnabled
    {
        get => aiEnabled;
        set {
            if (!SetProperty(ref aiEnabled, value)) return;
            try { Directory.CreateDirectory(Path.GetDirectoryName(AiPreference)!); File.WriteAllText(AiPreference, value ? "enabled" : "disabled"); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { AiStatus = "AI 开关未能保存；重启后请检查设置。"; }
            if (!value) { aiCancellation?.Cancel(); _ = StopWaitingAiAsync(); AiStatus = "AI 已关闭，正在停止请求；已有证据与草稿保留。"; }
            else AiStatus = "AI 已启用。选择范围并点击开始；连接测试只发送合成数据。";
        }
    }
    public bool AiBusy { get => aiBusy; private set { SetProperty(ref aiBusy, value); OnPropertyChanged(nameof(AiCanEdit)); } }
    public bool AiCanEdit => !AiBusy && !IsBusy && !AiPending;
    public string AiFolder { get => aiFolder; private set { SetProperty(ref aiFolder, value); OnPropertyChanged(nameof(AiMeasurement)); OnPropertyChanged(nameof(AiScopeLabel)); } }
    public string AiScopeLabel => storageRoot is not null && !string.IsNullOrEmpty(AiFolder) && SamePath(storageRoot,AiFolder) ? "全部已扫描范围：当前索引根及子目录，不包含其他卷。" : "单个目录：仅此目录及其子目录。调查范围不改变清理勾选。";
    public string AiRequest { get => aiRequest; set => SetProperty(ref aiRequest, value); }
    public string AiStatus { get => aiStatus; private set => SetProperty(ref aiStatus, value); }
    public string AiSummary { get => aiSummary; private set => SetProperty(ref aiSummary, value); }
    public string AiUsage { get => aiUsage; private set => SetProperty(ref aiUsage, value); }
    public string AiDecisions { get => aiDecisions; private set => SetProperty(ref aiDecisions, value); }
    public string AiEvidence { get => aiEvidence; private set => SetProperty(ref aiEvidence, value); }
    public string AiConnectionDisclosure { get => aiConnectionDisclosure; private set => SetProperty(ref aiConnectionDisclosure, value); }
    public string AiMeasurement => AiReusableScope() is not null ? "将复用现有空间索引；开始前不发送网络请求。" : "开始时先在本地测量此目录，再发送有界的相对元数据。";
    public AiConnectionRow? SelectedAiConnection { get => selectedAiConnection; set {
        if (!SetProperty(ref selectedAiConnection, value)) return;
        OnPropertyChanged(nameof(AiDecisionEnabled));
        if(!AiPending) UpdateAiDisclosure(value?.Profile);
        if(value is null) return;
        try { Directory.CreateDirectory(Path.GetDirectoryName(AiConnectionPreference)!); File.WriteAllText(AiConnectionPreference,value.Id); }
        catch(Exception error) when(error is IOException or UnauthorizedAccessException) { AiStatus="默认 AI 配置未能保存；重启后请重新选择。"; }
    } }
    public bool AiDecisionEnabled { get => SelectedAiConnection?.UsesDecision==true; set {
        if(SelectedAiConnection is { } connection && AiCanEdit && value!=connection.UsesDecision) {
            if(value && connection.Profile["decision"] is null) _=EditAiConnectionAsync(true,true);
            else _=SetAiDecisionEnabledAsync(connection,value);
        }
    } }
    public AiGoalRow? SelectedAiGoal { get => selectedAiGoal; set => SetProperty(ref selectedAiGoal, value); }
    public AiHistoryRow? SelectedAiHistory { get => selectedAiHistory; set => SetProperty(ref selectedAiHistory, value); }
    private bool AiPending => Text(aiState, "status") is "waiting" or "running";
    private bool AiExpired => DateTimeOffset.TryParse(Text(aiState, "created_at"), out var created) && DateTimeOffset.UtcNow - created >= TimeSpan.FromHours(24);
    private bool AiStale => AiExpired || aiRoot is not null && storageRoot is not null && SamePath(aiRoot,storageRoot) && (storageScanId!=Text(aiState,"scan_id") || storageRemovedPaths.Count>0);
    public bool HasAiWork => AiBusy || AiPending || AiQuestions.Any(q => !string.IsNullOrWhiteSpace(q.Answer));
    public Task WhenAiIdleAsync() => aiIdle?.Task ?? Task.CompletedTask;

    private void InitializeAI()
    {
        try { aiEnabled = File.Exists(AiPreference) && File.ReadAllText(AiPreference) == "enabled"; } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        selectedAiGoal = AiGoals[0];
        bool Ready() => aiAvailable && AiEnabled && !AiBusy && !IsBusy;
        AiChooseFolderCommand = new AsyncRelayCommand(() => { var path=dialogs.ChooseFolder(); if(path is not null) AiFolder=path; return Task.CompletedTask; }, () => AiCanEdit);
        AiAllScannedCommand = new RelayCommand(() => AiFolder=storageRoot!, () => AiCanEdit && storageRoot is not null);
        AiNewConnectionCommand = new AsyncRelayCommand(() => EditAiConnectionAsync(false), () => AiCanEdit);
        AiEditConnectionCommand = new AsyncRelayCommand(() => EditAiConnectionAsync(true), () => AiCanEdit && SelectedAiConnection is not null);
        AiDeleteConnectionCommand = new AsyncRelayCommand(async () => {
            if(SelectedAiConnection is not { } connection || !dialogs.ConfirmAIConfigurationDeletion(connection.Name)) return;
            await RunAiAsync(async token => { await client.RequestAsync("ai.connections.delete",new() { ["connection_id"]=connection.Id },cancellation:token); await LoadAiConnectionsAsync(token); AiStatus="配置已移至已删除配置，可随时恢复。已有调查记录和密钥已保留。"; });
        }, () => AiCanEdit && SelectedAiConnection is not null);
        AiRestoreConnectionCommand = new AsyncRelayCommand(async () => {
            if(SelectedAiDeletedConnection is not { } connection) return;
            await RunAiAsync(async token => { await client.RequestAsync("ai.connections.restore",new() { ["connection_id"]=connection.Id },cancellation:token); await LoadAiConnectionsAsync(token); SelectedAiConnection=AiConnections.FirstOrDefault(row=>row.Id==connection.Id); AiStatus="配置已恢复。"; });
        }, () => AiCanEdit && SelectedAiDeletedConnection is not null);
        AiTestCommand = new AsyncRelayCommand(() => RunAiAsync(async token => {
            var connection=SelectedAiConnection!;
            if (connection.Profile["main_model_enabled"]?.GetValue<bool>() != false) {
                await client.RequestAsync("ai.test", new() { ["connection_id"]=connection.Id }, cancellation: token);
                token.ThrowIfCancellationRequested();
            }
            if (connection.UsesDecision) await client.RequestAsync("ai.decision.test", new() { ["connection_id"]=connection.Id }, cancellation: token);
            AiStatus="所选连接的合成数据测试通过。";
        }), () => Ready() && SelectedAiConnection?.HasMainModel==true);
        AiStartCommand = new AsyncRelayCommand(StartAiAsync, () => Ready() && !AiPending && SelectedAiConnection?.HasMainModel==true && !string.IsNullOrEmpty(AiFolder));
        AiResumeCommand = new AsyncRelayCommand(() => RunAiAsync(async token => {
            var answers=new JsonObject(); foreach(var q in AiQuestions) answers[q.Id]=q.Answer;
            ApplyAi(await client.RequestAsync("ai.resume",new() { ["investigation_id"]=aiId,["answers"]=answers },AiProgress(),cancellation:token));
        }), () => Ready() && Text(aiState,"status")=="waiting" && !AiStale && AiQuestions.Count>0 && AiQuestions.All(q=>!string.IsNullOrWhiteSpace(q.Answer) && q.Answer.Length<=2000));
        AiStopCommand = new AsyncRelayCommand(StopAiAsync, () => AiBusy || AiPending);
        AiNewCommand = new AsyncRelayCommand(async () => { await StopAiAsync(); aiState=null; aiId=null; AiQuestions.Clear(); AiAdvice.Clear(); AiSummary=""; AiUsage=""; AiEvidence=""; AiDecisions=""; AiRequest=""; UpdateAiDisclosure(SelectedAiConnection?.Profile); OnPropertyChanged(nameof(AiCanEdit)); RefreshCommands(); }, () => !AiBusy && !IsBusy);
        AiPreviewCommand = new AsyncRelayCommand<AiAdviceRow>(PreviewAiAdviceAsync, row => !AiBusy && !IsBusy && row is not null && aiId is not null && !AiStale && Text(aiState,"status")!="running");
        AiLoadCommand = new AsyncRelayCommand(() => RunAiAsync(async token => {
            var state=await client.RequestAsync("ai.show",new() { ["investigation_id"]=SelectedAiHistory!.Id },cancellation:token);
            var scan=await client.RequestAsync("storage.show",new() { ["scan_id"]=Text(state,"scan_id") },cancellation:token);
            aiRoot=Text(scan,"root_path"); AiFolder=Path.Combine(aiRoot,Text(state,"scope")=="." ? "" : Text(state,"scope")); ApplyAi(state);
        }), () => !AiBusy && !IsBusy && !AiPending && SelectedAiHistory is not null);
        AiFromCleanupCommand = new RelayCommand(() => OpenAi(SelectedWorkspace?.Path), () => !IsBusy);
        AiFromStorageCommand = new RelayCommand(() => {
            var relative=SelectedStorageNode is { Kind:"directory" } row ? row.Path : StoragePath;
            OpenAi(storageRoot is null ? null : Path.Combine(storageRoot,relative=="." ? "" : relative));
        }, () => !IsBusy && storageRoot is not null);
        AiFromRulesCommand = new RelayCommand(() => { if(!AiBusy && !AiPending) SelectedAiGoal=AiGoals[2]; OpenAi(SelectedWorkspace?.Path); }, () => !IsBusy);
        AiFromLargeFileCommand = new RelayCommand<LargeFileRow>(row => OpenAi(Path.GetDirectoryName(row!.AbsolutePath)), row => !IsBusy && row is not null);
        commands.AddRange([AiChooseFolderCommand,AiAllScannedCommand,AiNewConnectionCommand,AiEditConnectionCommand,AiDeleteConnectionCommand,AiRestoreConnectionCommand,AiTestCommand,AiStartCommand,AiResumeCommand,AiStopCommand,AiNewCommand,AiPreviewCommand,AiLoadCommand,AiFromCleanupCommand,AiFromStorageCommand,AiFromRulesCommand,AiFromLargeFileCommand]);
        PropertyChanged += (_,e) => { if(e.PropertyName==nameof(IsBusy)) OnPropertyChanged(nameof(AiCanEdit)); };
    }
    private void OpenAi(string? path)
    {
        SelectedSection=5;
        if(AiBusy || AiPending) { AiStatus="已有调查正在运行或等待回答。请先完成或停止，再开始新范围；原范围和未提交回答已保留。"; return; }
        if(path is not null) AiFolder=Path.GetFullPath(path);
    }
    private string? AiReusableScope()
    {
        if(storageScanId is null || storageRoot is null || storageRemovedPaths.Count>0 || string.IsNullOrEmpty(AiFolder)) return null;
        var root=Path.GetFullPath(storageRoot).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
        var folder=Path.GetFullPath(AiFolder).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
        if(folder.Equals(root,StringComparison.OrdinalIgnoreCase)) return ".";
        return folder.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase) ? Path.GetRelativePath(root,folder).Replace('\\','/') : null;
    }
    private async Task LoadAIAsync(JsonNode capabilities)
    {
        aiAvailable=capabilities["features"]?["ai_investigation"]?.GetValue<bool>()==true;
        aiProviders=Array(await client.RequestAsync("ai.providers",cancellation:Token));
        await LoadAiConnectionsAsync(Token);
        await LoadAiHistoryAsync(Token);
        if(!aiAvailable) AiStatus="此清理核心尚不支持 AI，请更新完整应用。";
        else if(AiEnabled) AiStatus="AI 已启用。选择范围并点击开始；连接测试只发送合成数据。";
    }
    private async Task LoadAiConnectionsAsync(CancellationToken token)
    {
        var selected=SelectedAiConnection?.Id;
        if(selected is null) {
            try { if(File.Exists(AiConnectionPreference)) selected=File.ReadAllText(AiConnectionPreference); }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException) { AiStatus="无法读取默认 AI 配置。"; }
        }
        var rows=await client.RequestAsync("ai.connections",cancellation:token);
        AiConnections.Clear();
        foreach(var item in Array(rows).OfType<JsonObject>()) AiConnections.Add(new(Text(item,"id"),Text(item,"name"),(JsonObject)item.DeepClone()));
        SelectedAiConnection=AiConnections.FirstOrDefault(row=>row.Id==selected && row.HasMainModel) ?? AiConnections.FirstOrDefault(row=>row.HasMainModel);
        var deleted=await client.RequestAsync("ai.connections.deleted",cancellation:token);
        AiDeletedConnections.Clear();
        foreach(var item in Array(deleted).OfType<JsonObject>()) AiDeletedConnections.Add(new(Text(item,"id"),Text(item,"name"),(JsonObject)item.DeepClone()));
        SelectedAiDeletedConnection=AiDeletedConnections.FirstOrDefault();
        OnPropertyChanged(nameof(SelectedAiDeletedConnection)); RefreshCommands();
    }
    private Task SetAiDecisionEnabledAsync(AiConnectionRow connection,bool enabled) => RunAiAsync(async token => {
        var profile=(JsonObject)connection.Profile.DeepClone();
        if(enabled && profile["decision"] is null) {
            var provider=aiProviders.OfType<JsonObject>().FirstOrDefault();
            if(provider?["default_connection"] is not JsonObject defaults) throw new InvalidOperationException("请先在编辑配置中选择可用的决策服务。");
            profile["decision"]=defaults.DeepClone();
        }
        profile["routing_strategy"]=enabled ? "decision_first" : "main_only";
        try { await client.RequestAsync("ai.connections.save",new() { ["profile"]=profile },cancellation:token); }
        finally { OnPropertyChanged(nameof(AiDecisionEnabled)); }
        await LoadAiConnectionsAsync(token);
        AiStatus=enabled ? "决策服务已开启，将协助主模型节省 token。" : "决策服务已关闭，由主模型接管；决策配置和密钥已保留。";
    });
    private async Task LoadAiHistoryAsync(CancellationToken token)
    {
        AiHistory.Clear();
        foreach(var item in Array(await client.RequestAsync("ai.list",cancellation:token)).Where(item=>Text(item,"status")!="running")) AiHistory.Add(new(Text(item,"id"),Text(item,"scope")+" · "+AiStateName(Text(item,"status"))+" · "+Text(item,"created_at")));
    }
    private async Task EditAiConnectionAsync(bool edit,bool enableDecision=false)
    {
        var profile=edit ? (JsonObject?)SelectedAiConnection?.Profile.DeepClone() : null;
        if(enableDecision && profile is not null && aiProviders.OfType<JsonObject>().FirstOrDefault()?["default_connection"] is JsonObject defaults) {
            profile["decision"]=defaults.DeepClone(); profile["routing_strategy"]="decision_first";
        }
        var input=dialogs.EditAIConnection(profile, aiProviders);
        OnPropertyChanged(nameof(AiDecisionEnabled));
        if(input is null) return;
        try {
            var saved=await client.RequestAsync("ai.connections.save",input);
            await LoadAiConnectionsAsync(CancellationToken.None);
            SelectedAiConnection=AiConnections.FirstOrDefault(row=>row.Id==Text(saved,"id"));
            AiStatus="AI 配置已保存，密钥按各服务所选方式保存。点击测试验证；保存不会发起模型请求。";
        } catch(BridgeException error) { AiStatus=error.Code+"："+error.Message; }
        finally { input["model_key"]=null; input["decision_key"]=null; }
    }
    private Task StartAiAsync() => RunAiAsync(async token => {
        var connection=SelectedAiConnection!; var folder=AiFolder; var request=AiRequest; var goal=SelectedAiGoal?.Id ?? "investigate";
        aiState=null; aiId=null; AiQuestions.Clear(); AiAdvice.Clear(); AiSummary=""; AiUsage=""; AiEvidence=""; AiDecisions="";
        aiSavedScope=AiReusableScope(); aiSavedScan=storageScanId;
        if(aiSavedScope is null) {
            AiStatus="正在本地测量所选目录…";
            var scan=await client.RequestAsync("storage.scan",new() { ["path"]=folder },cancellation:token);
            aiSavedScan=Text(scan,"scan_id"); aiSavedScope=".";
        }
        var scopeInfo=await client.RequestAsync("storage.show",new() { ["scan_id"]=aiSavedScan },cancellation:token);
        aiRoot=Text(scopeInfo,"root_path");
        token.ThrowIfCancellationRequested();
        if(!AiEnabled) return;
        ApplyAi(await client.RequestAsync("ai.investigate",new() { ["scan_id"]=aiSavedScan,["path"]=aiSavedScope,["connection_id"]=connection.Id,["request"]=request,["goal"]=goal,["locale"]="zh-CN" },AiProgress(),cancellation:token));
    });
    private IProgress<JsonObject> AiProgress() { var generation=aiGeneration; return new Progress<JsonObject>(value => { if(AiBusy && generation==aiGeneration && value["id"] is not null) ApplyAi(value); }); }
    private async Task RunAiAsync(Func<CancellationToken,Task> action)
    {
        if(AiBusy || IsBusy) return;
        using var cancellation=new CancellationTokenSource(); aiCancellation=cancellation;
        aiIdle=new(TaskCreationOptions.RunContinuationsAsynchronously); aiGeneration++; AiBusy=true;
        try { await action(cancellation.Token); }
        catch(BridgeException error) { AiStatus=error.Code+"："+error.Message; }
        catch(OperationCanceledException) { AiStatus="AI 已停止。已有证据与草稿保留。"; }
        catch(Exception error) { AiStatus="AI 操作未完成："+error.Message; }
        finally {
            aiGeneration++;
            if(aiId is not null && Text(aiState,"status")=="running") {
                try { ApplyAi(await client.RequestAsync("ai.show",new() { ["investigation_id"]=aiId })); } catch(BridgeException) { }
            }
            try { await LoadAiHistoryAsync(CancellationToken.None); } catch(BridgeException) { }
            aiCancellation=null; AiBusy=false; aiIdle.TrySetResult();
            OnPropertyChanged(nameof(AiCanEdit)); RefreshCommands();
        }
    }
    private async Task StopWaitingAiAsync()
    {
        if(aiId is not null && AiPending && !AiBusy) {
            try { ApplyAi(await client.RequestAsync("ai.cancel",new() { ["investigation_id"]=aiId })); }
            catch(BridgeException error) { AiStatus=error.Message; }
        }
    }
    public async Task StopAiAsync()
    {
        aiCancellation?.Cancel();
        await WhenAiIdleAsync();
        await StopWaitingAiAsync();
    }
    private static string AiStateName(string value) => value switch { "running"=>"调查中", "waiting"=>"等待回答", "complete"=>"已完成", "cancelled"=>"已停止", "limited"=>"已达到本次调查上限", "failed"=>"未完成", _=>value };
    private static string AiLimitMessage(JsonNode state) => Text(state,"limit_reason") switch {
        "time"=>"达到单次 3 分钟处理时限。已有证据已保存，可缩小目录重新调查；这不代表 API 账户余额不足。",
        "tokens"=>"达到单次 32,000 个报告 token 上限。已有证据已保存，可缩小目录重新调查。",
        "steps"=>"达到单次 12 步分析上限。已有证据已保存，可选择具体子目录继续调查。",
        "decisions"=>"达到单次 8 次决策请求上限。已有证据已保存，可选择具体子目录继续调查。",
        "tools"=>"达到单次 32 次工具调用上限。已有证据已保存，可缩小目录重新调查。",
        "evidence"=>"达到本次证据大小上限。已有证据已保存，可缩小目录重新调查。",
        "response"=>"服务响应超过允许大小。已有证据已保存，请检查连接或缩小目录。",
        "directories"=>"本次概览已分析 8 个目录。请审阅已有发现，再选择具体子目录继续调查。",
        _=>Text(state,"issue")
    };
    private void UpdateAiDisclosure(JsonObject? connection)
    {
        if(connection is null) { AiConnectionDisclosure="尚未选择 AI 配置。"; return; }
        var main=connection["main_model_enabled"]?.GetValue<bool>()!=false;
        var decision=connection["decision"];
        var usesDecision=decision is not null && Text(connection,"routing_strategy")!="main_only";
        var provider=Text(decision,"provider") is { Length:>0 } configured ? configured : "jev";
        var lines=new List<string>();
        if(usesDecision) lines.Add("决策服务（优先）："+(provider=="jev" ? "Jev" : provider)+" · "+Text(decision,"model")+" · "+Text(decision,"base_url"));
        if(main) lines.Add((usesDecision ? "主模型（按需）：" : "主模型：")+Text(connection,"model")+" · "+Text(connection,"base_url"));
        lines.Add(!main ? "旧配置缺少主模型，请编辑补全后使用。" : usesDecision ? "本地分析 → 结构化决策 → 必要时主模型。同一配置中的两项服务协作，按需调用。" : "本地分析 → 主模型。当前策略不使用结构化决策。");
        lines.Add("只发送相对路径、统计及您提交的回答。");
        AiConnectionDisclosure=string.Join("\n",lines);
    }
    private void ApplyAi(JsonNode value)
    {
        var same=aiId==Text(value,"id"); var answers=AiQuestions.ToDictionary(q=>q.Id,q=>q.Answer);
        aiState=(JsonObject)value.DeepClone(); aiId=Text(value,"id");
        UpdateAiDisclosure(aiState["connection"] as JsonObject);
        AiSummary=Text(value,"summary");
        AiStatus=AiStateName(Text(value,"status"))+" · "+Text(value,"activity")+(AiStale ? " · 索引已变化或调查超过 24 小时，请新建。" : "")+
            (AiLimitMessage(value) is { Length:>0 } issue ? "\n"+issue : "");
        AiUsage=string.Join("\n",Array(value["service_usage"]).Select(item=>Text(item,"service")+"："+(item?["requests"]?.ToString() ?? "0")+" 次请求，报告 "+(item?["reported_tokens"]?.ToString() ?? "0")+" token"))+
            "\n"+string.Join("\n",Array(value["escalation_reasons"]).Select(item=>item?.GetValue<string>()));
        AiDecisions=string.Join("\n",Array(value["decision_reviews"]).Select(item=>Text(item,"path")+" · "+Text(item,"model")+" · "+Text(item,"verdict")))+"\n判断仅支持草稿审阅，置信度不代表安全删除概率。";
        AiEvidence="原调查目录："+AiFolder+"\n调查范围："+Text(value,"scope")+" · 索引 "+Text(value,"scan_id")+"\n"+string.Join("\n",Array(value["evidence"]).Select(item=>Text(item,"path")+" · "+Bytes(item?["allocated_bytes"]?.GetValue<long>() ?? 0)+(item?["complete"]?.GetValue<bool>()==false ? "（部分测量）" : "")));
        AiQuestions.Clear();
        foreach(var q in Array(value["questions"])) {
            var row=new AiQuestionRow(Text(q,"id"),Text(q,"text"),Array(q?["choices"]).Select(c=>c!.GetValue<string>()).ToArray());
            if(same && answers.TryGetValue(row.Id,out var answer)) row.Answer=answer;
            row.PropertyChanged+=(_,_)=>AiResumeCommand.NotifyCanExecuteChanged(); AiQuestions.Add(row);
        }
        AiAdvice.Clear();
        foreach(var advice in Array(value["advice"])) AiAdvice.Add(new(Text(advice,"id"),Text(advice,"path"),Text(advice,"explanation"),Text(advice?["rule"]?["risk"],"rebuild_note")+"\n"+string.Join("；",Array(advice?["rule"]?["risk"]?["limitations"]).Select(x=>x?.GetValue<string>()))));
        if(Text(value,"status")=="complete" && AiAdvice.Count==0) AiStatus+="\n本次没有可导入的规则建议。您可以保留结果或更换范围重新调查。";
        OnPropertyChanged(nameof(AiCanEdit)); RefreshCommands();
    }
    private async Task PreviewAiAdviceAsync(AiAdviceRow? advice)
    {
        if(advice is null || aiId is null) return;
        await RunAsync(async () => {
            var record=await client.RequestAsync("ai.advice.import",new() { ["investigation_id"]=aiId,["advice_id"]=advice.Id },cancellation:Token);
            await LoadConfigurationAsync();
            var rootRef=Text(record["rule"]?["scope"],"root_ref");
            SelectedWorkspace=Workspaces.FirstOrDefault(row=>row.RootRef==rootRef);
            SelectedRule=Rules.FirstOrDefault(row=>row.Id==Text(record["rule"],"id"));
            if(SelectedRule is null) throw new BridgeException("not_found","草稿已导入，请在对应工作区逐条预览。");
            SelectedSection=2; Status="已导入这一条停用草稿。请预览，再启用并扫描。";
        });
        if(SelectedRule is not null) await PreviewRuleAsync();
    }
}
