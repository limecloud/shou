using System.Collections.Immutable;
using System.Runtime.InteropServices;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Reads Toolhelp names and only requested tools' current-directory fields; no command lines or environments.</summary>
public sealed class WindowsProcessInventory : IProcessInventory
{
    public async Task<ProcessInventory> InspectAsync(ImmutableArray<string> executableNames, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (executableNames.IsDefault || executableNames.Length > 128 || executableNames.Any(name => string.IsNullOrEmpty(name) || name.Length > 260 ||
            name.Any(character => char.IsControl(character) || character is '/' or '\\' or ':')))
            throw new ShouException("invalid_argument", "Choose bounded executable basenames for process observations.");
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8) return new(false, [], "unsupported_platform");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(CleanupActivityService.Duration);
        var selected = executableNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        try { return await NativeOperationScheduler.RunAsync(() => Read(selected, deadline.Token), deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return new(false, [], "activity_time_limit"); }
    }

    private static ProcessInventory Read(HashSet<string> selected, CancellationToken token)
    {
        var inventory = ReadNames(token);
        var scoped = ImmutableArray.CreateBuilder<ProcessObservation>();
        var inspected = 0;
        foreach (var process in inventory.Processes)
        {
            token.ThrowIfCancellationRequested();
            scoped.Add(selected.Contains(process.ExecutableName) && ++inspected <= 64 ? WindowsProcessScope.Read(process, token) : process);
        }
        return inventory with { Processes = scoped.ToImmutable() };
    }

    internal static unsafe ProcessInventory ReadNames(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var snapshot = NativeMethods.ProcessSnapshot(2, 0); // TH32CS_SNAPPROCESS
        if (snapshot.IsInvalid) return new(false, [], "process_inventory_unavailable");
        var entry = new NativeMethods.ProcessEntry { Size = (uint)sizeof(NativeMethods.ProcessEntry) };
        if (!NativeMethods.ProcessFirst(snapshot, ref entry)) return new(false, [], "process_inventory_unavailable");
        var processes = ImmutableArray.CreateBuilder<ProcessObservation>();
        var ids = new HashSet<uint>();
        do
        {
            token.ThrowIfCancellationRequested();
            if (processes.Count >= CleanupActivityService.MaximumProcesses) return new(false, processes.ToImmutable(), "process_inventory_limit");
            var length = 0;
            while (length < 260 && entry.Executable[length] != '\0') length++;
            if (entry.Size != sizeof(NativeMethods.ProcessEntry) || length is 0 or 260 || !ids.Add(entry.ProcessId))
                return new(false, [], "process_inventory_invalid");
            var name = new string(entry.Executable, 0, length);
            if (name.Any(character => char.IsControl(character) || character is '/' or '\\' or ':')) return new(false, [], "process_inventory_invalid");
            processes.Add(new(entry.ProcessId, name, IsCurrentProcess: entry.ProcessId == Environment.ProcessId));
        }
        while (NativeMethods.ProcessNext(snapshot, ref entry));
        var complete = Marshal.GetLastPInvokeError() == 18;
        return new(complete, processes.ToImmutable(), complete ? null : "process_inventory_incomplete");
    }
}
