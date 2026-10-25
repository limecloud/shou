using System.Collections.Immutable;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Read-only native counters with bounded process metadata and owned PDH handles.</summary>
public sealed class WindowsSystemMonitor : ISystemMonitorSampling, IDisposable
{
    private readonly object gate = new();
    private nint query, cpuCounter, gpuCounter, diskReadCounter, diskWriteCounter;
    private bool disposed;
    public Task<SystemMonitorObservation> ObserveAsync(CancellationToken cancellationToken) => Task.Run(() => Read(cancellationToken), cancellationToken);
    private SystemMonitorObservation Read(CancellationToken token)
    {
        if (!OperatingSystem.IsWindows()) throw new ShouException("unsupported_platform", "System monitoring requires native Windows.");
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this); token.ThrowIfCancellationRequested();
            var uptime = Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
            var logicalCpuCount = Math.Max(1, (int)GetActiveProcessorCount(ushort.MaxValue));
            ulong? volumeTotal = null, volumeAvailable = null;
            try { var volume = new DriveInfo(Path.GetPathRoot(Environment.SystemDirectory)!); volumeTotal = (ulong)volume.TotalSize; volumeAvailable = (ulong)volume.AvailableFreeSpace; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            var hardware = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", "") as string ?? "";
            var cpu = ImmutableArray<MonitorCpuCounter>.Empty;
            if (GetActiveProcessorGroupCount() == 1 && GetSystemTimes(out var idle, out var kernel, out var user) && kernel.Value >= idle.Value)
                cpu = [new(kernel.Value - idle.Value + user.Value, idle.Value)];
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            var memoryAvailable = GlobalMemoryStatusEx(ref memory);
            var powerAvailable = GetSystemPowerStatus(out var power);
            InitializeQuery();
            var collected = query != 0 && PdhCollectQueryData(query) == 0;
            var cores = collected ? Formatted(cpuCounter).Where(pair => pair.Key.Split(',') is [var group, var index] && int.TryParse(group, out _) && int.TryParse(index, out _))
                .OrderBy(pair => int.Parse(pair.Key.Split(',')[0])).ThenBy(pair => int.Parse(pair.Key.Split(',')[1])).Select(pair => pair.Value).ToImmutableArray() : [];
            var gpu = collected ? Formatted(gpuCounter) : new Dictionary<string, double>();
            // Sum process contributions for each physical engine, then report the busiest engine.
            var gpuValues = gpu.Where(pair => pair.Key.StartsWith("pid_", StringComparison.Ordinal) && pair.Key.Contains("_luid_", StringComparison.Ordinal))
                .GroupBy(pair => pair.Key[(pair.Key.IndexOf("_luid_", StringComparison.Ordinal) + 1)..], StringComparer.Ordinal)
                .Select(group => group.Sum(pair => pair.Value)).ToArray();
            var read = collected ? Raw(diskReadCounter) : new Dictionary<string, ulong>();
            var write = collected ? Raw(diskWriteCounter) : new Dictionary<string, ulong>();
            MonitorIoCounter? disk = read.Count > 0 && read.Keys.Order().SequenceEqual(write.Keys.Order())
                ? new(read.Values.Aggregate(0UL, (sum, value) => checked(sum + value)), write.Values.Aggregate(0UL, (sum, value) => checked(sum + value)), string.Join('|', read.Keys.Order())) : null;
            MonitorIoCounter? network = null;
            try
            {
                var interfaces = NetworkInterface.GetAllNetworkInterfaces().Where(value => value.OperationalStatus == OperationalStatus.Up &&
                    value.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211).OrderBy(value => value.Id, StringComparer.Ordinal).ToArray();
                ulong received = 0, sent = 0;
                foreach (var item in interfaces)
                {
                    var stats = item.GetIPStatistics(); received = checked(received + (ulong)stats.BytesReceived); sent = checked(sent + (ulong)stats.BytesSent);
                }
                if (interfaces.Length > 0) network = new(received, sent, string.Join('|', interfaces.Select(value => value.Id)));
            }
            catch (Exception error) when (error is NetworkInformationException or InvalidOperationException or OverflowException) { }
            var processes = ImmutableArray.CreateBuilder<MonitorProcessCounter>();
            var coverage = "Complete";
            var processStart = Stopwatch.GetTimestamp();
            var all = Process.GetProcesses();
            try
            {
                foreach (var process in all.Take(4096))
                {
                    token.ThrowIfCancellationRequested();
                    if (Stopwatch.GetElapsedTime(processStart).TotalSeconds > 0.6) { coverage = "Partial process coverage"; break; }
                    try
                    {
                        var start = process.StartTime.ToUniversalTime().Ticks;
                        var name = process.ProcessName;
                        var seconds = process.TotalProcessorTime.TotalSeconds;
                        var resident = process.WorkingSet64;
                        if (resident < 0) { coverage = "Partial process coverage"; continue; }
                        processes.Add(new(process.Id + ":" + start, process.Id, name.Length > 256 ? name[..256] : name, seconds, (ulong)resident));
                    }
                    catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException)
                    { coverage = "Partial process coverage"; }
                }
                if (all.Length > 4096) coverage = "Partial process coverage";
            }
            finally { foreach (var process in all) process.Dispose(); }
            if (!collected && query != 0) { PdhCloseQuery(query); query = 0; }
            var issues = ImmutableDictionary.CreateBuilder<string, string>();
            if (gpuValues.Length == 0) issues["gpu"] = "GPU counters are unavailable on this device.";
            var battery = powerAvailable && (power.BatteryFlag & 128) == 0 && power.BatteryLifePercent <= 100 ? (double?)power.BatteryLifePercent : null;
            if (battery is null) issues["battery"] = "No readable internal battery was found.";
            return new()
            {
                Uptime = uptime, Cpu = cpu, CorePercent = cores, LogicalCpuCount = logicalCpuCount,
                Hardware = hardware.Trim(), OperatingSystem = RuntimeInformation.OSDescription,
                VolumeTotal = volumeTotal, VolumeAvailable = volumeAvailable,
                MemoryTotal = memoryAvailable ? memory.TotalPhysical : null,
                MemoryUsed = memoryAvailable ? memory.TotalPhysical - Math.Min(memory.TotalPhysical, memory.AvailablePhysical) : null,
                Disk = disk, Network = network, GpuPercent = gpuValues.Length > 0 ? Math.Clamp(gpuValues.Max(), 0, 100) : null,
                BatteryPercent = battery, PowerSource = !powerAvailable ? "Unavailable" : (power.BatteryFlag & 8) != 0 ? "Charging" :
                    power.AcLineStatus == 1 ? "AC Power" : power.AcLineStatus == 0 ? "Battery Power" : "Unavailable",
                Processes = processes.ToImmutable(), ProcessCoverage = coverage, Issues = issues.ToImmutable()
            };
        }
    }
    private void InitializeQuery()
    {
        if (query != 0 || PdhOpenQueryW(null, 0, out query) != 0) return;
        _ = PdhAddEnglishCounterW(query, @"\Processor Information(*)\% Processor Time", 0, out cpuCounter);
        _ = PdhAddEnglishCounterW(query, @"\GPU Engine(*)\Utilization Percentage", 0, out gpuCounter);
        _ = PdhAddEnglishCounterW(query, @"\PhysicalDisk(*)\Disk Read Bytes/sec", 0, out diskReadCounter);
        _ = PdhAddEnglishCounterW(query, @"\PhysicalDisk(*)\Disk Write Bytes/sec", 0, out diskWriteCounter);
    }
    private static Dictionary<string, double> Formatted(nint counter)
    {
        var result = new Dictionary<string, double>(StringComparer.Ordinal);
        if (counter == 0) return result;
        uint bytes = 0, count = 0;
        if (PdhGetFormattedCounterArrayW(counter, 0x200, ref bytes, ref count, 0) != 0x800007D2 || bytes is 0 or > 4_194_304) return result;
        var allocated = bytes; var buffer = Marshal.AllocHGlobal((int)bytes);
        try
        {
            if (PdhGetFormattedCounterArrayW(counter, 0x200, ref bytes, ref count, buffer) != 0 || bytes > allocated || count > bytes / Marshal.SizeOf<FormattedItem>()) return result;
            for (var index = 0; index < count; index++)
            {
                var item = Marshal.PtrToStructure<FormattedItem>(buffer + index * Marshal.SizeOf<FormattedItem>());
                var name = Name(item.Name, buffer, bytes);
                if (name is not null && item.Value.Status <= 1 && double.IsFinite(item.Value.Value) && item.Value.Value >= 0) result[name] = item.Value.Value;
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return result;
    }
    private static Dictionary<string, ulong> Raw(nint counter)
    {
        var result = new Dictionary<string, ulong>(StringComparer.Ordinal);
        if (counter == 0) return result;
        uint bytes = 0, count = 0;
        if (PdhGetRawCounterArrayW(counter, ref bytes, ref count, 0) != 0x800007D2 || bytes is 0 or > 4_194_304) return result;
        var allocated = bytes; var buffer = Marshal.AllocHGlobal((int)bytes);
        try
        {
            if (PdhGetRawCounterArrayW(counter, ref bytes, ref count, buffer) != 0 || bytes > allocated || count > bytes / Marshal.SizeOf<RawItem>()) return result;
            for (var index = 0; index < count; index++)
            {
                var item = Marshal.PtrToStructure<RawItem>(buffer + index * Marshal.SizeOf<RawItem>());
                var name = Name(item.Name, buffer, bytes);
                if (name is not null && name != "_Total" && item.Value.Status <= 1 && item.Value.First >= 0) result[name] = (ulong)item.Value.First;
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return result;
    }
    private static string? Name(nint pointer, nint buffer, uint bytes)
    {
        var offset = pointer.ToInt64() - buffer.ToInt64();
        if (offset < 0 || offset >= bytes || offset % 2 != 0) return null;
        var text = Marshal.PtrToStringUni(pointer, (int)Math.Min((bytes - offset) / 2, 1024));
        var end = text?.IndexOf('\0') ?? -1;
        return end < 0 ? null : text![..end];
    }
    public void Dispose()
    {
        lock (gate) { if (disposed) return; disposed = true; if (query != 0) PdhCloseQuery(query); query = 0; }
        GC.SuppressFinalize(this);
    }
    [StructLayout(LayoutKind.Sequential)] private struct FileTime { public uint Low, High; public readonly ulong Value => ((ulong)High << 32) | Low; }
    [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus { public uint Length, Load; public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtended; }
    [StructLayout(LayoutKind.Sequential)] private struct PowerStatus { public byte AcLineStatus, BatteryFlag, BatteryLifePercent, SystemStatus; public uint LifeTime, FullLifeTime; }
    [StructLayout(LayoutKind.Sequential)] private struct FormattedValue { public uint Status; public double Value; }
    [StructLayout(LayoutKind.Sequential)] private struct FormattedItem { public nint Name; public FormattedValue Value; }
    [StructLayout(LayoutKind.Sequential)] private struct RawValue { public uint Status; public FileTime Timestamp; public long First, Second; public uint MultiCount; }
    [StructLayout(LayoutKind.Sequential)] private struct RawItem { public nint Name; public RawValue Value; }
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll")] private static extern ushort GetActiveProcessorGroupCount();
    [DllImport("kernel32.dll")] private static extern uint GetActiveProcessorCount(ushort group);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetSystemPowerStatus(out PowerStatus status);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhOpenQueryW(string? source, nuint user, out nint query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhAddEnglishCounterW(nint query, string path, nuint user, out nint counter);
    [DllImport("pdh.dll")] private static extern uint PdhCollectQueryData(nint query);
    [DllImport("pdh.dll")] private static extern uint PdhCloseQuery(nint query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhGetFormattedCounterArrayW(nint counter, uint format, ref uint bytes, ref uint count, nint buffer);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhGetRawCounterArrayW(nint counter, ref uint bytes, ref uint count, nint buffer);
}
