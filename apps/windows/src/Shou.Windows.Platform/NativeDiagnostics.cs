using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public static class NativeDiagnostics
{
    private static readonly string Session = Guid.NewGuid().ToString("N");
    private static readonly byte[] PathKey = RandomNumberGenerator.GetBytes(32);
    private static readonly Lazy<IDisposable> Subscription = new(() => OperationDiagnostics.Source.Subscribe(new Observer()));
    private static readonly object Gate = new();
    private static long dropped;
    [ThreadStatic] private static bool writing;
    public static long DroppedEvents => Interlocked.Read(ref dropped);
    public static string LogDirectory => Environment.GetEnvironmentVariable("SHOU_DIAGNOSTICS_DIR") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "Diagnostics");

    public static void Initialize() => _ = Subscription.Value;

    public static void Write(Exception error, [CallerMemberName] string stage = "unhandled")
    {
        Initialize();
        using var operation = OperationDiagnostics.Start("application.exception");
        operation.Fail(error, stage);
    }

    public static async Task<T> RunAsync<T>(string name, Func<Task<T>> run)
    {
        Initialize();
        using var operation = OperationDiagnostics.Start(name);
        try { var result = await run().ConfigureAwait(false); operation.Complete(); return result; }
        catch (Exception error) { operation.Fail(error); throw; }
    }

    internal static string Format(OperationDiagnostic value)
    {
        var exceptions = new List<object>();
        for (var error = value.Error; error is not null && exceptions.Count < 4; error = error.InnerException)
            exceptions.Add(new
            {
                type = error.GetType().FullName,
                code = ErrorCode(error),
                hresult = $"0x{error.HResult:X8}",
                win32_error = error is Win32Exception native ? native.NativeErrorCode : (int?)null,
                // Method names retain useful call sites without source paths or exception messages.
                stack = new StackTrace(error, false).GetFrames().Take(16)
                    .Select(frame => frame.GetMethod()).Where(method => method is not null)
                    .Select(method => method!.DeclaringType?.FullName + "." + method.Name).ToArray(),
                xaml_startup_message = Environment.GetEnvironmentVariable("SHOU_XAML_STARTUP_DIAGNOSTICS") == "1" &&
                    error.GetType().FullName == "Microsoft.UI.Xaml.Markup.XamlParseException" ? error.Message[..Math.Min(error.Message.Length, 2048)] : null
            });
        return JsonSerializer.Serialize(new
        {
            schema_version = 1, at_utc = DateTimeOffset.UtcNow, session_id = Session, process_id = Environment.ProcessId,
            application_version = typeof(NativeDiagnostics).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
            os = RuntimeInformation.OSDescription, architecture = RuntimeInformation.ProcessArchitecture.ToString(),
            operation_id = value.OperationId, parent_id = value.ParentId, operation = Label(value.Operation), @event = Label(value.Event),
            duration_ms = Math.Round(value.DurationMs, 2), state = Label(value.State), code = Label(value.Code ?? (value.Error is null ? null : ErrorCode(value.Error))),
            stage = Label(value.Stage), owner_kind = Label(value.OwnerKind), count = value.Count, issue_count = value.IssueCount,
            path_ref = value.Path is null ? null : Convert.ToHexStringLower(HMACSHA256.HashData(PathKey, Encoding.UTF8.GetBytes(value.Path.Value)))[..16],
            exceptions, dropped_events = DroppedEvents
        });
    }

    private static string? Label(string? value) => value is null ? null : value.Length is > 0 and <= 96 &&
        value.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '.' or '-') ? value : "redacted";
    private static string ErrorCode(Exception error) => error switch
    {
        ShouException known => Label(known.Code)!, OperationCanceledException => "cancelled",
        UnauthorizedAccessException => "permission_denied", IOException => "io_error", _ => "unexpected_error"
    };

    private sealed class Observer : IObserver<KeyValuePair<string, object?>>
    {
        public void OnNext(KeyValuePair<string, object?> item)
        {
            if (writing || item.Value is not OperationDiagnostic value) return;
            writing = true;
            try { Append(Format(value)); }
            catch (Exception) { Interlocked.Increment(ref dropped); }
            finally { writing = false; }
        }
        public void OnCompleted() { }
        public void OnError(Exception error) => Interlocked.Increment(ref dropped);
    }

    internal static void Append(string line) => Append(line, WindowsRecordStore.ForDiagnostics());

    internal static void Append(string line, WindowsRecordStore store)
    {
        lock (Gate) AppendLocked(line, store);
    }

    private static void AppendLocked(string line, WindowsRecordStore store)
    {
        const int maximumBytes = 1_048_576;
        var bytes = Encoding.UTF8.GetBytes(line + "\n");
        if (bytes.Length > maximumBytes / 4) throw new IOException("Diagnostic event exceeds its bound.");
        var mutexName = "Local\\ShouDiagnostics-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(store.OwnerSid + store.Directory.Value)))[..24];
        using var mutex = new Mutex(false, mutexName);
        var held = false;
        try
        {
            try { held = mutex.WaitOne(TimeSpan.FromSeconds(1)); }
            catch (AbandonedMutexException) { held = true; }
            if (!held) throw new IOException("Diagnostic log is busy.");
            using var pinned = store.PinPrivateDirectory();
            using var handle = store.OpenDiagnosticFile("application.jsonl");
            using var stream = new FileStream(handle, FileAccess.ReadWrite);
            if (stream.Length + bytes.Length > maximumBytes)
            {
                using var previousHandle = store.OpenDiagnosticFile("application.jsonl.previous");
                using var previous = new FileStream(previousHandle, FileAccess.ReadWrite);
                previous.SetLength(0);
                stream.Position = 0;
                stream.CopyTo(previous);
                previous.Flush();
                stream.SetLength(0);
            }
            stream.Position = stream.Length;
            stream.Write(bytes);
            stream.Flush();
        }
        finally { if (held) mutex.ReleaseMutex(); }
    }
}
