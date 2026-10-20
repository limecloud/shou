using System.Reflection;
using System.Text.Json.Nodes;
using Shou.Windows.Services;

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
    if (mode == "error") { await Emit("result", new() { ["api_version"] = "1.0", ["ok"] = false, ["error"] = new JsonObject { ["code"] = "plan_stale", ["message"] = "Changed evidence" } }); return 0; }
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
static void Require(bool condition) { if (!condition) throw new Exception("Check failed"); }
async Task Failure(string code, Func<Task<JsonNode>> action)
{
    try { await action(); } catch (BridgeException error) when (error.Code == code) { return; }
    throw new Exception("Expected " + code);
}
await Check("UTF-8、参数隔离、同时排空诊断", async () =>
{
    var result = await Fixture("echo").RequestAsync("capabilities", new() { ["path"] = "中文 空格 & $(literal)" });
    Require(result["input"]?["path"]?.GetValue<string>() == "中文 空格 & $(literal)");
    Require(result["arguments"] is JsonArray { Count: 1 } list && list[0]?.GetValue<string>() == "--desktop-bridge");
});
await Check("结构化错误", () => Failure("plan_stale", () => Fixture("error").RequestAsync("scan")));
await Check("非法 JSON 拒绝", () => Failure("transport_failed", () => Fixture("invalid").RequestAsync("scan")));
await Check("重复字段拒绝", () => Failure("transport_failed", () => Fixture("duplicate").RequestAsync("scan")));
await Check("输出超限立即结束只读生产者", () => Failure("output_limit", () => Fixture("overflow").RequestAsync("scan")));
await Check("只读请求期限", () => Failure("request_timeout", () => Fixture("timeout", TimeSpan.FromMilliseconds(500)).RequestAsync("scan")));
await Check("确认绑定本次挑战和摘要", async () =>
{
    var result = await Fixture("confirm").RequestAsync("plan.execute", confirm: _ => Task.FromResult(true));
    Require(result["kind"]?.GetValue<string>() == "confirm" && result["challenge"]?.GetValue<string>() == "one-use" && result["digest"]?.GetValue<string>() == "scope-digest");
});
await Check("缺少确认处理器时取消", async () =>
{
    var result = await Fixture("confirm").RequestAsync("plan.execute"); Require(result["kind"]?.GetValue<string>() == "cancel");
});
await Check("变更请求协作取消并等待回执", async () =>
{
    using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
    var result = await Fixture("mutation-cancel").RequestAsync("plan.execute", cancellation: stop.Token);
    Require(result["kind"]?.GetValue<string>() == "cancel" && result["receipt_saved"]?.GetValue<bool>() == true);
});
await Check("过大输入在启动前拒绝", () => Failure("input_limit", () => Fixture("echo").RequestAsync("configuration", new() { ["value"] = new string('x', 1024 * 1024) })));
if (args.Length == 2 && args[0] == "--engine")
{
    await Check("真实共享 CLI 能力发现", async () =>
    {
        var result = await new BridgeProcessClient(Path.GetFullPath(args[1])).RequestAsync("capabilities");
        Require(result["api_version"]?.GetValue<string>() == "1.0" && result["bridge_version"]?.GetValue<int>() == 1);
    });
}
Console.WriteLine($"{passed} process bridge checks passed; no user files changed.");
return 0;
