using System.Diagnostics;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Removes only frozen entries through verified parent handles. No path-recursive fallback.</summary>
public sealed class WindowsCleanupMutation : ICleanupMutation
{
    // GUI and CLI share this gate; enable only after native mutation, interruption and UI/terminal acceptance.
    public static bool PublicExecutionAvailable => false;
    public bool VerifiesMutationManifest => true;
    public bool Supports(CleanupAction action) => action == CleanupAction.Permanent &&
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) && IntPtr.Size == 8;

    public Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action, CancellationToken cancellationToken) =>
        ApplyAsync(workspace, item, action, null, cancellationToken);

    public async Task<CleanupMutationResult> ApplyAsync(Workspace workspace, CleanupPlanItem item, CleanupAction action,
        IProgress<CleanupMutationProgress>? progress, CancellationToken cancellationToken)
    {
        if (!Supports(action)) throw new ShouException("unsupported_capability", "This native cleanup action is unavailable.");
        try
        {
            return await NativeOperationScheduler.RunToCompletionAsync(() => Apply(workspace, item, progress, cancellationToken), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Scheduler cancellation occurs before dispatch. Once dispatched, Apply reports the observed boundary itself.
            return new(CleanupMutationOutcome.Cancelled, Reason: "cancelled");
        }
    }

    private static CleanupMutationResult Apply(Workspace workspace, CleanupPlanItem item, IProgress<CleanupMutationProgress>? progress, CancellationToken token)
    {
        var started = Stopwatch.GetTimestamp();
        void Check()
        {
            token.ThrowIfCancellationRequested();
            if (Stopwatch.GetElapsedTime(started) >= TimeSpan.FromMinutes(2))
                throw new ShouException("time_limit", "Native manifest validation reached its two-minute budget.");
        }
        var removed = 0;
        var pending = false;
        try
        {
            Check();
            using var scope = Scope.Open(workspace, item, Check);
            // A complete native preflight precedes the first disposition. Later checks bind each individual unlink.
            scope.VerifyTree(scope.Target, scope.TargetEntry, Check, path => Report(progress, new("checking", path, 0)));
            scope.VerifyContext();
            void Remove(FileEntry expected, SafeFileHandle handle, SafeFileHandle parent, bool parentCaseSensitive)
            {
                Check();
                RequireEntry(expected, WindowsFileSystem.ReadEntry(expected.Path, handle), strictDirectory: true);
                foreach (var child in scope.Children(expected.Path))
                {
                    Check();
                    using var childHandle = NativeFileHandles.OpenChild(handle, child.Path, expected.IsCaseSensitive,
                        child.Kind == EntryKind.Directory, deletion: true);
                    Remove(child, childHandle, handle, expected.IsCaseSensitive);
                }
                scope.VerifyContext();
                RequireEntry(expected, WindowsFileSystem.ReadEntry(expected.Path, handle), strictDirectory: false);
                if (expected.Kind == EntryKind.Directory && NativeFileHandles.Names(handle, expected.IsCaseSensitive, 0, Check).Count != 0) throw Stale();
                Check();
                NativeFileHandles.MarkForRemoval(handle);
                pending = true;
                handle.Dispose();
                // Ancestors remain pinned until all children finish; verify this unlink before observing cancellation.
                RequireUnlinked(parent, expected, parentCaseSensitive);
                pending = false;
                removed++;
                Report(progress, new("purging", expected.Path, removed));
            }
            var targetParent = scope.TargetParent;
            Remove(scope.TargetEntry, scope.Target, targetParent.Handle, targetParent.Entry.IsCaseSensitive);
            return new(CleanupMutationOutcome.Completed, removed);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        { return new(pending ? CleanupMutationOutcome.Unknown : CleanupMutationOutcome.Cancelled, removed, pending ? "native_result_unknown" : "cancelled"); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException)
        {
            var reason = pending ? "native_result_unknown" : error is ShouException known ? known.Code : error is UnauthorizedAccessException ? "permission_denied" : "io_error";
            return new(pending ? CleanupMutationOutcome.Unknown : CleanupMutationOutcome.Failed, removed, reason);
        }
    }

    private static void RequireUnlinked(SafeFileHandle parent, FileEntry expected, bool caseSensitive)
    {
        SafeFileHandle handle;
        try { handle = NativeFileHandles.OpenChild(parent, expected.Path, caseSensitive, directory: false); }
        catch (ShouException error) when (error.Code == "not_found") { return; }
        using (handle)
            if (WindowsFileSystem.ReadEntry(expected.Path, handle).Identity == expected.Identity)
                throw new ShouException("native_result_unknown", "The selected name still references the original object after disposition.");
        // A different object at this name is preserved. It is never added to the deletion manifest.
    }

    private static void RequireEntry(FileEntry expected, FileEntry actual, bool strictDirectory)
    {
        if (!FileManifestVerification.MatchesEntry(actual, expected, allowingDirectoryChanges: !strictDirectory)) throw Stale();
    }

    private sealed class Scope : IDisposable
    {
        private readonly WindowsFileSystem.PinnedPath workspace;
        private readonly CleanupPlanItem item;
        private readonly Dictionary<WindowsPath, (FileEntry Entry, SafeFileHandle Handle)> context = new();
        private readonly List<SafeFileHandle> owned = [];
        private readonly Dictionary<WindowsPath, FileEntry[]> children;
        internal Dictionary<WindowsPath, FileEntry> Manifest { get; }
        internal SafeFileHandle Target { get; private set; } = null!;
        internal FileEntry TargetEntry => Manifest[item.Path];
        internal (FileEntry Entry, SafeFileHandle Handle) TargetParent => context[item.Path.Parent!];
        internal FileEntry[] Children(WindowsPath path) => children.GetValueOrDefault(path) ?? [];

        private Scope(WindowsFileSystem.PinnedPath workspace, CleanupPlanItem item, Dictionary<WindowsPath, FileEntry> manifest)
        {
            this.workspace = workspace;
            this.item = item;
            Manifest = manifest;
            children = manifest.Values.Where(entry => entry.Path != item.Path).GroupBy(entry => entry.Path.Parent!)
                .ToDictionary(group => group.Key, group => group.ToArray());
        }

        internal static Scope Open(Workspace root, CleanupPlanItem item, Action check)
        {
            using var currentUser = WindowsIdentity.GetCurrent();
            if (root.Path.IsVolumeRoot || root.Identity.OwnerSid != currentUser.User?.Value ||
                item.Path is null || !item.Path.IsWithin(root.Path, caseSensitive: true, includeRoot: false) ||
                item.RelativePath != item.Path.RelativeTo(root.Path, caseSensitive: true) ||
                item.Manifest.IsDefaultOrEmpty || item.Manifest.Length > 1_000_000 || item.Context.IsDefaultOrEmpty || item.Context.Length > 80) throw Stale();
            var manifest = new Dictionary<WindowsPath, FileEntry>();
            var identities = new HashSet<FileIdentity>();
            foreach (var entry in item.Manifest)
            {
                check();
                RequireSafeEntry(entry, root);
                if (!entry.Path.IsWithin(item.Path, caseSensitive: true) || !manifest.TryAdd(entry.Path, entry) || !identities.Add(entry.Identity) ||
                    entry.Path.RelativeTo(root.Path, caseSensitive: true).Split('/').Length > 64) throw Stale();
            }
            if (!manifest.TryGetValue(item.Path, out var target) || target.Kind != EntryKind.Directory) throw Stale();
            foreach (var entry in manifest.Values.Where(entry => entry.Path != item.Path))
                if (entry.Path.Parent is not { } parent || !manifest.TryGetValue(parent, out var ancestor) || ancestor.Kind != EntryKind.Directory) throw Stale();
            var expectedContext = new Dictionary<WindowsPath, FileEntry>();
            foreach (var entry in item.Context)
            {
                check();
                RequireSafeEntry(entry, root);
                if (!entry.Path.IsWithin(root.Path, caseSensitive: true) || !expectedContext.TryAdd(entry.Path, entry) ||
                    (entry.Kind == EntryKind.Directory ? !item.Path.IsWithin(entry.Path, caseSensitive: true, includeRoot: false) : entry.Path.Parent != item.Path.Parent)) throw Stale();
            }
            if (!expectedContext.TryGetValue(root.Path, out var rootEntry) || rootEntry.Kind != EntryKind.Directory ||
                rootEntry.Identity != root.Identity || rootEntry.IsCaseSensitive != root.CaseSensitive) throw Stale();
            for (var parent = item.Path.Parent!; parent != root.Path; parent = parent.Parent!)
                if (!expectedContext.TryGetValue(parent, out var ancestor) || ancestor.Kind != EntryKind.Directory) throw Stale();

            var pinned = WindowsFileSystem.PinPath(root.Path, finalAccess: NativeMethods.ReadData);
            var scope = new Scope(pinned, item, manifest);
            try
            {
                RequireEntry(rootEntry, WindowsFileSystem.ReadEntry(root.Path, pinned.Final), strictDirectory: false);
                scope.context.Add(root.Path, (rootEntry, pinned.Final));
                foreach (var entry in expectedContext.Values.Where(entry => entry.Path != root.Path).OrderBy(entry => entry.Path.Value.Length))
                {
                    check();
                    if (!scope.context.TryGetValue(entry.Path.Parent!, out var parent) || parent.Entry.Kind != EntryKind.Directory) throw Stale();
                    var handle = NativeFileHandles.OpenChild(parent.Handle, entry.Path, parent.Entry.IsCaseSensitive, entry.Kind == EntryKind.Directory);
                    scope.owned.Add(handle);
                    RequireEntry(entry, WindowsFileSystem.ReadEntry(entry.Path, handle), strictDirectory: false);
                    scope.context.Add(entry.Path, (entry, handle));
                }
                var targetParent = scope.context[item.Path.Parent!];
                scope.Target = NativeFileHandles.OpenChild(targetParent.Handle, item.Path, targetParent.Entry.IsCaseSensitive, directory: true, deletion: true);
                scope.owned.Add(scope.Target);
                RequireEntry(target, WindowsFileSystem.ReadEntry(item.Path, scope.Target), strictDirectory: true);
                return scope;
            }
            catch { scope.Dispose(); throw; }
        }

        internal void VerifyTree(SafeFileHandle directory, FileEntry expected, Action check, Action<WindowsPath> progress)
        {
            check();
            RequireEntry(expected, WindowsFileSystem.ReadEntry(expected.Path, directory), strictDirectory: true);
            var direct = children.GetValueOrDefault(expected.Path) ?? [];
            var names = NativeFileHandles.Names(directory, expected.IsCaseSensitive, direct.Length, check);
            if (names.Count != direct.Length || direct.Any(entry => !names.Contains(entry.Path.Name))) throw Stale();
            foreach (var child in direct)
            {
                check();
                progress(child.Path);
                using var handle = NativeFileHandles.OpenChild(directory, child.Path, expected.IsCaseSensitive, child.Kind == EntryKind.Directory);
                RequireEntry(child, WindowsFileSystem.ReadEntry(child.Path, handle), strictDirectory: true);
                if (child.Kind == EntryKind.Directory) VerifyTree(handle, child, check, progress);
            }
            RequireEntry(expected, WindowsFileSystem.ReadEntry(expected.Path, directory), strictDirectory: true);
        }

        internal void VerifyContext()
        {
            foreach (var (entry, handle) in context.Values)
                RequireEntry(entry, WindowsFileSystem.ReadEntry(entry.Path, handle), strictDirectory: false);
        }

        private static void RequireSafeEntry(FileEntry entry, Workspace root)
        {
            if (entry is null || entry.Path is null || entry.Identity is null || entry.Kind is not (EntryKind.File or EntryKind.Directory) ||
                entry.Identity.OwnerSid != root.Identity.OwnerSid || entry.Identity.VolumeSerialNumber != root.Identity.VolumeSerialNumber ||
                entry.Kind == EntryKind.File && entry.LinkCount != 1) throw Stale();
        }

        public void Dispose()
        {
            for (var index = owned.Count - 1; index >= 0; index--) owned[index].Dispose();
            workspace.Dispose();
        }
    }

    private static void Report(IProgress<CleanupMutationProgress>? progress, CleanupMutationProgress value)
    {
        try { progress?.Report(value); } catch (Exception error) when (error is not OutOfMemoryException) { }
    }

    private static ShouException Stale() => new("plan_stale", "The native identity, context or exact manifest changed.");
}
