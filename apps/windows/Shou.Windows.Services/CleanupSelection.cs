namespace Shou.Windows.Services;

public sealed record CleanupChoice(string Key, string ScanId, string CandidateId, string WorkspaceId,
    string AbsolutePath, string CategoryId, string GroupId, long Bytes);

/// <summary>Selection survives paging and filters; only explicit evidence keys are stored.</summary>
public sealed class CleanupSelection
{
    private readonly Dictionary<string, CleanupChoice> choices = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> categoryCounts = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> groupCounts = new(StringComparer.Ordinal);
    public IReadOnlyCollection<CleanupChoice> Items => choices.Values;
    public int Count => choices.Count;
    public long Bytes { get; private set; }
    public bool Contains(string key) => choices.ContainsKey(key);

    public void Set(CleanupChoice choice, bool selected)
    {
        if (choices.Remove(choice.Key, out var old)) Adjust(old, -1);
        if (selected) { choices.Add(choice.Key, choice); Adjust(choice, 1); }
    }
    private void Adjust(CleanupChoice choice, int delta)
    {
        categoryCounts[choice.CategoryId] = categoryCounts.GetValueOrDefault(choice.CategoryId) + delta;
        groupCounts[choice.GroupId] = groupCounts.GetValueOrDefault(choice.GroupId) + delta;
        Bytes += choice.Bytes * delta;
    }
    public bool? State(int selectableCount, string categoryId, string? groupId = null)
    {
        var selected = groupId is null ? categoryCounts.GetValueOrDefault(categoryId) : groupCounts.GetValueOrDefault(groupId);
        return selected == 0 ? false : selected == selectableCount ? true : null;
    }
    public void RemoveWhere(Func<CleanupChoice, bool> predicate)
    {
        foreach (var choice in choices.Values.Where(predicate).ToArray()) Set(choice, false);
    }
    public void Clear()
    {
        choices.Clear(); categoryCounts.Clear(); groupCounts.Clear(); Bytes = 0;
    }
}
