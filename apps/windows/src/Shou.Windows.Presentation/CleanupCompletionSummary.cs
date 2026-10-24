using Shou.Windows.Core;

namespace Shou.Windows.Presentation;

/// <summary>Completion copy and estimates come from the recorded outcome, never the selected plan alone.</summary>
public sealed record CleanupCompletionSummary(bool Complete, bool Cancelled, bool HasRecord, bool Permanent,
    long RemovedBytesEstimate, int Removed, int Skipped, int Failed, int Unverified, DateTimeOffset? StartedAt, bool Unfinished = false)
{
    public string TitleKey => !HasRecord ? "Cleanup could not start" : Complete ? "Cleanup complete" :
        Unfinished ? "Unfinished cleanup" : Cancelled ? "Cleanup stopped" : "Cleanup finished with issues";
    public string DescriptionKey => !HasRecord
        ? "A recorded outcome is unavailable. This does not prove that no files changed. Read the recorded result before continuing."
        : Complete ? Permanent ? "Permanently removed; this cannot be undone." : "Moved to Trash; this is not freed space."
        : "Some items could not be removed. Review the result.";

    public static CleanupCompletionSummary Create(CleanupPlan plan, CleanupExecution? execution, string? errorCode = null)
    {
        if (execution is null || execution.Items.IsDefault || execution.PlanId != plan.Id || execution.PlanDigest != plan.Digest ||
            execution.Action != plan.Action || execution.Items.Length != plan.Items.Length ||
            execution.Items.Select(item => item.ItemId).Distinct().Count() != execution.Items.Length ||
            execution.Items.Any(item => !plan.Items.Any(target => target.Id == item.ItemId)))
            return new(false, false, false, plan.Action == CleanupAction.Permanent,
            0, 0, 0, 0, plan.Items.Length, null);
        var targets = plan.Items.ToDictionary(item => item.Id);
        var removed = 0; var skipped = 0; var failed = 0; var unverified = 0; long bytes = 0;
        foreach (var item in execution.Items)
        {
            if (!targets.TryGetValue(item.ItemId, out var target)) { unverified++; continue; }
            switch (item.State)
            {
                case CleanupItemState.Purged when plan.Action == CleanupAction.Permanent:
                case CleanupItemState.Trashed when plan.Action == CleanupAction.Trash:
                    removed++; bytes = target.AllocatedBytes > long.MaxValue - bytes ? long.MaxValue : bytes + target.AllocatedBytes; break;
                case CleanupItemState.Skipped:
                case CleanupItemState.Cancelled:
                case CleanupItemState.Pending when execution.State != CleanupExecutionState.Executing:
                    skipped++; break;
                case CleanupItemState.Failed: failed++; break;
                default: unverified++; break;
            }
        }
        unverified += plan.Items.Count(target => !execution.Items.Any(item => item.ItemId == target.Id));
        var complete = errorCode is null && !execution.Items.IsEmpty &&
            execution.State == CleanupExecutionState.Completed && removed == plan.Items.Length;
        var cancelled = errorCode is null && execution.State == CleanupExecutionState.Cancelled && failed == 0 && unverified == 0;
        return new(complete, cancelled, true, plan.Action == CleanupAction.Permanent, bytes,
            removed, skipped, failed, unverified, execution.StartedAt, execution.State == CleanupExecutionState.Executing);
    }
}
