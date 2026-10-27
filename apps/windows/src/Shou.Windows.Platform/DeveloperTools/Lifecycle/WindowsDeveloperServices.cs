using System.Collections.Immutable;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Exact SCM services whose executable belongs to a verified installed package.</summary>
public sealed class WindowsDeveloperServices : IDeveloperServices
{
    public static bool PublicExecutionAvailable => false;
    private readonly IDeveloperTools packages;
    private readonly string? generatedRoot;
    private readonly string? generatedName;
    public WindowsDeveloperServices() { packages = new WindowsDeveloperTools(); }
    internal WindowsDeveloperServices(IDeveloperTools packages, string generatedRoot, string generatedName)
    {
        if (!generatedName.StartsWith("ShouFixture_", StringComparison.Ordinal) || !System.IO.Path.GetFileName(generatedRoot).StartsWith("shou-generated-service-", StringComparison.Ordinal)) throw Unavailable();
        this.packages = packages; this.generatedRoot = WindowsPath.Parse(generatedRoot).Value; this.generatedName = generatedName;
    }
    public Task<DeveloperServiceSnapshot> ScanAsync(DeveloperToolCatalog catalog, DeveloperToolInventory inventory, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        if (!OperatingSystem.IsWindows()) throw Unavailable();
        var services = ImmutableArray.CreateBuilder<DeveloperService>(); var issues = new HashSet<string>(StringComparer.Ordinal);
        using var scm = Connect(0x0001 | 0x0004);
        foreach (var name in Names(scm))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (generatedName is not null && name != generatedName) continue;
            try
            {
                using var service = Open(scm, name, 0x0001 | 0x0004);
                var config = Configuration(service);
                var path = Image(config.BinaryPath);
                var matches = inventory.Installations.Where(r => catalog.Tools.Any(t => t.Id == r.ToolId) && r.Source == "WinGet" && !r.Path.StartsWith("winget:", StringComparison.Ordinal) &&
                    path.IsWithin(WindowsPath.Parse(r.Path), includeRoot: false)).ToArray();
                if (matches.Length != 1) continue;
                var row = matches[0];
                var reference = catalog.Tools.Single(t => t.Id == row.ToolId).Packages.SingleOrDefault(p => p.Provider == "winget");
                if (reference is null) continue;
                var package = await packages.InspectAsync(reference, cancellationToken).ConfigureAwait(false);
                if (!package.Installed || package.InstalledVersion != row.Version || package.Issue is not null || package.InstallationPath is null ||
                    !WindowsPath.Parse(package.InstallationPath).SamePath(WindowsPath.Parse(row.Path))) continue;
                services.Add(Read(service, name, row.ToolId, row.Path, package, config));
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (error is not OutOfMemoryException) { issues.Add("Some service sources could not be verified."); }
        }
        return new DeveloperServiceSnapshot(services.ToImmutable(), issues.ToImmutableArray());
    }, cancellationToken);

    public async Task<DeveloperService> InspectAsync(DeveloperService expected, CancellationToken cancellationToken)
    {
        Require(expected);
        var package = await PackageAsync(expected, cancellationToken).ConfigureAwait(false);
        return await Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var scm = Connect(0x0001); using var service = Open(scm, expected.Name, 0x0001 | 0x0004);
            return Read(service, expected.Name, expected.ToolId, expected.InstallationPath, package, Configuration(service));
        }, cancellationToken).ConfigureAwait(false);
    }
    public async Task SetRunningAsync(bool running, DeveloperService expected, DateTimeOffset expiresAt, CancellationToken cancellationToken)
    {
        if (generatedRoot is null && !PublicExecutionAvailable) throw Unavailable();
        Require(expected);
        var package = await PackageAsync(expected, cancellationToken).ConfigureAwait(false);
        await Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var scm = Connect(0x0001);
            using var service = Open(scm, expected.Name, 0x0001 | 0x0004 | (running ? 0x0010u : 0x0020u));
            var config = Configuration(service);
            using var pinned = WindowsFileSystem.PinPath(Image(config.BinaryPath));
            if (!expected.Controllable || Read(service, expected.Name, expected.ToolId, expected.InstallationPath, package, config) != expected || DateTimeOffset.UtcNow >= expiresAt) throw Unavailable();
            cancellationToken.ThrowIfCancellationRequested();
            var accepted = running ? StartService(service, 0, 0) : ControlService(service, 1, out _);
            if (!accepted) throw Error();
            // SCM owns the in-flight transition. Do not turn cancellation into an
            // arbitrary process kill or a change to service startup configuration.
            var timer = Stopwatch.StartNew();
            while (timer.Elapsed < TimeSpan.FromSeconds(30))
            {
                var state = Status(service).CurrentState;
                if (state == (running ? 4u : 1u)) return;
                if (state is not (2 or 3 or 4 or 1)) throw Unavailable();
                Thread.Sleep(100);
            }
            throw Unavailable();
        }, cancellationToken).ConfigureAwait(false);
    }
    private async Task<DeveloperToolInspection> PackageAsync(DeveloperService expected, CancellationToken token)
    {
        var tool = WindowsDeveloperTools.LoadCatalog().Tools.Single(t => t.Id == expected.ToolId);
        var reference = tool.Packages.Single(p => p.Provider == "winget");
        var package = await packages.InspectAsync(reference, token).ConfigureAwait(false);
        if (!package.Installed || package.InstalledVersion != expected.Version || package.Issue is not null || package.InstallationPath is null ||
            !WindowsPath.Parse(package.InstallationPath).SamePath(WindowsPath.Parse(expected.InstallationPath))) throw Unavailable();
        return package;
    }
    private void Require(DeveloperService expected)
    {
        if (!OperatingSystem.IsWindows() || expected.Source != "WinGet" || expected.Name.Length is < 1 or > 256 || expected.Name.Any(c => char.IsControl(c) || c is '/' or '\\')) throw Unavailable();
        if (generatedRoot is not null && (expected.Name != generatedName || !WindowsPath.Parse(expected.InstallationPath).SamePath(WindowsPath.Parse(generatedRoot)))) throw Unavailable();
    }
    private DeveloperService Read(ServiceHandle service, string name, string toolId, string root, DeveloperToolInspection package, ServiceConfiguration config)
    {
        var image = Image(config.BinaryPath); var installation = WindowsPath.Parse(root);
        if (!image.IsWithin(installation, includeRoot: false) || (config.Type & 0x30) == 0 || config.StartType is not (2 or 3 or 4)) throw Unavailable();
        using var pinned = WindowsFileSystem.PinPath(image);
        var entry = WindowsFileSystem.ReadEntry(image, pinned.Final);
        if (entry.Kind != EntryKind.File || entry.LinkCount != 1) throw Unavailable();
        var status = Status(service);
        var state = status.CurrentState switch { 1 => "stopped", 4 => "running", 2 => "starting", 3 => "stopping", _ => "unknown" };
        var desiredAccess = 0x0001u | 0x0004u | (state == "running" ? 0x0020u : 0x0010u);
        using var scm = Connect(0x0001); using var capability = OpenService(scm, name, desiredAccess);
        var issue = capability.IsInvalid || config.StartType == 4 || state is not ("running" or "stopped") ? "developer_service_unavailable" : null;
        if (issue is null && generatedRoot is null && !PublicExecutionAvailable) issue = "developer_service_native_acceptance_pending";
        var definition = Hash(JsonSerializer.SerializeToUtf8Bytes(new { config, entry, package.SourceIdentity, package.InstallationIdentity, package.InstalledVersion }));
        return new(Hash(Encoding.UTF8.GetBytes("scm:" + name)), toolId, "WinGet", name, package.InstalledVersion!, installation.Value,
            image.Value, state, config.StartType == 2, Hash(JsonSerializer.SerializeToUtf8Bytes(new { definition, status.CurrentState, status.ProcessId })), definition, issue, ProcessId: status.ProcessId == 0 ? null : status.ProcessId);
    }
    private static WindowsPath Image(string command)
    {
        if (command.Length is < 1 or > 32760 || command.Any(char.IsControl)) throw Unavailable();
        string path;
        if (command[0] == '"') { var end = command.IndexOf('"', 1); if (end < 2) throw Unavailable(); path = command[1..end]; }
        else { var end = command.IndexOf(' '); path = end < 0 ? command : command[..end]; }
        if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || path.Contains('%')) throw Unavailable();
        return WindowsPath.Parse(path);
    }
    private static ServiceHandle Connect(uint access)
    { var handle = OpenSCManager(null, null, access); if (handle.IsInvalid) { handle.Dispose(); throw Error(); } return handle; }
    private static ServiceHandle Open(ServiceHandle scm, string name, uint access)
    { var handle = OpenService(scm, name, access); if (handle.IsInvalid) { handle.Dispose(); throw Error(); } return handle; }
    private sealed record ServiceConfiguration(uint Type, uint StartType, string BinaryPath, string Account, string Dependencies);
    private static ServiceConfiguration Configuration(ServiceHandle service)
    {
        _ = QueryServiceConfig(service, 0, 0, out var needed);
        if (needed is < 1 or > 65536) throw Unavailable();
        var buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!QueryServiceConfig(service, buffer, needed, out _)) throw Error();
            var value = Marshal.PtrToStructure<QueryConfiguration>(buffer);
            return new(value.ServiceType, value.StartType, ReadString(buffer, needed, value.BinaryPathName), ReadString(buffer, needed, value.ServiceStartName), ReadString(buffer, needed, value.Dependencies, multi: true));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static ServiceStatus Status(ServiceHandle service)
    { if (!QueryServiceStatusEx(service, 0, out var status, (uint)Marshal.SizeOf<ServiceStatus>(), out _)) throw Error(); return status; }
    private static string[] Names(ServiceHandle scm)
    {
        uint resume = 0;
        _ = EnumServicesStatusEx(scm, 0, 0x30, 3, 0, 0, out var needed, out _, ref resume, null);
        if (needed is < 1 or > 2 * 1024 * 1024) throw Unavailable();
        var buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            resume = 0;
            if (!EnumServicesStatusEx(scm, 0, 0x30, 3, buffer, needed, out _, out var returned, ref resume, null) || returned > 512) throw Unavailable();
            var size = Marshal.SizeOf<EnumService>(); var names = new List<string>();
            if ((ulong)returned * (ulong)size > needed) throw Unavailable();
            for (var index = 0; index < returned; index++)
            { var item = Marshal.PtrToStructure<EnumService>(buffer + index * size); var name = ReadString(buffer, needed, item.Name); if (name is { Length: > 0 and <= 256 }) names.Add(name); }
            return names.ToArray();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    private static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
    private static string ReadString(nint buffer, uint length, nint pointer, bool multi = false)
    {
        if (pointer == 0) return "";
        var offset = (long)pointer - (long)buffer;
        if (offset < 0 || offset >= length || offset % 2 != 0) throw Unavailable();
        var characters = new StringBuilder();
        for (long index = offset; index + 1 < length; index += 2)
        {
            var character = (char)Marshal.ReadInt16(buffer, (int)index);
            if (character == '\0' && (!multi || index + 3 < length && Marshal.ReadInt16(buffer, (int)index + 2) == 0)) return characters.ToString();
            characters.Append(character);
        }
        throw Unavailable();
    }
    private static ShouException Error() => new("developer_service_unavailable", "The exact Windows service could not be accessed.");
    private static ShouException Unavailable() => new("developer_service_unavailable", "The exact installed service source could not be verified.");
    [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint, ProcessId, ServiceFlags; }
    [StructLayout(LayoutKind.Sequential)] private struct ControlStatus { public uint ServiceType, CurrentState, ControlsAccepted, Win32ExitCode, ServiceSpecificExitCode, CheckPoint, WaitHint; }
    [StructLayout(LayoutKind.Sequential)] private struct QueryConfiguration { public uint ServiceType, StartType, ErrorControl; public nint BinaryPathName, LoadOrderGroup; public uint TagId; public nint Dependencies, ServiceStartName, DisplayName; }
    [StructLayout(LayoutKind.Sequential)] private struct EnumService { public nint Name, DisplayName; public ServiceStatus Status; }
    private sealed class ServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
    { public ServiceHandle() : base(true) { } protected override bool ReleaseHandle() => CloseServiceHandle(handle); }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "OpenSCManagerW")] private static extern ServiceHandle OpenSCManager(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "OpenServiceW")] private static extern ServiceHandle OpenService(ServiceHandle scm, string name, uint access);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseServiceHandle(nint handle);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "QueryServiceConfigW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceConfig(ServiceHandle service, nint buffer, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceStatusEx(ServiceHandle service, int level, out ServiceStatus status, uint size, out uint needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "EnumServicesStatusExW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumServicesStatusEx(ServiceHandle scm, int level, uint type, uint state, nint services, uint size, out uint needed, out uint returned, ref uint resume, string? group);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "StartServiceW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool StartService(ServiceHandle service, uint count, nint arguments);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ControlService(ServiceHandle service, uint control, out ControlStatus status);
}
