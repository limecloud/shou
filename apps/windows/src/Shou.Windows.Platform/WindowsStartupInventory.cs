using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Fixed, read-only startup sources; no command execution, shortcut resolution or enablement guesses.</summary>
public sealed class WindowsStartupInventory : IStartupInventory
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private static readonly UnicodeEncoding StrictUnicode = new(false, false, true);

    public Task<StartupInventory> ReadAsync(StartupDiscoveryBudget budget, CancellationToken cancellationToken)
    {
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || !Environment.Is64BitProcess)
            throw new ShouException("unsupported_platform", "Startup discovery requires 64-bit Windows 11.");
        return ReadSourcesAsync(budget, ReadSourceAsync, cancellationToken);
    }

    internal static async Task<StartupInventory> ReadSourcesAsync(StartupDiscoveryBudget budget,
        Func<StartupSource, int, CancellationToken, Task<StartupInventory>> read, CancellationToken cancellationToken)
    {
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(budget.Duration);
        var token = deadline.Token;
        var registrations = ImmutableArray.CreateBuilder<StartupRegistration>();
        var coverage = ImmutableArray.CreateBuilder<StartupSourceCoverage>();
        var remaining = budget.MaxEntries;
        var consumptionUnknown = false;
        foreach (var source in Enum.GetValues<StartupSource>())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (remaining == 0 || deadline.IsCancellationRequested)
            {
                coverage.Add(new(source, StartupSourceState.NotRead, 0, [consumptionUnknown ? "entry_budget_unknown" : remaining == 0 ? "entry_limit" : "time_limit"]));
                continue;
            }
            try
            {
                var result = await read(source, remaining, token).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                var observed = result.Sources.Single();
                if (observed.Source != source || observed.InspectedEntries < 0 || observed.InspectedEntries > remaining ||
                    result.Registrations.IsDefault || result.Registrations.Any(item => item.Source != source) ||
                    result.Registrations.Length > (observed.InspectedEntries ?? 0))
                    throw new ShouException("startup_inventory_invalid", "The source returned invalid startup coverage.");
                consumptionUnknown = observed.InspectedEntries is null;
                remaining = consumptionUnknown ? 0 : remaining - observed.InspectedEntries!.Value;
                registrations.AddRange(result.Registrations);
                coverage.Add(observed);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { coverage.Add(new(source, StartupSourceState.Unavailable, null, ["time_limit"])); remaining = 0; consumptionUnknown = true; }
            catch (Exception error) when (ReadFailure(error))
            { coverage.Add(new(source, StartupSourceState.Unavailable, null, [ErrorCode(error)])); remaining = 0; consumptionUnknown = true; }
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new(registrations.ToImmutable(), coverage.ToImmutable());
    }

    private static async Task<StartupInventory> ReadSourceAsync(StartupSource source, int limit, CancellationToken token)
    {
        if (source == StartupSource.PackagedStartupTasks)
            return await NativeOperationScheduler.RunAsync(() => WindowsPackagedStartupTasks.Read(limit, token), token).ConfigureAwait(false);
        if (source == StartupSource.ScheduledTasks)
            return await NativeOperationScheduler.RunAsync(() => WindowsScheduledStartupTasks.Read(limit, token), token).ConfigureAwait(false);
        if (source is StartupSource.CurrentUserStartup or StartupSource.CommonStartup)
        {
            var folder = await NativeOperationScheduler.RunAsync(() => Environment.GetFolderPath(
                source == StartupSource.CurrentUserStartup ? Environment.SpecialFolder.Startup : Environment.SpecialFolder.CommonStartup,
                Environment.SpecialFolderOption.DoNotVerify), token).ConfigureAwait(false);
            if (string.IsNullOrEmpty(folder)) throw new ShouException("startup_folder_unavailable", "The startup folder could not be located.");
            return await ReadFolderAsync(new WindowsFileSystem(), WindowsPath.Parse(folder), source, limit, token).ConfigureAwait(false);
        }
        // Each worker owns its builders. A timed-out read cannot mutate a returned snapshot.
        return await NativeOperationScheduler.RunAsync(() => ReadRegistrySource(source, limit, token), token).ConfigureAwait(false);
    }

    private static StartupInventory ReadRegistrySource(StartupSource source, int limit, CancellationToken token)
    {
        var user = source is StartupSource.CurrentUserRun or StartupSource.CurrentUserRunOnce;
        var view = source is StartupSource.MachineRun32 or StartupSource.MachineRunOnce32 ? RegistryView.Registry32 : RegistryView.Registry64;
        var once = source is StartupSource.CurrentUserRunOnce or StartupSource.MachineRunOnce64 or StartupSource.MachineRunOnce32;
        using var root = RegistryKey.OpenBaseKey(user ? RegistryHive.CurrentUser : RegistryHive.LocalMachine, view);
        using var key = root.OpenSubKey(RunKey + (once ? "Once" : ""), writable: false);
        return key is null ? new([], [new(source, StartupSourceState.Missing, 0, [])]) : ReadRegistryValues(key, source, limit, token);
    }

    // Test entry accepts only an already-open key; production callers always use the fixed sources above.
    internal static unsafe StartupInventory ReadRegistryValues(RegistryKey key, StartupSource source, int limit, CancellationToken token)
    {
        var items = ImmutableArray.CreateBuilder<StartupRegistration>();
        var issues = new HashSet<string>(StringComparer.Ordinal);
        var inspected = 0;
        var name = stackalloc char[513];
        for (uint index = 0; ; index++)
        {
            token.ThrowIfCancellationRequested();
            uint length = 513;
            var result = StartupRegistryNative.EnumValue(key.Handle, index, name, ref length, 0, 0, 0, 0);
            if (result == 259) break;
            if (inspected == limit) { issues.Add("entry_limit"); break; }
            inspected++;
            if (result == 234) { issues.Add("invalid_registration_metadata"); continue; }
            if (result != 0) { issues.Add(result == 5 ? "permission_denied" : "registry_enumeration_failed"); break; }
            var registration = new string(name, 0, checked((int)length));
            try
            {
                var data = ReadCommand(key, registration);
                var repeated = ReadCommand(key, registration);
                if (data != repeated) { issues.Add("registration_changed"); continue; }
                var executable = ExecutablePath(data);
                items.Add(new(source, registration, registration, executable?.Value,
                    Issues: executable is null ? ["executable_unresolved"] : []));
            }
            catch (Exception error) when (ReadFailure(error)) { issues.Add(ErrorCode(error)); }
        }
        return new(items.ToImmutable(), [new(source, issues.Count == 0 ? StartupSourceState.Complete : StartupSourceState.Partial,
            inspected, issues.Order(StringComparer.Ordinal).ToImmutableArray())]);
    }

    internal static async Task<StartupInventory> ReadFolderAsync(IWindowsFileSystem files, WindowsPath folder, StartupSource source, int limit, CancellationToken token)
    {
        var items = ImmutableArray.CreateBuilder<StartupRegistration>();
        var issues = new HashSet<string>(StringComparer.Ordinal);
        FileEntry before;
        try { before = await files.InspectAsync(folder, token).ConfigureAwait(false); }
        catch (ShouException error) when (error.Code == "not_found") { return new([], [new(source, StartupSourceState.Missing, 0, [])]); }
        if (before.Kind != EntryKind.Directory) throw new ShouException("unsafe_path", "The startup source must be a local directory without reparse points.");
        var inspected = 0;
        await foreach (var entry in files.ReadDirectoryAsync(folder, token).ConfigureAwait(false))
        {
            token.ThrowIfCancellationRequested();
            if (inspected == limit) { issues.Add("entry_limit"); break; }
            inspected++;
            if (entry.Path.Parent is not { } parent || !parent.SamePath(folder, caseSensitive: true))
            { issues.Add("registration_changed"); continue; }
            if (entry.Entry is not { } file) { issues.Add("entry_unavailable"); continue; }
            if (file.Path != entry.Path) { issues.Add("registration_changed"); continue; }
            if (file.Kind is EntryKind.ReparsePoint or EntryKind.Unsupported) { issues.Add("unsafe_path"); continue; }
            if (file.Kind != EntryKind.File || file.Path.Name.Equals("desktop.ini", StringComparison.OrdinalIgnoreCase)) continue;
            var executable = file.Path.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || file.Path.Name.EndsWith(".com", StringComparison.OrdinalIgnoreCase);
            items.Add(new(source, file.Path.Value, file.Path.Name, executable ? file.Path.Value : null, file.Path.Value,
                executable ? [] : ["target_not_resolved"]));
        }
        if (await files.InspectAsync(folder, token).ConfigureAwait(false) != before) issues.Add("source_changed");
        return new(items.ToImmutable(), [new(source, issues.Count == 0 ? StartupSourceState.Complete : StartupSourceState.Partial,
            inspected, issues.Order(StringComparer.Ordinal).ToImmutableArray())]);
    }

    // A display clue only. Never resolves PATH, environment variables, ambiguous unquoted paths or arguments.
    internal static WindowsPath? ExecutablePath(string command)
    {
        if (command.Length is 0 or > 4096 || char.IsWhiteSpace(command[0])) return null;
        string path;
        if (command[0] == '"')
        {
            var closing = command.IndexOf('"', 1);
            if (closing <= 1 || closing + 1 < command.Length && !char.IsWhiteSpace(command[closing + 1])) return null;
            path = command[1..closing];
        }
        else path = command.Split([' ', '\t'], 2)[0];
        if (path.Contains('%') || !(path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".com", StringComparison.OrdinalIgnoreCase))) return null;
        try { return WindowsPath.Parse(path); }
        catch (ShouException) { return null; }
    }

    private static unsafe string ReadCommand(RegistryKey key, string name)
    {
        uint length = 0;
        var result = ApplicationRegistryNative.QueryValue(key.Handle, name, 0, out var kind, null, ref length);
        if (result == 5) throw new UnauthorizedAccessException();
        if (result != 0 || kind is not (1 or 2) || length is < 2 or > 8192 || length % 2 != 0) throw InvalidMetadata();
        var buffer = new byte[length];
        fixed (byte* data = buffer) result = ApplicationRegistryNative.QueryValue(key.Handle, name, 0, out kind, data, ref length);
        if (result == 5) throw new UnauthorizedAccessException();
        if (result != 0 || kind is not (1 or 2) || length > buffer.Length || length % 2 != 0) throw InvalidMetadata();
        return StrictUnicode.GetString(buffer.AsSpan(0, checked((int)length))).TrimEnd('\0');
    }
    private static ShouException InvalidMetadata() => new("invalid_registration_metadata", "A startup registration is invalid or exceeds its read limit.");
    private static bool ReadFailure(Exception error) => error is ShouException or IOException or UnauthorizedAccessException or SecurityException or ArgumentException or InvalidOperationException or COMException or InvalidCastException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException;
    private static string ErrorCode(Exception error) => error is UnauthorizedAccessException or SecurityException || error is COMException { HResult: unchecked((int)0x80070005) }
        ? "permission_denied" : error is ShouException known ? known.Code : "registration_read_failed";
}

internal static partial class StartupRegistryNative
{
    [LibraryImport("advapi32.dll", EntryPoint = "RegEnumValueW")]
    internal static unsafe partial int EnumValue(SafeRegistryHandle key, uint index, char* name, ref uint length,
        nint reserved, nint kind, nint data, nint dataLength);
}
