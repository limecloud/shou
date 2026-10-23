using System.Collections.Immutable;

namespace Shou.Windows.Core;

public interface IApplicationUninstallActivity
{
    Task<ActivityObservation> InspectAsync(ApplicationUninstallObservation installation, CancellationToken cancellationToken);
}

/// <summary>Read-only installation-directory evidence, never a reusable execution authorization.</summary>
public sealed class ApplicationActivityService(IWindowsFileSystem fileSystem, ICleanupFileUse fileUse, IProcessInventory processes,
    TimeProvider? timeProvider = null) : IApplicationUninstallActivity
{
    public const int MaximumEntries = 20_000;
    public const int MaximumExecutableNames = 128;
    public const int MaximumDepth = 32;
    public static readonly TimeSpan Duration = TimeSpan.FromSeconds(10);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<ActivityObservation> InspectAsync(ApplicationUninstallObservation installation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (installation.Identity is null || installation.IsProtected || !installation.Issues.IsEmpty ||
            installation.InstalledRoot is not { Kind: EntryKind.Directory } root || root.Path.IsVolumeRoot)
            return Unknown("installation_activity_scope_unavailable");
        using var deadline = new CancellationTokenSource(Duration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try
        {
            var work = ObserveAsync(root, linked.Token);
            _ = work.ContinueWith(completed => { _ = completed.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return await work.WaitAsync(linked.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        { return Unknown("application_activity_time_limit"); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return Unknown(error is UnauthorizedAccessException ? "permission_denied" : "application_activity_unavailable"); }
    }

    private async Task<ActivityObservation> ObserveAsync(FileEntry root, CancellationToken token)
    {
        var snapshot = await new StorageScanner(fileSystem, clock).ScanAsync(root.Path, new(MaximumEntries, MaximumDepth, Duration), null, token);
        token.ThrowIfCancellationRequested();
        if (!snapshot.IsComplete || !snapshot.IsCompleteAt(root.Path) || !snapshot.Issues.IsEmpty || snapshot.Entries.IsDefaultOrEmpty ||
            snapshot.Entries.Length > MaximumEntries || snapshot.RootIdentity != root.Identity || snapshot.Entries[0].Entry != root)
            return Unknown("installation_activity_coverage_incomplete");
        var files = ImmutableArray.CreateBuilder<WindowsPath>();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var measured in snapshot.Entries)
        {
            var entry = measured.Entry;
            token.ThrowIfCancellationRequested();
            if (entry.Identity.VolumeSerialNumber != root.Identity.VolumeSerialNumber || !entry.Path.IsWithin(root.Path, root.IsCaseSensitive) ||
                entry.Kind is not (EntryKind.Directory or EntryKind.File) || entry.Kind == EntryKind.File && entry.LinkCount != 1)
                return Unknown("installation_activity_scope_unavailable");
            if (entry.Kind != EntryKind.File) continue;
            files.Add(entry.Path);
            if (entry.Path.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || entry.Path.Name.EndsWith(".com", StringComparison.OrdinalIgnoreCase))
                names.Add(entry.Path.Name);
        }
        if (files.Count == 0) return Unknown("installation_activity_scope_unavailable");
        if (names.Count > MaximumExecutableNames) return Unknown("application_executable_limit");
        var orderedNames = names.Order(StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        var filesTask = ReadFilesAsync(files.ToImmutable(), token);
        var processesTask = ReadProcessesAsync(root.Path, names, orderedNames, token);
        var observed = await Task.WhenAll(filesTask, processesTask);
        token.ThrowIfCancellationRequested();
        // Additions change a parent directory; replacements and writes change the observed entry.
        foreach (var measured in snapshot.Entries)
        {
            token.ThrowIfCancellationRequested();
            if (await fileSystem.InspectAsync(measured.Entry.Path, token) != measured.Entry)
                return Unknown("installation_changed_during_activity_check");
        }
        return observed.FirstOrDefault(value => value.State == ActivityState.Active)
            ?? observed.FirstOrDefault(value => value.State == ActivityState.Unknown)
            ?? new(ActivityState.Idle, "no_observed_installation_users");
    }

    private async Task<ActivityObservation> ReadFilesAsync(ImmutableArray<WindowsPath> paths, CancellationToken token)
    {
        try
        {
            var observed = await fileUse.InspectAsync(paths, token);
            return observed is not null && Enum.IsDefined(observed.State) && (observed.Reason is null || ApplicationUninstallReviewer.Code(observed.Reason))
                ? observed : Unknown("file_activity_invalid");
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return Unknown("file_activity_unavailable"); }
    }

    private async Task<ActivityObservation> ReadProcessesAsync(WindowsPath root, HashSet<string> names, ImmutableArray<string> orderedNames, CancellationToken token)
    {
        try
        {
            var inventory = await processes.InspectAsync(orderedNames, token);
            if (inventory is null || inventory.Processes.IsDefault || inventory.Processes.Length > CleanupActivityService.MaximumProcesses)
                return Unknown("process_inventory_invalid");
            var seen = new HashSet<uint>();
            var active = false;
            var unknown = !inventory.Complete;
            foreach (var process in inventory.Processes)
            {
                token.ThrowIfCancellationRequested();
                if (process is null || process.ExecutableName is not { Length: > 0 and <= 260 } name || !seen.Add(process.ProcessId) ||
                    name.Any(character => char.IsControl(character) || character is '/' or '\\' or ':')) return Unknown("process_inventory_invalid");
                if (!names.Contains(name) || process.Exited) continue;
                // The Shou host is deliberately included: it must never uninstall its own installation.
                if (process.ExecutablePath is not { } image || !string.Equals(image.Name, name, StringComparison.OrdinalIgnoreCase))
                { unknown = true; continue; }
                // Ambiguous case variants are conservatively treated as potentially overlapping.
                if (image.IsWithin(root, includeRoot: false)) active = true;
            }
            return active ? new(ActivityState.Active, "application_process_running") : unknown ? Unknown("application_process_scope_unavailable") : new(ActivityState.Idle);
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return Unknown("process_inventory_unavailable"); }
    }

    private static ActivityObservation Unknown(string reason) => new(ActivityState.Unknown, reason);
}
