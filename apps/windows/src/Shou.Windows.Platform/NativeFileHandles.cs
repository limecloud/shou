using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Relative handle operations. The caller retains the verified parent for the whole operation.</summary>
internal static class NativeFileHandles
{
    private const int DirectoryBufferBytes = 65_536;
    private const int DirectoryNameOffset = 68; // FILE_FULL_DIR_INFO.FileName, shared by x64 and ARM64.

    internal static unsafe SafeFileHandle OpenChild(SafeFileHandle parent, WindowsPath path, bool caseSensitive,
        bool directory, bool deletion = false)
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
                var access = NativeMethods.ReadAttributes | NativeMethods.ReadControl | NativeMethods.SynchronizeAccess |
                    (directory ? NativeMethods.ReadData : 0) | (deletion ? NativeMethods.DeleteAccess : 0);
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

    internal static unsafe HashSet<string> Names(SafeFileHandle directory, bool caseSensitive, int maximumEntries, Action check)
    {
        var names = new HashSet<string>(caseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
        var buffer = NativeMemory.AllocZeroed(DirectoryBufferBytes);
        try
        {
            var informationClass = NativeMethods.FullDirectoryRestartInfo;
            while (true)
            {
                check();
                NativeMemory.Clear(buffer, DirectoryBufferBytes);
                if (!NativeMethods.GetDirectoryInfo(directory, informationClass, (nint)buffer, DirectoryBufferBytes))
                {
                    var error = Marshal.GetLastPInvokeError();
                    if (error == 18) return names; // ERROR_NO_MORE_FILES
                    throw WindowsFileSystem.NativeError(error);
                }
                informationClass = NativeMethods.FullDirectoryInfo;
                var offset = 0;
                while (true)
                {
                    check();
                    if (offset > DirectoryBufferBytes - DirectoryNameOffset) throw InvalidDirectory();
                    var start = (nint)buffer + offset;
                    var next = Marshal.ReadInt32(start);
                    var length = Marshal.ReadInt32(start, 60);
                    if (length is < 2 or > 510 || length % 2 != 0 || length > DirectoryBufferBytes - offset - DirectoryNameOffset ||
                        next != 0 && (next < DirectoryNameOffset + length || next % 8 != 0 || next > DirectoryBufferBytes - offset - DirectoryNameOffset)) throw InvalidDirectory();
                    var name = Marshal.PtrToStringUni(start + DirectoryNameOffset, length / 2) ?? throw InvalidDirectory();
                    if (name is not ("." or ".."))
                    {
                        if (name.Contains('\0') || name.Contains('\\') || name.Contains('/') || !names.Add(name)) throw InvalidDirectory();
                        if (names.Count > maximumEntries) throw new ShouException("plan_stale", "The directory contains entries outside the frozen manifest.");
                    }
                    if (next == 0) break;
                    offset = checked(offset + next);
                }
            }
        }
        finally { NativeMemory.Free(buffer); }
    }

    internal static unsafe void MarkForRemoval(SafeFileHandle handle)
    {
        // POSIX disposition unlinks this opened name when its delete handle closes. No recursive or readonly override.
        var flags = NativeMethods.DispositionDelete | NativeMethods.DispositionPosix | NativeMethods.DispositionForceImageSectionCheck;
        if (!NativeMethods.SetFileInformation(handle, NativeMethods.DispositionInfoEx, (nint)(&flags), sizeof(uint)))
            throw WindowsFileSystem.NativeError(Marshal.GetLastPInvokeError());
    }

    private static ShouException UnsafePath() => new("unsafe_path", "A relative native operation requires a verified basename.");
    private static ShouException InvalidDirectory() => new("unsupported_metadata", "The native directory listing could not be verified.");
}
