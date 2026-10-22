using System.Text.Json.Nodes;

namespace Shou.Windows.Services;

public sealed record RecordMaintenanceSummary
{
    public int RemovableCount { get; }
    public long TotalBytes { get; }
    public long RemovableBytes { get; }
    public int RetainedCount { get; }
    public int IssueCount { get; }
    public bool CanCollect => RemovableCount > 0 && IssueCount == 0;

    private RecordMaintenanceSummary(int count, long total, long removable, int retained, int issues)
    {
        RemovableCount = count; TotalBytes = total; RemovableBytes = removable;
        RetainedCount = retained; IssueCount = issues;
    }

    public static RecordMaintenanceSummary Read(JsonNode value)
    {
        static long Number(JsonNode? field) => field is JsonValue number && number.TryGetValue<long>(out var result) && result >= 0
            ? result : throw Invalid();
        static BridgeException Invalid() => new("invalid_protocol", T("扫描记录预览不完整，请重新检查。"));
        if (value is not JsonObject root || root["records"] is not JsonArray records || root["issues"] is not JsonArray issues) throw Invalid();
        var total = Number(root["total_bytes"]);
        var removable = Number(root["removable_bytes"]);
        var retained = Number(root["retained_count"]);
        if (removable > total || retained > int.MaxValue || issues.Any(issue => issue is not JsonValue text || !text.TryGetValue<string>(out var message) || string.IsNullOrWhiteSpace(message))) throw Invalid();
        long recordBytes = 0;
        foreach (var record in records)
        {
            if (record is not JsonObject item) throw Invalid();
            var bytes = Number(item["byte_count"]);
            if (bytes > total - recordBytes) throw Invalid();
            recordBytes += bytes;
        }
        if (recordBytes != removable || (issues.Count > 0 && records.Count > 0)) throw Invalid();
        return new(records.Count, total, removable, (int)retained, issues.Count);
    }
}
