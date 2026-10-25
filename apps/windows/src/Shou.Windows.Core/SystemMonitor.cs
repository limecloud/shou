using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record MonitorCpuCounter(ulong Busy, ulong Idle);
public sealed record MonitorIoCounter(ulong Received, ulong Sent, string Scope);
public sealed record MonitorProcessCounter(string Id, int Pid, string Name, double CpuSeconds, ulong MemoryBytes);
public sealed record SystemMonitorObservation
{
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.UtcNow;
    public double Uptime { get; init; }
    public int LogicalCpuCount { get; init; } = 1;
    public ImmutableArray<MonitorCpuCounter> Cpu { get; init; } = [];
    public ImmutableArray<double> CorePercent { get; init; } = [];
    public ulong? MemoryTotal { get; init; }
    public ulong? MemoryUsed { get; init; }
    public ulong? MemoryCompressed { get; init; }
    public ulong? SwapUsed { get; init; }
    public string MemoryPressure { get; init; } = "Unavailable";
    public MonitorIoCounter? Disk { get; init; }
    public MonitorIoCounter? Network { get; init; }
    public double? GpuPercent { get; init; }
    public double? BatteryPercent { get; init; }
    public string PowerSource { get; init; } = "Unavailable";
    public string Hardware { get; init; } = "";
    public string OperatingSystem { get; init; } = "";
    public ulong? VolumeTotal { get; init; }
    public ulong? VolumeAvailable { get; init; }
    public double? BatteryHealth { get; init; }
    public int? BatteryCycles { get; init; }
    public double? CpuTemperature { get; init; }
    public double? GpuTemperature { get; init; }
    public ImmutableArray<double> FanRpm { get; init; } = [];
    public string ThermalState { get; init; } = "Unavailable";
    public ImmutableArray<MonitorProcessCounter> Processes { get; init; } = [];
    public string ProcessCoverage { get; init; } = "Complete";
    public ImmutableDictionary<string, string> Issues { get; init; } = ImmutableDictionary<string, string>.Empty;
}
public interface ISystemMonitorSampling
{
    Task<SystemMonitorObservation> ObserveAsync(CancellationToken cancellationToken);
}
public sealed record MonitorProcessUsage(MonitorProcessCounter Counter, double? CpuPercent);
public sealed record SystemMonitorSample(SystemMonitorObservation Observation, ImmutableDictionary<string, double> Values,
    ImmutableArray<double?> Cores, ImmutableArray<MonitorProcessUsage> Processes, bool Baseline);

/// <summary>Transient rate calculations; no persistence, mutation or process-control capability.</summary>
public sealed class SystemMonitorCalculator
{
    private SystemMonitorObservation? previous;
    private readonly Queue<SystemMonitorSample> history = new();
    public ImmutableArray<SystemMonitorSample> History => [.. history];
    public void ResetBaseline() => previous = null;
    private static double? Percent(double? value) => value is { } number && double.IsFinite(number) && number is >= 0 and <= 100 ? number : null;
    public SystemMonitorSample Append(SystemMonitorObservation observation)
    {
        var elapsed = observation.Uptime - (previous?.Uptime ?? observation.Uptime);
        var prior = double.IsFinite(elapsed) && elapsed is > 0 and <= 30 ? previous : null;
        var values = ImmutableDictionary.CreateBuilder<string, double>(StringComparer.Ordinal);
        var cores = ImmutableArray<double?>.Empty;
        if (prior is not null && prior.Cpu.Length == observation.Cpu.Length)
        {
            cores = observation.Cpu.Zip(prior.Cpu).Select(pair =>
            {
                if (pair.First.Busy < pair.Second.Busy || pair.First.Idle < pair.Second.Idle) return (double?)null;
                var busy = (double)(pair.First.Busy - pair.Second.Busy); var idle = (double)(pair.First.Idle - pair.Second.Idle);
                return busy + idle > 0 ? busy / (busy + idle) * 100 : (double?)null;
            }).ToImmutableArray();
            if (!cores.IsEmpty && cores.All(value => value.HasValue)) values["cpu"] = cores.Average(value => value!.Value);
        }
        // GetSystemTimes is an aggregate, never a single logical-core reading.
        if (observation.Cpu.Length == 1 && observation.LogicalCpuCount > 1) cores = [];
        if (prior is not null && !observation.CorePercent.IsEmpty)
        {
            cores = observation.CorePercent.Select(value => Percent(value)).ToImmutableArray();
            if (!values.ContainsKey("cpu") && cores.Length == observation.LogicalCpuCount && cores.All(value => value.HasValue))
                values["cpu"] = cores.Average(value => value!.Value);
        }
        if (observation.MemoryTotal is > 0 and var total && observation.MemoryUsed is { } used && used <= total)
            values["memory"] = (double)used / total * 100;
        if (Percent(observation.GpuPercent) is { } gpu) values["gpu"] = gpu;
        if (Percent(observation.BatteryPercent) is { } battery) values["battery"] = battery;
        void Rates(MonitorIoCounter? now, MonitorIoCounter? before, string read, string write)
        {
            if (prior is null || now is null || before is null || now.Scope != before.Scope || now.Received < before.Received || now.Sent < before.Sent) return;
            values[read] = (now.Received - before.Received) / elapsed; values[write] = (now.Sent - before.Sent) / elapsed;
        }
        Rates(observation.Disk, prior?.Disk, "diskRead", "diskWrite"); Rates(observation.Network, prior?.Network, "networkReceive", "networkSend");
        var older = (prior?.Processes ?? []).GroupBy(value => value.Id).ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
        var processes = observation.Processes.Select(process => new MonitorProcessUsage(process,
            older.TryGetValue(process.Id, out var before) && double.IsFinite(process.CpuSeconds) && process.CpuSeconds >= before.CpuSeconds
                ? Percent((process.CpuSeconds - before.CpuSeconds) / elapsed / Math.Max(1, observation.LogicalCpuCount) * 100) : null)).ToImmutableArray();
        var sample = new SystemMonitorSample(observation, values.ToImmutable(), cores, processes, prior is null);
        previous = observation; history.Enqueue(sample); while (history.Count > 60) history.Dequeue(); return sample;
    }
}
