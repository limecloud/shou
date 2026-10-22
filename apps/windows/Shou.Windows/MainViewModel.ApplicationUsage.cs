using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private bool applicationUsageAvailable;
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
        row.BeginMeasurement(T("正在测量所选应用的安装目录…"));ProgressVisible=true;
        try {
            var usage=await client.RequestAsync("applications.usage",new() { ["scan_id"]=scan,["application_id"]=row.Id },cancellation:Token);
            if(registeredApplicationScanId!=scan || !allRegisteredApplications.Contains(row))return;
            var partial=Text(usage,"status")!="complete";
            var bytes=usage["allocated_bytes"]?.GetValue<long>() ?? throw new InvalidOperationException(T("占用测量缺少容量。"));
            row.SetMeasurement(bytes,partial);
            row.MeasurementSummary=row.Name+"\n"+Text(usage,"path")+"\n"+F("实测占用 {0} · 逻辑大小 {1} · {2} 个文件",Bytes(bytes),Bytes(usage["logical_bytes"]?.GetValue<long>() ?? 0),usage["file_count"]?.GetValue<int>() ?? 0)+
                (partial ? T("\n部分目录未完成测量，当前数值仅为已观察到的估计。") : T("\n本次目录遍历已完成，文件仍可能变化。"))+
                T("\n只测量登记的安装目录；可能包含共享文件，不包含全部关联数据，也不代表可释放空间或删除授权。不同应用的结果不应直接相加。");
            var issues=Array(usage["issues"]);
            if(issues.Length>0)row.MeasurementSummary+="\n"+string.Join(T("、"),issues.Select(item=>ApplicationUsageIssue(item?.GetValue<string>() ?? "")));
        } catch(BridgeException error) {
            row.MeasurementSummary=ApplicationUsageIssue(error.Code);
        } catch(OperationCanceledException) {
            row.MeasurementSummary=ApplicationUsageIssue("cancelled");
            throw;
        } catch {
            row.MeasurementSummary=ApplicationUsageIssue("");
            throw;
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
        var measured=SelectedRegisteredApplication;
        measured.SetMeasurement(8192,true);
        measured.MeasurementSummary=measured.Name+"\n"+T("部分目录未完成测量，当前数值仅为已观察到的估计。")+T("\n只测量登记的安装目录；可能包含共享文件，不包含全部关联数据，也不代表可释放空间或删除授权。不同应用的结果不应直接相加。");
        SelectedRegisteredApplication=RegisteredApplications.First(row=>row!=measured);
        if(SelectedRegisteredApplication.MeasurementSummary!="" || SelectedRegisteredApplication.MeasuredBytes is not null)
            throw new InvalidOperationException("Switching applications retained another row's measurement.");
        SelectedRegisteredApplication.BeginMeasurement(T("正在测量所选应用的安装目录…"));
        SelectedRegisteredApplication.SetMeasurement(4096,false);
        SelectedRegisteredApplication.BeginMeasurement(T("正在测量所选应用的安装目录…"));
        if(SelectedRegisteredApplication.MeasuredBytes is not null || measured.MeasuredBytes!=8192)
            throw new InvalidOperationException("Remeasurement retained stale bytes or changed another application.");
        SelectedRegisteredApplication=measured;
        registeredApplicationScanId=null;
        if(MeasureApplicationUsageCommand.CanExecute(null))throw new InvalidOperationException("Stale selection retained measurement authority.");
    }
}
