using System.Globalization;
using System.Text.Json.Nodes;
using Shou.Windows.Services;

internal static class StorageCoverageChecks
{
    private static void Require(bool value) { if(!value)throw new Exception("Storage coverage check failed."); }
    private static JsonObject Payload(string status="partial") => new()
    {
        ["scan_id"]="storage_fixture",["root_path"]="C:/fixture 中文 & literal",["status"]=status,["entry_count"]=1200L,["coverage_notes"]=new JsonArray()
    };
    private static JsonObject Note(string code,string path,bool managed=false) => new() { ["code"]=code,["path"]=path,["system_managed"]=managed };
    public static async Task Run(Func<string,Func<Task>,Task> check)
    {
        await check("扫描覆盖区分完整、部分、缺少原因和系统管理位置",()=>
        {
            var originalLanguage=UiText.RequestedLanguage;
            var originalCulture=CultureInfo.CurrentUICulture;
            try
            {
                foreach(var language in new[] { "zh-CN","en" })
                {
                    UiText.SetLanguage(language,CultureInfo.InvariantCulture);
                    var complete=StorageCoverageSummary.Read(Payload("complete"));
                    var partial=StorageCoverageSummary.Read(Payload());
                    Require(!complete.Partial && partial.Partial && complete.State!=partial.State && complete.EmptyMessage!=partial.EmptyMessage);
                    var input=Payload();
                    input["coverage_notes"]=new JsonArray(Note("unreadable_directory","project/cache"),Note("unreadable","Windows",true),Note("cloud_placeholder","online"),Note("resource_limit","."),Note("new_future_code","future"));
                    var before=input.ToJsonString();
                    var summary=StorageCoverageSummary.Read(input);
                    Require(input.ToJsonString()==before && summary.ScanId=="storage_fixture" && summary.EntryCount==1200 && summary.Items.Count==5);
                    Require(summary.Items[0].CanReveal && !summary.Items[1].CanReveal && summary.Items[1].CanCopy && summary.Items[1].SystemManaged);
                    Require(!summary.Items[2].CanReveal && summary.Items[2].Reason!=summary.Items[0].Reason);
                    Require(summary.Items[3].Reason!=summary.Items[0].Reason && summary.Items[4].Code=="new_future_code");
                    Require(summary.RootPath=="C:/fixture 中文 & literal" && summary.Items[0].AbsolutePath==summary.RootPath+"/project/cache");
                }
            }
            finally { UiText.SetLanguage(originalLanguage,originalCulture); }
            return Task.CompletedTask;
        });
        await check("覆盖路径固定于扫描根，旧诊断、汇总与越界文本不能复制或定位",()=>
        {
            foreach(var path in new[] { "../outside","/outside","C:/outside","//server/share","folder\\file","folder//file","folder/./file","folder/../file","file:stream","folder\nfile","old cache (5)" })
            {
                var input=Payload();input["coverage_notes"]=new JsonArray(Note("unreadable",path));
                var note=StorageCoverageSummary.Read(input).Items.Single();
                Require(!note.CanCopy && !note.CanReveal && note.Path==path && note.AbsolutePath is null);
            }
            foreach(var path in new[] { ".","中文 & literal/quote' file","cache (name)" })
            {
                var input=Payload();input["coverage_notes"]=new JsonArray(Note("changed_directory",path));
                var note=StorageCoverageSummary.Read(input).Items.Single();
                Require(note.CanCopy && !note.CanReveal && note.AbsolutePath==(path=="." ? "C:/fixture 中文 & literal" : "C:/fixture 中文 & literal/"+path));
            }
            var aggregate=Payload();aggregate["coverage_notes"]=new JsonArray(Note("additional_coverage_issues","9"));
            Require(!StorageCoverageSummary.Read(aggregate).Items.Single().CanCopy);
            var drive=Payload();drive["root_path"]="D:/";drive["coverage_notes"]=new JsonArray(Note("unreadable","folder"));
            Require(StorageCoverageSummary.Read(drive).Items.Single().AbsolutePath=="D:/folder");
            return Task.CompletedTask;
        });
        await check("覆盖信息拒绝缺失、错误类型、矛盾状态和无效根目录",()=>
        {
            var invalid=new List<JsonNode> { new JsonArray(),new JsonObject() };
            foreach(var (key,value) in new (string,JsonNode?)[] {
                ("scan_id",null),("scan_id",JsonValue.Create("../other")),("status",JsonValue.Create("unknown")),
                ("entry_count",JsonValue.Create(-1)),("entry_count",JsonValue.Create(0)),("entry_count",JsonValue.Create(1.5)),("entry_count",JsonValue.Create("1")),
                ("root_path",JsonValue.Create("relative")),("root_path",JsonValue.Create("C:/fixture/../outside")),("root_path",JsonValue.Create("//server/share")),
                ("coverage_notes",null),("coverage_notes",new JsonArray((JsonNode?)null)),("coverage_notes",new JsonArray(new JsonObject())),
                ("coverage_notes",new JsonArray(new JsonObject { ["code"]="unreadable",["path"]="folder",["system_managed"]="false" })),
                ("coverage_notes",new JsonArray(Note("unreadable","nul\0path"))),
                ("coverage_notes",new JsonArray(Enumerable.Range(0,1025).Select(_=>(JsonNode?)Note("unreadable","folder")).ToArray())) })
            { var valueWithError=Payload();valueWithError[key]=value;invalid.Add(valueWithError); }
            var contradictory=Payload("complete");contradictory["coverage_notes"]=new JsonArray(Note("unreadable","folder"));invalid.Add(contradictory);
            foreach(var value in invalid)
            {
                try { StorageCoverageSummary.Read(value);throw new Exception("Invalid scan coverage accepted."); }
                catch(BridgeException error) when(error.Code=="invalid_protocol") { }
            }
            return Task.CompletedTask;
        });
    }
}
