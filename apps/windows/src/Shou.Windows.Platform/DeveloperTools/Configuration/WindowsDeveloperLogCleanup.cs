using System.Runtime.InteropServices;
using System.Security.Principal;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Pin every ancestor and the exact file; never follow links or remove an active log's directory entry.</summary>
public sealed class WindowsDeveloperLogCleanup(string toolId, WindowsPath path) : IDeveloperLogCleaning
{
    public Task<DeveloperLogInspection> InspectAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested(); RequirePath(path);
        using var pinned = WindowsFileSystem.PinPath(path, allowFinalSharedWrites: true);
        var entry = WindowsFileSystem.ReadEntry(path, pinned.Final);
        RequireFile(entry);
        var writable = false;
        try
        {
            using var write = WindowsFileSystem.PinPath(path, finalAccess: 2);
            writable = WindowsFileSystem.ReadEntry(path, write.Final) == entry;
        }
        catch (ShouException) { }
        return new DeveloperLogInspection(toolId, entry, writable);
    }, cancellationToken);

    public Task ClearAsync(DeveloperLogInspection expected, CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested(); RequirePath(path);
        if (expected.ToolId != toolId || expected.File.Path != path || !expected.Writable) throw Changed();
        // Deny writes and replacement until truncation and FlushFileBuffers finish.
        using var pinned = WindowsFileSystem.PinPath(path, finalAccess: 2);
        var entry = WindowsFileSystem.ReadEntry(path, pinned.Final); RequireFile(entry);
        if (entry != expected.File) throw Changed();
        RandomAccess.SetLength(pinned.Final, 0);
        if (!NativeMethods.FlushFileBuffers(pinned.Final)) throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
        var after = WindowsFileSystem.ReadEntry(path, pinned.Final);
        if (after.Identity != entry.Identity || after.LogicalBytes != 0) throw Changed();
    }, cancellationToken);

    private static void RequireFile(FileEntry entry)
    {
        using var user = WindowsIdentity.GetCurrent();
        if (entry.Kind != EntryKind.File || entry.LinkCount != 1 || entry.Identity.OwnerSid != user.User?.Value) throw Changed();
    }
    internal static void RequirePath(WindowsPath target)
    {
        var extension = System.IO.Path.GetExtension(target.Name);
        if (!new[] { ".log", ".err", ".out" }.Contains(extension, StringComparer.OrdinalIgnoreCase)) throw Changed();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roots = new[] { ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".config/gcloud", "AppData/Roaming/Microsoft/Credentials", "AppData/Local/Microsoft/Credentials" }
            .Select(suffix => WindowsPath.Parse(home).Append(suffix)).ToList();
        roots.Add(WindowsRecordStore.ForCurrentUser().Directory);
        roots.Add(WindowsRecordStore.ForDiagnostics().Directory);
        foreach (var name in new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.System })
        {
            var value = Environment.GetFolderPath(name);
            if (!string.IsNullOrEmpty(value)) roots.Add(WindowsPath.Parse(value));
        }
        if (roots.Any(root => target.IsWithin(root))) throw Changed();
    }
    private static ShouException Changed() => new("developer_log_changed", "The log changed or cannot be cleared. Reload its exact file before trying again.");
}
