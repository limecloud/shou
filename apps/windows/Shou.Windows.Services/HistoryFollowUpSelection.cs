namespace Shou.Windows.Services;

public sealed record HistoryFollowUpChoice(string Id, bool CanRestore, bool CanPurge);

/// <summary>A follow-up uses the entire explicit selection or refuses it.</summary>
public static class HistoryFollowUpSelection
{
    public const int MaximumItems = 500;

    public static bool CanSubmit(string action, IReadOnlyCollection<HistoryFollowUpChoice> items) =>
        action is "restore" or "purge" && items.Count is > 0 and <= MaximumItems &&
        items.All(item => !string.IsNullOrWhiteSpace(item.Id) && (action == "restore" ? item.CanRestore : item.CanPurge)) &&
        items.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() == items.Count;

    public static string[] ItemIds(string action, IReadOnlyCollection<HistoryFollowUpChoice> items)
    {
        if (!CanSubmit(action, items)) throw new BridgeException("invalid_argument", "请选择 1–500 个均支持此操作的历史项目。");
        return items.Select(item => item.Id).ToArray();
    }
}
