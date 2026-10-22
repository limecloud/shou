using Shou.Windows.Services;

namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private string recordMaintenanceStatus = "";
    public string RecordMaintenanceStatus { get => recordMaintenanceStatus; private set => SetProperty(ref recordMaintenanceStatus, value); }

    private Task CollectRecordsAsync() => RunAsync(async () =>
    {
        var collecting = false;
        RecordMaintenanceStatus = Status = T("正在检查可回收的扫描记录…");
        ProgressVisible = true;
        try
        {
            var preview = RecordMaintenanceSummary.Read(await client.RequestAsync("records.preview", cancellation: Token));
            ProgressVisible = false;
            if (!dialogs.ReviewRecordMaintenance(preview, Token))
            {
                RecordMaintenanceStatus = Status = preview.IssueCount > 0 ? T("部分扫描记录需要核实，本次未回收。")
                    : !preview.CanCollect ? T("目前没有可回收的扫描记录。") : T("已取消回收扫描记录。");
                return;
            }
            Token.ThrowIfCancellationRequested();
            collecting = true; ProgressVisible = true;
            RecordMaintenanceStatus = Status = T("正在重新检查并回收扫描记录…");
            var result = RecordMaintenanceSummary.Read(await client.RequestAsync("records.collect", cancellation: Token));
            RecordMaintenanceStatus = Status = result.IssueCount > 0 ? T("记录状态发生变化，部分记录需要核实，本次未回收。")
                : F("已回收 {0} 条扫描记录 · {1}。活跃计划、清理历史、恢复数据和你的文件已保留。",result.RemovableCount,Bytes(result.RemovableBytes));
        }
        catch
        {
            RecordMaintenanceStatus = collecting ? T("扫描记录回收未确认完成，可能已回收部分派生记录。请重新检查后再决定是否继续；你的文件、清理历史与恢复数据会保留。")
                : T("扫描记录检查未完成，本次未请求回收。");
            throw;
        }
    });
}
