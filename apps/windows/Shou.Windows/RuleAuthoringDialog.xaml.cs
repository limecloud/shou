using System.ComponentModel;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using Microsoft.Win32;
using Shou.Windows.Services;

namespace Shou.Windows;

/// <summary>Owns form state; rule generation, validation and scanning stay in the shared core.</summary>
public partial class RuleAuthoringDialog : Window
{
    private readonly BridgeProcessClient client;
    private readonly WorkspaceRow workspace;
    private readonly JsonObject? original;
    private readonly CancellationToken cancellation;
    private readonly string ruleId="personal."+Guid.NewGuid().ToString("N");
    private CancellationTokenSource? active;
    private bool initialized, busy, closeWhenIdle, layoutVerification;
    private int step;
    private string? previewedJson, reviewedRevision, validatedText;
    public JsonNode? SavedRule { get; private set; }
    private bool Editing => original is not null;
    private static string Text(JsonNode? node,string key)=>node?[key]?.GetValue<string>() ?? "";
    private static string Pretty(JsonNode value)=>value.ToJsonString(new JsonSerializerOptions { WriteIndented=true });
    private static JsonArray Lines(string value)=>new(value.Split(['\r','\n'],StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries).Select(line=>(JsonNode?)JsonValue.Create(line)).ToArray());

    public RuleAuthoringDialog(Window? owner,BridgeProcessClient client,WorkspaceRow workspace,CancellationToken cancellation,JsonObject? original=null)
    {
        this.client=client;this.workspace=workspace;this.cancellation=cancellation;this.original=original?.DeepClone().AsObject();
        InitializeComponent();if(owner is not null)Owner=owner;
        Title=Editing ? "编辑个人规则" : "创建个人规则";Heading.Text=Title;
        WorkspacePath.Text=workspace.Path+(Editing ? "\n"+Text(original,"id")+" · "+Text(original,"version") : "");
        if(original is not null)RuleJson.Text=Pretty(original);
        initialized=true;UpdateState();
    }
    private async void LoadedEditor(object sender,RoutedEventArgs e)
    {
        if(!Editing || layoutVerification)return;
        await WorkAsync(async token=> {
            var result=await client.RequestAsync("rules.revision",new() { ["rule_id"]=Text(original,"id"),["version"]=Text(original,"version") },cancellation:token);
            token.ThrowIfCancellationRequested();RuleJson.Text=Pretty(result["rule"]!);
        });
    }
    internal void VerifyLayout()
    {
        layoutVerification=true;
        for(step=0;step<3;step++) { UpdateState();Measure(new Size(800,780));Arrange(new Rect(0,0,800,780));UpdateLayout(); }
        step=0;UpdateState();
    }
    private void DraftChanged(object sender,RoutedEventArgs e)
    {
        if(!initialized)return;
        previewedJson=null;reviewedRevision=null;validatedText=null;
        PreviewRows.ItemsSource=null;PreviewSummary.Text="";Coverage.Text="";Issue.Text="";UpdateState();
    }
    private void UpdateState()
    {
        if(!initialized)return;
        Wizard.Visibility=Editing ? Visibility.Collapsed : Visibility.Visible;
        Revision.Visibility=Editing ? Visibility.Visible : Visibility.Collapsed;
        ScopePage.Visibility=step==0 ? Visibility.Visible : Visibility.Collapsed;
        ConditionsPage.Visibility=step==1 ? Visibility.Visible : Visibility.Collapsed;
        PreviewPage.Visibility=step==2 ? Visibility.Visible : Visibility.Collapsed;
        Steps.Text=step switch { 0=>"1. 规则范围   →   2. 条件与保留   →   3. 只读预览",1=>"1. 规则范围   →   2. 条件与保留（当前）   →   3. 只读预览",_=>"1. 规则范围   →   2. 条件与保留   →   3. 只读预览（当前）" };
        ScopeFields.IsEnabled=ConditionFields.IsEnabled=RuleJson.IsEnabled=!busy;
        Age.IsEnabled=UseAge.IsChecked==true;
        ChooseTarget.Visibility=TargetMode.SelectedIndex==0 ? Visibility.Visible : Visibility.Collapsed;
        TargetLabel.Text=TargetMode.SelectedIndex==0 ? "工作区内的目录（相对路径或完整路径）" : "相对于工作区的模式（每行一个）";
        BackButton.Visibility=!Editing && step>0 ? Visibility.Visible : Visibility.Collapsed;BackButton.IsEnabled=!busy;
        NextButton.Visibility=!Editing && step<2 ? Visibility.Visible : Visibility.Collapsed;NextButton.IsEnabled=!busy;
        NextButton.Content=step==0 ? "继续" : "预览规则";
        PreviewAgainButton.Visibility=!Editing && step==2 ? Visibility.Visible : Visibility.Collapsed;PreviewAgainButton.IsEnabled=!busy;
        ValidateButton.Visibility=Editing ? Visibility.Visible : Visibility.Collapsed;ValidateButton.IsEnabled=!busy;
        SaveButton.Visibility=Editing || step==2 ? Visibility.Visible : Visibility.Collapsed;
        SaveButton.Content=Editing ? "保存新版本" : "保存草稿";
        SaveButton.IsEnabled=!busy && (Editing ? validatedText==RuleJson.Text : previewedJson is not null);
        SaveButton.IsDefault=SaveButton.IsEnabled;NextButton.IsDefault=!Editing && step<2;
        StopButton.Visibility=busy && !Editing && step==2 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void ChooseTargetFolder(object sender,RoutedEventArgs e)
    {
        var picker=new OpenFolderDialog { Title="选择当前工作区内可重新生成的目录",InitialDirectory=workspace.Path };
        if(picker.ShowDialog(this)==true)Targets.Text=picker.FolderName;
    }
    private void Back(object sender,RoutedEventArgs e) { if(!busy && step>0) { step--;Issue.Text="";UpdateState(); } }
    private async void Next(object sender,RoutedEventArgs e)
    {
        if(busy)return;
        if(step==0) {
            if(string.IsNullOrWhiteSpace(RuleName.Text) || string.IsNullOrWhiteSpace(Targets.Text)) { Issue.Text="填写规则名称，并选择目录或输入相对模式。";return; }
            if(!int.TryParse(Depth.Text.Trim(),NumberStyles.None,CultureInfo.InvariantCulture,out var depth) || depth is <1 or >32) { Issue.Text="最大发现深度必须是 1–32 的整数。";return; }
            step=1;Issue.Text="";UpdateState();return;
        }
        step=2;UpdateState();await PreviewAsync();
    }
    private async Task<JsonNode> BuildDraftAsync(CancellationToken token)
    {
        if(!long.TryParse(MinimumMB.Text.Trim(),NumberStyles.None,CultureInfo.InvariantCulture,out var mb) || mb<0 || mb>long.MaxValue/1_000_000)throw new InvalidOperationException("最小 MB 必须是非负整数。相乘后不能溢出。");
        if(!int.TryParse(Depth.Text.Trim(),NumberStyles.None,CultureInfo.InvariantCulture,out var depth) || depth is <1 or >32)throw new InvalidOperationException("最大发现深度必须是 1–32 的整数。");
        int? days=null;
        if(UseAge.IsChecked==true) {
            if(!int.TryParse(Age.Text.Trim(),NumberStyles.None,CultureInfo.InvariantCulture,out var age) || age is <0 or >3650)throw new InvalidOperationException("保留天数必须是 0–3650 的整数。");
            days=age;
        }
        return await client.RequestAsync("rules.draft",new() { ["workspace_id"]=workspace.Id,["rule_id"]=ruleId,["mode"]=TargetMode.SelectedIndex==0 ? "folder" : "patterns",["folder"]=Targets.Text.Trim(),
            ["fields"]=new JsonObject { ["name"]=RuleName.Text,["relative_patterns"]=TargetMode.SelectedIndex==0 ? new JsonArray() : Lines(Targets.Text),["project_markers"]=Lines(Markers.Text),["exclusions"]=Lines(Exclusions.Text),["max_depth"]=depth,["minimum_allocated_bytes"]=mb*1_000_000,["minimum_age_days"]=days,["rebuild_note"]=Rebuild.Text,["limitations"]=Lines(Limitations.Text),["high_risk"]=HighRisk.IsChecked==true } },cancellation:token);
    }
    private async void PreviewAgain(object sender,RoutedEventArgs e)=>await PreviewAsync();
    private async Task PreviewAsync()
    {
        previewedJson=null;reviewedRevision=null;PreviewRows.ItemsSource=null;PreviewSummary.Text="正在预览…";Coverage.Text="";
        await WorkAsync(async token=> {
            var draft=await BuildDraftAsync(token);
            var progress=new Progress<JsonObject>(value=> { if(busy)Issue.Text="正在只读检查 · "+ProgressPresentation.ShortPath(Text(value,"path")); });
            var result=await client.RequestAsync("rules.draft.preview",new() { ["workspace_id"]=workspace.Id,["json"]=Text(draft,"json") },progress:progress,cancellation:token);
            token.ThrowIfCancellationRequested();
            previewedJson=Text(result,"json");reviewedRevision=Text(result,"configuration_revision");Issue.Text="";
            PreviewSummary.Text=$"{result["matched_count"]} 项满足条件 · {result["blocked_count"]} 项受保护 · {result["not_matched_count"]} 项不满足条件"+(Text(result,"status")=="complete" ? "" : "\n预览部分完成，无法读取或未完成的范围不算完整覆盖。");
            PreviewRows.ItemsSource=(result["rows"] as JsonArray ?? []).Select(row=>new RulePreviewRow(Text(row,"path"),MainViewModel.Bytes(row?["allocated_bytes"]?.GetValue<long>() ?? 0),Decision(row))).ToArray();
            Coverage.Text="仅测量规则范围内、发现深度和扫描预算允许的目录；这不是完整空间分析。显示前 200 项，总计 "+result["total_count"]+" 项。\n"+string.Join("\n",(result["issues"] as JsonArray ?? []).Select(value=>value?.GetValue<string>()));
        });
        if(previewedJson is null)PreviewSummary.Text="预览未完成。重新预览成功后才能保存。";
    }
    private JsonObject RevisionInput()=>new() { ["json"]=RuleJson.Text,["original_rule_id"]=Text(original,"id") };
    private async Task<JsonNode> ValidateRevisionAsync(CancellationToken token)
    {
        validatedText=null;
        if(Encoding.UTF8.GetByteCount(RuleJson.Text)>262144)throw new InvalidOperationException("规则超过 256 KiB。请缩小定义。");
        var result=await client.RequestAsync("rules.validate",RevisionInput(),cancellation:token);
        token.ThrowIfCancellationRequested();validatedText=RuleJson.Text;
        Issue.Text="规则有效。可保存为新的停用版本，旧版本和绑定继续保留。";return result;
    }
    private async void Validate(object sender,RoutedEventArgs e)=>await WorkAsync(async token=> { _=await ValidateRevisionAsync(token); });
    private async void Save(object sender,RoutedEventArgs e)
    {
        if(!SaveButton.IsEnabled)return;
        await WorkAsync(async token=> {
            JsonObject input;
            if(Editing) {
                var validated=await ValidateRevisionAsync(token);
                input=new() { ["json"]=Text(validated,"json"),["original_rule_id"]=Text(original,"id"),["configuration_revision"]=Text(validated,"configuration_revision") };
            } else {
                var current=await BuildDraftAsync(token);
                if(previewedJson is null || Text(current,"json")!=previewedJson)throw new InvalidOperationException("规则已改变，请重新预览后保存。");
                input=new() { ["workspace_id"]=workspace.Id,["json"]=previewedJson,["configuration_revision"]=reviewedRevision };
            }
            input["require_new_version"]=true;
            SavedRule=await client.RequestAsync("rules.import",input,cancellation:token);
        });
        if(SavedRule is not null)DialogResult=true;
    }
    private async Task WorkAsync(Func<CancellationToken,Task> action)
    {
        if(busy)return;
        using var operation=CancellationTokenSource.CreateLinkedTokenSource(cancellation);active=operation;busy=true;Issue.Text="";UpdateState();
        try { await action(operation.Token); }
        catch(BridgeException error) {
            if(error.Code is "plan_stale" or "version_conflict" or "cancelled") { previewedJson=null;reviewedRevision=null;validatedText=null; }
            Issue.Text=error.Code+"："+error.Message+(error.Details?["issues"]?.GetValue<string>() is { } issues ? "\n"+issues : "");
        }
        catch(OperationCanceledException) { previewedJson=null;reviewedRevision=null;validatedText=null;Issue.Text="操作已停止。预览或校验未完成时不能保存。"; }
        catch(Exception error) { Issue.Text=error.Message; }
        finally { busy=false;active=null;UpdateState();if(closeWhenIdle && SavedRule is null)Close(); }
    }
    private void Stop(object sender,RoutedEventArgs e) { previewedJson=null;reviewedRevision=null;active?.Cancel(); }
    private void ClosingEditor(object? sender,CancelEventArgs e)
    {
        if(!busy)return;e.Cancel=true;closeWhenIdle=true;previewedJson=null;validatedText=null;active?.Cancel();Issue.Text="正在停止，请等待当前操作结束。";
    }
    private static string Decision(JsonNode? row)
    {
        var state=Text(row,"status") switch { "matched"=>"满足条件", "blocked"=>"受保护", _=>"不满足条件" };
        var reasons=(row?["reasons"] as JsonArray ?? []).Select(value=>value?.GetValue<string>() switch {
            "rule_minimum_size"=>"低于最小磁盘占用", "rule_recent_modification"=>"内容最近被修改", "rule_missing_markers"=>"父目录缺少普通项目标记", "rule_maximum_depth"=>"超过发现深度",
            "excluded_descendant"=>"包含保留项，整个目标保留", "protected_content"=>"包含受保护内容", "incomplete_scan"=>"目标尚未完整检查", "excluded"=>"命中排除规则", var code=>code ?? "需进一步核实" });
        return state+" · "+string.Join("；",reasons);
    }
}
