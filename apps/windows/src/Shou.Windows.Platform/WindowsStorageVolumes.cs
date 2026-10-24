using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed record StorageVolume(WindowsPath Path, string Name, long TotalBytes, long AvailableBytes);

public static class WindowsStorageVolumes
{
    public static ImmutableArray<StorageVolume> Read()
    {
        var result = ImmutableArray.CreateBuilder<StorageVolume>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (drive.DriveType != DriveType.Fixed || !drive.IsReady) continue;
                result.Add(new(WindowsPath.Parse(drive.RootDirectory.FullName),
                    string.IsNullOrEmpty(drive.VolumeLabel) ? drive.Name : drive.VolumeLabel + " (" + drive.Name + ")",
                    drive.TotalSize, drive.AvailableFreeSpace));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ShouException) { NativeDiagnostics.Write(error); }
        }
        return result.ToImmutable();
    }
}
