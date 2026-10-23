using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;
using Windows.Management.Deployment;

namespace Shou.Windows.Platform;

/// <summary>Bounded read-only registration discovery; never reads or executes uninstall commands.</summary>
public sealed class WindowsApplicationInventory : IApplicationInventory
{
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall";

    public async Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken cancellationToken)
    {
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8)
            throw new ShouException("unsupported_platform", "Application discovery requires 64-bit Windows 11.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(budget.Duration);
        try { return await NativeOperationScheduler.RunAsync(() => Read(budget, deadline.Token), deadline.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new([], Enum.GetValues<ApplicationSource>().Select(source => new ApplicationSourceCoverage(source,
                ApplicationSourceState.Unavailable, null, ["time_limit"])).ToImmutableArray());
        }
    }

    private static ApplicationInventory Read(ApplicationDiscoveryBudget budget, CancellationToken token)
    {
        var registrations = ImmutableArray.CreateBuilder<ApplicationRegistration>();
        var coverage = ImmutableArray.CreateBuilder<ApplicationSourceCoverage>();
        var remaining = budget.MaxEntries;
        foreach (var source in Enum.GetValues<ApplicationSource>())
        {
            if (remaining == 0 || token.IsCancellationRequested)
            {
                coverage.Add(new(source, ApplicationSourceState.NotRead, 0, [remaining == 0 ? "entry_limit" : "time_limit"]));
                continue;
            }
            var inspected = 0;
            var issues = new HashSet<string>(StringComparer.Ordinal);
            var state = ApplicationSourceState.Complete;
            try
            {
                if (source == ApplicationSource.CurrentUserMsix) ReadPackages();
                else
                {
                    var hive = source == ApplicationSource.CurrentUserRegistry ? RegistryHive.CurrentUser : RegistryHive.LocalMachine;
                    var view = source == ApplicationSource.MachineRegistry32 ? RegistryView.Registry32 : RegistryView.Registry64;
                    using var root = RegistryKey.OpenBaseKey(hive, view);
                    using var key = root.OpenSubKey(UninstallKey, writable: false);
                    if (key is not null) ReadRegistry(key, source, registrations, Next, token, issues);
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { state = ApplicationSourceState.Partial; issues.Add("time_limit"); }
            catch (Exception error) when (IsReadFailure(error))
            {
                state = inspected == 0 ? ApplicationSourceState.Unavailable : ApplicationSourceState.Partial;
                issues.Add(ErrorCode(error));
            }
            if (issues.Count > 0 && state == ApplicationSourceState.Complete) state = ApplicationSourceState.Partial;
            coverage.Add(new(source, state, inspected, issues.Order(StringComparer.Ordinal).ToImmutableArray()));

            bool Next()
            {
                token.ThrowIfCancellationRequested();
                if (remaining == 0) { issues.Add("entry_limit"); return false; }
                remaining--;
                inspected++;
                return true;
            }

            void ReadPackages()
            {
                var manager = new PackageManager();
                using var packages = manager.FindPackagesForUser(string.Empty).GetEnumerator();
                while (true)
                {
                    token.ThrowIfCancellationRequested();
                    if (!packages.MoveNext()) break;
                    if (!Next()) break;
                    try
                    {
                        var package = packages.Current;
                        if (package.IsFramework || package.IsResourcePackage || package.IsBundle) continue;
                        var id = package.Id;
                        var version = id.Version;
                        string? location = null;
                        try { location = package.InstalledLocation?.Path; }
                        catch (Exception error) when (IsReadFailure(error)) { issues.Add("package_location_unavailable"); }
                        registrations.Add(new(source, id.FullName, package.DisplayName,
                            $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}", package.PublisherDisplayName,
                            location, IsSystemPackage: package.SignatureKind == global::Windows.ApplicationModel.PackageSignatureKind.System));
                    }
                    catch (Exception error) when (IsReadFailure(error)) { issues.Add(ErrorCode(error)); }
                }
            }
        }
        return new(registrations.ToImmutable(), coverage.ToImmutable());
    }

    // Kept internal so native tests can enumerate a generated HKCU fixture without changing real installations.
    internal static unsafe void ReadRegistry(RegistryKey parent, ApplicationSource source,
        ImmutableArray<ApplicationRegistration>.Builder registrations, Func<bool> next, CancellationToken token, HashSet<string> issues)
    {
        var name = stackalloc char[256];
        for (uint index = 0; ; index++)
        {
            token.ThrowIfCancellationRequested();
            uint length = 256;
            var error = ApplicationRegistryNative.EnumKey(parent.Handle, index, name, ref length, 0, 0, 0, 0);
            if (error == 259) break; // ERROR_NO_MORE_ITEMS
            if (!next()) break;
            if (error != 0) { issues.Add(error == 5 ? "permission_denied" : "registry_enumeration_failed"); break; }
            var subkey = new string(name, 0, checked((int)length));
            try
            {
                using var key = parent.OpenSubKey(subkey, writable: false);
                if (key is null) { issues.Add("registration_changed"); continue; }
                var displayName = ReadString(key, "DisplayName");
                if (string.IsNullOrWhiteSpace(displayName)) continue;
                var hidden = ReadDword(key, "SystemComponent") is > 0;
                var update = !string.IsNullOrEmpty(ReadString(key, "ParentKeyName")) || ReadString(key, "ReleaseType") is "Update" or "Hotfix" or "Security Update";
                if (hidden || update) continue;
                var size = ReadDword(key, "EstimatedSize");
                registrations.Add(new(source, subkey, displayName, ReadString(key, "DisplayVersion"), ReadString(key, "Publisher"),
                    ReadString(key, "InstallLocation"), size is { } kib ? (long)kib * 1024 : null,
                    UsesWindowsInstaller: ReadDword(key, "WindowsInstaller") == 1));
            }
            catch (Exception failure) when (IsReadFailure(failure)) { issues.Add(ErrorCode(failure)); }
        }
    }

    private static string? ReadString(RegistryKey key, string name)
    {
        var bytes = ReadValue(key, name, out var kind);
        if (bytes is null) return null;
        if (kind is not (1 or 2) || bytes.Length % 2 != 0) throw InvalidMetadata(); // REG_SZ / unexpanded REG_EXPAND_SZ
        var text = new UnicodeEncoding(bigEndian: false, byteOrderMark: false, throwOnInvalidBytes: true).GetString(bytes).TrimEnd('\0');
        return text.Length == 0 ? null : text;
    }

    private static uint? ReadDword(RegistryKey key, string name)
    {
        var bytes = ReadValue(key, name, out var kind);
        if (bytes is null) return null;
        if (kind != 4 || bytes.Length != 4) throw InvalidMetadata();
        return System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(bytes);
    }

    private static unsafe byte[]? ReadValue(RegistryKey key, string name, out uint kind)
    {
        uint length = 0;
        var result = ApplicationRegistryNative.QueryValue(key.Handle, name, 0, out kind, null, ref length);
        if (result == 2) return null;
        if (result == 5) throw new UnauthorizedAccessException();
        if (result != 0 || length > 8192) throw InvalidMetadata();
        var buffer = new byte[length];
        fixed (byte* data = buffer)
        {
            result = ApplicationRegistryNative.QueryValue(key.Handle, name, 0, out kind, data, ref length);
        }
        if (result == 5) throw new UnauthorizedAccessException();
        if (result != 0 || length > buffer.Length) throw InvalidMetadata();
        return buffer[..checked((int)length)];
    }

    private static ShouException InvalidMetadata() => new("invalid_registration_metadata", "An application registration value is invalid or exceeds its read limit.");
    private static bool IsReadFailure(Exception error) => error is UnauthorizedAccessException or SecurityException or IOException or COMException or ArgumentException or ShouException or InvalidOperationException;
    private static string ErrorCode(Exception error) => error is UnauthorizedAccessException or SecurityException ? "permission_denied" :
        error is ShouException known ? known.Code : "registration_read_failed";
}

internal static partial class ApplicationRegistryNative
{
    [LibraryImport("advapi32.dll", EntryPoint = "RegEnumKeyExW")]
    internal static unsafe partial int EnumKey(SafeRegistryHandle key, uint index, char* name, ref uint length,
        nint reserved, nint keyClass, nint classLength, nint lastWriteTime);

    [LibraryImport("advapi32.dll", EntryPoint = "RegQueryValueExW", StringMarshalling = StringMarshalling.Utf16)]
    internal static unsafe partial int QueryValue(SafeRegistryHandle key, string name, nint reserved, out uint kind,
        byte* data, ref uint length);
}
