using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class SystemMonitorTests
{
    private static SystemMonitorObservation Observation(double time, ulong counter = 100) => new()
    {
        Uptime = time, LogicalCpuCount = 2, Cpu = [new(counter, 100)], MemoryTotal = 1000, MemoryUsed = 500,
        Disk = new(counter, counter, "disk1"), Network = new(counter, counter, "nic1"),
        Processes = [new("42:start1", 42, "fixture", time, 50)]
    };
    [Fact] public void RatesNeedTwoFreshObservationsAndUseTotalMachineCapacity()
    {
        var calculator = new SystemMonitorCalculator(); var first = calculator.Append(Observation(1));
        Assert.False(first.Values.ContainsKey("cpu")); Assert.False(first.Values.ContainsKey("diskRead")); Assert.Null(first.Processes[0].CpuPercent);
        var next = calculator.Append(Observation(3, 200));
        Assert.Equal(100, next.Values["cpu"]); Assert.Equal(50, next.Values["diskRead"]); Assert.Equal(50, next.Processes[0].CpuPercent);
        Assert.Equal(50, next.Values["memory"]); Assert.Empty(next.Cores);
    }
    [Theory]
    [InlineData("sleep")][InlineData("backwards")][InlineData("zero")][InlineData("scope")][InlineData("counter")]
    public void DiscontinuitiesNeverBecomeZeroOrNegativeRates(string kind)
    {
        var calculator = new SystemMonitorCalculator(); calculator.Append(Observation(1));
        var now = kind switch
        {
            "sleep" => Observation(40, 200), "backwards" => Observation(0, 200), "zero" => Observation(1, 200),
            "scope" => Observation(3, 200) with { Disk = new(200, 200, "disk2") }, _ => Observation(3, 50)
        };
        Assert.False(calculator.Append(now).Values.ContainsKey("diskRead"));
        Assert.True(calculator.Append(Observation(now.Uptime + 2, 300)).Values.ContainsKey("memory"));
    }
    [Fact] public void ProcessorGroupsRequireCompleteCoreCoverageAndRespectWarmup()
    {
        var calculator = new SystemMonitorCalculator(); var observation = Observation(1) with { Cpu = [], CorePercent = [20, 60] };
        Assert.False(calculator.Append(observation).Values.ContainsKey("cpu"));
        Assert.Equal(40, calculator.Append(observation with { Uptime = 3 }).Values["cpu"]);
        Assert.False(calculator.Append(observation with { Uptime = 5, CorePercent = [20] }).Values.ContainsKey("cpu"));
        calculator.ResetBaseline(); Assert.False(calculator.Append(observation with { Uptime = 7 }).Values.ContainsKey("cpu"));
    }
    [Fact] public void PidReuseUnknownValuesAndHistoryStayBounded()
    {
        var calculator = new SystemMonitorCalculator(); calculator.Append(Observation(1));
        var next = calculator.Append(Observation(3) with { GpuPercent = double.NaN, BatteryPercent = 101, MemoryUsed = 1001, Processes = [new("42:start2", 42, "new", 100, 0)] });
        Assert.Null(next.Processes[0].CpuPercent); Assert.False(next.Values.ContainsKey("gpu")); Assert.False(next.Values.ContainsKey("battery")); Assert.False(next.Values.ContainsKey("memory"));
        for (var i = 0; i < 100; i++) calculator.Append(Observation(i + 10));
        Assert.Equal(60, calculator.History.Length);
    }
}
