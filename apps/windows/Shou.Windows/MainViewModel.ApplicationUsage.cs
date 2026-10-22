using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private bool applicationUsageAvailable;
    private string applicationUsageSummary="";
    public string ApplicationUsageSummary { get=>applicationUsageSummary;private set=>SetProperty(ref applicationUsageSummary,value); }
    public IAsyncRelayCommand MeasureApplicationUsageCommand { get;private set; }=null!;
    private void InitializeApplicationUsage()
    {
        MeasureApplicationUsageCommand=new AsyncRelayCommand(()=>RunAsync(MeasureApplicationUsageAsync),()=>applicationUsageAvailable && CanEditRuleSettings &&
            registeredApplicationScanId is not null && SelectedRegisteredApplication is not null);
        commands.Add(MeasureApplicationUsageCommand);
    }
    private async Task MeasureApplicationUsageAsync()
    {
        var row=SelectedRegisteredApplication!;var scan=registeredApplicationScanId!;
        ApplicationUsageSummary=T("正在测量所选应用的安装目录…");ProgressVisible=true;
        try {
            var usage=await client.RequestAsync("applications.usage",new() { ["scan_id"]=scan,["application_id"]=row.Id },cancellation:Token);
            if(registeredApplicationScanId!=scan || !allRegisteredApplications.Contains(row))return;
            var partial=Text(usage,"status")!="complete";
            var bytes=usage["allocated_bytes"]?.GetValue<long>() ?? throw new InvalidOperationException(T("占用测量缺少容量。"));
            row.SetMeasurement(bytes,partial);
            ApplicationUsageSummary=Text(usage,"path")+"\n"+F("实测占用 {0} · 逻辑大小 {1} · {2} 个文件",Bytes(bytes),Bytes(usage["logical_bytes"]?.GetValue<long>() ?? 0),usage["file_count"]?.GetValue<int>() ?? 0)+
                (partial ? T("\n部分目录未完成测量，当前数值仅为已观察到的估计。") : T("\n本次目录遍历已完成，文件仍可能变化。"))+
                T("\n只测量登记的安装目录；可能包含共享文件，不包含全部关联数据，也不代表可释放空间或删除授权。不同应用的结果不应直接相加。");
            var issues=Array(usage["issues"]);
            if(issues.Length>0)ApplicationUsageSummary+="\n"+string.Join(T("、"),issues.Select(item=>ApplicationUsageIssue(item?.GetValue<string>() ?? "")));
        } catch(BridgeException error) {
            ApplicationUsageSummary=ApplicationUsageIssue(error.Code);
        }
    }
    private static string ApplicationUsageIssue(string code)=>code switch {
        "plan_stale"=>T("应用登记已变化或扫描已过期，请重新扫描。"),
        "cancelled" or "request_cancelled"=>T("占用测量已停止，未改变应用文件。"),
        "measurement_timeout" or "request_timeout"=>T("占用测量达到时间上限。"),
        "entry_limit" or "depth_limit"=>T("占用测量达到数量或深度上限。"),
        "directory_changed"=>T("测量期间目录发生变化。"),
        "permission_denied" or "entry_unavailable" or "directory_unavailable" or "directory_read_failed"=>T("部分内容无法读取，可能受权限、链接或在线文件限制。"),
        _=>T("无法完整测量此安装目录，登记大小仍可单独参考。")
    };
    internal void VerifyApplicationUsageLayout()
    {
        applicationUsageAvailable=true;registeredApplicationScanId="layout-usage";SelectedRegisteredApplication=RegisteredApplications.First();
        if(!MeasureApplicationUsageCommand.CanExecute(null))throw new InvalidOperationException("Current application selection did not enable measurement.");
        SelectedRegisteredApplication.SetMeasurement(8192,true);
        ApplicationUsageSummary=T("部分目录未完成测量，当前数值仅为已观察到的估计。")+T("\n只测量登记的安装目录；可能包含共享文件，不包含全部关联数据，也不代表可释放空间或删除授权。不同应用的结果不应直接相加。");
        registeredApplicationScanId=null;
        if(MeasureApplicationUsageCommand.CanExecute(null))throw new InvalidOperationException("Stale selection retained measurement authority.");
    }
}
