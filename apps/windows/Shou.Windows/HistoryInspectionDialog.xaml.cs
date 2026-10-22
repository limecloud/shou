using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed record HistoryObservation(string? Path, string State, string? Issue)
{
    public string DisplayPath => Path ?? "未记录路径";
    public string Label => State switch
    {
        "matches" => "内容与记录一致", "missing" => "当前位置不存在", "changed" => "内容已改变",
        "not_recorded" => "未记录此位置", _ => "无法核验"
    };
    public string IssueText => Issue switch
    {
        null => "", "unverified_location" => "位置身份无法确认。", "resource_limit" => "已达到本次核验的数量或时间上限。",
        "permission_or_type_unavailable" => "无法读取此位置，或文件类型不受支持。", "incomplete_manifest" => "未能完整读取目录内容。",
        "manifest_changed" => "项目的身份或内容与记录不一致。", "inspection_failed" => "读取失败，请检查访问权限后重试。",
        _ => "未能完成核验：" + Issue
    };
}
public sealed record HistoryInspectionFollowUp(string State);
public sealed record HistoryInspectionItem(string Id, string RelativePath, HistoryObservation Original, HistoryObservation Trash, HistoryInspectionFollowUp? FollowUp, string State)
{
    public string Label => State switch
    {
        "verified_trash" => "回收站项目与记录一致", "verified_original" => "项目位于原始路径，且与记录一致",
        "restore_conflict" => "恢复目标位置已被占用", "restored" => "已恢复，且内容与记录一致",
        "purged" => "已记录永久删除，原位置或回收站项目已不存在", "missing" => "未找到记录中的项目", _ => "结果需要进一步核实"
    };
    public string PendingNotice => FollowUp?.State == "pending" ? "后续操作尚未结束，需要核实结果。" : "";
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
        VerificationSummary.Text = "正在核验记录中的具体位置…";
        try
        {
            var result = await client.RequestAsync("history.inspect", new() { ["execution_id"] = executionId }, cancellation: stop.Token);
            var report = result.Deserialize<HistoryInspectionReport>(JsonOptions);
            if (report is null || report.ExecutionId != executionId || report.Items is null)
                throw new BridgeException("transport_failed", "核验结果与所选记录不一致。");
            if (!closed) ShowReport(report);
        }
        catch (Exception error)
        {
            if (!closed) VerificationSummary.Text = "核验未完成：" + error.Message;
        }
        finally
        {
            checking = null;
            if (!closed) { CheckAgain.IsEnabled = true; CheckingProgress.Visibility = Visibility.Collapsed; }
        }
    }
    private void ShowReport(HistoryInspectionReport report)
    {
        VerificationSummary.Text = $"{report.CheckedAt.ToLocalTime():g} · {report.Items.Length} 项 · " + (report.Status == "complete" ? "已核验记录位置" : "部分结果需要核实");
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
