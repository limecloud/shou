using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Shou.Windows.Platform;

internal static partial class NativeMethods
{
    [LibraryImport("kernel32.dll", EntryPoint = "OpenProcess", SetLastError = true)]
    internal static partial SafeFileHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint processId);

    [LibraryImport("kernel32.dll", EntryPoint = "WaitForSingleObject", SetLastError = true)]
    internal static partial uint WaitForProcess(SafeFileHandle process, uint milliseconds);

    [LibraryImport("kernel32.dll", EntryPoint = "ReadProcessMemory", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ReadProcessMemory(SafeFileHandle process, nint address, nint buffer, nuint size, out nuint read);

    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ProcessImageName(SafeFileHandle process, uint flags, nint name, ref uint length);

    [LibraryImport("ntdll.dll", EntryPoint = "NtQueryInformationProcess")]
    internal static partial int ProcessInformation(SafeFileHandle process, int informationClass, nint buffer, uint size, out uint returned);

    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessBasicInformation
    {
        internal nint ExitStatus;
        internal nint PebAddress;
        internal nuint Affinity;
        internal nint Priority;
        internal nuint ProcessId;
        internal nuint ParentId;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateToolhelp32Snapshot", SetLastError = true)]
    internal static partial SafeFileHandle ProcessSnapshot(uint flags, uint processId);

    [LibraryImport("kernel32.dll", EntryPoint = "Process32FirstW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ProcessFirst(SafeFileHandle snapshot, ref ProcessEntry entry);

    [LibraryImport("kernel32.dll", EntryPoint = "Process32NextW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool ProcessNext(SafeFileHandle snapshot, ref ProcessEntry entry);

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct ProcessEntry
    {
        internal uint Size;
        internal uint Usage;
        internal uint ProcessId;
        internal nuint DefaultHeap;
        internal uint ModuleId;
        internal uint Threads;
        internal uint ParentProcessId;
        internal int Priority;
        internal uint Flags;
        internal fixed char Executable[260];
    }
}
