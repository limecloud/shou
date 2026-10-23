using Shou.Windows.Core;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsApplicationActivityTests
{
    [WindowsFact]
    public async Task CurrentProcessImageIsObservedWithoutWorkingDirectoryOrPrivateMemory()
    {
        var expected = WindowsPath.Parse(Environment.ProcessPath!);
        var snapshot = await new WindowsApplicationProcesses().InspectAsync([expected.Name], default);
        Assert.True(snapshot.Complete, snapshot.Reason);
        var process = Assert.Single(snapshot.Processes, process => process.ProcessId == Environment.ProcessId);
        Assert.True(process.IsCurrentProcess);
        Assert.NotNull(process.ExecutablePath);
        Assert.True(expected.SamePath(process.ExecutablePath));
        Assert.Null(process.WorkingDirectory);
        Assert.False(process.Exited);
    }

    [WindowsFact]
    public void ReusedOrMismatchedProcessNameCannotProduceAnImageScope()
    {
        var observed = WindowsApplicationProcesses.ReadImage(new((uint)Environment.ProcessId, "Shou.Tests.Unmatched.exe"), default);
        Assert.Null(observed.ExecutablePath);
        Assert.False(observed.Exited);
    }

    [WindowsFact]
    public async Task GeneratedInstallationDirectoryCanBeInspectedWithoutAnInstallerOrTargetChanges()
    {
        using var fixture = new NativeFixture();
        var path = Path.Combine(fixture.Root, "Shou.Tests." + Guid.NewGuid().ToString("N") + ".exe");
        var bytes = new byte[] { 1, 2, 3, 4 };
        await File.WriteAllBytesAsync(path, bytes);
        var root = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(fixture.Root), default);
        var installation = new ApplicationUninstallObservation(new(ApplicationInstallerKind.Msi, Guid.NewGuid().ToString("B"), MsiInstallationContext.Machine,
            null, Guid.NewGuid().ToString("B")), "Generated fixture", "1.0", null, root, false, []);
        var observed = await new WindowsApplicationActivity().InspectAsync(installation, default);
        Assert.Equal(ActivityState.Idle, observed.State);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(path));
    }

    [WindowsFact]
    public async Task PreCancelledImageInspectionDoesNotEnumerateOrReadAProcess()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new WindowsApplicationProcesses().InspectAsync([], cancellation.Token));
    }
}
