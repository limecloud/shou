using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Relative handle operations. The caller retains the verified parent for the whole operation.</summary>
internal static class NativeFileHandles
{
    internal static unsafe SafeFileHandle OpenChild(SafeFileHandle parent, WindowsPath path, bool caseSensitive,
        bool deletion = false)
    {
        // WindowsPath validates a single basename before it reaches OBJECT_ATTRIBUTES.
        var name = path.Name;
        if (path.IsVolumeRoot || name.Length is < 1 or > 255) throw UnsafePath();
        var added = false;
        try
        {
            parent.DangerousAddRef(ref added);
            fixed (char* characters = name)
            {
                var unicode = new NativeMethods.UnicodeString
                {
                    Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)(name.Length * 2)),
                    Buffer = (nint)characters
                };
                var attributes = new NativeMethods.ObjectAttributes
                {
                    Length = (uint)Marshal.SizeOf<NativeMethods.ObjectAttributes>(), RootDirectory = parent.DangerousGetHandle(),
                    ObjectName = (nint)(&unicode), Attributes = caseSensitive ? 0 : NativeMethods.ObjectCaseInsensitive
                };
                // Data/list access is required for the share mask to protect both files and directories.
                var access = NativeMethods.ReadData | NativeMethods.ReadAttributes | NativeMethods.ReadControl | NativeMethods.SynchronizeAccess |
                    (deletion ? NativeMethods.DeleteAccess : 0);
                var status = NativeMethods.OpenRelativeFile(out var handle, access, (nint)(&attributes), out _, 0, 0,
                    NativeMethods.ShareRead, NativeMethods.NtOpen,
                    NativeMethods.NtSynchronousNonAlert | NativeMethods.NtOpenReparsePoint | NativeMethods.NtOpenNoRecall,
                    0, 0);
                if (status >= 0 && !handle.IsInvalid) return handle;
                handle.Dispose();
                throw WindowsFileSystem.NativeError(checked((int)NativeMethods.NtStatusToDosError(status)));
            }
        }
        finally { if (added) parent.DangerousRelease(); }
    }

    internal static HashSet<string> Names(SafeFileHandle directory, bool caseSensitive, int maximumEntries, Action check)
    {
        var names = new HashSet<string>(caseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
        try { NativeDirectoryReader.Read(directory, caseSensitive, maximumEntries, check, name => names.Add(name)); }
        catch (ShouException error) when (error.Code == "entry_limit")
        { throw new ShouException("plan_stale", "The directory contains entries outside the frozen manifest.", error); }
        return names;
    }

    internal static unsafe void MarkForRemoval(SafeFileHandle handle)
    {
        // POSIX disposition unlinks this opened name when its delete handle closes. No recursive or readonly override.
        var flags = NativeMethods.DispositionDelete | NativeMethods.DispositionPosix | NativeMethods.DispositionForceImageSectionCheck;
        if (!NativeMethods.SetFileInformation(handle, NativeMethods.DispositionInfoEx, (nint)(&flags), sizeof(uint)))
            throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
    }

    private static ShouException UnsafePath() => new("unsafe_path", "A relative native operation requires a verified basename.");
}
