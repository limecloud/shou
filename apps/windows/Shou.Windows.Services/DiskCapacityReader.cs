using System.Runtime.InteropServices;

namespace Shou.Windows.Services;

public sealed record DiskCapacity(long TotalBytes, long AvailableBytes)
{
    public double UsedPercentage => 100d * (TotalBytes - AvailableBytes) / TotalBytes;
}

public static class DiskCapacityReader
{
    public static DiskCapacity? Read(string directory)
    {
        if (!OperatingSystem.IsWindows() || string.IsNullOrWhiteSpace(directory) || directory.Contains('\0') ||
            directory.Length > 32766 || !Path.IsPathFullyQualified(directory)) return null;
        // Query the actual folder so mounted volumes and per-user quotas retain
        // their native meaning. Never sum scan sizes to infer disk capacity.
        var path = Path.EndsInDirectorySeparator(directory) ? directory : directory + Path.DirectorySeparatorChar;
        if (!GetDiskFreeSpaceEx(path, out var available, out var total, out _) ||
            total == 0 || total > long.MaxValue || available > total) return null;
        return new((long)total, (long)available);
    }

    [DllImport("kernel32.dll", EntryPoint = "GetDiskFreeSpaceExW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceEx(string directory, out ulong availableToCaller, out ulong totalToCaller, out ulong totalFree);
}
