using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsSystemMonitorTests
{
    [WindowsFact] public async Task NativeReadReturnsBoundedFactsAndOwnedHandlesCanBeDisposed()
    {
        var source = new WindowsSystemMonitor();
        var first = await source.ObserveAsync(default);
        await Task.Delay(100);
        var second = await source.ObserveAsync(default);
        Assert.True(first.Uptime > 0); Assert.True(second.Uptime > first.Uptime); Assert.True(first.LogicalCpuCount > 0);
        Assert.True(first.MemoryTotal > 0); Assert.True(first.MemoryUsed <= first.MemoryTotal);
        Assert.InRange(first.Processes.Length, 0, 4096); Assert.All(first.Processes, process => Assert.InRange(process.Name.Length, 0, 256));
        Assert.All(first.CorePercent, value => Assert.True(double.IsFinite(value) && value is >= 0 and <= 100));
        Assert.Null(first.SwapUsed); Assert.Null(first.MemoryCompressed); Assert.Null(first.CpuTemperature);
        var calculator = new SystemMonitorCalculator(); calculator.Append(first); var sample = calculator.Append(second);
        Assert.All(sample.Values, pair => Assert.True(double.IsFinite(pair.Value) && pair.Value >= 0));
        source.Dispose(); source.Dispose();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => source.ObserveAsync(default));
    }
    [WindowsFact] public async Task NativeReadHonorsAlreadyCanceledRequests()
    {
        using var source = new WindowsSystemMonitor(); using var canceled = new CancellationTokenSource(); canceled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => source.ObserveAsync(canceled.Token));
    }
}
