using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Reads matching executable paths with query-only rights; no PEB, command lines or process control.</summary>
public sealed class WindowsApplicationProcesses : IProcessInventory
{
    public async Task<ProcessInventory> InspectAsync(ImmutableArray<string> executableNames, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (executableNames.IsDefault || executableNames.Length > ApplicationActivityService.MaximumExecutableNames ||
            executableNames.Any(name => string.IsNullOrEmpty(name) || name.Length > 260 || name.Any(character => char.IsControl(character) || character is '/' or '\\' or ':')))
            throw new ShouException("invalid_argument", "Choose bounded application executable names.");
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8) return new(false, [], "unsupported_platform");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(ApplicationActivityService.Duration);
        var selected = executableNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        try { return await NativeOperationScheduler.RunAsync(() => Read(selected, deadline.Token), deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return new(false, [], "application_activity_time_limit"); }
    }

    private static ProcessInventory Read(HashSet<string> selected, CancellationToken token)
    {
        var inventory = WindowsProcessInventory.ReadNames(token);
        var result = ImmutableArray.CreateBuilder<ProcessObservation>();
        var inspected = 0;
        foreach (var process in inventory.Processes)
        {
            token.ThrowIfCancellationRequested();
            result.Add(selected.Contains(process.ExecutableName) && ++inspected <= 256 ? ReadImage(process, token) : process);
        }
        return inventory with { Processes = result.ToImmutable() };
    }

    internal static unsafe ProcessObservation ReadImage(ProcessObservation observation, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        // PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, without memory read, terminate or debug rights.
        using var process = NativeMethods.OpenProcess(0x00101000, false, observation.ProcessId);
        if (process.IsInvalid) return observation;
        if (NativeMethods.WaitForProcess(process, 0) == 0) return observation with { Exited = true };
        var buffer = stackalloc char[32768];
        uint count = 32768;
        if (!NativeMethods.ProcessImageName(process, 0, (nint)buffer, ref count) || count is 0 or >= 32768) return observation;
        try
        {
            var image = WindowsPath.Parse(new string(buffer, 0, checked((int)count)));
            if (!string.Equals(image.Name, observation.ExecutableName, StringComparison.OrdinalIgnoreCase)) return observation;
            token.ThrowIfCancellationRequested();
            return NativeMethods.WaitForProcess(process, 0) switch
            {
                258 => observation with { ExecutablePath = image },
                0 => observation with { Exited = true },
                _ => observation
            };
        }
        catch (ShouException) { return observation; }
    }
}
