using System.Diagnostics;
using Shou.Windows.Core;
using NativeFixture = Shou.Windows.Platform.Tests.WindowsFileSystemTests.NativeFixture;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsProcessInventoryTests
{
    [WindowsFact]
    public async Task NativeSnapshotIncludesTheCurrentProcessAndContainsOnlyBoundedNames()
    {
        var result = await new WindowsProcessInventory().InspectAsync([], default);
        Assert.True(result.Complete, result.Reason);
        Assert.Contains(result.Processes, process => process.ProcessId == Environment.ProcessId);
        Assert.True(result.Processes.Single(process => process.ProcessId == Environment.ProcessId).IsCurrentProcess);
        Assert.InRange(result.Processes.Length, 1, CleanupActivityService.MaximumProcesses);
        Assert.Equal(result.Processes.Length, result.Processes.Select(process => process.ProcessId).Distinct().Count());
        Assert.All(result.Processes, process => Assert.DoesNotContain(process.ExecutableName, character => char.IsControl(character) || character is '/' or '\\' or ':'));
    }

    [WindowsFact]
    public async Task CurrentProcessDirectoryMatchesNativeDirectoryIdentity()
    {
        var path = WindowsPath.Parse(Environment.CurrentDirectory);
        var expected = await new WindowsFileSystem().InspectAsync(path, default);
        var name = Path.GetFileName(Environment.ProcessPath)!;
        var snapshot = await new WindowsProcessInventory().InspectAsync([name], default);
        var process = snapshot.Processes.Single(item => item.ProcessId == Environment.ProcessId);
        Assert.NotNull(process.WorkingDirectory);
        Assert.Equal(expected.Identity, process.WorkingDirectory.Identity);
        Assert.True(process.WorkingDirectory.Path.SamePath(path));
    }

    [WindowsFact]
    public async Task Wow64ProcessDirectoryIsReadWithoutReadingArgumentsOrEnvironment()
    {
        using var fixture = new NativeFixture();
        var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "SysWOW64/cmd.exe");
        Assert.True(File.Exists(executable));
        var start = new ProcessStartInfo(executable) { WorkingDirectory = fixture.Root, UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("/d");
        start.ArgumentList.Add("/q");
        using var process = Process.Start(start)!;
        try
        {
            ProcessObservation? observed = null;
            var started = Stopwatch.GetTimestamp();
            while (Stopwatch.GetElapsedTime(started) < TimeSpan.FromSeconds(5))
            {
                var snapshot = await new WindowsProcessInventory().InspectAsync(["cmd.exe"], default);
                observed = snapshot.Processes.FirstOrDefault(item => item.ProcessId == process.Id);
                if (observed?.WorkingDirectory is not null) break;
                Assert.False(process.HasExited);
                await Task.Delay(25);
            }
            Assert.NotNull(observed?.WorkingDirectory);
            var expected = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(fixture.Root), default);
            Assert.Equal(expected.Identity, observed.WorkingDirectory.Identity);
            Assert.True(observed.WorkingDirectory.Path.SamePath(expected.Path));
        }
        finally
        {
            if (!process.HasExited)
            {
                await process.StandardInput.WriteLineAsync("exit");
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
                catch (TimeoutException) { process.Kill(); await process.WaitForExitAsync(); }
            }
        }
    }

    [WindowsFact]
    public async Task PreCancelledSnapshotsDoNotStartNativeEnumeration()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new WindowsProcessInventory().InspectAsync([], cancelled.Token));
    }
}
