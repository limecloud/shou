using System.Collections.Immutable;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Bounded Restart Manager evidence for explicitly supplied regular-file paths.</summary>
public sealed class WindowsFileUseActivity : ICleanupFileUse
{
    public async Task<ActivityObservation> InspectAsync(ImmutableArray<WindowsPath> paths, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8)
            return new(ActivityState.Unknown, "unsupported_platform");
        if (paths.IsDefaultOrEmpty || paths.Length > 1_000_080 || paths.Any(path => path is null || path.IsVolumeRoot))
            return new(ActivityState.Unknown, "activity_scope_invalid");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(CleanupActivityService.Duration);
        try { return await NativeOperationScheduler.RunAsync(() => Inspect(paths, deadline.Token), deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { return new(ActivityState.Unknown, "activity_time_limit"); }
    }

    private static unsafe ActivityObservation Inspect(ImmutableArray<WindowsPath> paths, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var started = Stopwatch.GetTimestamp();
        var key = stackalloc char[33];
        if (NativeMethods.RestartManagerStart(out var session, 0, (nint)key) != 0) return new(ActivityState.Unknown, "activity_unavailable");
        ActivityObservation observed;
        var closed = false;
        try
        {
            observed = RegisterAndInspect();
        }
        finally { closed = NativeMethods.RestartManagerEnd(session) == 0; }
        return closed ? observed : new(ActivityState.Unknown, "activity_session_unconfirmed");

        ActivityObservation RegisterAndInspect()
        {
            for (var offset = 0; offset < paths.Length; offset += 256)
            {
                token.ThrowIfCancellationRequested();
                if (Stopwatch.GetElapsedTime(started) >= CleanupActivityService.Duration) return new(ActivityState.Unknown, "activity_time_limit");
                var batch = paths.Skip(offset).Take(256).Select(path => path.Value).ToArray();
                if (NativeMethods.RestartManagerRegister(session, (uint)batch.Length, batch, 0, 0, 0, 0) != 0)
                    return new(ActivityState.Unknown, "activity_unavailable");
            }
            token.ThrowIfCancellationRequested();
            uint count = 0;
            var result = NativeMethods.RestartManagerList(session, out var needed, ref count, 0, out var reboot);
            token.ThrowIfCancellationRequested();
            if (result is 0 or 234 && needed > 0) return new(ActivityState.Active, "files_in_use");
            return result == 0 && needed == 0 && reboot == 0
                ? new(ActivityState.Idle, "no_registered_file_users") : new(ActivityState.Unknown, "activity_unavailable");
        }
    }
}
