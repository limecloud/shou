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
            CleanupCloseResult = string.Join("\n", Array(receipt["items"]).Select(item => Text(item, "name") + T("：") + (Text(item, "state") switch {
                "closed" => T("已关闭"), "still_running" => T("仍在运行，请处理应用内的保存提示或手动退出"), "cancelled" => T("已停止请求"), _ => T("未能核验或关闭，请手动退出")
            })));
            var affected = Array(result["affected_workspace_ids"]).Select(item => item!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
            var paths = cleanupSelection.Items.Select(item => item.AbsolutePath).Concat(Array(result["affected_paths"]).Select(item => item!.GetValue<string>())).ToHashSet(StringComparer.OrdinalIgnoreCase);
            // Invalidate synchronously before the first cancellable read.
            // Retain unrelated evidence and choices even if refresh fails.
            InvalidateCleanupOwners(affected);
            try {
                foreach (var workspace in affected.Order()) {
                    var scan = await client.RequestAsync("scan", new() { ["workspace_id"] = workspace }, Progress(), cancellation: Token);
                    RememberCleanupScan(scan);
                }
                if (cleanupScanIds.Count > 0) {
                    await LoadCleanupReviewAsync(true, rebuildGroups: true);
                    var refreshed = await FetchCleanupSourcesAsync();
                    Token.ThrowIfCancellationRequested();
                    foreach (var row in refreshed.Where(row => paths.Contains(row.AbsolutePath))) cleanupSelection.Set(row.Choice, true);
                }
            } catch {
                CleanupCloseResult += T("\n刷新未完成。受影响的旧扫描已失效，请重新扫描后审阅；其他目录的选择已保留。");
                throw;
            } finally { SyncCleanupSelection(); }
            Status = T("受影响目录已重新扫描。请审阅当前选择，再确认清理；仍在运行或无法核验的项目继续受保护。");
        }), () => !IsBusy && !AiBusy && cleanupClosingAvailable && cleanupScanIds.Count > 0);
        commands.Add(CloseCleanupOwnersCommand);
    }

    private void InvalidateCleanupOwners(HashSet<string> affected)
    {
        var previous = cleanupScanIds.Where(id => !cleanupScanWorkspaces.TryGetValue(id, out var workspace) || affected.Contains(workspace)).ToHashSet(StringComparer.Ordinal);
        cleanupScanIds.RemoveAll(previous.Contains);
        foreach (var id in previous) cleanupScanWorkspaces.Remove(id);
        foreach (var refinement in cleanupRefinements.Where(item => previous.Contains(Text(item, "original_scan_id")) || previous.Contains(Text(item, "scan_id"))).ToArray()) cleanupRefinements.Remove(refinement);
        cleanupSelection.RemoveWhere(item => affected.Contains(item.WorkspaceId) || previous.Contains(item.ScanId));
        cleanupNextOffset = null; cleanupQueryDigest = "";
        Candidates.Clear(); SelectedCleanupCandidate = null; CleanupGroups.Clear();
        CleanupResultSummary = T("正在刷新受影响目录。旧扫描已失效，清理仍需重新审阅。");
        SyncCleanupSelection();
    }

    internal void VerifyCleanupClosingState()
    {
        ResetCleanupReview();
        RememberCleanupScan(new JsonObject { ["scan_id"] = "affected", ["workspace_id"] = "workspace-a" });
        RememberCleanupScan(new JsonObject { ["scan_id"] = "refined", ["workspace_id"] = "workspace-a" });
        RememberCleanupScan(new JsonObject { ["scan_id"] = "retained", ["workspace_id"] = "workspace-b" });
        cleanupRefinements.Add(new JsonObject { ["original_scan_id"] = "affected", ["scan_id"] = "refined" });
        cleanupSelection.Set(new("a", "affected", "a", "workspace-a", "C:/fixture/a/cache", "build", "fixture", 10), true);
        cleanupSelection.Set(new("b", "retained", "b", "workspace-b", "C:/fixture/b/cache", "build", "fixture", 20), true);
        cleanupNextOffset = 200; cleanupQueryDigest = "old-query";
        InvalidateCleanupOwners(new(StringComparer.Ordinal) { "workspace-a" });
        if (!cleanupScanIds.SequenceEqual(["retained"]) || cleanupRefinements.Count != 0 || cleanupNextOffset is not null || cleanupQueryDigest.Length != 0 ||
            cleanupSelection.Count != 1 || !cleanupSelection.Contains("b") || cleanupSelection.Bytes != 20 || Candidates.Count != 0 || CleanupGroups.Count != 0)
            throw new InvalidOperationException("A cancelled close refresh retained affected evidence or lost an unrelated selection.");
        ResetCleanupReview();
        CleanupCloseResult = "Visual Studio Code：仍在运行，请处理应用内的保存提示或手动退出\nChrome：已关闭\n刷新未完成。受影响的旧扫描已失效，请重新扫描后审阅；其他目录的选择已保留。";
    }
}
