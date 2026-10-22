using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record AiConnectionRow(string Id, string Name, JsonObject Profile);
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

    public ObservableCollection<AiConnectionRow> AiConnections { get; } = [];
    public ObservableCollection<AiGoalRow> AiGoals { get; } = [new("investigate", "调查所选目录"), new("space", "解释空间占用（仅本地）"), new("rules", "生成规则草稿")];
    public ObservableCollection<AiQuestionRow> AiQuestions { get; } = [];
    public ObservableCollection<AiAdviceRow> AiAdvice { get; } = [];
    public ObservableCollection<AiHistoryRow> AiHistory { get; } = [];
    public IAsyncRelayCommand AiChooseFolderCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiEditConnectionCommand { get; private set; } = null!;
    public IAsyncRelayCommand AiNewConnectionCommand { get; private set; } = null!;
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
    public string AiFolder { get => aiFolder; private set { SetProperty(ref aiFolder, value); OnPropertyChanged(nameof(AiMeasurement)); } }
    public string AiRequest { get => aiRequest; set => SetProperty(ref aiRequest, value); }
    public string AiStatus { get => aiStatus; private set => SetProperty(ref aiStatus, value); }
    public string AiSummary { get => aiSummary; private set => SetProperty(ref aiSummary, value); }
    public string AiUsage { get => aiUsage; private set => SetProperty(ref aiUsage, value); }
    public string AiDecisions { get => aiDecisions; private set => SetProperty(ref aiDecisions, value); }
    public string AiEvidence { get => aiEvidence; private set => SetProperty(ref aiEvidence, value); }
    public string AiConnectionDisclosure { get => aiConnectionDisclosure; private set => SetProperty(ref aiConnectionDisclosure, value); }
    public string AiMeasurement => AiReusableScope() is not null ? "将复用现有空间索引；开始前不发送网络请求。" : "开始时先在本地测量此目录，再发送有界的相对元数据。";
    public AiConnectionRow? SelectedAiConnection { get => selectedAiConnection; set { if (SetProperty(ref selectedAiConnection, value) && !AiPending) UpdateAiDisclosure(value?.Profile); } }
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
        AiNewConnectionCommand = new AsyncRelayCommand(() => EditAiConnectionAsync(false), () => !AiBusy && !IsBusy);
        AiEditConnectionCommand = new AsyncRelayCommand(() => EditAiConnectionAsync(true), () => !AiBusy && !IsBusy && SelectedAiConnection is not null);
        AiTestCommand = new AsyncRelayCommand(() => RunAiAsync(async token => {
            var connection=SelectedAiConnection!;
            if (connection.Profile["main_model_enabled"]?.GetValue<bool>() != false) {
                await client.RequestAsync("ai.test", new() { ["connection_id"]=connection.Id }, cancellation: token);
                token.ThrowIfCancellationRequested();
            }
            if (connection.Profile["decision"] is JsonObject) await client.RequestAsync("ai.decision.test", new() { ["connection_id"]=connection.Id }, cancellation: token);
            AiStatus="所选连接的合成数据测试通过。";
        }), () => Ready() && SelectedAiConnection is not null);
        AiStartCommand = new AsyncRelayCommand(StartAiAsync, () => Ready() && !AiPending && SelectedAiConnection is not null && !string.IsNullOrEmpty(AiFolder));
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
        commands.AddRange([AiChooseFolderCommand,AiNewConnectionCommand,AiEditConnectionCommand,AiTestCommand,AiStartCommand,AiResumeCommand,AiStopCommand,AiNewCommand,AiPreviewCommand,AiLoadCommand,AiFromCleanupCommand,AiFromStorageCommand,AiFromRulesCommand,AiFromLargeFileCommand]);
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
        var rows=await client.RequestAsync("ai.connections",cancellation:token);
        AiConnections.Clear();
        foreach(var item in Array(rows).OfType<JsonObject>()) AiConnections.Add(new(Text(item,"id"),Text(item,"name"),(JsonObject)item.DeepClone()));
        SelectedAiConnection=AiConnections.FirstOrDefault(row=>row.Id==selected) ?? AiConnections.FirstOrDefault();
    }
    private async Task LoadAiHistoryAsync(CancellationToken token)
    {
        AiHistory.Clear();
        foreach(var item in Array(await client.RequestAsync("ai.list",cancellation:token)).Where(item=>Text(item,"status")!="running")) AiHistory.Add(new(Text(item,"id"),Text(item,"scope")+" · "+AiStateName(Text(item,"status"))+" · "+Text(item,"created_at")));
    }
    private async Task EditAiConnectionAsync(bool edit)
    {
        var input=dialogs.EditAIConnection(edit ? SelectedAiConnection?.Profile : null, aiProviders);
        if(input is null) return;
        try {
            var saved=await client.RequestAsync("ai.connections.save",input);
            await LoadAiConnectionsAsync(CancellationToken.None);
            SelectedAiConnection=AiConnections.FirstOrDefault(row=>row.Id==Text(saved,"id"));
            AiStatus="连接已保存，密钥存入 Windows 凭据管理器。点击测试验证；保存不会发起模型请求。";
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
    private static string AiStateName(string value) => value switch { "running"=>"调查中", "waiting"=>"等待回答", "complete"=>"已完成", "cancelled"=>"已停止", "limited"=>"已达到预算", "failed"=>"未完成", _=>value };
    private void UpdateAiDisclosure(JsonObject? connection)
    {
        if(connection is null) { AiConnectionDisclosure="尚未选择连接。"; return; }
        var main=connection["main_model_enabled"]?.GetValue<bool>()!=false;
        var decision=connection["decision"];
        AiConnectionDisclosure=(main ? "主模型："+Text(connection,"model")+" · "+Text(connection,"base_url") : "主模型未启用")+
            (decision is null ? "\n未配置结构化决策服务。" : "\n决策服务："+(Text(decision,"provider") is { Length:>0 } provider ? provider : "jev")+" · "+Text(decision,"model")+" · "+Text(decision,"base_url"))+
            "\n"+(Text(connection,"routing_strategy")=="main_only" ? "当前策略直接使用主模型。" : "优先使用本地信息与结构化决策；确有需要时升级到此处披露的主模型。")+"只发送相对路径、统计及您提交的回答。";
    }
    private void ApplyAi(JsonNode value)
    {
        var same=aiId==Text(value,"id"); var answers=AiQuestions.ToDictionary(q=>q.Id,q=>q.Answer);
        aiState=(JsonObject)value.DeepClone(); aiId=Text(value,"id");
        UpdateAiDisclosure(aiState["connection"] as JsonObject);
        AiSummary=Text(value,"summary");
        AiStatus=AiStateName(Text(value,"status"))+" · "+Text(value,"activity")+(AiStale ? " · 索引已变化或调查超过 24 小时，请新建。" : "")+
            (Text(value,"issue") is { Length:>0 } issue ? "\n"+issue : "");
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
