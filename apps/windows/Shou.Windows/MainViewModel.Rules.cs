using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record RulePresetRow(string Id,string WorkspaceId,string Label);

public sealed partial class MainViewModel
{
    private bool ruleAuthoringAvailable;
    private int ruleSource,exclusionScope;
    private string presetName="",exclusionProject="",inheritedExclusions="";
    private RulePresetRow? selectedRulePreset;
    public bool CanEditRuleSettings=>!IsBusy && !AiBusy;
    public int RuleSource { get=>ruleSource; set { if(SetProperty(ref ruleSource,Math.Clamp(value,0,2)))LoadRules(); } }
    public string PresetName { get=>presetName; set=>SetProperty(ref presetName,value); }
    public ObservableCollection<RulePresetRow> RulePresets { get; }=[];
    public RulePresetRow? SelectedRulePreset { get=>selectedRulePreset; set=>SetProperty(ref selectedRulePreset,value); }
    public int ExclusionScope { get=>exclusionScope; set { if(SetProperty(ref exclusionScope,Math.Clamp(value,0,2))) { ExclusionPattern="";ExclusionProject="";LoadExclusionScope();OnPropertyChanged(nameof(ProjectExclusionScope)); } } }
    public bool ProjectExclusionScope=>ExclusionScope==2;
    public string ExclusionProject { get=>exclusionProject; set { if(SetProperty(ref exclusionProject,value))LoadExclusionScope(); } }
    public string InheritedExclusions { get=>inheritedExclusions; private set=>SetProperty(ref inheritedExclusions,value); }
    public IAsyncRelayCommand CreateRuleCommand { get; private set; }=null!;
    public IAsyncRelayCommand EditRuleCommand { get; private set; }=null!;
    public IAsyncRelayCommand ExportRuleCommand { get; private set; }=null!;
    public IAsyncRelayCommand SaveRulePresetCommand { get; private set; }=null!;
    public IAsyncRelayCommand ScanRulePresetCommand { get; private set; }=null!;
    private void InitializeRuleAuthoring()
    {
        bool Ready()=>ruleAuthoringAvailable && !IsBusy && !AiBusy;
        CreateRuleCommand=new AsyncRelayCommand(()=>AuthorRuleAsync(false),()=>Ready() && SelectedWorkspace is not null);
        EditRuleCommand=new AsyncRelayCommand(()=>AuthorRuleAsync(true),()=>Ready() && SelectedRule is { IsBuiltin:false });
        ExportRuleCommand=new AsyncRelayCommand(()=>RunAsync(ExportPersonalRuleAsync),()=>!IsBusy && !AiBusy && SelectedRule is { IsBuiltin:false });
        SaveRulePresetCommand=new AsyncRelayCommand(SaveRulePresetAsync,()=>CanEditRuleSettings && SelectedWorkspace is not null && !string.IsNullOrWhiteSpace(PresetName));
        ScanRulePresetCommand=new AsyncRelayCommand(ScanRulePresetAsync,()=>CanEditRuleSettings && SelectedRulePreset is not null);
        commands.AddRange([CreateRuleCommand,EditRuleCommand,ExportRuleCommand,SaveRulePresetCommand,ScanRulePresetCommand]);
        PropertyChanged+=(_,args)=> { if(args.PropertyName is nameof(IsBusy) or nameof(AiBusy))OnPropertyChanged(nameof(CanEditRuleSettings)); };
    }
    private void LoadRuleSettings()
    {
        var selected=SelectedRulePreset?.Id;
        RulePresets.Clear();
        foreach(var preset in Array(configuration?["configuration"]?["presets"])) {
            var workspace=Workspaces.FirstOrDefault(item=>item.Id==Text(preset,"workspace_id"));
            if(workspace is not null)RulePresets.Add(new(Text(preset,"id"),workspace.Id,Text(preset,"name")+" · "+workspace.Path));
        }
        SelectedRulePreset=RulePresets.FirstOrDefault(item=>item.Id==selected);
        LoadExclusionScope();
    }
    private void LoadExclusionScope()
    {
        Exclusions.Clear();SelectedExclusion=null;
        var global=Array(configuration?["configuration"]?["global_exclusions"]).Select(item=>item?.GetValue<string>() ?? "").ToArray();
        var workspace=Array(configuration?["configuration"]?["workspaces"]).FirstOrDefault(item=>Text(item,"id")==SelectedWorkspace?.Id);
        var patterns=ExclusionScope==0 ? global : Array(workspace?["exclusions"]).Select(item=>item?.GetValue<string>() ?? "");
        if(ExclusionScope==2)patterns=patterns.Where(pattern=>!string.IsNullOrWhiteSpace(ExclusionProject) && pattern.StartsWith(ExclusionProject+"/",StringComparison.OrdinalIgnoreCase));
        foreach(var pattern in patterns)Exclusions.Add(pattern);
        InheritedExclusions=ExclusionScope==0 || global.Length==0 ? "" : "继承的全局排除（请在“所有工作区”中管理）：\n"+string.Join("\n",global);
    }
    private Task SaveRulePresetAsync()=>RunAsync(async()=> {
        var result=await client.RequestAsync("presets.save",new() { ["name"]=PresetName.Trim(),["workspace_id"]=SelectedWorkspace!.Id,["configuration_revision"]=Text(configuration?["configuration"],"revision") },cancellation:Token);
        ResetCleanupReview();await LoadConfigurationAsync();
        SelectedRulePreset=RulePresets.FirstOrDefault(item=>item.Id==Text(result,"id"));PresetName="";
        Status="已保存当前目录启用的规则选择。使用时重新扫描，不会自动启用已停用的规则。";
    });
    private Task ScanRulePresetAsync()=>RunAsync(async()=> {
        var preset=SelectedRulePreset ?? throw new InvalidOperationException("请选择已保存的规则选择。");
        SelectedWorkspace=Workspaces.FirstOrDefault(item=>item.Id==preset.WorkspaceId) ?? throw new InvalidOperationException("工作区已变化，请刷新后重试。");
        standardScan=false;ResetCleanupReview();
        var result=await client.RequestAsync("presets.scan",new() { ["preset_id"]=preset.Id },Progress(),cancellation:Token);
        RememberCleanupScan(result);await LoadCleanupReviewAsync(true);SelectedSection=0;
        Status="已按保存的规则选择重新扫描。请审阅当前结果，再选择需要清理的项目。";
    });
    private Task SetScopedExclusionAsync(bool remove)=>RunAsync(async()=> {
        var input=new JsonObject { ["pattern"]=remove ? SelectedExclusion : ProjectExclusionScope && string.IsNullOrWhiteSpace(ExclusionPattern) ? "**" : ExclusionPattern,["remove"]=remove };
        if(ExclusionScope!=0)input["workspace_id"]=SelectedWorkspace?.Id ?? throw new InvalidOperationException("请先选择工作区。");
        if(ProjectExclusionScope && !remove)input["project"]=ExclusionProject;
        await client.RequestAsync("exclusions.set",input,cancellation:Token);
        ResetCleanupReview();await LoadConfigurationAsync();
        if(!remove)ExclusionPattern="";
        Status="排除保护已更新，请重新扫描。排除内容也会保护包含它的父级清理目标。";
    });
    private JsonObject SelectedPersonalDefinition()
    {
        var selected=SelectedRule ?? throw new InvalidOperationException("请选择个人规则。");
        if(selected.IsBuiltin)throw new InvalidOperationException("内置规则由系统提供，请创建独立个人规则。");
        return Array(configuration?["configuration"]?["rules"]).Select(record=>record?["rule"]).OfType<JsonObject>()
            .FirstOrDefault(rule=>Text(rule,"id")==selected.Id && Text(rule,"version")==selected.Version)?.DeepClone().AsObject()
            ?? throw new InvalidOperationException("规则已变化，请刷新后重试。");
    }
    private Task AuthorRuleAsync(bool editing)=>RunAsync(async()=> {
        var original=editing ? SelectedPersonalDefinition() : null;
        var workspace=editing ? Workspaces.FirstOrDefault(item=>item.RootRef==Text(original?["scope"],"root_ref")) : SelectedWorkspace;
        workspace ??= editing ? new WorkspaceRow("","工作区未注册 · "+Text(original?["scope"],"root_ref"),Text(original?["scope"],"root_ref")) : throw new InvalidOperationException("请先选择一个工作区。");
        var saved=dialogs.AuthorPersonalRule(client,workspace,Token,original);
        // Refresh even after cancellation: a metadata save may have completed
        // before the dialog observed cancellation or lost its response.
        var revision=Text(configuration?["configuration"],"revision");
        await LoadConfigurationAsync();
        if(revision!=Text(configuration?["configuration"],"revision"))ResetCleanupReview();
        if(saved is not null) {
            var definition=saved["rule"];
            RuleSource=2;
            SelectedRule=Rules.FirstOrDefault(rule=>rule.Id==Text(definition,"id") && rule.Version==Text(definition,"version"));
            Status=editing ? "新版本已保存为停用草稿；旧版本和绑定已保留。预览后再决定是否启用。" : "规则已保存为停用草稿。请逐条预览，再启用并重新扫描。";
        }
    });
    private async Task ExportPersonalRuleAsync()
    {
        var definition=SelectedPersonalDefinition();
        var path=dialogs.ChooseRuleExport(Text(definition,"id"));if(path is null)return;
        var bytes=Encoding.UTF8.GetBytes(definition.ToJsonString(new JsonSerializerOptions { WriteIndented=true }));
        // Exclusive creation preserves any file that appeared after the picker.
        await using var stream=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None);
        await stream.WriteAsync(bytes,Token);await stream.FlushAsync(Token);
        Status="已导出所选版本的规则定义。导出不会启用规则或清理文件。";
    }
}
