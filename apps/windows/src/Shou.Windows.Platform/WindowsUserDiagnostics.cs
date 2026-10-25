using System.Runtime.InteropServices;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed partial class WindowsUserDiagnostics(string applicationVersion, WindowsPath? recordsDirectory = null) : IUserDiagnostics
{
    public async Task<DiagnosticReport> CollectAsync(CancellationToken cancellationToken)
    {
        if (!NativeWindowsSupport.IsSupported) throw new ShouException("unsupported_platform", "User diagnostics require native 64-bit Windows 11.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        try { return await NativeOperationScheduler.RunAsync(() => Collect(deadline.Token), deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new ShouException("resource_limit", "System facts could not be observed within the diagnostic time limit."); }
    }

    private DiagnosticReport Collect(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        long? capacity = null, free = null;
        try
        {
            var home = WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
            using var pinned = WindowsFileSystem.PinPath(home);
            var volume = new DriveInfo(home.Value[..3]);
            capacity = volume.TotalSize; free = volume.AvailableFreeSpace;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or ArgumentException) { }
        cancellationToken.ThrowIfCancellationRequested();
        var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        ulong? physical = GlobalMemoryStatus(ref memory) ? memory.TotalPhysical : null;
        DiagnosticRecordState records;
        try
        {
            var store = recordsDirectory is null ? WindowsRecordStore.ForCurrentUser() : new WindowsRecordStore(recordsDirectory);
            records = store.InspectDirectoryForDiagnostics(cancellationToken);
        }
        catch (ShouException) { records = DiagnosticRecordState.Unavailable; }
        cancellationToken.ThrowIfCancellationRequested();
        return DiagnosticReport.Create(applicationVersion, RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
            Environment.OSVersion.Version.ToString(), Environment.ProcessorCount, physical, capacity, free, records);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        internal uint Length, Load;
        internal ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "GlobalMemoryStatusEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GlobalMemoryStatus(ref MemoryStatus status);
}
