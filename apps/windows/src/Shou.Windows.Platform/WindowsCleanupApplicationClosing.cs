using System.Collections.Immutable;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Restart Manager supplies exact file users; no executable-name matching or forced termination.</summary>
public sealed class WindowsCleanupApplicationClosing : ICleanupApplicationClosing
{
    // Independent native acceptance is required before public process-control actions.
    public bool Available => false;

    public async Task<CleanupApplicationUsers> InspectAsync(ImmutableArray<WindowsPath> files, CancellationToken token)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || files.IsDefaultOrEmpty)
            return new([], !files.IsDefault && files.IsEmpty);
        if (files.Length > 4096 || files.Any(path => path.IsVolumeRoot))
            return new([], false);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        try { return await NativeOperationScheduler.RunAsync(() => Inspect(files, deadline.Token), deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return new([], false); }
    }

    private static unsafe CleanupApplicationUsers Inspect(ImmutableArray<WindowsPath> files, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var key = stackalloc char[33];
        if (NativeMethods.RestartManagerStart(out var session, 0, (nint)key) != 0) return new([], false);
        CleanupApplicationUsers result;
        var ended = false;
        try { result = ReadUsers(); }
        finally { ended = NativeMethods.RestartManagerEnd(session) == 0; }
        return ended ? result : result with { Complete = false };

        CleanupApplicationUsers ReadUsers()
        {
            var applications = ImmutableArray.CreateBuilder<CleanupRunningApplication>();
            var complete = true;
            for (var offset = 0; offset < files.Length; offset += 256)
            {
                token.ThrowIfCancellationRequested();
                var paths = files.Skip(offset).Take(256).Select(path => path.Value).ToArray();
                if (NativeMethods.RestartManagerRegister(session, (uint)paths.Length, paths, 0, 0, 0, 0) != 0) return new([], false);
            }
            uint count = 0;
            var status = NativeMethods.RestartManagerList(session, out var needed, ref count, 0, out var reboot);
            if (status == 0 && needed == 0) return new([], reboot == 0);
            if (status != 234 || needed is 0 or > 256) return new([], false);
            var entries = new RmProcess[needed]; count = needed;
            fixed (RmProcess* buffer = entries)
                status = NativeMethods.RestartManagerList(session, out needed, ref count, (nint)buffer, out reboot);
            if (status != 0 || count > entries.Length || reboot != 0) return new([], false);
            var caller = WindowsAuthorizationPeer.Read(Environment.ProcessId);
            foreach (var entry in entries.Take((int)count))
            {
                token.ThrowIfCancellationRequested();
                if (entry.Type is not (1 or 2) || entry.Pid == Environment.ProcessId) { complete = false; continue; }
                try
                {
                    var peer = WindowsAuthorizationPeer.Read(entry.Pid);
                    using var process = Process.GetProcessById(entry.Pid);
                    var fileTime = ((long)entry.StartHigh << 32) | entry.StartLow;
                    if (peer.Sid != caller.Sid || peer.Elevated || peer.Executable.Equals(caller.Executable, StringComparison.OrdinalIgnoreCase) ||
                        peer.Started != DateTime.FromFileTimeUtc(fileTime).Ticks || process.SessionId != Process.GetCurrentProcess().SessionId ||
                        process.MainWindowHandle == 0 || !peer.IsCurrent) { complete = false; continue; }
                    applications.Add(new(peer.Pid, peer.Started, WindowsPath.Parse(peer.Executable), process.ProcessName));
                }
                catch (Exception error) when (error is Win32Exception or InvalidOperationException or ArgumentException or ShouException)
                { complete = false; }
            }
            return new(applications.Distinct().ToImmutableArray(), complete);
        }
    }

    public async Task<CleanupApplicationCloseResult> RequestCloseAsync(CleanupRunningApplication application, CancellationToken token)
    {
        if (!Available) throw new ShouException("unsupported_capability", "Quit affected apps, then scan again.");
        token.ThrowIfCancellationRequested();
        try
        {
            using var process = Process.GetProcessById(application.ProcessId);
            _ = process.SafeHandle; // Keep the observed process object open across the request.
            var peer = WindowsAuthorizationPeer.Read(application.ProcessId);
            var caller = WindowsAuthorizationPeer.Read(Environment.ProcessId);
            if (peer.Pid == caller.Pid || peer.Sid != caller.Sid || peer.Elevated ||
                peer.Executable.Equals(caller.Executable, StringComparison.OrdinalIgnoreCase) ||
                peer.Started != application.StartedUtcTicks || !WindowsPath.Parse(peer.Executable).SamePath(application.Executable) ||
                process.SessionId != Process.GetCurrentProcess().SessionId || !peer.IsCurrent)
                return new(application, "identity_changed");
            if (!process.CloseMainWindow()) return new(application, "still_running");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(10));
            try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { return new(application, "still_running"); }
            return new(application, "closed");
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or ArgumentException or ShouException)
        { return new(application, "unverified"); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private unsafe struct RmProcess
    {
        internal int Pid;
        internal uint StartLow, StartHigh;
        internal fixed char Name[256];
        internal fixed char Service[64];
        internal int Type;
        internal uint Status, Session;
        internal int Restartable;
    }
}
