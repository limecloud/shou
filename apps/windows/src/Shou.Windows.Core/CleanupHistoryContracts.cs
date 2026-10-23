using System.Collections.Immutable;

namespace Shou.Windows.Core;

public enum HistoryLocationState { Matches, Missing, Changed, Unavailable, NotRecorded }

public sealed record CleanupHistorySummary(string ExecutionId, string PlanId, CleanupAction Action,
    DateTimeOffset StartedAt, DateTimeOffset UpdatedAt, CleanupExecutionState RecordedState, int ItemCount,
    int CompletedItems, bool Unfinished, bool NeedsVerification, bool PlanVerified = false);
public sealed record CleanupHistoryIssue(string ExecutionId, string Code);
public sealed record CleanupHistoryPage(string State, string SnapshotDigest, int TotalCount,
    ImmutableArray<CleanupHistorySummary> Entries, ImmutableArray<CleanupHistoryIssue> Issues, string? NextCursor);
public sealed record CleanupHistoryDetail(CleanupPlan Plan, CleanupExecution Execution, bool Unfinished,
    bool NeedsVerification, bool RecoveryAvailable = false);
public sealed record HistoryLocation(WindowsPath? Path, HistoryLocationState State, bool Complete,
    int ObservedEntries = 0, string? Reason = null);
public sealed record CleanupHistoryInspectionItem(string ItemId, CleanupItemState RecordedState,
    HistoryLocation Original, HistoryLocation Trash, string Assessment);
public sealed record CleanupHistoryInspection(string ExecutionId, CleanupExecutionState RecordedState,
    DateTimeOffset CheckedAt, string State, bool Unfinished, bool NeedsVerification, int ObservedEntries,
    ImmutableArray<CleanupHistoryInspectionItem> Items, bool RecordsChanged = false, bool RecoveryAvailable = false);
