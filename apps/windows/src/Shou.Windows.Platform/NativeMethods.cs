using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Shou.Windows.Platform;

internal static partial class NativeMethods
{
    internal const uint ReadData = 1;
    internal const uint ReadAttributes = 0x80;
    internal const uint ReadControl = 0x20000;
    internal const uint ShareRead = 1;
    internal const uint ShareWrite = 2;
    internal const uint OpenExisting = 3;
    internal const uint OpenReparsePoint = 0x00200000;
    internal const uint BackupSemantics = 0x02000000;
    internal const uint OpenNoRecall = 0x00100000;
    internal const uint DirectoryAttribute = 0x10;
    internal const uint ReparseAttribute = 0x400;
    internal const uint OfflineAttribute = 0x1000;

    [LibraryImport("kernel32.dll", EntryPoint = "CreateDirectoryW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CreateDirectory(string path, nint security);

    [LibraryImport("kernel32.dll", EntryPoint = "FlushFileBuffers", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool FlushFileBuffers(SafeFileHandle handle);

    [LibraryImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetFileInformation(SafeFileHandle handle, int informationClass, nint info, uint size);

    [LibraryImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ConvertSecurityDescriptor(string text, uint revision, out nint descriptor, out uint size);

    [LibraryImport("advapi32.dll", EntryPoint = "GetSecurityDescriptorLength")]
    internal static partial uint SecurityDescriptorLength(nint descriptor);

    [LibraryImport("advapi32.dll", EntryPoint = "GetSecurityInfo")]
    internal static partial uint GetPrivateSecurityInfo(SafeFileHandle handle, uint objectType, uint information,
        out nint owner, nint group, out nint dacl, nint sacl, out nint descriptor);

    [StructLayout(LayoutKind.Sequential)]
    internal struct SecurityAttributes
    {
        internal int Length;
        internal nint Descriptor;
        internal int InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileRenameInfo
    {
        internal uint Flags;
        internal nint RootDirectory;
        internal uint FileNameLength;
        internal ushort FileName;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial SafeFileHandle CreateFile(string path, uint access, uint share, nint security,
        uint creation, uint flags, nint template);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetBasicInfo(SafeFileHandle handle, int informationClass, out FileBasicInfo info, uint size);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetStandardInfo(SafeFileHandle handle, int informationClass, out FileStandardInfo info, uint size);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetIdInfo(SafeFileHandle handle, int informationClass, out FileIdInfo info, uint size);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCaseInfo(SafeFileHandle handle, int informationClass, out FileCaseInfo info, uint size);

    [LibraryImport("advapi32.dll", EntryPoint = "GetSecurityInfo")]
    internal static partial uint GetSecurityInfo(SafeFileHandle handle, uint objectType, uint information,
        out nint owner, nint group, nint dacl, nint sacl, out nint descriptor);

    [LibraryImport("advapi32.dll", EntryPoint = "ConvertSidToStringSidW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ConvertSidToString(nint sid, out nint text);

    [LibraryImport("kernel32.dll", EntryPoint = "LocalFree")]
    internal static partial nint LocalFree(nint memory);

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileBasicInfo
    {
        internal long CreationTime;
        internal long LastAccessTime;
        internal long LastWriteTime;
        internal long ChangeTime;
        internal uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileStandardInfo
    {
        internal long AllocationSize;
        internal long EndOfFile;
        internal uint NumberOfLinks;
        internal byte DeletePending;
        internal byte Directory;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct FileIdInfo
    {
        internal ulong VolumeSerialNumber;
        internal fixed byte Id[16];
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileCaseInfo { internal uint Flags; }
}
