using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Shou.Windows.Platform;

internal static partial class NativeMethods
{
    internal const uint DeleteAccess = 0x00010000;
    internal const uint SynchronizeAccess = 0x00100000;
    internal const uint NtOpen = 1;
    internal const uint NtSynchronousNonAlert = 0x20;
    internal const uint NtOpenReparsePoint = 0x00200000;
    internal const uint NtOpenNoRecall = 0x00400000;
    internal const uint ObjectCaseInsensitive = 0x40;
    internal const int FullDirectoryInfo = 14;
    internal const int FullDirectoryRestartInfo = 15;
    internal const int DispositionInfoEx = 21;
    internal const int RenameInformation = 10;
    internal const uint DispositionDelete = 1;
    internal const uint DispositionPosix = 2;
    internal const uint DispositionForceImageSectionCheck = 4;

    [LibraryImport("ntdll.dll", EntryPoint = "NtCreateFile")]
    internal static partial int OpenRelativeFile(out SafeFileHandle handle, uint access, nint attributes,
        out IoStatusBlock status, nint allocation, uint fileAttributes, uint share, uint disposition,
        uint options, nint extendedAttributes, uint extendedAttributeLength);

    [LibraryImport("ntdll.dll", EntryPoint = "NtSetInformationFile")]
    internal static partial int SetRelativeFileInformation(SafeFileHandle handle, out IoStatusBlock status,
        nint information, uint size, int informationClass);

    [LibraryImport("ntdll.dll", EntryPoint = "RtlNtStatusToDosError")]
    internal static partial uint NtStatusToDosError(int status);

    [LibraryImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetDirectoryInfo(SafeFileHandle handle, int informationClass, nint buffer, uint size);

    [StructLayout(LayoutKind.Sequential)]
    internal struct UnicodeString
    {
        internal ushort Length;
        internal ushort MaximumLength;
        internal nint Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ObjectAttributes
    {
        internal uint Length;
        internal nint RootDirectory;
        internal nint ObjectName;
        internal uint Attributes;
        internal nint SecurityDescriptor;
        internal nint SecurityQualityOfService;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IoStatusBlock
    {
        internal nint Status;
        internal nuint Information;
    }

    [LibraryImport("rstrtmgr.dll", EntryPoint = "RmStartSession")]
    internal static partial int RestartManagerStart(out uint session, uint flags, nint key);

    [DllImport("rstrtmgr.dll", EntryPoint = "RmRegisterResources", CharSet = CharSet.Unicode)]
    internal static extern int RestartManagerRegister(uint session, uint fileCount,
        [In, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr, SizeParamIndex = 1)] string[] files,
        uint applicationCount, nint applications, uint serviceCount, nint services);

    [LibraryImport("rstrtmgr.dll", EntryPoint = "RmGetList")]
    internal static partial int RestartManagerList(uint session, out uint needed, ref uint count,
        nint applications, out uint rebootReasons);

    [LibraryImport("rstrtmgr.dll", EntryPoint = "RmEndSession")]
    internal static partial int RestartManagerEnd(uint session);
}
