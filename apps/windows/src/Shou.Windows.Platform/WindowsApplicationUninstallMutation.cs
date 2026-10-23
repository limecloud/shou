using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Shou.Windows.Core;
using Windows.Foundation;
using Windows.Management.Deployment;

namespace Shou.Windows.Platform;

/// <summary>System-managed uninstall only. No registry command, shell, recursive file deletion or process termination.</summary>
public sealed class WindowsApplicationUninstallMutation : IApplicationUninstallMutation
{
    // Shared by GUI and CLI. Enable only after native installer, interruption and UI acceptance is recorded.
    public static bool PublicExecutionAvailable => false;
    private static readonly SemaphoreSlim Sessions = new(1, 1);
    public bool Supports(ApplicationInstallerKind kind) => Enum.IsDefined(kind) && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) && Environment.Is64BitProcess;

    public async Task<ApplicationUninstallResult> ApplyAsync(ApplicationUninstallReview review, string ownerSid, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested) return NotStarted("cancelled_before_installer");
        if (authorizationExpiresAt.Offset != TimeSpan.Zero || authorizationExpiresAt <= DateTimeOffset.UtcNow) return NotStarted("uninstall_authorization_expired");
        if (review?.Installation.Identity is not { } identity || !Supports(identity.Kind)) return NotStarted("unsupported_platform");
        try { await Sessions.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return NotStarted("cancelled_before_installer"); }
        var invocationAttempted = false;
        try
        {
            using var actor = WindowsIdentity.GetCurrent();
            if (actor.User?.Value != ownerSid || identity.Context != MsiInstallationContext.Machine && identity.UserSid != ownerSid)
                return NotStarted("installation_user_changed");
            var current = await new ApplicationUninstallReviewer(new(new WindowsApplicationInventory()),
                new WindowsApplicationUninstallInspector(), new WindowsApplicationActivity()).InspectAsync(review.Application.Id, cancellationToken).ConfigureAwait(false);
            if (!current.CanPreparePlan || current.Digest != review.Digest) return NotStarted("application_changed");
            if (cancellationToken.IsCancellationRequested) return NotStarted("cancelled_before_installer");
            if (authorizationExpiresAt <= DateTimeOffset.UtcNow) return NotStarted("uninstall_authorization_expired");
            invocationAttempted = true;
            var result = identity.Kind == ApplicationInstallerKind.Msi
                ? await RemoveMsiAsync(identity).ConfigureAwait(false)
                : await RemoveMsixAsync(identity, cancellationToken).ConfigureAwait(false);
            return result with { Presence = await ObservePresenceAsync(review).ConfigureAwait(false) };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        { return invocationAttempted ? new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown, Reason: "native_result_unknown") : NotStarted("cancelled_before_installer"); }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or COMException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { return invocationAttempted ? new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown, Reason: "native_result_unknown") : NotStarted("installer_preflight_failed"); }
        finally { Sessions.Release(); }
    }

    internal static ProcessStartInfo MsiStartInfo(string systemDirectory, string productCode)
    {
        if (!Guid.TryParseExact(productCode, "B", out var product) || productCode != product.ToString("B").ToUpperInvariant())
            throw new ShouException("invalid_argument", "Choose an exact canonical MSI product code.");
        var directory = WindowsPath.Parse(systemDirectory);
        if (directory.IsVolumeRoot) throw new ShouException("invalid_argument", "A Windows system directory is required.");
        var start = new ProcessStartInfo(directory.Append("msiexec.exe").Value) { UseShellExecute = false, WorkingDirectory = directory.Value };
        // Basic UI retains the installer's Cancel button; passive mode would hide it. Never request reboot or application shutdown.
        foreach (var argument in new[] { "/x", productCode, "/qb", "/norestart", "REBOOT=ReallySuppress", "MSIRESTARTMANAGERCONTROL=Disable" })
            start.ArgumentList.Add(argument);
        return start;
    }

    private static async Task<ApplicationUninstallResult> RemoveMsiAsync(ApplicationInstallIdentity identity)
    {
        using var process = new Process { StartInfo = MsiStartInfo(Environment.SystemDirectory, identity.SystemId) };
        try
        {
            if (!process.Start()) return NotStarted("installer_start_failed");
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        { return new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown, Reason: "installer_start_unknown"); }
        try
        {
            // Once launched, cancellation never kills msiexec or releases the domain lease before the real outcome.
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            var code = process.ExitCode;
            return new(code is 0 or 3010 ? SystemUninstallOutcome.Succeeded : code == 1602 ? SystemUninstallOutcome.Cancelled : SystemUninstallOutcome.Failed,
                InstallationPresence.Unknown, code, code == 3010, code == 1641 ? "unexpected_installer_restart" : null);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        { return new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown, Reason: "installer_completion_unknown"); }
    }

    private static async Task<ApplicationUninstallResult> RemoveMsixAsync(ApplicationInstallIdentity identity, CancellationToken token)
    {
        IAsyncOperationWithProgress<DeploymentResult, DeploymentProgress> operation;
        try { operation = new PackageManager().RemovePackageAsync(identity.SystemId, RemovalOptions.None); }
        catch (Exception error) when (error is COMException or ArgumentException or UnauthorizedAccessException or InvalidOperationException)
        { return new(SystemUninstallOutcome.Unknown, InstallationPresence.Unknown, Reason: "installer_start_unknown"); }
        using var cancellation = token.Register(() =>
        {
            // Request cooperative deployment cancellation, then continue waiting for its terminal status.
            try { operation.Cancel(); }
            catch (Exception error) when (error is COMException or InvalidOperationException) { }
        });
        try
        {
            var result = await operation.AsTask().ConfigureAwait(false);
            var code = result.ExtendedErrorCode?.HResult ?? 0;
            return new(code == 0 ? SystemUninstallOutcome.Succeeded : SystemUninstallOutcome.Failed, InstallationPresence.Unknown, code);
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException)
        {
            return new(operation.Status == AsyncStatus.Canceled ? SystemUninstallOutcome.Cancelled :
                operation.Status == AsyncStatus.Error ? SystemUninstallOutcome.Failed : SystemUninstallOutcome.Unknown,
                InstallationPresence.Unknown, error.HResult, Reason: "package_deployment_ended");
        }
        finally { operation.Close(); }
    }

    private static async Task<InstallationPresence> ObservePresenceAsync(ApplicationUninstallReview review)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            return await NativeOperationScheduler.RunAsync(() =>
            {
                var identity = review.Installation.Identity!;
                if (identity.Kind == ApplicationInstallerKind.Msix)
                {
                    var package = new PackageManager().FindPackageForUser(string.Empty, identity.SystemId);
                    return package is null ? InstallationPresence.Absent : package.Id.FullName == identity.SystemId && package.Id.FamilyName == identity.PackageFamilyName
                        ? InstallationPresence.Present : InstallationPresence.Changed;
                }
                var state = WindowsApplicationUninstallInspector.ReadMsiProperty(identity.SystemId, identity.UserSid, identity.Context, "State", missingProductAllowed: true);
                if (state is null) return InstallationPresence.Absent;
                if (state != "5") return InstallationPresence.Changed;
                var packageCode = WindowsApplicationUninstallInspector.ReadMsiProperty(identity.SystemId, identity.UserSid, identity.Context, "PackageCode");
                return string.Equals(packageCode, identity.PackageCode, StringComparison.OrdinalIgnoreCase) ? InstallationPresence.Present : InstallationPresence.Changed;
            }, deadline.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is ShouException or COMException or IOException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException)
        { return InstallationPresence.Unknown; }
    }

    private static ApplicationUninstallResult NotStarted(string reason) => new(SystemUninstallOutcome.NotStarted, InstallationPresence.Unknown, Reason: reason);
}
