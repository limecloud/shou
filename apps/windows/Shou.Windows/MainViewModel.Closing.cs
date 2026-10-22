using System.Text.Json.Nodes;
using CommunityToolkit.Mvvm.Input;

namespace Shou.Windows;

public sealed partial class MainViewModel
{
    private bool cleanupClosingAvailable;
    private string cleanupCloseResult = "";
    public string CleanupCloseResult { get => cleanupCloseResult; private set => SetProperty(ref cleanupCloseResult, value); }
    public IAsyncRelayCommand CloseCleanupOwnersCommand { get; private set; } = null!;

    private void InitializeCleanupClosing()
    {
        CloseCleanupOwnersCommand = new AsyncRelayCommand(() => RunAsync(async () => {
            CleanupCloseResult = "";
            var result = await client.RequestAsync("cleanup.close-owners", new() { ["scan_ids"] = Strings(cleanupScanIds) }, Progress(), review => dialogs.ConfirmAsync(review, Token), Token);
            var receipt = result["receipt"]!;
            CleanupCloseResult = string.Join("\n", Array(receipt["items"]).Select(item => Text(item, "name") + "：" + (Text(item, "state") switch {
                "closed" => "已关闭", "still_running" => "仍在运行，请处理应用内的保存提示或手动退出", "cancelled" => "已停止请求", _ => "未能核验或关闭，请手动退出"
            })));
            var affected = Array(result["affected_workspace_ids"]).Select(item => item!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
            var paths = cleanupSelection.Items.Select(item => item.AbsolutePath).Concat(Array(result["affected_paths"]).Select(item => item!.GetValue<string>())).ToHashSet(StringComparer.OrdinalIgnoreCase);
            // Remove only affected evidence before scanning. Cancellation or a
            // partial refresh must not leave old blocked targets actionable.
            var previous = new List<string>();
            foreach (var id in cleanupScanIds) {
                var scan = await client.RequestAsync("scan.results", new() { ["scan_id"] = id }, cancellation: Token);
                if (affected.Contains(Text(scan, "workspace_id"))) previous.Add(id);
            }
            cleanupScanIds.RemoveAll(previous.Contains);
            foreach (var refinement in cleanupRefinements.Where(item => previous.Contains(Text(item, "original_scan_id")) || previous.Contains(Text(item, "scan_id"))).ToArray()) cleanupRefinements.Remove(refinement);
            cleanupSelection.RemoveWhere(item => affected.Contains(item.WorkspaceId));
            Candidates.Clear(); SelectedCleanupCandidate = null;
            foreach (var workspace in affected.Order()) {
                var scan = await client.RequestAsync("scan", new() { ["workspace_id"] = workspace }, Progress(), cancellation: Token);
                RememberCleanupScan(scan);
            }
            if (cleanupScanIds.Count > 0) {
                await LoadCleanupReviewAsync(true, rebuildGroups: true);
                var refreshed = await FetchCleanupSourcesAsync();
                foreach (var row in refreshed.Where(row => paths.Contains(row.AbsolutePath))) cleanupSelection.Set(row.Choice, true);
            }
            SyncCleanupSelection();
            Status = "受影响目录已重新扫描。请审阅当前选择，再确认清理；仍在运行或无法核验的项目继续受保护。";
        }), () => !IsBusy && !AiBusy && cleanupClosingAvailable && cleanupScanIds.Count > 0);
        commands.Add(CloseCleanupOwnersCommand);
    }
}
