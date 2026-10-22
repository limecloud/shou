using System.Buffers;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Shou.Windows.Services;

public sealed class BridgeException(string code, string message, JsonObject? details = null) : Exception(message)
{
    public string Code { get; } = code;
    public JsonObject? Details { get; } = details?.DeepClone().AsObject();
}

/// <summary>Owns one request process. Filesystem mutations stop cooperatively.</summary>
public sealed class BridgeProcessClient
{
    private readonly string executable;
    private readonly string[] prefix;
    private readonly string? dataDirectory;
    private readonly TimeSpan timeout;
    private static readonly HashSet<string> Reads = ["capabilities", "configuration", "locations.scan", "system.scan", "scan", "scan.target", "scan.results", "cleanup.review", "startup.scan", "applications.scan", "privacy.scan", "privacy.history", "presets.scan", "history", "history.page", "history.inspect", "history.cleanup-preview", "rules.preview", "rules.draft", "rules.validate", "rules.revision", "rules.draft.preview", "records.preview", "storage.scan", "storage.show", "storage.directory", "storage.map", "storage.context", "storage.page", "storage.browse", "storage.selection", "storage.preview", "storage.large-files"];

    public BridgeProcessClient(string executable, IEnumerable<string>? argumentPrefix = null, string? dataDirectory = null, TimeSpan? timeout = null)
    {
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable))
            throw new BridgeException("engine_not_found", "缺少随包清理核心，请安装完整的 Shou 应用。");
        this.executable = Path.GetFullPath(executable);
        prefix = argumentPrefix?.ToArray() ?? [];
        this.dataDirectory = dataDirectory;
        this.timeout = timeout ?? TimeSpan.FromMinutes(10);
        if (this.timeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(timeout));
    }

    public async Task<JsonNode> RequestAsync(string operation, JsonObject? input = null,
        IProgress<JsonObject>? progress = null, Func<JsonObject, Task<bool>>? confirm = null, CancellationToken cancellation = default)
    {
        var requestId = Guid.NewGuid().ToString("N");
        var request = new JsonObject { ["bridge_version"] = 1, ["request_id"] = requestId, ["operation"] = operation, ["input"] = input ?? [] };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(request);
        if (bytes.Length > 1024 * 1024) throw new BridgeException("input_limit", "请求超过 1 MiB，请缩小范围。");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), WorkingDirectory = Path.GetDirectoryName(executable)!
        };
        foreach (var argument in prefix) start.ArgumentList.Add(argument);
        start.ArgumentList.Add("--desktop-bridge");
        if (dataDirectory is not null) start.Environment["SHOU_DATA_DIR"] = Path.GetFullPath(dataDirectory);
        using var process = new Process { StartInfo = start };
        using var writes = new SemaphoreSlim(1);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(timeout);
        var readOnly = Reads.Contains(operation);
        var started = false;
        Task? diagnostics = null;
        Task cancellationWrite = Task.CompletedTask;
        CancellationTokenRegistration registration = default;
        async Task SendAsync(JsonObject control)
        {
            await writes.WaitAsync();
            try
            {
                var message = JsonSerializer.SerializeToUtf8Bytes(control);
                await process.StandardInput.BaseStream.WriteAsync(message);
                await process.StandardInput.BaseStream.WriteAsync(new byte[] { 10 });
                await process.StandardInput.BaseStream.FlushAsync();
            }
            catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
            finally { writes.Release(); }
        }
        JsonObject Control(string kind) => new() { ["bridge_version"] = 1, ["request_id"] = requestId, ["kind"] = kind };
        try
        {
            cancellation.ThrowIfCancellationRequested();
            started = process.Start();
            if (!started) throw new BridgeException("engine_start_failed", "清理核心未启动。");
            diagnostics = DrainAsync(process.StandardError.BaseStream);
            await process.StandardInput.BaseStream.WriteAsync(bytes, cancellation);
            await process.StandardInput.BaseStream.WriteAsync(new byte[] { 10 }, cancellation);
            await process.StandardInput.BaseStream.FlushAsync(cancellation);
            registration = deadline.Token.Register(() =>
            {
                cancellationWrite = SendAsync(Control("cancel"));
                if (readOnly) { try { process.Kill(entireProcessTree: true); } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { } }
            });
            var reader = new Lines(process.StandardOutput.BaseStream);
            var confirmations = 0;
            while (await reader.NextAsync() is { } line)
            {
                var envelope = Parse(line);
                if (envelope["bridge_version"]?.GetValue<int>() != 1 || envelope["request_id"]?.GetValue<string>() != requestId || envelope["value"] is not JsonNode value)
                    throw new BridgeException("invalid_protocol", "清理核心返回了不匹配的进程合同。");
                switch (envelope["kind"]?.GetValue<string>())
                {
                    case "progress":
                        if (value is not JsonObject update) throw new BridgeException("invalid_protocol", "无效的进度事件。");
                        progress?.Report(update); break;
                    case "confirmation":
                        if (readOnly || ++confirmations != 1 || value is not JsonObject review || review["challenge"] is not JsonValue || review["digest"] is not JsonValue)
                            throw new BridgeException("invalid_protocol", "无效的确认请求。");
                        var accepted = !deadline.IsCancellationRequested && confirm is not null && await confirm(review);
                        var response = Control(accepted && !deadline.IsCancellationRequested ? "confirm" : "cancel");
                        if (response["kind"]!.GetValue<string>() == "confirm")
                        {
                            response["challenge"] = review["challenge"]!.DeepClone(); response["digest"] = review["digest"]!.DeepClone();
                        }
                        await SendAsync(response); break;
                    case "result":
                        if (value is not JsonObject result || result["api_version"]?.GetValue<string>() != "1.0" || result["ok"] is not JsonValue flag || !flag.TryGetValue<bool>(out var ok))
                            throw new BridgeException("invalid_protocol", "清理核心结果合同不兼容。");
                        process.StandardInput.Close();
                        await process.WaitForExitAsync();
                        if (process.ExitCode != 0) throw new BridgeException("engine_failed", "清理核心异常退出；请查询历史确认实际状态。");
                        await diagnostics;
                        // AI failures carry a checkpoint, evidence and a resumable
                        // user-facing status. Preserve that bounded partial result.
                        var aiPartial = operation.StartsWith("ai.", StringComparison.Ordinal) &&
                            result["status"]?.GetValue<string>() == "partial" &&
                            result["data"] is JsonObject checkpoint &&
                            checkpoint["status"]?.GetValue<string>() is "failed" or "cancelled" or "limited";
                        if (!ok && !aiPartial)
                        {
                            var error = result["error"] as JsonObject;
                            throw new BridgeException(error?["code"]?.GetValue<string>() ?? "engine_error", error?["message"]?.GetValue<string>() ?? "操作未完成，请查询实际状态。", error?["details"] as JsonObject);
                        }
                        return result["data"]?.DeepClone() ?? throw new BridgeException("invalid_protocol", "缺少业务结果。");
                    default: throw new BridgeException("invalid_protocol", "未知的清理核心事件。");
                }
            }
            if (deadline.IsCancellationRequested) throw new BridgeException(cancellation.IsCancellationRequested ? "cancelled" : "request_timeout", "请求已停止；变更结果请以历史回执为准。");
            throw new BridgeException("engine_disconnected", "清理核心连接中断；请查询历史，勿自动重试变更。");
        }
        catch (OperationCanceledException) { throw new BridgeException("cancelled", "请求已取消。"); }
        catch (Exception error) when (error is IOException or JsonException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            if (deadline.IsCancellationRequested) throw new BridgeException(cancellation.IsCancellationRequested ? "cancelled" : "request_timeout", "请求已停止；变更结果请以历史回执为准。");
            throw new BridgeException("transport_failed", "清理核心通信失败；请查询历史确认实际状态。" + error.Message);
        }
        finally
        {
            // Dispose waits for the callback to publish its write task. Observe
            // that task before disposing the pipe and serialization semaphore.
            registration.Dispose();
            await cancellationWrite;
            if (started)
            {
                try { process.StandardInput.Close(); } catch (InvalidOperationException) { }
                if (readOnly) { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { } }
                // Closing stdin requests cooperative cancellation of a mutation.
                // Never kill a process that may be writing a cleanup receipt.
                try
                {
                    if (!readOnly) await DrainAsync(process.StandardOutput.BaseStream);
                    await process.WaitForExitAsync();
                    if (diagnostics is not null) await diagnostics;
                }
                catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
            }
        }
    }

    private static async Task DrainAsync(Stream source)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(65536);
        try { while (await source.ReadAsync(buffer) > 0) { } }
        finally { ArrayPool<byte>.Shared.Return(buffer); }
    }
    private static JsonObject Parse(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 64 });
        static void Unique(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.Object)
            {
                var keys = new HashSet<string>(StringComparer.Ordinal);
                foreach (var property in value.EnumerateObject()) { if (!keys.Add(property.Name)) throw new JsonException("重复的 JSON 字段。"); Unique(property.Value); }
            }
            else if (value.ValueKind == JsonValueKind.Array) foreach (var child in value.EnumerateArray()) Unique(child);
        }
        Unique(document.RootElement);
        return JsonNode.Parse(bytes) as JsonObject ?? throw new JsonException("Expected an object.");
    }
    private sealed class Lines(Stream source)
    {
        private readonly List<byte> pending = [];
        private readonly byte[] buffer = new byte[65536];
        private int position, count, total;
        public async Task<byte[]?> NextAsync()
        {
            while (true)
            {
                if (position == count)
                {
                    count = await source.ReadAsync(buffer); position = 0;
                    if (count == 0) { if (pending.Count != 0) throw new JsonException("Truncated protocol line."); return null; }
                    total += count;
                    if (total > 64 * 1024 * 1024) throw new BridgeException("output_limit", "进程输出超过限额。");
                }
                var current = buffer[position++];
                if (current == 10) { var line = pending.ToArray(); pending.Clear(); return line; }
                if (pending.Count >= 8 * 1024 * 1024) throw new BridgeException("output_limit", "进程结果超过 8 MiB。");
                pending.Add(current);
            }
        }
    }
}
