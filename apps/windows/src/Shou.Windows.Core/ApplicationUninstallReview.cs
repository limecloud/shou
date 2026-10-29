using System.Collections.Immutable;

namespace Shou.Windows.Core;

public enum ApplicationInstallerKind { Msi, Msix }
public enum MsiInstallationContext { None, UserManaged, UserUnmanaged, Machine }

/// <summary>System installation identity, independent of file ownership and arbitrary uninstall strings.</summary>
public sealed record ApplicationInstallIdentity(ApplicationInstallerKind Kind, string SystemId, MsiInstallationContext Context,
    string? UserSid, string? PackageCode = null, string? PackageFamilyName = null);
public sealed record ApplicationUninstallObservation(ApplicationInstallIdentity? Identity, string? Name, string? Version, string? Publisher,
    FileEntry? InstalledRoot, bool IsProtected, ImmutableArray<string> Issues);

public interface IApplicationUninstallInspector
{
    Task<ApplicationUninstallObservation> InspectAsync(InstalledApplication application, CancellationToken cancellationToken);
}

public sealed record ApplicationUninstallReview(InstalledApplication Application, ApplicationUninstallObservation Installation, ActivityObservation Activity,
    DateTimeOffset ObservedAt, ImmutableArray<string> BlockingReasons, ImmutableArray<string> Warnings, string Digest)
{
    public bool CanPreparePlan => BlockingReasons.IsEmpty && Installation.Identity is not null && Activity.State == ActivityState.Idle;
    public bool RequiresAdministrator => Installation.Identity is { Kind: ApplicationInstallerKind.Msi, Context: MsiInstallationContext.Machine } ||
        BlockingReasons.Contains("permission_denied") || Activity.Reason == "permission_denied";
    public bool ExecutionAvailable => false;
}

/// <summary>A read-only review never opens the record store or constitutes current execution consent.</summary>
public sealed class ApplicationUninstallReviewer(ApplicationCatalog catalog, IApplicationUninstallInspector inspector,
    IApplicationUninstallActivity activity, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<ApplicationUninstallReview> InspectAsync(string applicationId, CancellationToken cancellationToken = default)
    {
        if (!ApplicationCatalog.IsApplicationId(applicationId)) throw new ShouException("invalid_argument", "Choose an exact application identifier from the current catalog.");
        var snapshot = await catalog.ReadAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        var application = snapshot.Applications.SingleOrDefault(item => item.Id == applicationId) ?? throw new ShouException(
            snapshot.State == ScanState.Complete ? "not_found" : "application_discovery_incomplete", "The application was not found in the available registration observation.");
        var observation = await inspector.InspectAsync(application, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        ValidateObservation(application, observation);
        var reasons = ImmutableArray.CreateBuilder<string>();
        if (application.IsSystemPackage || observation.IsProtected) reasons.Add("protected_application");
        if (observation.Identity is null) reasons.AddRange(observation.Issues.IsEmpty ? ["unsupported_installer"] : observation.Issues);
        if (observation.Identity is not null && !observation.Issues.IsEmpty) reasons.AddRange(observation.Issues);
        var activityObservation = reasons.Count == 0 && observation.InstalledRoot is { } scope && !scope.Path.IsVolumeRoot
            ? await activity.InspectAsync(observation, cancellationToken).ConfigureAwait(false)
            : new ActivityObservation(ActivityState.Unknown, observation.InstalledRoot is null ? "installation_activity_scope_unavailable" : "installation_not_eligible");
        cancellationToken.ThrowIfCancellationRequested();
        if (activityObservation is null || !Enum.IsDefined(activityObservation.State) || activityObservation.Reason is not { } activityReason || !Code(activityReason))
            throw new ShouException("application_inspection_invalid", "The application activity observation is invalid.");
        if (reasons.Count == 0 && activityObservation.State != ActivityState.Idle)
            reasons.Add(activityObservation.State == ActivityState.Active ? "application_running" : "application_activity_unknown");
        var warnings = ImmutableArray.CreateBuilder<string>();
        warnings.AddRange(ImmutableArray.Create("installer_managed_data_may_be_removed", "installer_may_stop_managed_processes", "residual_files_not_included", "no_shou_restore", "activity_covers_installation_directory_only", "current_confirmation_required"));
        if (observation.Identity?.Kind == ApplicationInstallerKind.Msix) warnings.Add("windows_may_remove_unused_package_dependencies");
        if (observation.InstalledRoot is null) warnings.Add("installation_location_unavailable");
        if (snapshot.State != ScanState.Complete) warnings.Add("application_discovery_incomplete");
        var review = new ApplicationUninstallReview(application, observation, activityObservation, clock.GetUtcNow(),
            reasons.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray(), warnings.ToImmutable(), "");
        return review with { Digest = Digest(review) };
    }

    internal static string Digest(ApplicationUninstallReview review) => RecordJson.Digest(new
    {
        review.Application, review.Installation, review.Activity, review.BlockingReasons, review.Warnings
    });

    internal static void ValidateObservation(InstalledApplication application, ApplicationUninstallObservation observation)
    {
        if (application is null || !Enum.IsDefined(application.Source) || !ApplicationCatalog.IsApplicationId(application.Id) ||
            application.Id != ApplicationCatalog.ApplicationId(application.Source, application.RegistrationKey) ||
            string.IsNullOrWhiteSpace(application.RegistrationKey) || !Text(application.RegistrationKey, 2048) ||
            string.IsNullOrWhiteSpace(application.Name) || !Text(application.Name, 512) || !Text(application.Version, 256) || !Text(application.Publisher, 512) ||
            application.RegisteredEstimatedBytes < 0 || application.Issues.IsDefault || application.Issues.Length > 32 || application.Issues.Any(issue => !Code(issue)) ||
            observation is null || observation.Issues.IsDefault || observation.Issues.Length > 32 || observation.Issues.Any(issue => !Code(issue)) ||
            !Text(observation.Name, 512) || !Text(observation.Version, 256) || !Text(observation.Publisher, 512) ||
            observation.InstalledRoot is { } root && (root.Kind != EntryKind.Directory || root.Path is null || root.Identity is null || root.LogicalBytes < 0 || root.AllocatedBytes < 0)) throw Invalid();
        if (observation.Identity is not { } identity) return;
        if (!Enum.IsDefined(identity.Kind) || !Enum.IsDefined(identity.Context) || string.IsNullOrWhiteSpace(observation.Name)) throw Invalid();
        if (identity.Kind == ApplicationInstallerKind.Msix)
        {
            if (application.Source != ApplicationSource.CurrentUserMsix || identity.Context != MsiInstallationContext.None ||
                identity.SystemId != application.RegistrationKey || !Text(identity.SystemId, 2048) || !Text(identity.PackageFamilyName, 512) ||
                string.IsNullOrEmpty(identity.PackageFamilyName) || identity.PackageCode is not null || !Sid(identity.UserSid)) throw Invalid();
        }
        else if (application.Source == ApplicationSource.CurrentUserMsix || !application.UsesWindowsInstaller ||
            !Guid.TryParseExact(application.RegistrationKey, "B", out var registration) || !Guid.TryParseExact(identity.SystemId, "B", out var system) || registration != system ||
            identity.SystemId != system.ToString("B").ToUpperInvariant() || !Guid.TryParseExact(identity.PackageCode, "B", out _) || identity.PackageFamilyName is not null ||
            (identity.Context == MsiInstallationContext.Machine
                ? application.Source == ApplicationSource.CurrentUserRegistry || identity.UserSid is not null
                : identity.Context is not (MsiInstallationContext.UserManaged or MsiInstallationContext.UserUnmanaged) || !Sid(identity.UserSid))) throw Invalid();
    }

    internal static bool Sid(string? value) => value is { Length: > 0 and <= 184 } &&
        System.Text.RegularExpressions.Regex.IsMatch(value, @"^S-1-[0-9]+(?:-[0-9]+)+$", System.Text.RegularExpressions.RegexOptions.CultureInvariant | System.Text.RegularExpressions.RegexOptions.NonBacktracking);
    internal static bool Code(string? value) => value is { Length: > 0 and <= 128 } && value.All(character => char.IsAsciiLetterLower(character) || character == '_' || char.IsAsciiDigit(character));
    private static bool Text(string? value, int maximum)
    {
        if (value is null) return true;
        if (value.Length > maximum || value.Any(character => char.IsControl(character) || character is '\u202a' or '\u202b' or '\u202c' or '\u202d' or '\u202e' or '\u2066' or '\u2067' or '\u2068' or '\u2069')) return false;
        for (var index = 0; index < value.Length; index++)
            if (char.IsSurrogate(value[index]) && (!char.IsHighSurrogate(value[index]) || ++index >= value.Length || !char.IsLowSurrogate(value[index]))) return false;
        return true;
    }
    private static ShouException Invalid() => new("application_inspection_invalid", "The system installation observation is invalid or does not match this registration.");
}
