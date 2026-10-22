using System.Reflection;
using System.Text.Json.Nodes;
using Shou.Windows.Services;

if (args.FirstOrDefault() == "--preview-fixture")
{
    var mode = args[1];
    if (args.Last() != "--native-preview-worker") return 2;
    var input = JsonNode.Parse(await Console.In.ReadToEndAsync())!;
    if (input["version"]!.GetValue<int>() != 1 || input["host_window"]!.GetValue<ulong>() != 123 || input["parent_pid"]!.GetValue<int>() <= 0) return 2;
    if (mode == "timeout") { await Task.Delay(30000); return 0; }
    if (mode == "missing-ready") return 0;
    if (mode == "overflow") { await Console.Out.WriteAsync(new string('x', 20000)); await Task.Delay(30000); return 0; }
    if (mode == "error") { await Console.Out.WriteLineAsync("{\"version\":1,\"kind\":\"error\",\"code\":\"plan_stale\"}"); return 1; }
    await Console.Out.WriteLineAsync("{\"version\":1,\"kind\":\"ready\"}");
    if (mode == "stderr-overflow") { await Console.Error.WriteAsync(new string('x', 20000)); await Task.Delay(30000); return 0; }
    if (mode == "hang") { await Task.Delay(30000); return 0; }
    if (mode == "duplicate") { await Console.Out.WriteLineAsync("{\"version\":1,\"kind\":\"ready\"}"); await Task.Delay(30000); return 0; }
    if (mode == "partial") { await Console.Out.WriteAsync("{\"version\":1"); return 0; }
    if (mode == "delayed-close") await Task.Delay(2300);
    await Console.Out.WriteLineAsync("{\"version\":1,\"kind\":\"closed\"}");
    return mode == "badexit" ? 3 : 0;
}

if (args.Length == 4 && args[0] == "--install-cli-fixture")
{
    try
    {
        var installer = new WindowsCliInstallation(args[1], args[2], args[3]);
        var preview = installer.Preview();
        Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(installer.Install(preview.Digest), new System.Text.Json.JsonSerializerOptions { PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower }));
        return 0;
    }
    catch (IOException error) { Console.Error.WriteLine(error.Message); return 1; }
}

if (args.FirstOrDefault() == "--fixture")
{
    var mode = args[1];
    var request = JsonNode.Parse((await Console.In.ReadLineAsync())!)!;
    var id = request["request_id"]!.GetValue<string>();
    async Task Emit(string kind, JsonObject value) => await Console.Out.WriteLineAsync(new JsonObject { ["bridge_version"] = 1, ["request_id"] = id, ["kind"] = kind, ["value"] = value }.ToJsonString());
    async Task Result(JsonObject value) => await Emit("result", new() { ["api_version"] = "1.0", ["ok"] = true, ["data"] = value });
    if (mode == "timeout") { await Task.Delay(TimeSpan.FromMinutes(1)); return 0; }
    if (mode == "overflow") { await Console.Out.WriteAsync(new string('x', 9 * 1024 * 1024)); await Task.Delay(TimeSpan.FromMinutes(1)); return 0; }
    if (mode == "duplicate") { await Console.Out.WriteLineAsync("{\"bridge_version\":1,\"bridge_version\":2}"); return 0; }
    if (mode == "invalid") { await Console.Out.WriteLineAsync("not a protocol"); return 0; }
    if (mode == "error") { await Emit("result", new() { ["api_version"] = "1.0", ["ok"] = false, ["error"] = new JsonObject { ["code"] = "plan_stale", ["message"] = "Changed evidence", ["details"] = new JsonObject { ["issues"] = "$.match: generated fixture issue" } } }); return 0; }
    if (mode == "ai-partial") {
        await Emit("result",new() { ["api_version"]="1.0",["ok"]=false,["status"]="partial",["data"]=new JsonObject { ["id"]="investigation_fixture",["status"]="cancelled",["evidence"]=new JsonArray(new JsonObject { ["path"]="build/cache" }) } }); return 0;
    }
    if (mode == "ai-cancel") {
        var control=JsonNode.Parse((await Console.In.ReadLineAsync())!)!;
        await Emit("result",new() { ["api_version"]="1.0",["ok"]=false,["status"]="partial",["data"]=new JsonObject { ["id"]="investigation_fixture",["status"]="cancelled",["control"]=control["kind"]!.DeepClone() } }); return 0;
    }
    if (mode == "confirm")
    {
        await Emit("confirmation", new() { ["challenge"] = "one-use", ["digest"] = "scope-digest", ["operation"] = "trash", ["review"] = new JsonObject { ["items"] = new JsonArray() } });
        var control = JsonNode.Parse((await Console.In.ReadLineAsync())!)!;
        await Result(new() { ["kind"] = control["kind"]!.DeepClone(), ["challenge"] = control["challenge"]?.DeepClone(), ["digest"] = control["digest"]?.DeepClone() }); return 0;
    }
    if (mode == "mutation-cancel")
    {
        var control = JsonNode.Parse((await Console.In.ReadLineAsync())!)!;
        await Task.Delay(100);
        await Result(new() { ["kind"] = control["kind"]!.DeepClone(), ["receipt_saved"] = true }); return 0;
    }
    await Console.Error.WriteAsync(new string('诊', 300_000));
    await Result(new() { ["input"] = request["input"]!.DeepClone(), ["arguments"] = new JsonArray(args.Skip(2).Select(value => (JsonNode?)JsonValue.Create(value)).ToArray()) });
    return 0;
}

var executable = Environment.ProcessPath ?? throw new Exception("Missing process executable");
var prefix = Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase) ? new[] { Assembly.GetExecutingAssembly().Location } : System.Array.Empty<string>();
BridgeProcessClient Fixture(string mode, TimeSpan? timeout = null) => new(executable, prefix.Concat(["--fixture", mode]), timeout: timeout);
var passed = 0;
async Task Check(string title, Func<Task> action) { await action(); passed++; Console.WriteLine("PASS " + title); }
await DesktopSettingsChecks.Run(Check);
await CliInstallationChecks.Run(Check);
await SystemPreviewChecks.Run(Check);
await Check("progress paths shorten only the middle and preserve Unicode text elements", () =>
{
    if (ProgressPresentation.ShortPath("C:\\Users\\person\\build\\output.bin") != "C:/Users/person/build/output.bin") throw new Exception("Short Windows paths must be preserved.");
    if (ProgressPresentation.ShortPath("/Users/person/build/output.bin") != "/Users/person/build/output.bin") throw new Exception("Short POSIX paths must be preserved.");
    if (ProgressPresentation.ShortPath("/file.bin") != "/file.bin") throw new Exception("Short paths must be preserved.");
    if (ProgressPresentation.ShortPath("") != "") throw new Exception("Empty paths must be preserved.");
    if (ProgressPresentation.ShortPath("/a/line\r\n/tab\tfile") != "/a/line /tab file") throw new Exception("Progress paths must remain on one line.");
    foreach (var path in new[] {
        "/Users/person/Library/Containers/long.application.identifier/Data/Library/Caches/LINE.lproj/locale.pak",
        "C:/Users/person/AppData/Local/long.application.identifier/Cache/LINE.lproj/locale.pak",
        "/Users/测试/" + string.Concat(Enumerable.Repeat("e\u0301👩🏽‍💻中文", 30)) + "/locale.pak" })
    {
        var elements = System.Globalization.StringInfo.ParseCombiningCharacters(path);
        var shortened = ProgressPresentation.ShortPath(path);
        if (shortened != path[..elements[24]] + "…" + path[elements[^39]..] || System.Globalization.StringInfo.ParseCombiningCharacters(shortened).Length != 64)
            throw new Exception("Only the middle may be shortened, without splitting a text element.");
    }
    if (ProgressPresentation.ShortPath(new string('a', 64)) != new string('a', 64)
        || ProgressPresentation.ShortPath(new string('a', 65)) != new string('a', 24) + "…" + new string('a', 39))
        throw new Exception("Progress path length boundary is incorrect.");
    var longPath = "C:/Users/person/AppData/Local/long.application.identifier/Cache/LINE.lproj/locale.pak";
    var fitted = ProgressPresentation.FitPath(longPath, value => value.Length <= 21);
    if (fitted.Length != 21 || !fitted.StartsWith("C:/Users") || !fitted.EndsWith("/locale.pak") || !fitted.Contains('…'))
        throw new Exception("Narrow layouts must shorten the middle instead of the filename.");
    if (ProgressPresentation.FitPath(longPath, value => value.Length <= 0) != "")
        throw new Exception("Zero-width layouts must remain bounded.");
    return Task.CompletedTask;
});
static void Require(bool condition) { if (!condition) throw new Exception("Check failed"); }
await Check("扫描记录预览区分可回收、空记录和核验受阻", () =>
{
    var eligible = RecordMaintenanceSummary.Read(JsonNode.Parse("""
        {"records":[{"byte_count":4096},{"byte_count":1024}],"total_bytes":8192,"removable_bytes":5120,"retained_count":3,"issues":[]}
        """)!);
    Require(eligible.CanCollect && eligible.RemovableCount == 2 && eligible.RemovableBytes == 5120 && eligible.TotalBytes == 8192 && eligible.RetainedCount == 3);
    var empty = RecordMaintenanceSummary.Read(JsonNode.Parse("""
        {"records":[],"total_bytes":8192,"removable_bytes":0,"retained_count":3,"issues":[]}
        """)!);
    Require(!empty.CanCollect && empty.RemovableCount == 0 && empty.IssueCount == 0);
    var blocked = RecordMaintenanceSummary.Read(JsonNode.Parse("""
        {"records":[],"total_bytes":8192,"removable_bytes":0,"retained_count":3,"issues":["unreadable_plan:fixture"]}
        """)!);
    Require(!blocked.CanCollect && blocked.IssueCount == 1 && blocked.RetainedCount == 3);
    return Task.CompletedTask;
});
await Check("扫描记录预览拒绝缺失、负数、矛盾、溢出和核验未知的容量", () =>
{
    foreach (var json in new[] {
        "[]", "{}",
        """{"records":[],"total_bytes":0,"removable_bytes":-1,"retained_count":0,"issues":[]}""",
        """{"records":[{"byte_count":2}],"total_bytes":1,"removable_bytes":2,"retained_count":0,"issues":[]}""",
        """{"records":[{"byte_count":2}],"total_bytes":4,"removable_bytes":1,"retained_count":0,"issues":[]}""",
        """{"records":[{"byte_count":9223372036854775807},{"byte_count":1}],"total_bytes":9223372036854775807,"removable_bytes":0,"retained_count":0,"issues":[]}""",
        """{"records":[{"byte_count":1}],"total_bytes":1,"removable_bytes":1,"retained_count":0,"issues":["unknown"]}""",
        """{"records":[null],"total_bytes":0,"removable_bytes":0,"retained_count":0,"issues":[]}""",
        """{"records":[],"total_bytes":0,"removable_bytes":0,"retained_count":2147483648,"issues":[]}""",
        """{"records":[],"total_bytes":0,"removable_bytes":0,"retained_count":0,"issues":[null]}"""
    })
    {
        try { RecordMaintenanceSummary.Read(JsonNode.Parse(json)!); throw new Exception("Invalid record preview accepted."); }
        catch (BridgeException error) when (error.Code == "invalid_protocol") { }
    }
    return Task.CompletedTask;
});
await Check("空间导航仅在目录加载成功后提交，分支跳转清空前进记录", () =>
{
    var history = new StorageNavigationHistory();
    Require(history.Current == "." && history.BackTarget is null && history.ForwardTarget is null);
    history.Visit("project"); history.Visit("project/target");
    Require(history.BackTarget == "project" && history.Current == "project/target");
    // Inspecting a target before a failed load must not change the stacks.
    Require(history.BackTarget == "project" && history.Current == "project/target");
    history.CommitBack(); Require(history.Current == "project" && history.ForwardTarget == "project/target");
    history.CommitForward(); Require(history.Current == "project/target" && history.BackTarget == "project");
    history.CommitBack(); history.Visit("other"); Require(history.ForwardTarget is null && history.BackTarget == "project");
    history.Visit("other"); history.CommitBack(); Require(history.Current == "project");
    history.Reset(); Require(history.Current == "." && history.BackTarget is null && history.ForwardTarget is null);
    return Task.CompletedTask;
});
await Check("清理选择跨页保留、三态聚合与容量去重", () =>
{
    var selection = new CleanupSelection();
    var first = new CleanupChoice("scan:a", "scan", "a", "root", "C:/projects/a/target", "build", "cargo", 100);
    var second = first with { Key = "scan:b", CandidateId = "b", AbsolutePath = "C:/projects/b/target", Bytes = 200 };
    var cache = first with { Key = "cache:c", ScanId = "cache", CategoryId = "browser", GroupId = "edge", Bytes = 300 };
    Require(selection.State(2, "build", "cargo") == false);
    selection.Set(first, true);
    Require(selection.State(2, "build", "cargo") is null && selection.Bytes == 100);
    selection.Set(first, true); // Loading another page must not charge a source twice.
    selection.Set(second, true); selection.Set(cache, true);
    Require(selection.Count == 3 && selection.Bytes == 600 && selection.State(2, "build") == true);
    Require(selection.State(1, "browser", "edge") == true);
    selection.RemoveWhere(choice => choice.AbsolutePath.StartsWith("C:/projects/b/", StringComparison.Ordinal));
    Require(selection.Count == 2 && selection.Bytes == 400 && selection.Contains(first.Key) && selection.Contains(cache.Key));
    Require(selection.State(2, "build") is null && selection.State(1, "browser") == true);
    selection.Set(cache, false);
    Require(selection.State(1, "browser") == false && selection.Bytes == 100);
    selection.Clear();
    Require(selection.Count == 0 && selection.Bytes == 0 && selection.State(2, "build") == false);
    return Task.CompletedTask;
});
async Task Failure(string code, Func<Task<JsonNode>> action)
{
    try { await action(); } catch (BridgeException error) when (error.Code == code) { return; }
    throw new Exception("Expected " + code);
}
await Check("历史后续操作保持精确子集，拒绝混合权限和超限选择", () =>
{
    var both = new HistoryFollowUpChoice("both", true, true);
    var restoreOnly = new HistoryFollowUpChoice("restore-only", true, false);
    var blocked = new HistoryFollowUpChoice("pending", false, false);
    Require(!HistoryFollowUpSelection.CanSubmit("restore", []));
    Require(HistoryFollowUpSelection.ItemIds("restore", [restoreOnly, both]).SequenceEqual(["restore-only", "both"]));
    Require(HistoryFollowUpSelection.ItemIds("purge", [both]).SequenceEqual(["both"]));
    foreach (var selection in new HistoryFollowUpChoice[][] { [both, restoreOnly], [blocked], [both, both], [both with { Id = "" }] })
    {
        Require(!HistoryFollowUpSelection.CanSubmit("purge", selection));
        try { HistoryFollowUpSelection.ItemIds("purge", selection); throw new Exception("Invalid history selection accepted."); }
        catch (BridgeException error) when (error.Code == "invalid_argument") { }
    }
    Require(!HistoryFollowUpSelection.CanSubmit("restore", [both, blocked]));
    Require(!HistoryFollowUpSelection.CanSubmit("permanent", [both]));
    var maximum = Enumerable.Range(0, 500).Select(index => both with { Id = "item-" + index }).ToArray();
    Require(HistoryFollowUpSelection.ItemIds("purge", maximum).Length == 500);
    Require(!HistoryFollowUpSelection.CanSubmit("purge", maximum.Append(both).ToArray()));
    return Task.CompletedTask;
});
await Check("UTF-8、参数隔离、同时排空诊断", async () =>
{
    var result = await Fixture("echo").RequestAsync("capabilities", new() { ["path"] = "中文 空格 & $(literal)" });
    Require(result["input"]?["path"]?.GetValue<string>() == "中文 空格 & $(literal)");
    Require(result["arguments"] is JsonArray { Count: 1 } list && list[0]?.GetValue<string>() == "--desktop-bridge");
});
await Check("结构化错误", () => Failure("plan_stale", () => Fixture("error").RequestAsync("scan")));
await Check("规则校验问题详情保留",async()=> {
    try { await Fixture("error").RequestAsync("rules.validate"); }
    catch(BridgeException error) when(error.Code=="plan_stale" && error.Details?["issues"]?.GetValue<string>()=="$.match: generated fixture issue") { return; }
    throw new Exception("Structured rule issues were lost.");
});
await Check("非法 JSON 拒绝", () => Failure("transport_failed", () => Fixture("invalid").RequestAsync("scan")));
await Check("重复字段拒绝", () => Failure("transport_failed", () => Fixture("duplicate").RequestAsync("scan")));
await Check("输出超限立即结束只读生产者", () => Failure("output_limit", () => Fixture("overflow").RequestAsync("scan")));
await Check("只读请求期限", () => Failure("request_timeout", () => Fixture("timeout", TimeSpan.FromMilliseconds(500)).RequestAsync("scan")));
await Check("补扫、跨目录扫描和大文件查询遵守只读请求期限", async () =>
{
    foreach(var operation in new[] { "agent.setup", "skills.preview", "scan.target", "system.scan", "storage.large-files", "storage.browse", "storage.selection", "storage.preview", "cleanup.review", "startup.scan", "applications.scan", "applications.prepare-scan", "applications.uninstall-history", "privacy.scan", "privacy.history", "tools.scan", "tools.history", "history.inspect", "locations.scan", "presets.scan", "rules.draft", "rules.revision", "rules.validate", "rules.draft.preview", "records.preview" })
        await Failure("request_timeout", () => Fixture("timeout", TimeSpan.FromMilliseconds(500)).RequestAsync(operation));
});
await Check("历史位置核验支持取消并拒绝任何变更确认", async () =>
{
    using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
    await Failure("cancelled", () => Fixture("timeout").RequestAsync("history.inspect", cancellation: stop.Token));
    await Failure("invalid_protocol", () => Fixture("confirm").RequestAsync("history.inspect", confirm: _ => throw new Exception("Read-only verification requested consent.")));
});
await Check("确认绑定本次挑战和摘要", async () =>
{
    var result = await Fixture("confirm").RequestAsync("plan.execute", confirm: _ => Task.FromResult(true));
    Require(result["kind"]?.GetValue<string>() == "confirm" && result["challenge"]?.GetValue<string>() == "one-use" && result["digest"]?.GetValue<string>() == "scope-digest");
});
await Check("扫描范围查询只读且不能请求变更确认", () =>
    Failure("invalid_protocol", () => Fixture("confirm").RequestAsync("locations.scan", confirm: _ => throw new Exception("Read-only locations requested consent."))));
await Check("空间浏览和选择计算只读且不能请求变更确认", async () =>
{
    foreach (var operation in new[] { "storage.browse", "storage.selection", "storage.preview" })
        await Failure("invalid_protocol", () => Fixture("confirm").RequestAsync(operation, confirm: _ => throw new Exception("Read-only storage requested consent.")));
});
await Check("文件预览取消立即终止只读生产者", async () =>
{
    using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
    await Failure("cancelled", () => Fixture("timeout").RequestAsync("storage.preview", cancellation: stop.Token));
});
await Check("隐私统计、回执与扫描记录预览只读且不能请求变更确认", async () =>
{
    foreach (var operation in new[] { "agent.setup", "skills.preview", "privacy.scan", "privacy.history", "records.preview", "applications.prepare-scan", "applications.uninstall-history" })
        await Failure("invalid_protocol", () => Fixture("confirm").RequestAsync(operation, confirm: _ => throw new Exception("Read-only privacy requested consent.")));
});
await Check("缺少确认处理器时取消", async () =>
{
    var result = await Fixture("confirm").RequestAsync("plan.execute"); Require(result["kind"]?.GetValue<string>() == "cancel");
});
await Check("应用数据检查只读且清理取消等待独立回执", async () =>
{
    await Failure("invalid_protocol", () => Fixture("confirm").RequestAsync("applications.data-scan", confirm: _ => throw new Exception("Read-only data review requested consent.")));
    await Failure("request_timeout", () => Fixture("timeout", TimeSpan.FromMilliseconds(500)).RequestAsync("applications.data-scan"));
    using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
    var result = await Fixture("mutation-cancel").RequestAsync("applications.data-clean", cancellation: stop.Token);
    Require(result["kind"]?.GetValue<string>() == "cancel" && result["receipt_saved"]?.GetValue<bool>() == true);
});
await Check("应用占用测量只读且取消不请求确认", async () =>
{
    await Failure("invalid_protocol", () => Fixture("confirm").RequestAsync("applications.usage",confirm: _ => throw new Exception("Read-only usage requested consent.")));
    await Failure("request_timeout", () => Fixture("timeout",TimeSpan.FromMilliseconds(500)).RequestAsync("applications.usage"));
    using var stop=new CancellationTokenSource(500);
    await Failure("request_cancelled", () => Fixture("timeout").RequestAsync("applications.usage",cancellation: stop.Token));
});
await Check("MSIX 数据历史只读且清理取消等待独立回执", async () =>
{
    await Failure("invalid_protocol", () => Fixture("confirm").RequestAsync("applications.package-data-history", confirm: _ => throw new Exception("Read-only package history requested consent.")));
    await Failure("request_timeout", () => Fixture("timeout", TimeSpan.FromMilliseconds(500)).RequestAsync("applications.package-data-history"));
    using var stop=new CancellationTokenSource(500);
    var receipt=await Fixture("mutation-cancel").RequestAsync("applications.package-data-clear",cancellation: stop.Token);
    Require(receipt["kind"]?.GetValue<string>()=="cancel" && receipt["receipt_saved"]?.GetValue<bool>()==true);
});
await Check("变更请求协作取消并等待回执", async () =>
{
    foreach(var operation in new[] { "skills.install", "skills.export", "plan.execute", "startup.control", "workspace.remove", "privacy.clean", "cleanup.close-owners", "applications.uninstall", "tools.clean", "records.collect" }) {
        using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
        var result = await Fixture("mutation-cancel").RequestAsync(operation, cancellation: stop.Token);
        Require(result["kind"]?.GetValue<string>() == "cancel" && result["receipt_saved"]?.GetValue<bool>() == true);
    }
});
await Check("AI 部分结果保留证据，普通业务错误仍拒绝", async () => {
    var result=await Fixture("ai-partial").RequestAsync("ai.investigate");
    Require(result["status"]?.GetValue<string>()=="cancelled" && result["evidence"] is JsonArray { Count:1 });
    await Failure("engine_error",()=>Fixture("ai-partial").RequestAsync("plan.execute"));
});
await Check("AI 请求协作取消并保留检查点", async () => {
    using var stop=new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
    var result=await Fixture("ai-cancel").RequestAsync("ai.investigate",cancellation:stop.Token);
    Require(result["status"]?.GetValue<string>()=="cancelled" && result["control"]?.GetValue<string>()=="cancel");
});
await Check("过大输入在启动前拒绝", () => Failure("input_limit", () => Fixture("echo").RequestAsync("configuration", new() { ["value"] = new string('x', 1024 * 1024) })));
if (args.Length == 2 && args[0] == "--engine")
{
    await Check("真实共享 CLI 能力发现", async () =>
    {
        var result = await new BridgeProcessClient(Path.GetFullPath(args[1])).RequestAsync("capabilities");
        Require(result["api_version"]?.GetValue<string>() == "1.0" && result["bridge_version"]?.GetValue<int>() == 1);
    });
    await Check("真实共享扫描记录预览及回收仅使用独占空数据目录", async () =>
    {
        var fixture = Directory.CreateTempSubdirectory("shou-record-maintenance-check-");
        // Resolve the generated fixture's ancestors, including macOS /var.
        static string CanonicalDirectory(DirectoryInfo directory) => directory.ResolveLinkTarget(returnFinalTarget: true) is DirectoryInfo target
            ? CanonicalDirectory(target) : directory.Parent is { } parent ? Path.Combine(CanonicalDirectory(parent), directory.Name) : directory.FullName;
        try
        {
            var client = new BridgeProcessClient(Path.GetFullPath(args[1]), dataDirectory: Path.Combine(CanonicalDirectory(fixture), "data"));
            foreach (var operation in new[] { "records.preview", "records.collect" })
            {
                var summary = RecordMaintenanceSummary.Read(await client.RequestAsync(operation));
                Require(!summary.CanCollect && summary.TotalBytes == 0 && summary.RemovableCount == 0 && summary.RetainedCount == 0 && summary.IssueCount == 0);
            }
        }
        finally { fixture.Delete(recursive: true); }
    });
}
Console.WriteLine($"{passed} process bridge checks passed; no user files changed.");
return 0;
