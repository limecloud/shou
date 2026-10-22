using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record StartupFilterRow(string Id, string Name);
public sealed record StartupItemRow(string Id, string Digest, string Name, string Path, string Source, string Program, string Configured, string Runtime, string Target, string Capability)
{
    public bool CanToggle => Capability=="windows_user_task" && Configured is "enabled" or "disabled";
    public string State => Configured switch { "enabled"=>T("已启用"), "disabled"=>T("已停用"), _=>T("未知") };
    public string Activity => Runtime switch { "running"=>T("正在运行"), "queued"=>T("等待运行"), "not_running"=>T("未运行"), _=>T("未知") };
    public string TargetDescription => Target switch { "missing"=>T("目标缺失，需核实"), "exists"=>T("目标文件存在"), _=>T("目标未核实") };
    public string Management => CanToggle ? T("当前用户任务，可直接启停") : T("在 Windows 中管理");
}

public sealed partial class MainViewModel
{
    private readonly List<StartupItemRow> startupRows=[];
    private bool startupAvailable, startupIncludeSystem, startupEvidenceCurrent;
    private string startupQuery="", startupSummary=T("尚未扫描启动项。"), startupCoverage="";
    private StartupItemRow? selectedStartupItem;
    private StartupFilterRow? selectedStartupFilter;
    public ObservableCollection<StartupItemRow> StartupItems { get; }=[];
    public ObservableCollection<StartupFilterRow> StartupFilters { get; }=[new("all",T("全部状态")),new("enabled",T("已启用")),new("disabled",T("已停用")),new("leftover",T("目标缺失"))];
    public IAsyncRelayCommand ScanStartupCommand { get; private set; }=null!;
    public IAsyncRelayCommand EnableStartupCommand { get; private set; }=null!;
    public IAsyncRelayCommand DisableStartupCommand { get; private set; }=null!;
    public IAsyncRelayCommand StartupSettingsCommand { get; private set; }=null!;
    public IAsyncRelayCommand StartupTaskSchedulerCommand { get; private set; }=null!;
    public IAsyncRelayCommand StartupServicesCommand { get; private set; }=null!;
    public bool StartupCanEdit => !IsBusy && !AiBusy;
    public bool StartupIncludeSystem { get=>startupIncludeSystem; set { if(!StartupCanEdit || !SetProperty(ref startupIncludeSystem,value))return; startupEvidenceCurrent=false;startupRows.Clear();ApplyStartupFilter();StartupSummary=T("范围已变更，请重新扫描。");StartupCoverage=""; } }
    public string StartupQuery { get=>startupQuery; set { if(SetProperty(ref startupQuery,value))ApplyStartupFilter(); } }
    public string StartupSummary { get=>startupSummary; private set=>SetProperty(ref startupSummary,value); }
    public string StartupCoverage { get=>startupCoverage; private set=>SetProperty(ref startupCoverage,value); }
    public StartupItemRow? SelectedStartupItem { get=>selectedStartupItem; set=>SetProperty(ref selectedStartupItem,value); }
    public StartupFilterRow? SelectedStartupFilter { get=>selectedStartupFilter; set { if(SetProperty(ref selectedStartupFilter,value))ApplyStartupFilter(); } }

    private void InitializeStartup()
    {
        selectedStartupFilter=StartupFilters[0];
        bool Ready()=>startupAvailable && StartupCanEdit;
        ScanStartupCommand=new AsyncRelayCommand(()=>RunAsync(ScanStartupAsync),Ready);
        EnableStartupCommand=new AsyncRelayCommand(()=>ChangeStartupAsync("enable"),()=>Ready() && startupEvidenceCurrent && SelectedStartupItem is { CanToggle:true,Configured:"disabled" });
        DisableStartupCommand=new AsyncRelayCommand(()=>ChangeStartupAsync("disable"),()=>Ready() && startupEvidenceCurrent && SelectedStartupItem is { CanToggle:true,Configured:"enabled" });
        StartupSettingsCommand=new AsyncRelayCommand(()=>RunAsync(()=> { dialogs.OpenStartupSettings();return Task.CompletedTask; }),()=>StartupCanEdit);
        StartupTaskSchedulerCommand=new AsyncRelayCommand(()=>RunAsync(()=> { dialogs.OpenStartupConsole(false);return Task.CompletedTask; }),()=>StartupCanEdit);
        StartupServicesCommand=new AsyncRelayCommand(()=>RunAsync(()=> { dialogs.OpenStartupConsole(true);return Task.CompletedTask; }),()=>StartupCanEdit);
        commands.AddRange([ScanStartupCommand,EnableStartupCommand,DisableStartupCommand,StartupSettingsCommand,StartupTaskSchedulerCommand,StartupServicesCommand]);
        PropertyChanged+=(_,e)=> { if(e.PropertyName is nameof(IsBusy) or nameof(AiBusy))OnPropertyChanged(nameof(StartupCanEdit)); };
    }
    private void ApplyStartupFilter()
    {
        var previous=SelectedStartupItem?.Id;var query=StartupQuery.Trim();
        var filter=SelectedStartupFilter?.Id ?? "all";
        StartupItems.Clear();
        foreach(var row in startupRows.Where(row=>(filter=="all" || filter=="enabled" && row.Configured=="enabled" || filter=="disabled" && row.Configured=="disabled" || filter=="leftover" && row.Target=="missing") &&
            (query.Length==0 || new[] { row.Name,row.Path,row.Source,row.Program }.Any(value=>value.Contains(query,StringComparison.OrdinalIgnoreCase)))))StartupItems.Add(row);
        SelectedStartupItem=StartupItems.FirstOrDefault(row=>row.Id==previous);
    }
    private async Task ScanStartupAsync()
    {
        startupEvidenceCurrent=false;
        StartupSummary=T("正在读取启动项；现有结果暂不能用于启停。失败或取消后请重新扫描。");
        var result=await client.RequestAsync("startup.scan",new() { ["include_system"]=StartupIncludeSystem },cancellation:Token);
        var inventory=result["inventory"] ?? throw new InvalidOperationException(T("启动项结果缺少来源清单。"));
        startupRows.Clear();
        foreach(var item in Array(result["items"])) {
            var definition=item?["definition"];
            startupRows.Add(new(Text(definition,"id"),Text(item,"digest"),Text(definition,"display_name") is { Length:>0 } display ? display : Text(definition,"label"),Text(definition,"path"),StartupSourceName(Text(definition,"source_id")),Text(definition,"program_path"),Text(definition,"configured_state"),Text(definition,"runtime_state"),Text(definition,"target_state"),Text(definition,"control_capability")));
        }
        startupEvidenceCurrent=true;ApplyStartupFilter();
        var partial=Text(inventory,"status")!="complete";
        StartupSummary=F("发现 {0} 个已声明来源中的启动项。",startupRows.Count)+(partial ? T("部分来源未能完整检查，请查看覆盖范围。") : T("已完成本次声明来源的读取。"))+T(" 运行状态是扫描时的观察；未知状态不表示已停用。");
        var coverage=new List<string>();
        foreach(var source in Array(inventory["sources"])) {
            var id=Text(source?["location"],"id");
            coverage.Add(F("{0}：{1}；检查 {2} 项，识别 {3} 个启动项\n{4}",StartupSourceName(id),StartupCoverageState(Text(source,"status")),source?["entry_count"],source?["definition_count"],Text(source?["location"],"path")));
        }
        foreach(var issue in Array(inventory["issues"]))coverage.Add(F("{0}：{1} · {2}",StartupSourceName(Text(issue,"source_id")),Text(issue,"code"),Text(issue,"path")));
        var unavailable=Array(inventory["unavailable_sources"]).Select(value=>value?.GetValue<string>() ?? "").Select(value=>value switch { "packaged_app_startup_tasks"=>T("打包应用 StartupTask"), "group_policy_scripts"=>T("组策略登录脚本"), "winlogon_extensions"=>T("Winlogon 扩展"), "shortcut_target_resolution"=>T("启动文件夹快捷方式目标解析"), _=>value });
        coverage.Add(T("尚未覆盖：")+string.Join(T("、"),unavailable));
        coverage.Add(T("注册表和启动文件夹的有效启用状态可能由 Windows 策略或启动设置决定；本次不推断该状态，也不直接修改未公开的 StartupApproved 数据。"));
        StartupCoverage=string.Join("\n\n",coverage);Status=T("启动项读取完成；启停操作仍需单独确认。");
    }
    private Task ChangeStartupAsync(string action)=>RunAsync(async()=> {
        var row=SelectedStartupItem;if(row is null || !row.CanToggle || !startupEvidenceCurrent)return;
        startupEvidenceCurrent=false;
        StartupSummary=T("正在核验所选任务；操作中止或结果未核实后，请重新扫描再继续。");
        var result=await client.RequestAsync("startup.control",new() { ["include_system"]=StartupIncludeSystem,["definition_id"]=row.Id,["definition_digest"]=row.Digest,["action"]=action },confirm:review=>dialogs.ConfirmAsync(review,Token),cancellation:Token);
        await ScanStartupAsync();
        Status=Text(result,"configured_state")=="enabled" ? T("所选任务已启用并核验，不会立即启动任务。") : T("所选任务已停用并核验；正在运行的实例会继续运行。");
    });
    private static string StartupCoverageState(string state)=>state switch { "complete"=>T("读取完成"), "missing"=>T("位置不存在"), "partial"=>T("部分结果"), "not_scanned"=>T("预算内未读取"), _=>T("无法读取") };
    private static string StartupSourceName(string id)=>id switch {
        "windows.user_run"=>T("当前用户 Run"), "windows.user_run_once"=>T("当前用户 RunOnce"), "windows.user_startup"=>T("当前用户启动文件夹"),
        "windows.machine_run64"=>T("全机 Run（64 位）"), "windows.machine_run32"=>T("全机 Run（32 位）"), "windows.machine_run_once64"=>T("全机 RunOnce（64 位）"), "windows.machine_run_once32"=>T("全机 RunOnce（32 位）"),
        "windows.machine_startup"=>T("公共启动文件夹"), "windows.scheduled_tasks"=>T("登录与开机计划任务"), "windows.services"=>T("自动启动与停用的系统服务"), _=>id
    };
}
