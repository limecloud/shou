using System.Runtime.InteropServices;
using System.Security.Principal;
using Shou.Windows.Core;
using Windows.Management.Deployment;

namespace Shou.Windows.Platform;

/// <summary>Reads system installation identities; no command line, installer launch or target mutation.</summary>
public sealed class WindowsApplicationUninstallInspector : IApplicationUninstallInspector
{
    public async Task<ApplicationUninstallObservation> InspectAsync(InstalledApplication application, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || IntPtr.Size != 8)
            throw new ShouException("unsupported_platform", "Application inspection requires 64-bit Windows 11.");
        if (!ApplicationCatalog.IsApplicationId(application.Id) || !Enum.IsDefined(application.Source) ||
            application.Id != ApplicationCatalog.ApplicationId(application.Source, application.RegistrationKey))
            throw new ShouException("invalid_argument", "Choose an exact application registration.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            return await NativeOperationScheduler.RunAsync(() => Read(application, deadline.Token), deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { return Unavailable("application_inspection_time_limit"); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or COMException or ArgumentException or InvalidOperationException)
        { return Unavailable(error is UnauthorizedAccessException ? "permission_denied" : "application_inspection_unavailable"); }
    }

    private static ApplicationUninstallObservation Read(InstalledApplication application, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        using var actor = WindowsIdentity.GetCurrent();
        var sid = actor.User?.Value ?? throw new ShouException("unsupported_metadata", "The current user SID is unavailable.");
        ApplicationUninstallObservation observed;
        string? location;
        if (application.Source == ApplicationSource.CurrentUserMsix)
        {
            var package = new PackageManager().FindPackageForUser(string.Empty, application.RegistrationKey);
            if (package is null || package.Id.FullName != application.RegistrationKey) return Unavailable("application_changed");
            var id = package.Id;
            var version = id.Version;
            location = package.InstalledLocation?.Path;
            var protectedPackage = package.IsFramework || package.IsResourcePackage || package.IsBundle ||
                package.SignatureKind == global::Windows.ApplicationModel.PackageSignatureKind.System;
            observed = new(new(ApplicationInstallerKind.Msix, id.FullName, MsiInstallationContext.None, sid, PackageFamilyName: id.FamilyName),
                package.DisplayName, $"{version.Major}.{version.Minor}.{version.Build}.{version.Revision}", package.PublisherDisplayName, null,
                protectedPackage, []);
        }
        else
        {
            if (!application.UsesWindowsInstaller || !Guid.TryParseExact(application.RegistrationKey, "B", out var guid))
                return Unavailable("unsupported_installer");
            var product = guid.ToString("B").ToUpperInvariant();
            var matches = new List<(MsiInstallationContext Context, string? Sid)>();
            foreach (var (context, user) in new[] { (MsiInstallationContext.UserManaged, sid), (MsiInstallationContext.UserUnmanaged, sid), (MsiInstallationContext.Machine, (string?)null) })
            {
                token.ThrowIfCancellationRequested();
                var state = ReadMsiProperty(product, user, context, "State", missingProductAllowed: true);
                if (state == "5") matches.Add((context, user));
                else if (state is not null) return Unavailable("installer_not_fully_installed");
            }
            if (matches.Count != 1) return Unavailable(matches.Count == 0 ? "application_changed" : "ambiguous_installer_context");
            var selected = matches[0];
            if ((application.Source == ApplicationSource.CurrentUserRegistry) == (selected.Context == MsiInstallationContext.Machine))
                return Unavailable("installer_registration_mismatch");
            var name = ReadMsiProperty(product, selected.Sid, selected.Context, "InstalledProductName");
            var version = ReadMsiProperty(product, selected.Sid, selected.Context, "VersionString");
            var publisher = ReadMsiProperty(product, selected.Sid, selected.Context, "Publisher");
            var packageCode = ReadMsiProperty(product, selected.Sid, selected.Context, "PackageCode");
            if (!Guid.TryParseExact(packageCode, "B", out var packageGuid)) return Unavailable("installer_identity_unavailable");
            location = ReadMsiProperty(product, selected.Sid, selected.Context, "InstallLocation");
            if (!string.Equals(name?.Trim(), application.Name, StringComparison.Ordinal) ||
                application.Version is not null && !string.Equals(version?.Trim(), application.Version, StringComparison.Ordinal) ||
                application.Publisher is not null && !string.Equals(publisher?.Trim(), application.Publisher, StringComparison.Ordinal))
                return Unavailable("installer_registration_mismatch");
            observed = new(new(ApplicationInstallerKind.Msi, product, selected.Context, selected.Sid, packageGuid.ToString("B").ToUpperInvariant()),
                name, version, publisher, null, false, []);
        }
        token.ThrowIfCancellationRequested();
        if (!string.IsNullOrWhiteSpace(location))
        {
            try
            {
                var path = WindowsPath.Parse(location);
                using var pinned = WindowsFileSystem.PinPath(path);
                var root = WindowsFileSystem.ReadEntry(path, pinned.Final);
                if (root.Kind == EntryKind.Directory)
                {
                    var currentImage = Environment.ProcessPath is { } image ? WindowsPath.Parse(image) : null;
                    var protectedRoot = path.IsVolumeRoot || path.IsWithin(WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.Windows))) ||
                        new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles,
                        Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.CommonApplicationData }
                        .Select(Environment.GetFolderPath).Where(value => !string.IsNullOrWhiteSpace(value)).Select(WindowsPath.Parse)
                        .Any(system => path.SamePath(system) || system.IsWithin(path));
                    observed = observed with { InstalledRoot = root, IsProtected = observed.IsProtected || protectedRoot || currentImage?.IsWithin(path, root.IsCaseSensitive) == true };
                }
            }
            catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or ArgumentException)
            { /* The package identity remains observable, but no directory identity was established. */ }
        }
        token.ThrowIfCancellationRequested();
        return observed;
    }

    internal static unsafe string? ReadMsiProperty(string product, string? sid, MsiInstallationContext context, string property, bool missingProductAllowed = false)
    {
        var nativeContext = context switch { MsiInstallationContext.UserManaged => 1u, MsiInstallationContext.UserUnmanaged => 2u, MsiInstallationContext.Machine => 4u,
            _ => throw new ShouException("invalid_argument", "Choose an exact Windows Installer context.") };
        uint length = 0;
        var result = ApplicationInstallerNative.ProductInfo(product, sid, nativeContext, property, null, ref length);
        if (result == 1605 && missingProductAllowed) return null; // ERROR_UNKNOWN_PRODUCT is not an installed identity.
        if (result is not (0 or 234) || length > 4096) throw new ShouException("installer_identity_unavailable", "The Windows Installer property is unavailable or exceeds its read limit.");
        var buffer = new char[length + 1];
        var capacity = (uint)buffer.Length;
        fixed (char* value = buffer) result = ApplicationInstallerNative.ProductInfo(product, sid, nativeContext, property, value, ref capacity);
        if (result != 0 || capacity >= buffer.Length) throw new ShouException("installer_identity_unavailable", "The Windows Installer property changed or could not be read.");
        return new string(buffer, 0, checked((int)capacity));
    }

    private static ApplicationUninstallObservation Unavailable(string reason) => new(null, null, null, null, null, false, [reason]);
}

internal static partial class ApplicationInstallerNative
{
    [LibraryImport("msi.dll", EntryPoint = "MsiGetProductInfoExW", StringMarshalling = StringMarshalling.Utf16)]
    internal static unsafe partial uint ProductInfo(string product, string? sid, uint context, string property, char* value, ref uint length);
}
