using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal static class ReviewText
{
    public static string BlockedReason(TextCatalog text, string code) => text.Get(code switch
    {
        "coverage_incomplete" => "This folder was not completely scanned.",
        "protected_location" => "This location is protected.",
        "protected_data" => "Protected files were found inside this folder.",
        "project_marker_missing" => "The required project marker is missing.",
        "foreign_owner" => "Some files belong to another user.",
        "cross_volume" => "This folder contains entries on another volume.",
        "unsupported_entry" => "This folder contains links or unsupported entries.",
        "multiple_links" => "This folder contains files with multiple hard links.",
        "excluded" => "This folder contains excluded content.",
        "unsupported_metadata" => "File metadata could not be verified.",
        "below_minimum_size" => "This folder is below the rule's minimum size.",
        "newer_than_retention" => "Files are newer than the rule's retention period.",
        _ => "This item is protected or incomplete."
    });

    public static string Error(TextCatalog text, string? code) => text.Get(code switch
    {
        "plan_stale" or "source_changed" => "The scan or settings changed. Scan again before reviewing.",
        "activity_unknown" or "active_target" => "An application or build tool may be using these files. Close it and scan again.",
        "tracked_artifact_content" or "artifact_evidence_unavailable" => code!,
        "permission_denied" or "access_expired" => "Access to this location is unavailable.",
        "store_busy" => "Another operation is using Shou. Try again shortly.",
        "store_corrupt" => "The saved record could not be verified.",
        "overlapping_selection" => "The selected items overlap. Choose either a folder or its contents.",
        "selection_limit" => "Select up to 256 items for one review.",
        "selection_unavailable" => "This item is protected or incomplete.",
        _ => "This operation could not be completed. Try again."
    });

    public static string ItemState(TextCatalog text, CleanupItemState state) => text.Get(state switch
    {
        CleanupItemState.Purged => "Permanently removed",
        CleanupItemState.Trashed => "Moved to Recycle Bin",
        CleanupItemState.Purging or CleanupItemState.Moving => "In progress",
        CleanupItemState.Failed => "Failed",
        CleanupItemState.Skipped => "Skipped",
        CleanupItemState.Cancelled => "Cancelled",
        CleanupItemState.Pending => "Not started",
        _ => "Needs Verification"
    });

    public static string ExecutionState(TextCatalog text, CleanupExecutionState state) => text.Get(state switch
    {
        CleanupExecutionState.Completed => "Completed",
        CleanupExecutionState.Partial => "Partially completed",
        CleanupExecutionState.Executing => "In progress",
        CleanupExecutionState.Cancelled => "Cancelled",
        _ => "Needs Verification"
    });

    public static string LocationState(TextCatalog text, HistoryLocationState state) => text.Get(state switch
    {
        HistoryLocationState.Matches => "Matches saved evidence",
        HistoryLocationState.Missing => "Not found",
        HistoryLocationState.Changed => "Changed since operation",
        HistoryLocationState.NotRecorded => "No recorded location",
        _ => "Could not verify"
    });
}
