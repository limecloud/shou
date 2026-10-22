using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Shou.Windows.Services;

public sealed record StorageCoverageItem(string Code, string Path, bool SystemManaged, string? AbsolutePath)
{
    public string DisplayPath => AbsolutePath ?? Path;
    public bool CanCopy => AbsolutePath is not null;
    public bool CanReveal => CanCopy && !SystemManaged && Code is "authorization_required" or "unreadable" or "unreadable_directory" or "unreadable_directory_entry";
    public string Reason => SystemManaged ? T("系统管理的位置，无需调整权限") : Code switch
    {
        "authorization_required" or "unreadable" or "unreadable_directory" or "unreadable_directory_entry" => T("此位置未能完整读取，请检查访问情况后重新扫描。"),
        "changed_during_scan" or "changed_directory" => T("此位置在扫描期间发生变化。"),
        "cloud_placeholder" => T("仅在线内容未下载，未计入完整占用。"),
        "cross_filesystem" => T("此位置属于另一卷，本次扫描未跨卷读取。"),
        "resource_limit" => T("此位置达到扫描的时间、数量或深度限制。"),
        "additional_coverage_issues" => T("还有更多覆盖问题，已在此合并记录。"),
        _ => T("此位置未能完整测量。")
    };
}

/// <summary>A frozen read-only scan observation, independent of file selection.</summary>
public sealed record StorageCoverageSummary(string ScanId, string RootPath, string Status, long EntryCount, IReadOnlyList<StorageCoverageItem> Items)
{
    public bool Partial => Status == "partial";
    public string State => Partial ? T("部分扫描：未测量的空间仍未知。") : T("本次扫描已完成，文件仍可能变化。");
    public string EmptyMessage => Partial ? T("本次扫描未完成，但没有提供详细原因。请重新扫描。") : T("扫描未报告覆盖缺口。");

    public static StorageCoverageSummary Read(JsonNode value)
    {
        static BridgeException Invalid() => new("invalid_protocol", T("扫描覆盖信息不完整，请重新扫描。"));
        static string Text(JsonNode? value) => value is JsonValue text && text.TryGetValue<string>(out var result) && result.Length <= 32768 && !result.Contains('\0')
            ? result : throw Invalid();
        if (value is not JsonObject root || root["coverage_notes"] is not JsonArray notes || notes.Count > 1024) throw Invalid();
        var id=Text(root["scan_id"]); var path=Text(root["root_path"]).Replace('\\','/'); var status=Text(root["status"]);
        if (!Regex.IsMatch(id,"^[A-Za-z0-9_-]{1,200}$") || status is not ("complete" or "partial") ||
            !(path.StartsWith('/') && !path.StartsWith("//") || Regex.IsMatch(path,"^[A-Za-z]:/")) || path.Any(char.IsControl) ||
            path.Split('/').Any(part=>part is "." or "..") || root["entry_count"] is not JsonValue number || !number.TryGetValue<long>(out var entries) || entries < 1) throw Invalid();
        var items=new List<StorageCoverageItem>();
        foreach (var note in notes)
        {
            if (note is not JsonObject item || item["system_managed"] is not JsonValue flag || !flag.TryGetValue<bool>(out var managed)) throw Invalid();
            var code=Text(item["code"]); var relative=Text(item["path"]);
            if (code.Length==0 || code.Length>256) throw Invalid();
            // Legacy Windows notes appended a Win32 number to the path. Keep
            // that diagnostic visible without presenting it as an exact path.
            var canCopy=code!="additional_coverage_issues" && relative.Length>0 && !relative.Any(char.IsControl) && !relative.Contains('\\') && !relative.Contains(':') &&
                (relative=="." || relative.Split('/').All(part=>part.Length>0 && part is not ("." or ".."))) && !Regex.IsMatch(relative,@" \([0-9]+\)$");
            var absolute=canCopy ? relative=="." ? path : path.TrimEnd('/')+"/"+relative : null;
            items.Add(new(code,relative,managed,absolute));
        }
        if (status=="complete" && items.Count>0) throw Invalid();
        return new(id,path,status,entries,items.AsReadOnly());
    }
}
