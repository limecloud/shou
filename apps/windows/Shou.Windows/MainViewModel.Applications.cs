using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Shou.Windows;

public sealed class RegisteredApplicationRow(string id,string name,string version,string publisher,string kind,string scope,string location,string size,long? estimatedBytes,string registration,string details,bool canUninstall=false) : ObservableObject
{
    public string Id { get; }=id;
    public string Name { get; }=name;
    public string Version { get; }=version;
    public string Publisher { get; }=publisher;
    public string Kind { get; }=kind;
    public string Scope { get; }=scope;
    public string Location { get; }=location;
    public string Size { get; }=size;
    public long? EstimatedBytes { get; }=estimatedBytes;
    public string Registration { get; }=registration;
    public string Details { get; }=details;
    public bool CanUninstall { get; }=canUninstall;
    private long? measuredBytes;
    private bool measurementPartial;
    public long? MeasuredBytes => measuredBytes;
    public string MeasuredSize => measuredBytes is { } bytes ? (measurementPartial ? T("部分：") : "")+MainViewModel.Bytes(bytes) : T("未测量");
    public void SetMeasurement(long bytes,bool partial) {
        measuredBytes=bytes;measurementPartial=partial;OnPropertyChanged(nameof(MeasuredBytes));OnPropertyChanged(nameof(MeasuredSize));
    }
    private bool selected;
    public bool IsSelected { get=>selected;set=>SetProperty(ref selected,value && CanUninstall); }
}
public sealed record ApplicationCoverageRow(string Source,string State,int Entries,int Applications);
public sealed record RegisteredUninstallReceiptRow(string CreatedAt,string Application,string State,string Details);

public sealed partial class MainViewModel
{
    private bool applicationInventoryAvailable,applicationUninstallAvailable,includeSystemApplications;
    private string? registeredApplicationScanId;
    private string applicationUninstallResult="";
    private int applicationScope;
    private string applicationQuery="",applicationInventorySummary=T("尚未扫描已安装的应用。"),applicationCoverageSummary="";
    private RegisteredApplicationRow? selectedRegisteredApplication;
    private readonly List<RegisteredApplicationRow> allRegisteredApplications=[];
    public ObservableCollection<RegisteredApplicationRow> RegisteredApplications { get; }=[];
    public ObservableCollection<ApplicationCoverageRow> ApplicationCoverage { get; }=[];
    public ObservableCollection<RegisteredUninstallReceiptRow> ApplicationUninstallReceipts { get; }=[];
    public string ApplicationUninstallResult { get=>applicationUninstallResult;private set=>SetProperty(ref applicationUninstallResult,value); }
    public string ApplicationSelectionSummary => F("已选择 {0} 个应用 · 每次最多 20 个。操作前会另行审阅并确认；卸载或清空数据均无法通过 Shou 恢复。",allRegisteredApplications.Count(row=>row.IsSelected));
    public bool IncludeSystemApplications { get=>includeSystemApplications;set=>SetProperty(ref includeSystemApplications,value); }
    public string ApplicationQuery { get=>applicationQuery;set { if(SetProperty(ref applicationQuery,value))FilterRegisteredApplications(); } }
    public int ApplicationScope { get=>applicationScope;set { if(SetProperty(ref applicationScope,Math.Clamp(value,0,3)))FilterRegisteredApplications(); } }
    public RegisteredApplicationRow? SelectedRegisteredApplication { get=>selectedRegisteredApplication;set=>SetProperty(ref selectedRegisteredApplication,value); }
    public string ApplicationInventorySummary { get=>applicationInventorySummary;private set=>SetProperty(ref applicationInventorySummary,value); }
    public string ApplicationCoverageSummary { get=>applicationCoverageSummary;private set=>SetProperty(ref applicationCoverageSummary,value); }
    public IAsyncRelayCommand ScanApplicationsCommand { get;private set; }=null!;
    public IRelayCommand ManageApplicationsCommand { get;private set; }=null!;
    public IRelayCommand CopyApplicationNameCommand { get;private set; }=null!;
    public IRelayCommand SelectApplicationsCommand { get;private set; }=null!;
    public IRelayCommand ClearApplicationSelectionCommand { get;private set; }=null!;
    public IAsyncRelayCommand UninstallApplicationsCommand { get;private set; }=null!;
    public IAsyncRelayCommand ApplicationUninstallHistoryCommand { get;private set; }=null!;
    public IAsyncRelayCommand ReviewApplicationDataCommand { get;private set; }=null!;
    public IAsyncRelayCommand ClearPackageDataCommand { get;private set; }=null!;
    public IAsyncRelayCommand PackageDataHistoryCommand { get;private set; }=null!;
    private bool applicationDataAvailable;
    private bool packageDataAvailable;
    public ObservableCollection<RegisteredUninstallReceiptRow> PackageDataReceipts { get; }=[];
    private void InitializeApplications()
    {
        ScanApplicationsCommand=new AsyncRelayCommand(()=>RunAsync(ScanRegisteredApplicationsAsync),()=>applicationInventoryAvailable && CanEditRuleSettings);
        ManageApplicationsCommand=new RelayCommand(dialogs.OpenApplicationSettings,()=>applicationInventoryAvailable && CanEditRuleSettings);
        CopyApplicationNameCommand=new RelayCommand(()=>System.Windows.Clipboard.SetText(SelectedRegisteredApplication!.Name),()=>SelectedRegisteredApplication is not null && !IsBusy);
        SelectApplicationsCommand=new RelayCommand(()=>SetApplicationSelection(true),()=>!IsBusy && registeredApplicationScanId is not null && RegisteredApplications.Any(row=>row.CanUninstall && !row.IsSelected));
        ClearApplicationSelectionCommand=new RelayCommand(()=>SetApplicationSelection(false),()=>!IsBusy && allRegisteredApplications.Any(row=>row.IsSelected));
        UninstallApplicationsCommand=new AsyncRelayCommand(()=>RunAsync(UninstallRegisteredApplicationsAsync),()=>!IsBusy && !AiBusy && applicationUninstallAvailable && registeredApplicationScanId is not null && allRegisteredApplications.Count(row=>row.IsSelected) is >0 and <=20);
        ApplicationUninstallHistoryCommand=new AsyncRelayCommand(()=>RunAsync(LoadApplicationUninstallHistoryAsync),()=>!IsBusy && applicationUninstallAvailable);
        ReviewApplicationDataCommand=new AsyncRelayCommand(()=>RunAsync(async ()=> {
            dialogs.ReviewApplicationData(client);
            if (!Token.IsCancellationRequested) await LoadHistoryAsync();
        }),()=>applicationDataAvailable && CanEditRuleSettings);
        commands.AddRange([ScanApplicationsCommand,ManageApplicationsCommand,CopyApplicationNameCommand,SelectApplicationsCommand,ClearApplicationSelectionCommand,UninstallApplicationsCommand,ApplicationUninstallHistoryCommand]);
        commands.Add(ReviewApplicationDataCommand);
        ClearPackageDataCommand=new AsyncRelayCommand(()=>RunAsync(ClearPackageDataAsync),()=>packageDataAvailable && CanEditRuleSettings && registeredApplicationScanId is not null &&
            allRegisteredApplications.Count(row=>row.IsSelected) is >0 and <=20 && allRegisteredApplications.Where(row=>row.IsSelected).All(row=>row.Kind=="MSIX"));
        PackageDataHistoryCommand=new AsyncRelayCommand(()=>RunAsync(LoadPackageDataHistoryAsync),()=>packageDataAvailable && CanEditRuleSettings);
        commands.AddRange([ClearPackageDataCommand,PackageDataHistoryCommand]);
        InitializeApplicationUsage();
    }
    private void SetApplicationSelection(bool selected)
    {
        foreach(var row in selected ? RegisteredApplications : allRegisteredApplications.AsEnumerable()) row.IsSelected=selected;
        OnPropertyChanged(nameof(ApplicationSelectionSummary));RefreshCommands();
    }
    private void FilterRegisteredApplications()
    {
        var selection=SelectedRegisteredApplication?.Id;
        RegisteredApplications.Clear();
        foreach(var row in allRegisteredApplications.Where(row=>
            (ApplicationScope==0 || ApplicationScope==1 && row.Scope==T("当前用户") && row.Kind!="MSIX" || ApplicationScope==2 && row.Scope==T("全机") || ApplicationScope==3 && row.Kind=="MSIX") &&
            (string.IsNullOrWhiteSpace(ApplicationQuery) || new[] {row.Name,row.Publisher,row.Version,row.Location,row.Registration}.Any(value=>value.Contains(ApplicationQuery.Trim(),StringComparison.CurrentCultureIgnoreCase)))))RegisteredApplications.Add(row);
        SelectedRegisteredApplication=RegisteredApplications.FirstOrDefault(row=>row.Id==selection);
    }
    private async Task ScanRegisteredApplicationsAsync()
    {
        registeredApplicationScanId=null;
        ApplicationUsageSummary="";
        allRegisteredApplications.Clear();RegisteredApplications.Clear();ApplicationCoverage.Clear();SelectedRegisteredApplication=null;
        ApplicationInventorySummary=T("正在读取已安装的应用…");ApplicationCoverageSummary="";
        ProgressVisible=true;
        var response=await client.RequestAsync(applicationUninstallAvailable ? "applications.prepare-scan" : "applications.scan",new() { ["include_system"]=IncludeSystemApplications },cancellation:Token);
        var result=applicationUninstallAvailable ? response["catalog"]! : response;
        if(applicationUninstallAvailable) registeredApplicationScanId=Text(response,"id");
        ProgressVisible=false;
        static string Source(string id)=>id switch {
            "windows.user_uninstall64"=>T("当前用户 · 64 位注册表"), "windows.user_uninstall32"=>T("当前用户 · 32 位注册表"),
            "windows.machine_uninstall64"=>T("全机 · 64 位注册表"), "windows.machine_uninstall32"=>T("全机 · 32 位注册表"),
            "windows.user_packages"=>T("当前用户 · MSIX 包"),_=>id };
        foreach(var source in Array(result["sources"])) {
            var state=Text(source,"status") switch { "complete"=>T("已读取"), "missing"=>T("来源不存在"), "partial"=>T("部分读取"), "unavailable"=>T("不可读取"), "not_scanned"=>T("未扫描"),_=>T("未知") };
            ApplicationCoverage.Add(new(Source(Text(source?["source"],"id")),state,source?["entry_count"]?.GetValue<int>() ?? 0,source?["application_count"]?.GetValue<int>() ?? 0));
        }
        foreach(var item in Array(result["items"])) {
            var source=Text(item,"source_id");var kind=Text(item,"kind") switch { "msi"=>"MSI", "msix"=>"MSIX",_=>T("桌面应用") };
            long? size=item?["estimated_bytes"]?.GetValue<long>();
            bool? uninstall=item?["uninstall_available"]?.GetValue<bool>();
            var note=uninstall switch { true=>T("已登记卸载入口；选择后将重新核验注册和卸载程序的身份。"),false=>T("未登记可用卸载入口。"),_=>T("由 Windows 包管理器核验 MSIX 卸载资格。") };
            if(item?["system_component"]?.GetValue<bool>()==true)note=T("系统组件或包依赖。\n")+note;
            var details=note+T("\n来源：")+Source(source)+T("\n注册标识：")+Text(item,"registration")+T("\n包系列：")+Text(item,"package_family_name")+T("\n安装位置为登记值；大小为安装程序登记的估计，未实测。");
            var row=new RegisteredApplicationRow(Text(item,"id"),Text(item,"name"),Text(item,"version"),Text(item,"publisher"),kind,source.StartsWith("windows.machine_",StringComparison.Ordinal)?T("全机"):T("当前用户"),Text(item,"install_location"),size is { } bytes?Bytes(bytes):T("未知"),size,Text(item,"registration"),details,applicationUninstallAvailable && item?["system_component"]?.GetValue<bool>()!=true && (uninstall==true || kind=="MSIX"));
            row.PropertyChanged+=(_,args)=> { if(args.PropertyName==nameof(RegisteredApplicationRow.IsSelected)) { OnPropertyChanged(nameof(ApplicationSelectionSummary));RefreshCommands(); } };
            allRegisteredApplications.Add(row);
        }
        FilterRegisteredApplications();
        ApplicationInventorySummary=F("发现 {0} 个已注册应用 · 有大小记录 {1} 个 · {2}",allRegisteredApplications.Count,allRegisteredApplications.Count(row=>row.EstimatedBytes is not null),(Text(result,"status")=="complete"?T("声明来源已读取"):T("部分来源未完整读取")));
        var omitted=Array(result["unavailable_sources"]).Select(value=>(value?.GetValue<string>() ?? "") switch {
            "other_accounts"=>T("其他账户"), "unregistered_portable_applications"=>T("未注册的便携应用"), "custom_unregistered_installations"=>T("自定义未注册安装"),
            "application_data_ownership"=>T("应用数据归属"), "measured_disk_usage"=>T("实测空间"), "last_used_time"=>T("最近使用时间"),var other=>other });
        ApplicationCoverageSummary=T("盘点当前用户和全机的程序注册、当前用户的 MSIX 包。未覆盖：")+string.Join(T("、"),omitted)+T("。来源读取失败不能用于判断应用已卸载。");
        var issues=Array(result["issues"]);
        if(issues.Length>0)ApplicationCoverageSummary+=T("\n读取问题：")+string.Join(T("；"),issues.Take(20).Select(issue=>Text(issue,"code")+" · "+Text(issue,"path")));
        OnPropertyChanged(nameof(ApplicationSelectionSummary));RefreshCommands();
        if(applicationUninstallAvailable) await LoadApplicationUninstallHistoryAsync();
        if(packageDataAvailable) await LoadPackageDataHistoryAsync();
        Status=T("应用盘点完成，未选择任何应用。卸载前会重新核验并显示所属卸载器的影响。");
    }
    private async Task UninstallRegisteredApplicationsAsync()
    {
        ApplicationUninstallResult="";ProgressVisible=true;Status=T("正在核验所选应用和卸载程序…");
        try {
            var receipt=await client.RequestAsync("applications.uninstall",new() { ["scan_id"]=registeredApplicationScanId,["application_ids"]=Strings(allRegisteredApplications.Where(row=>row.IsSelected).Select(row=>row.Id)) },confirm:review=>dialogs.ConfirmAsync(review,Token),cancellation:Token);
            var items=Array(receipt["items"]);
            var completed=items.Count(item=>Text(item,"state")=="completed");
            ApplicationUninstallResult=F("已核验卸载 {0}/{1} 个应用。",completed,items.Length)+(items.Any(item=>item?["restart_required"]?.GetValue<bool>()==true)?T(" Windows Installer 报告需要重启，请保存工作后自行安排。"):"")+
                (completed==items.Length ? T(" 卸载无法通过 Shou 恢复。") : T(" 部分结果需要核实或尚未启动；请在 Windows 中检查卸载器和应用的当前状态。"))+
                T("\n请重新扫描后再选择应用，不会自动重试。");
            Status=T("卸载回执已保存。");
            if(!Token.IsCancellationRequested) await LoadApplicationUninstallHistoryAsync();
        } finally {
            registeredApplicationScanId=null;SetApplicationSelection(false);
            if(ApplicationUninstallResult.Length==0) ApplicationUninstallResult=T("请求未确认完成。如果已经确认卸载，安装程序可能仍在运行；请在 Windows 中核实，再重新扫描。Shou 不会自动重试。");
        }
    }
    private async Task LoadApplicationUninstallHistoryAsync()
    {
        var history=await client.RequestAsync("applications.uninstall-history",cancellation:Token);ApplicationUninstallReceipts.Clear();
        foreach(var receipt in Array(history["entries"])) foreach(var item in Array(receipt?["items"])) {
            var state=Text(item,"state") switch { "completed"=>T("已核验卸载"), "not_started"=>T("未启动"), "executing"=>T("尚未核实完成"), _=>T("需要核实") };
            var details=T("所属卸载器：")+Text(item?["action"],"route")+T("\n此操作无法通过 Shou 恢复。");
            if(item?["restart_required"]?.GetValue<bool>()==true) details+=T("\n需要重启，请保存工作后自行安排。");
            if(item?["error"] is not null) details+=T("\n原因：")+RegisteredUninstallIssue(Text(item,"error"));
            ApplicationUninstallReceipts.Add(new(Text(receipt,"created_at"),Text(item?["action"]?["application"],"name"),state,details));
        }
    }
    private async Task ClearPackageDataAsync()
    {
        ApplicationUninstallResult="";ProgressVisible=true;Status=T("正在核验所选 MSIX 应用数据…");
        try {
            var receipt=await client.RequestAsync("applications.package-data-clear",new() { ["scan_id"]=registeredApplicationScanId,
                ["application_ids"]=Strings(allRegisteredApplications.Where(row=>row.IsSelected).Select(row=>row.Id)),["include_user_data"]=true },
                confirm:review=>dialogs.ConfirmAsync(review,Token),cancellation:Token);
            var items=Array(receipt["items"]);var completed=items.Count(item=>Text(item,"state")=="completed");
            ApplicationUninstallResult=F("Windows 已完成 {0}/{1} 个应用的数据清理。",completed,items.Length)+
                T(" 此操作无法恢复；未报告完成的项目需先在 Windows 中核实。请重新扫描后再操作，不会自动重试。");
            if(!Token.IsCancellationRequested)await LoadPackageDataHistoryAsync();
        } catch (BridgeException error) {
            ApplicationUninstallResult=PackageDataIssue(error.Code)+T("\n如已确认，请先核实实际结果，再重新扫描，不会自动重试。");
        } finally {
            registeredApplicationScanId=null;SetApplicationSelection(false);
            if(ApplicationUninstallResult.Length==0)ApplicationUninstallResult=T("MSIX 数据清理未确认完成。如果已经确认，Windows 操作可能仍在继续；请先核实应用的实际数据状态，不会自动重试。");
        }
    }
    private async Task LoadPackageDataHistoryAsync()
    {
        var history=await client.RequestAsync("applications.package-data-history",cancellation:Token);PackageDataReceipts.Clear();
        foreach(var receipt in Array(history["entries"]))foreach(var item in Array(receipt?["items"])) {
            var state=Text(item,"state") switch { "completed"=>T("Windows 已完成清理"),"not_started"=>T("未启动"),_=>T("需要核实") };
            var details=Text(item?["action"],"data_path")+T("\n由 Windows 清空应用数据，无法恢复；不据此计算已释放空间。");
            if(item?["error"] is not null)details+=T("\n原因：")+PackageDataIssue(Text(item,"error"));
            PackageDataReceipts.Add(new(Text(receipt,"created_at"),Text(item?["action"]?["application"],"name"),state,details));
        }
    }
    private static string PackageDataIssue(string code)=>code switch {
        "application_running"=>T("应用仍在运行，请保存工作并退出后重新扫描。"),
        "permission_denied"=>T("系统包或无法核验的用户数据受保护，请在 Windows 设置中管理。"),
        "package_data_changed" or "plan_stale"=>T("包登记或数据目录已变化，请重新扫描。"),
        "cancelled"=>T("已停止等待，请先核实 Windows 操作是否已经完成。"),
        "package_data_timeout"=>T("等待 Windows 清理超时，已启动的操作可能继续。"),
        "package_data_unavailable"=>T("此包暂不支持直接清理数据，请在 Windows 设置中管理。"),
        "confirmation_required" or "confirmation_expired"=>T("确认已取消或过期，请重新审阅。"),
        _=>T("尚未核实 MSIX 数据清理结果，请先检查 Windows 中的应用状态。")
    };
    internal void VerifyPackageDataLayout()
    {
        packageDataAvailable=true;registeredApplicationScanId="layout-msix-data";SetApplicationSelection(false);
        var package=new RegisteredApplicationRow("layout-msix","生成 MSIX 应用","1.0","生成发布者","MSIX","当前用户","","未知",null,"layout-package","生成布局夹具",true);
        var desktop=new RegisteredApplicationRow("layout-desktop","生成桌面应用","1.0","生成发布者","桌面应用","当前用户","","未知",null,"layout-desktop","生成布局夹具",true);
        allRegisteredApplications.Add(package);allRegisteredApplications.Add(desktop);RegisteredApplications.Add(package);RegisteredApplications.Add(desktop);package.IsSelected=true;
        if(!ClearPackageDataCommand.CanExecute(null))throw new InvalidOperationException("An explicit MSIX selection did not enable data review.");
        desktop.IsSelected=true;
        if(ClearPackageDataCommand.CanExecute(null))throw new InvalidOperationException("Mixed desktop/MSIX selection expanded package-data scope.");
        desktop.IsSelected=false;registeredApplicationScanId=null;
        if(ClearPackageDataCommand.CanExecute(null))throw new InvalidOperationException("Stale registration selection retained package-data authority.");
        SetApplicationSelection(false);PackageDataReceipts.Add(new("2026-10-23","生成 MSIX 应用",T("需要核实"),T("等待 Windows 清理超时，已启动的操作可能继续。")));
    }
    private static string RegisteredUninstallIssue(string code)=>code switch {
        "cancelled"=>T("已停止等待或用户取消，请核实安装程序状态。"), "confirmation_expired"=>T("确认已过期，此项未启动。"),
        "installer_changed"=>T("安装注册或卸载程序已变化，请重新扫描。"), "installer_timeout"=>T("等待已超时，安装程序可能仍在运行。"),
        "permission_denied"=>T("无法核验访问权限，请在 Windows 中管理此应用。"), "uninstall_unavailable"=>T("此登记方式无法直接卸载，请在 Windows 中管理。"),
        "installer_failed"=>T("安装程序未报告成功，请检查它显示的提示。"), "registration_not_verified_absent"=>T("尚未核验到安装注册已移除，请检查实际状态。"),
        _=>T("当前结果无法核实，请检查安装程序及 Windows 中的应用状态。")
    };
    internal void VerifyRegisteredUninstallLayout()
    {
        applicationUninstallAvailable=true;registeredApplicationScanId="layout-fixture";
        var row=new RegisteredApplicationRow("layout-installer","布局夹具应用","1.0","布局夹具发布者","桌面应用","当前用户","C:/layout-fixture/app","未知",null,"layout-registration","生成布局夹具",true);
        allRegisteredApplications.Add(row);RegisteredApplications.Add(row);row.IsSelected=true;
        if(!UninstallApplicationsCommand.CanExecute(null))throw new InvalidOperationException("Explicit generated installer selection did not enable review.");
        ApplicationUninstallResult="部分结果需要核实。安装程序可能仍在运行，请检查 Windows 中的当前状态。";
        ApplicationUninstallReceipts.Add(new("2026-10-23","布局夹具应用","需要核实","停止只结束等待，已经启动的安装程序可能继续运行。"));
        registeredApplicationScanId=null;
        if(UninstallApplicationsCommand.CanExecute(null))throw new InvalidOperationException("Expired installer selection retained review authority.");
    }
}
