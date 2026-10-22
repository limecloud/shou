using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Shou.Windows.Services;

/// <summary>Owns one read-only native preview process; closing the view stops it.</summary>
public sealed class WindowsPreviewSession(string executable, IEnumerable<string>? argumentPrefix = null, TimeSpan? startupTimeout = null)
{
    private readonly string[] prefix = argumentPrefix?.ToArray() ?? [];
    private readonly TimeSpan startupTimeout = startupTimeout ?? TimeSpan.FromSeconds(10);

    public async Task RunAsync(JsonObject preview, ulong hostWindow, Action ready, CancellationToken cancellation = default)
    {
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable) || hostWindow == 0 || startupTimeout <= TimeSpan.Zero)
            throw Failure("invalid_preview");
        var input = JsonSerializer.SerializeToUtf8Bytes(new JsonObject {
            ["version"] = 1, ["parent_pid"] = Environment.ProcessId, ["host_window"] = hostWindow, ["preview"] = preview.DeepClone()
        });
        if (input.Length > 65536) throw Failure("input_limit");
        cancellation.ThrowIfCancellationRequested();
        var start = new ProcessStartInfo(executable) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), WorkingDirectory = Path.GetDirectoryName(executable)!
        };
        foreach (var value in prefix) start.ArgumentList.Add(value);
        start.ArgumentList.Add("--native-preview-worker");
        using var process = new Process { StartInfo = start };
        using var stopping = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        stopping.CancelAfter(startupTimeout);
        bool started = false, initialized = false, closed = false;
        string? remoteError = null;
        Exception? transportError = null;
        void Stop() { try { if (started && !process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } }
        using var registration = stopping.Token.Register(Stop);
        async Task Output()
        {
            try {
                var bytes = new byte[4096]; using var line = new MemoryStream(); int total = 0;
                while (true) {
                    var count = await process.StandardOutput.BaseStream.ReadAsync(bytes, stopping.Token);
                    if (count == 0) break;
                    total += count; if (total > 16384) throw Failure("output_limit");
                    for (var index = 0; index < count; index++) {
                        if (bytes[index] != 10) { line.WriteByte(bytes[index]); continue; }
                        using var document = JsonDocument.Parse(line.ToArray()); line.SetLength(0);
                        var value = document.RootElement;
                        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() != value.EnumerateObject().Count()
                            || value.GetProperty("version").GetInt32() != 1) throw Failure("transport_failed");
                        var kind = value.GetProperty("kind").GetString();
                        if (closed || remoteError is not null) throw Failure("transport_failed");
                        if (kind == "ready" && !initialized && value.EnumerateObject().Count() == 2) {
                            stopping.Token.ThrowIfCancellationRequested();
                            initialized = true; stopping.CancelAfter(Timeout.InfiniteTimeSpan); ready();
                        }
                        else if (kind == "closed" && initialized && value.EnumerateObject().Count() == 2) closed = true;
                        else if (kind == "error" && value.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.String
                            && value.EnumerateObject().All(p => p.Name is "version" or "kind" or "code" or "native_code")) { remoteError = code.GetString(); throw Failure(string.IsNullOrEmpty(remoteError) ? "transport_failed" : remoteError); }
                        else throw Failure("transport_failed");
                    }
                }
                if (line.Length != 0) throw Failure("transport_failed");
            }
            catch (Exception error) { transportError ??= error; stopping.Cancel(); throw; }
        }
        async Task Diagnostics()
        {
            try {
                var buffer = new byte[4096]; int total = 0, count;
                while ((count = await process.StandardError.BaseStream.ReadAsync(buffer, stopping.Token)) > 0) {
                    total += count; if (total > 16384) throw Failure("output_limit");
                }
            }
            catch (Exception error) { transportError ??= error; stopping.Cancel(); throw; }
        }
        Task output = Task.CompletedTask, diagnostics = Task.CompletedTask;
        try {
            if (!process.Start()) throw Failure("engine_not_found"); started = true;
            output = Output(); diagnostics = Diagnostics();
            await process.StandardInput.BaseStream.WriteAsync(input, stopping.Token);
            await process.StandardInput.BaseStream.FlushAsync(stopping.Token); process.StandardInput.Close();
            await Task.WhenAll(output, diagnostics, process.WaitForExitAsync(stopping.Token));
            if (remoteError is not null) throw Failure(remoteError);
            if (process.ExitCode != 0 || !initialized || !closed) throw Failure("preview_unavailable");
        }
        catch {
            cancellation.ThrowIfCancellationRequested();
            if (transportError is not null && transportError is not OperationCanceledException) throw Failure(transportError is BridgeException bridge ? bridge.Code : "transport_failed");
            if (stopping.IsCancellationRequested && !initialized) throw Failure("preview_timeout");
            throw;
        }
        finally {
            stopping.Cancel();
            Stop();
            if (started) {
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(3)); } catch (TimeoutException) { }
                try { await Task.WhenAll(output, diagnostics); } catch (Exception) { }
            }
        }
    }

    private static BridgeException Failure(string code) => new(code, T("系统预览未能完成，文件信息已保留。"));
}
