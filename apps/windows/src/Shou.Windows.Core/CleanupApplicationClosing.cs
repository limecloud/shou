using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record CleanupRunningApplication(int ProcessId, long StartedUtcTicks, WindowsPath Executable, string Name);
public sealed record CleanupApplicationUsers(ImmutableArray<CleanupRunningApplication> Applications, bool Complete);
public sealed record CleanupApplicationCloseResult(CleanupRunningApplication Application, string State);

/// <summary>File-use discovery grants no cleanup authority. Closing only requests a normal exit.</summary>
public interface ICleanupApplicationClosing
{
    bool Available { get; }
    Task<CleanupApplicationUsers> InspectAsync(ImmutableArray<WindowsPath> files, CancellationToken token);
    Task<CleanupApplicationCloseResult> RequestCloseAsync(CleanupRunningApplication application, CancellationToken token);
}

public sealed class CleanupApplicationClosingService(ICleanupApplicationClosing platform)
{
    public bool Available => platform.Available;
    public Task<CleanupApplicationUsers> InspectAsync(ImmutableArray<WindowsPath> files, CancellationToken token) =>
        platform.InspectAsync(files, token);

    public async Task<ImmutableArray<CleanupApplicationCloseResult>> CloseSelectedAsync(CleanupApplicationUsers observed,
        ImmutableArray<CleanupRunningApplication> selected, CancellationToken token)
    {
        if (!Available) throw new ShouException("unsupported_capability", "Quit affected apps, then scan again.");
        if (selected.IsDefaultOrEmpty || selected.Length > 100 || selected.Distinct().Count() != selected.Length ||
            selected.Select(app => app.ProcessId).Distinct().Count() != selected.Length || selected.Any(app => !observed.Applications.Contains(app)))
            throw new ShouException("plan_stale", "Choose currently observed applications.");
        var results = ImmutableArray.CreateBuilder<CleanupApplicationCloseResult>();
        foreach (var app in selected)
        {
            token.ThrowIfCancellationRequested();
            results.Add(await platform.RequestCloseAsync(app, token));
        }
        return results.ToImmutable();
    }
}
