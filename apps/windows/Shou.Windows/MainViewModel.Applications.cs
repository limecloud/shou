using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record RegisteredApplicationRow(string Id,string Name,string Version,string Publisher,string Kind,string Scope,string Location,string Size,long? EstimatedBytes,string Registration,string Details);
public sealed record ApplicationCoverageRow(string Source,string State,int Entries,int Applications);

public sealed partial class MainViewModel
{
    private bool applicationInventoryAvailable,includeSystemApplications;
    private int applicationScope;
    private string applicationQuery="",applicationInventorySummary="尚未扫描已安装的应用。",applicationCoverageSummary="";
    private RegisteredApplicationRow? selectedRegisteredApplication;
    private readonly List<RegisteredApplicationRow> allRegisteredApplications=[];
    public ObservableCollection<RegisteredApplicationRow> RegisteredApplications { get; }=[];
    public ObservableCollection<ApplicationCoverageRow> ApplicationCoverage { get; }=[];
    public bool IncludeSystemApplications { get=>includeSystemApplications;set=>SetProperty(ref includeSystemApplications,value); }
    public string ApplicationQuery { get=>applicationQuery;set { if(SetProperty(ref applicationQuery,value))FilterRegisteredApplications(); } }
    public int ApplicationScope { get=>applicationScope;set { if(SetProperty(ref applicationScope,Math.Clamp(value,0,3)))FilterRegisteredApplications(); } }
    public RegisteredApplicationRow? SelectedRegisteredApplication { get=>selectedRegisteredApplication;set=>SetProperty(ref selectedRegisteredApplication,value); }
    public string ApplicationInventorySummary { get=>applicationInventorySummary;private set=>SetProperty(ref applicationInventorySummary,value); }
    public string ApplicationCoverageSummary { get=>applicationCoverageSummary;private set=>SetProperty(ref applicationCoverageSummary,value); }
    public IAsyncRelayCommand ScanApplicationsCommand { get;private set; }=null!;
    public IRelayCommand ManageApplicationsCommand { get;private set; }=null!;
    public IRelayCommand CopyApplicationNameCommand { get;private set; }=null!;
    private void InitializeApplications()
    {
        ScanApplicationsCommand=new AsyncRelayCommand(()=>RunAsync(ScanRegisteredApplicationsAsync),()=>applicationInventoryAvailable && CanEditRuleSettings);
        ManageApplicationsCommand=new RelayCommand(dialogs.OpenApplicationSettings,()=>applicationInventoryAvailable && CanEditRuleSettings);
        CopyApplicationNameCommand=new RelayCommand(()=>System.Windows.Clipboard.SetText(SelectedRegisteredApplication!.Name),()=>SelectedRegisteredApplication is not null && !IsBusy);
        commands.AddRange([ScanApplicationsCommand,ManageApplicationsCommand,CopyApplicationNameCommand]);
    }
    private void FilterRegisteredApplications()
    {
        var selection=SelectedRegisteredApplication?.Id;
        RegisteredApplications.Clear();
        foreach(var row in allRegisteredApplications.Where(row=>
            (ApplicationScope==0 || ApplicationScope==1 && row.Scope=="当前用户" && row.Kind!="MSIX" || ApplicationScope==2 && row.Scope=="全机" || ApplicationScope==3 && row.Kind=="MSIX") &&
            (string.IsNullOrWhiteSpace(ApplicationQuery) || new[] {row.Name,row.Publisher,row.Version,row.Location,row.Registration}.Any(value=>value.Contains(ApplicationQuery.Trim(),StringComparison.CurrentCultureIgnoreCase)))))RegisteredApplications.Add(row);
        SelectedRegisteredApplication=RegisteredApplications.FirstOrDefault(row=>row.Id==selection);
    }
    private async Task ScanRegisteredApplicationsAsync()
    {
        allRegisteredApplications.Clear();RegisteredApplications.Clear();ApplicationCoverage.Clear();SelectedRegisteredApplication=null;
        ApplicationInventorySummary="正在读取已安装的应用…";ApplicationCoverageSummary="";
        var result=await client.RequestAsync("applications.scan",new() { ["include_system"]=IncludeSystemApplications },cancellation:Token);
        static string Source(string id)=>id switch {
            "windows.user_uninstall64"=>"当前用户 · 64 位注册表", "windows.user_uninstall32"=>"当前用户 · 32 位注册表",
            "windows.machine_uninstall64"=>"全机 · 64 位注册表", "windows.machine_uninstall32"=>"全机 · 32 位注册表",
            "windows.user_packages"=>"当前用户 · MSIX 包",_=>id };
        foreach(var source in Array(result["sources"])) {
            var state=Text(source,"status") switch { "complete"=>"已读取", "missing"=>"来源不存在", "partial"=>"部分读取", "unavailable"=>"不可读取", "not_scanned"=>"未扫描",_=>"未知" };
            ApplicationCoverage.Add(new(Source(Text(source?["source"],"id")),state,source?["entry_count"]?.GetValue<int>() ?? 0,source?["application_count"]?.GetValue<int>() ?? 0));
        }
        foreach(var item in Array(result["items"])) {
            var source=Text(item,"source_id");var kind=Text(item,"kind") switch { "msi"=>"MSI", "msix"=>"MSIX",_=>"桌面应用" };
            long? size=item?["estimated_bytes"]?.GetValue<long>();
            bool? uninstall=item?["uninstall_available"]?.GetValue<bool>();
            var note=uninstall switch { true=>"已登记卸载入口；实际可用性由 Windows 和安装程序决定。",false=>"未登记可用卸载入口。",_=>"卸载可用性需在 Windows 设置中确认。" };
            if(item?["system_component"]?.GetValue<bool>()==true)note="系统组件或包依赖。\n"+note;
            var details=note+"\n来源："+Source(source)+"\n注册标识："+Text(item,"registration")+"\n包系列："+Text(item,"package_family_name")+"\n安装位置为登记值；大小为安装程序登记的估计，未实测。";
            allRegisteredApplications.Add(new(Text(item,"id"),Text(item,"name"),Text(item,"version"),Text(item,"publisher"),kind,source.StartsWith("windows.machine_",StringComparison.Ordinal)?"全机":"当前用户",Text(item,"install_location"),size is { } bytes?Bytes(bytes):"未知",size,Text(item,"registration"),details));
        }
        FilterRegisteredApplications();
        ApplicationInventorySummary=$"发现 {allRegisteredApplications.Count} 个已注册应用 · 有大小记录 {allRegisteredApplications.Count(row=>row.EstimatedBytes is not null)} 个 · {(Text(result,"status")=="complete"?"声明来源已读取":"部分来源未完整读取")}";
        var omitted=Array(result["unavailable_sources"]).Select(value=>(value?.GetValue<string>() ?? "") switch {
            "other_accounts"=>"其他账户", "unregistered_portable_applications"=>"未注册的便携应用", "custom_unregistered_installations"=>"自定义未注册安装",
            "application_data_ownership"=>"应用数据归属", "measured_disk_usage"=>"实测空间", "last_used_time"=>"最近使用时间",var other=>other });
        ApplicationCoverageSummary="盘点当前用户和全机的程序注册、当前用户的 MSIX 包。未覆盖："+string.Join("、",omitted)+"。来源读取失败不能用于判断应用已卸载。";
        var issues=Array(result["issues"]);
        if(issues.Length>0)ApplicationCoverageSummary+="\n读取问题："+string.Join("；",issues.Take(20).Select(issue=>Text(issue,"code")+" · "+Text(issue,"path")));
        Status="应用盘点完成。卸载请在 Windows 的“已安装的应用”中确认；完成后重新扫描。";
    }
}
