using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Shared bounded 64 KiB handle-based directory reader for observations and mutation verification.</summary>
internal static class NativeDirectoryReader
{
    private const int DirectoryBufferBytes = 65_536;
    private const int DirectoryNameOffset = 68; // FILE_FULL_DIR_INFO.FileName on x64 and ARM64.

    internal static unsafe void Read(SafeFileHandle directory, bool caseSensitive, int maximumEntries, Action check, Action<string> consume)
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
                    if (error == 18) return; // ERROR_NO_MORE_FILES
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
                        if (names.Count > maximumEntries) throw new ShouException("entry_limit", "The native directory listing reached its entry budget.");
                        consume(name);
                    }
                    if (next == 0) break;
                    offset = checked(offset + next);
                }
            }
        }
        finally { NativeMemory.Free(buffer); }
    }

    private static ShouException InvalidDirectory() => new("unsupported_metadata", "The native directory listing could not be verified.");
}
