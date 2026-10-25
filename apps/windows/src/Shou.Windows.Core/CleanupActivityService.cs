using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record ProcessObservation(uint ProcessId, string ExecutableName, FileEntry? WorkingDirectory = null, bool Exited = false,
    bool IsCurrentProcess = false, WindowsPath? ExecutablePath = null);
public sealed record ProcessInventory(bool Complete, ImmutableArray<ProcessObservation> Processes, string? Reason = null);

public interface IProcessInventory
{
    Task<ProcessInventory> InspectAsync(ImmutableArray<string> executableNames, CancellationToken cancellationToken);
}

public interface ICleanupFileUse
{
    Task<ActivityObservation> InspectAsync(ImmutableArray<WindowsPath> paths, CancellationToken cancellationToken);
}

public interface IArtifactTracking
{
    Task<bool> HasTrackedContentAsync(WindowsPath target, string ownerSid, CancellationToken cancellationToken);
}

/// <summary>Known-tool working directories and file-use observations remain bounded, independent evidence.</summary>
public sealed class CleanupActivityService(ICleanupFileUse fileUse, IProcessInventory processes, TimeProvider? timeProvider = null,
    IArtifactTracking? tracking = null) : ICleanupActivity
{
    public const int MaximumProcesses = 16_384;
    public static readonly TimeSpan Duration = TimeSpan.FromSeconds(10);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private static readonly HashSet<string> ToolNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "cargo.exe", "rustc.exe", "rust-analyzer.exe", "clippy-driver.exe", "cargo-clippy.exe", "cargo-nextest.exe",
        "node.exe", "bun.exe", "deno.exe", "Cypress.exe", "esbuild.exe",
        "dotnet.exe", "MSBuild.exe", "csc.exe", "vbc.exe", "VBCSCompiler.exe", "Fsc.exe",
        "java.exe", "javaw.exe", "javac.exe", "gradle.exe", "mvn.exe",
        "python.exe", "pythonw.exe", "python3.exe", "uv.exe", "ruff.exe",
        "go.exe", "swift.exe", "swiftc.exe", "clang.exe", "clang++.exe", "clang-cl.exe",
        "cl.exe", "link.exe", "cmake.exe", "ninja.exe", "make.exe", "mingw32-make.exe",
        "gcc.exe", "g++.exe", "cc1.exe", "cc1plus.exe", "ld.exe", "dart.exe", "flutter.exe", "git.exe"
    };

    public async Task<ActivityObservation> InspectAsync(Workspace workspace, CleanupPlanItem item, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var deadline = new CancellationTokenSource(Duration, clock);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        try
        {
            if (item.Manifest.IsDefaultOrEmpty || item.Manifest.Length > 1_000_000 || item.Context.IsDefaultOrEmpty || item.Context.Length > 80 ||
                !item.Path.IsWithin(workspace.Path, caseSensitive: true, includeRoot: false)) return Unknown("activity_scope_invalid");
            var paths = new HashSet<WindowsPath>();
            foreach (var entry in item.Manifest.Concat(item.Context))
            {
                token.ThrowIfCancellationRequested();
                if (entry is null || entry.Path is null || entry.Identity is null || entry.Identity.OwnerSid != workspace.Identity.OwnerSid ||
                    entry.Identity.VolumeSerialNumber != workspace.Identity.VolumeSerialNumber || !entry.Path.IsWithin(workspace.Path, caseSensitive: true) ||
                    entry.Kind is not (EntryKind.File or EntryKind.Directory)) return Unknown("activity_scope_invalid");
                if (entry.Kind == EntryKind.File) paths.Add(entry.Path);
            }
            if (paths.Count == 0) return Unknown("activity_scope_unavailable");
            var filesTask = ReadFiles(paths.OrderBy(path => path.Value, StringComparer.Ordinal).ToImmutableArray(), token);
            var processesTask = ReadProcesses(workspace, item.Path.Parent!, token);
            // All adapters are read-only and bound native workers even if a kernel read outlives cancellation.
            var trackingTask = ReadTracking(item, workspace.Identity.OwnerSid, token);
            var combined = Task.WhenAll(filesTask, processesTask, trackingTask);
            ObserveFault(combined);
            var observations = await combined.WaitAsync(token);
            cancellationToken.ThrowIfCancellationRequested();
            return observations.FirstOrDefault(value => value.State == ActivityState.Active)
                ?? observations.FirstOrDefault(value => value.State == ActivityState.Unknown)
                ?? new(ActivityState.Idle, "no_observed_project_or_file_users");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && deadline.IsCancellationRequested)
        { return Unknown("activity_time_limit"); }
    }

    private async Task<ActivityObservation> ReadTracking(CleanupPlanItem item, string ownerSid, CancellationToken token)
    {
        // This check also applies to binary-only Cargo targets. Saved layout observations never grant Git authority.
        if (item.RuleId != RustArtifactPolicy.RuleId) return new(ActivityState.Idle);
        if (tracking is null) return Unknown("artifact_evidence_unavailable");
        try
        {
            return await tracking.HasTrackedContentAsync(item.Path, ownerSid, token)
                ? Unknown("tracked_artifact_content") : new(ActivityState.Idle);
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return Unknown("artifact_evidence_unavailable"); }
    }

    private async Task<ActivityObservation> ReadFiles(ImmutableArray<WindowsPath> paths, CancellationToken token)
    {
        try
        {
            var observed = await fileUse.InspectAsync(paths, token);
            return observed is not null && Enum.IsDefined(observed.State) ? observed : Unknown("activity_invalid_result");
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return Unknown("file_activity_unavailable"); }
    }

    private async Task<ActivityObservation> ReadProcesses(Workspace workspace, WindowsPath project, CancellationToken token)
    {
        try
        {
            var inventory = await processes.InspectAsync(ToolNames.Order(StringComparer.Ordinal).ToImmutableArray(), token);
            if (inventory is null || inventory.Processes.IsDefault || inventory.Processes.Length > MaximumProcesses) return Unknown("process_inventory_invalid");
            var ids = new HashSet<uint>();
            var active = false;
            var unknown = !inventory.Complete;
            foreach (var process in inventory.Processes)
            {
                token.ThrowIfCancellationRequested();
                if (process is null || process.ExecutableName is not { Length: > 0 and <= 260 } name ||
                    name.Any(character => char.IsControl(character) || character is '/' or '\\' or ':') || !ids.Add(process.ProcessId))
                    return Unknown("process_inventory_invalid");
                if (!ToolNames.Contains(name) || process.Exited || process.IsCurrentProcess) continue;
                var directory = process.WorkingDirectory;
                if (directory is null || directory.Path is null || directory.Identity is null || directory.Kind != EntryKind.Directory)
                { unknown = true; continue; }
                // Case-insensitive comparison conservatively treats ambiguous case variants as potentially overlapping.
                if (!directory.Path.IsWithin(project) && !project.IsWithin(directory.Path)) continue;
                // A verified unrelated directory grants no target authority and need not share its owner.
                if (directory.Identity.OwnerSid != workspace.Identity.OwnerSid) { unknown = true; continue; }
                active = true;
            }
            if (active) return new(ActivityState.Active, "known_build_process_running");
            return !unknown ? new(ActivityState.Idle, "no_observed_project_tools") : Unknown("process_scope_unavailable");
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        { return Unknown("process_inventory_unavailable"); }
    }

    private static ActivityObservation Unknown(string reason) => new(ActivityState.Unknown, reason);
    private static void ObserveFault(Task task) => _ = task.ContinueWith(completed => { _ = completed.Exception; },
        CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
}
