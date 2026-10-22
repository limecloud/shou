using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record HistoryObservation(string? Path, string State, string? Issue)
{
    public string DisplayPath => Path ?? T("未记录路径");
    public string Label => State switch
    {
        "matches" => T("内容与记录一致"), "missing" => T("当前位置不存在"), "changed" => T("内容已改变"),
        "not_recorded" => T("未记录此位置"), _ => T("无法核验")
    };
    public string IssueText => Issue switch
    {
        null => "", "unverified_location" => T("位置身份无法确认。"), "resource_limit" => T("已达到本次核验的数量或时间上限。"),
        "permission_or_type_unavailable" => T("无法读取此位置，或文件类型不受支持。"), "incomplete_manifest" => T("未能完整读取目录内容。"),
        "manifest_changed" => T("项目的身份或内容与记录不一致。"), "inspection_failed" => T("读取失败，请检查访问权限后重试。"),
        _ => T("未能完成核验：") + Issue
    };
}
public sealed record HistoryInspectionFollowUp(string State);
public sealed record HistoryInspectionItem(string Id, string RelativePath, HistoryObservation Original, HistoryObservation Trash, HistoryInspectionFollowUp? FollowUp, string State)
{
    public string Label => State switch
    {
        "verified_trash" => T("回收站项目与记录一致"), "verified_original" => T("项目位于原始路径，且与记录一致"),
        "restore_conflict" => T("恢复目标位置已被占用"), "restored" => T("已恢复，且内容与记录一致"),
        "purged" => T("已记录永久删除，原位置或回收站项目已不存在"), "missing" => T("未找到记录中的项目"), _ => T("结果需要进一步核实")
    };
    public string PendingNotice => FollowUp?.State == "pending" ? T("后续操作尚未结束，需要核实结果。") : "";
}
public sealed record HistoryInspectionReport(string ExecutionId, DateTimeOffset CheckedAt, bool Unfinished, string Status, HistoryInspectionItem[] Items);

public partial class HistoryInspectionDialog : Window
{
    private readonly BridgeProcessClient client;
    private readonly string executionId;
    private CancellationTokenSource? checking;
    private bool closed;
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    public HistoryInspectionDialog(Window? owner, BridgeProcessClient client, string executionId)
    {
        InitializeComponent();
        Owner = owner; this.client = client; this.executionId = executionId;
        ExecutionId.Text = executionId;
        Loaded += async (_, _) => await CheckAsync();
        Closed += (_, _) => { closed = true; checking?.Cancel(); };
    }
    private async void CheckAgainClicked(object sender, RoutedEventArgs args) => await CheckAsync();
    private async Task CheckAsync()
    {
        if (checking is not null || closed) return;
        using var stop = new CancellationTokenSource(); checking = stop;
        CheckAgain.IsEnabled = false; CheckingProgress.Visibility = Visibility.Visible;
        InspectionItems.ItemsSource = null; UnfinishedNotice.Visibility = Visibility.Collapsed;
        VerificationSummary.Text = T("正在核验记录中的具体位置…");
        try
        {
            var result = await client.RequestAsync("history.inspect", new() { ["execution_id"] = executionId }, cancellation: stop.Token);
            var report = result.Deserialize<HistoryInspectionReport>(JsonOptions);
            if (report is null || report.ExecutionId != executionId || report.Items is null)
                throw new BridgeException("transport_failed", T("核验结果与所选记录不一致。"));
            if (!closed) ShowReport(report);
        }
        catch (Exception error)
        {
            if (!closed) VerificationSummary.Text = T("核验未完成：") + error.Message;
        }
        finally
        {
            checking = null;
            if (!closed) { CheckAgain.IsEnabled = true; CheckingProgress.Visibility = Visibility.Collapsed; }
        }
    }
    private void ShowReport(HistoryInspectionReport report)
    {
        VerificationSummary.Text = F("{0:g} · {1} 项 · ",report.CheckedAt.ToLocalTime(),report.Items.Length) + (report.Status == "complete" ? T("已核验记录位置") : T("部分结果需要核实"));
        UnfinishedNotice.Visibility = report.Unfinished ? Visibility.Visible : Visibility.Collapsed;
        InspectionItems.ItemsSource = report.Items;
    }
    internal void VerifyLayout()
    {
        ShowReport(new(executionId, DateTimeOffset.UtcNow, true, "partial", [
            new("fixture", "build/cache", new("C:/layout-fixture/build/cache", "changed", "manifest_changed"), new(null, "unavailable", "resource_limit"), new("pending"), "needs_verification")
        ]));
        Measure(new Size(780, 680)); Arrange(new Rect(0, 0, 780, 680)); UpdateLayout();
    }
}
