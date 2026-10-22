using System.Collections.ObjectModel;
using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed record ToolTargetRow(string Id, string Tool, string Title, long? EstimatedBytes, string Impact)
{
    public string Size => EstimatedBytes is { } bytes ? MainViewModel.Bytes(bytes) : T("大小未知，请审阅工具预览");
}
public sealed record ToolReceiptRow(string Id, string Title, string State, string Details);

public sealed partial class MainViewModel
{
    private bool toolsAvailable;
    private string? toolScanId;
    private ToolTargetRow? selectedToolTarget;
    private string toolsStatus=T("检查 Docker 本机构建缓存、Conda 缓存及非当前 Rust 工具链。"), toolResult="";
    public ObservableCollection<ToolTargetRow> ToolTargets { get; } = [];
    public ObservableCollection<ToolReceiptRow> ToolReceipts { get; } = [];
    public ToolTargetRow? SelectedToolTarget { get => selectedToolTarget; set { if (SetProperty(ref selectedToolTarget,value)) RefreshCommands(); } }
    public string ToolsStatus { get => toolsStatus; private set => SetProperty(ref toolsStatus,value); }
    public string ToolResult { get => toolResult; private set => SetProperty(ref toolResult,value); }
    public IAsyncRelayCommand ScanToolsCommand { get; private set; } = null!;
    public IAsyncRelayCommand CleanToolCommand { get; private set; } = null!;
    public IAsyncRelayCommand ToolHistoryCommand { get; private set; } = null!;
    private void InitializeTools()
    {
        ScanToolsCommand=new AsyncRelayCommand(() => RunAsync(async () => {
            toolScanId=null;SelectedToolTarget=null;ToolTargets.Clear();ToolResult="";
            ToolsStatus=T("正在查询所属工具的只读预览…");
            var scan=await client.RequestAsync("tools.scan",cancellation:Token);
            toolScanId=Text(scan,"id");
            foreach(var target in Array(scan["targets"])) ToolTargets.Add(new(Text(target,"id"),Text(target,"tool"),ToolTitle(target),target?["estimated_bytes"]?.GetValue<long>(),ToolImpact(Text(target,"tool"))));
            var issues=Array(scan["issues"]).Where(item=>Text(item,"code")!="tool_not_installed").Select(item=>Text(item,"tool")+T("：")+ToolIssue(Text(item,"code"))).ToArray();
            ToolsStatus=F("已发现 {0} 项可审阅操作，未选择任何项目。",ToolTargets.Count)+(issues.Length==0 ? "" : T("\n部分工具无法核验：")+string.Join(T("；"),issues));
            await LoadToolHistoryAsync();
        }),()=>!IsBusy && !AiBusy && toolsAvailable);
        CleanToolCommand=new AsyncRelayCommand(() => RunAsync(async () => {
            var target=SelectedToolTarget!;ToolResult="";ToolsStatus=T("等待审阅并核验工具状态…");
            try {
                var receipt=await client.RequestAsync("tools.clean",new() { ["scan_id"]=toolScanId,["target_id"]=target.Id },confirm:review=>dialogs.ConfirmAsync(review,Token),cancellation:Token);
                ToolResult=ToolReceiptDetails(receipt);
                ToolsStatus=T("操作回执已保存。请重新检查工具的当前状态，再选择下一项。");
                if(!Token.IsCancellationRequested) await LoadToolHistoryAsync();
            } finally {
                toolScanId=null;SelectedToolTarget=null;ToolTargets.Clear();
                if(ToolResult.Length==0) ToolsStatus=T("本次请求未完成。若已确认操作，请先在所属工具中核实当前状态，再重新检查。");
            }
        }),()=>!IsBusy && !AiBusy && toolsAvailable && toolScanId is not null && SelectedToolTarget is not null);
        ToolHistoryCommand=new AsyncRelayCommand(()=>RunAsync(LoadToolHistoryAsync),()=>!IsBusy && toolsAvailable);
        commands.AddRange([ScanToolsCommand,CleanToolCommand,ToolHistoryCommand]);
    }
    private async Task LoadToolHistoryAsync()
    {
        var history=await client.RequestAsync("tools.history",cancellation:Token);ToolReceipts.Clear();
        foreach(var receipt in Array(history)) ToolReceipts.Add(new(Text(receipt,"id"),ToolTitle(receipt?["target"]),ToolState(Text(receipt,"state")),ToolReceiptDetails(receipt!)));
    }
    private static string ToolTitle(JsonNode? target)=>Text(target,"tool") switch { "docker"=>T("Docker 构建缓存"), "conda"=>T("Conda 包缓存"), "brew"=>T("Homebrew 旧版本与下载"), _=>Text(target,"title") };
    internal static string ToolImpact(string tool)=>tool switch {
        "docker"=>T("永久移除本机 Docker 未使用的构建缓存，保留镜像、容器和卷。后续构建可能重新下载或生成缓存。"),
        "conda"=>T("由 Conda 清理未使用的包、压缩包、索引和日志。使用符号链接指向包缓存的环境可能受影响，请先检查环境。"),
        "rustup"=>T("移除当前／默认及目录覆盖之外的所选工具链。项目的 rust-toolchain 文件可能仍需要它，再次使用可能需要下载。"),
        _=>T("由所属工具执行当前审阅的永久操作，无法通过 Shou 恢复。")
    };
    private static string ToolState(string state)=>state switch { "completed"=>T("已完成"), "partial"=>T("仍有可清理内容"), "executing"=>T("尚未核实完成，请检查工具当前状态"), _=>T("结果待核实，请检查工具当前状态") };
    private static string ToolReceiptDetails(JsonNode receipt)=>ToolTitle(receipt["target"])+T("：")+ToolState(Text(receipt,"state"))+
        (receipt["remaining_bytes_estimate"]?.GetValue<long>() is { } bytes ? T(" · 剩余估算 ")+Bytes(bytes) : "")+
        (receipt["error"] is not null ? T("\n原因：")+ToolIssue(Text(receipt,"error")) : "")+T("\n由工具管理的永久操作，无法通过 Shou 恢复。估算变化不代表实际释放的磁盘容量。");
    private static string ToolIssue(string code)=>code switch {
        "tool_changed"=>T("工具在审阅后发生变化，请重新检查"), "tool_timeout"=>T("工具超时，请先检查实际结果"), "cancelled"=>T("已停止等待，请先检查实际结果"),
        "remote_context"=>T("当前 Docker 上下文不是支持的本机连接"), "permission_denied"=>T("无法核验工具文件的访问权限"), "resource_limit"=>T("工具输出超过可核验范围"),
        "unsupported_schema"=>T("工具预览格式不受支持，保留原状"), "tool_failed"=>T("工具未正常完成，请在所属工具中检查"), _=>T("当前无法核验，请在所属工具中检查")
    };
    internal void VerifyToolsLayout()
    {
        ToolTargets.Add(new("fixture","rustup","1.75.0-x86_64-pc-windows-msvc",null,"此工具链当前未启用；项目中的 rust-toolchain 文件可能仍需要它。移除后再次使用可能需要下载。"));
        ToolReceipts.Add(new("fixture","Docker 构建缓存","结果待核实","取消后可能已发生部分变更，请在 Docker 中检查当前状态。"));
        ToolResult="Conda 包缓存：结果待核实\n由工具管理的永久操作，无法通过 Shou 恢复。";
    }
}
