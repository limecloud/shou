using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Management.Deployment;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsManagedPackageUpdates : IManagedPackageUpdates
{
    public static bool PublicExecutionAvailable => OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000);

    public async Task<ManagedPackageSnapshot> ReadAsync(CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
            return Unavailable("package_manager_unavailable");
        try
        {
            return await Task.Run(async () =>
            {
                using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                budget.CancelAfter(TimeSpan.FromSeconds(45));
                var (_, catalog) = await ConnectAsync(budget.Token).ConfigureAwait(false);
                var found = await catalog.FindPackagesAsync(new FindPackagesOptions { ResultLimit = 513 }).AsTask(budget.Token).ConfigureAwait(false);
                if (found.Status != FindPackagesResultStatus.Ok) return Unavailable("package_catalog_unavailable");
                var rows = ImmutableArray.CreateBuilder<ManagedPackageUpdate>();
                var complete = !found.WasLimitExceeded && found.Matches.Count <= 512;
                for (var index = 0; index < Math.Min(found.Matches.Count, 512); index++)
                {
                    budget.Token.ThrowIfCancellationRequested();
                    var row = Observe(found.Matches[index].CatalogPackage);
                    if (row is not null) rows.Add(row);
                }
                // Multiple installed identities or correlations for the same package cannot authorize an update.
                var duplicates = rows.GroupBy(p => p.Id, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
                if (duplicates.Count > 0) complete = false;
                return new ManagedPackageSnapshot(DateTimeOffset.UtcNow, rows.Where(p => !duplicates.Contains(p.Id)).ToImmutableArray(), complete,
                    complete ? null : "package_inventory_incomplete");
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is COMException or TypeLoadException or DllNotFoundException or EntryPointNotFoundException or ShouException or OperationCanceledException)
        { return Unavailable(error is ShouException known ? known.Code : "package_manager_unavailable"); }
    }

    public Task<ManagedPackageMutationResult> UpgradeAsync(ManagedPackageUpdate expected, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
    {
        if (!PublicExecutionAvailable)
            throw new ShouException("unsupported_capability", "Application upgrades require Windows 11 and the system package manager.");
        return UpgradeCoreAsync(expected, authorizationExpiresAt, cancellationToken);
    }

    private static async Task<ManagedPackageMutationResult> UpgradeCoreAsync(ManagedPackageUpdate expected, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken)
    {
        return await Task.Run<ManagedPackageMutationResult>(async () =>
        {
            using var preparation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            preparation.CancelAfter(TimeSpan.FromSeconds(45));
            var (manager, catalog) = await ConnectAsync(preparation.Token).ConfigureAwait(false);
            var search = new FindPackagesOptions { ResultLimit = 2 };
            search.Filters.Add(new PackageMatchFilter { Field = PackageMatchField.Id, Option = PackageFieldMatchOption.Equals, Value = expected.Id });
            var found = await catalog.FindPackagesAsync(search).AsTask(preparation.Token).ConfigureAwait(false);
            if (found.Status != FindPackagesResultStatus.Ok || found.WasLimitExceeded || found.Matches.Count != 1)
                return new(false, false, false, "package_update_changed");
            var package = found.Matches[0].CatalogPackage;
            if (Observe(package) is not { CanUpgrade: true } current || current != expected)
                return new(false, false, false, "package_update_changed");
            var target = TargetId(package, expected.AvailableVersion!, expected.TargetChannel);
            if (target is null) return new(false, false, false, "package_update_changed");
            cancellationToken.ThrowIfCancellationRequested();
            if (DateTimeOffset.UtcNow >= authorizationExpiresAt)
                return new(false, false, false, "package_update_plan_stale");
            var operation = manager.UpgradePackageAsync(package, Options(expected.Scope, target));
            // Stop at the package boundary. Do not cancel the COM operation after dispatch:
            // cancellation cannot roll back an installer and must not abandon its real result.
            try
            {
                var result = await operation.AsTask().ConfigureAwait(false);
                return new(result.Status == InstallResultStatus.Ok, true, result.RebootRequired,
                    result.Status == InstallResultStatus.Ok ? null : "package_installer_failed");
            }
            catch (Exception error) when (error is COMException or OperationCanceledException)
            { return new(false, true, false, "package_update_outcome_unknown"); }
        }, cancellationToken).ConfigureAwait(false);
    }

    internal static async Task<(PackageManager Manager, PackageCatalog Catalog)> ConnectAsync(CancellationToken token, CompositeSearchBehavior behavior = CompositeSearchBehavior.LocalCatalogs)
    {
        var manager = new PackageManager();
        var source = manager.GetPredefinedPackageCatalog(PredefinedPackageCatalog.OpenWindowsCatalog);
        var info = source.Info;
        if (!IsOfficialSource(info.Id, info.Origin == PackageCatalogOrigin.Predefined, info.Type, info.Argument))
            throw new ShouException("package_source_unverified", "Only the predefined official WinGet catalog is supported.");
        source.AcceptSourceAgreements = false;
        source.AuthenticationArguments = new AuthenticationArguments { AuthenticationMode = AuthenticationMode.Silent };
        var options = new CreateCompositePackageCatalogOptions { CompositeSearchBehavior = behavior };
        options.Catalogs.Add(source);
        var composite = manager.CreateCompositePackageCatalog(options);
        // WinGet only permits agreement settings on each underlying source, not a composite.
        var connection = await composite.ConnectAsync().AsTask(token).ConfigureAwait(false);
        if (connection.Status != ConnectResultStatus.Ok)
            throw new ShouException(connection.Status == ConnectResultStatus.SourceAgreementsNotAccepted ? "package_source_agreement_required" : "package_catalog_unavailable",
                "Open the official package manager to review required source agreements or repair the catalog.");
        return (manager, connection.PackageCatalog);
    }

    internal static bool IsOfficialSource(string id, bool predefined, string type, string argument) =>
        id == ManagedPackageUpdateService.OfficialCatalogId && predefined && type == "Microsoft.PreIndexed.Package" &&
        argument is "https://winget.azureedge.net/cache" or "https://cdn.winget.microsoft.com/cache";

    internal static ManagedPackageUpdate? Observe(CatalogPackage package)
    {
        var installed = package.InstalledVersion;
        var target = package.DefaultInstallVersion;
        if (installed is null || target is null || target.PackageCatalog.Info.Id != ManagedPackageUpdateService.OfficialCatalogId) return null;
        var scope = installed.GetMetadata(PackageVersionMetadataField.InstalledScope).ToLowerInvariant() switch
        { "user" => ManagedPackageScope.User, "machine" or "system" => ManagedPackageScope.System, _ => ManagedPackageScope.Unknown };
        var identities = new List<string>();
        for (var i = 0; i < installed.ProductCodes.Count; i++) identities.Add("product:" + installed.ProductCodes[i]);
        for (var i = 0; i < installed.PackageFamilyNames.Count; i++) identities.Add("family:" + installed.PackageFamilyNames[i]);
        var reason = scope == ManagedPackageScope.Unknown || identities.Count == 0 ? "package_identity_unverified" :
            installed.Version.Length == 0 || installed.Version.Equals("unknown", StringComparison.OrdinalIgnoreCase) ? "package_version_unverified" :
            target.Channel != installed.Channel ? "package_channel_unverified" :
            !package.IsUpdateAvailable ? "package_no_update" :
            target.CompareToVersion(installed.Version) != CompareResult.Greater ? "package_version_unverified" :
            target.GetCatalogPackageMetadata().Agreements.Count != 0 ? "package_agreement_required" :
            TargetId(package, target.Version, target.Channel) is not { } targetId || !target.HasApplicableInstaller(Options(scope, targetId)) ? "package_installer_unavailable" : null;
        identities.Sort(StringComparer.Ordinal);
        var identityFields = new[] { package.Id, scope.ToString(), installed.GetMetadata(PackageVersionMetadataField.InstalledLocation),
            installed.GetMetadata(PackageVersionMetadataField.PublisherDisplayName), installed.GetMetadata(PackageVersionMetadataField.InstallerType) }.Concat(identities);
        var identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\0', identityFields))));
        return new(package.Id, package.Name, installed.Version, target.Version, identity, scope,
            ManagedPackageUpdateService.OfficialCatalogId, target.Channel, reason is null, reason);
    }

    internal static PackageVersionId? TargetId(CatalogPackage package, string version, string channel)
    {
        PackageVersionId? result = null;
        for (var index = 0; index < package.AvailableVersions.Count; index++)
        {
            var key = package.AvailableVersions[index];
            if (key.PackageCatalogId != ManagedPackageUpdateService.OfficialCatalogId || key.Version != version || key.Channel != channel) continue;
            if (result is not null) return null;
            result = key;
        }
        return result;
    }

    internal static InstallOptions Options(ManagedPackageScope scope, PackageVersionId target) => new()
    {
        PackageVersionId = target,
        PackageInstallScope = scope == ManagedPackageScope.User ? PackageInstallScope.User : PackageInstallScope.System,
        PackageInstallMode = PackageInstallMode.Silent,
        AllowHashMismatch = false, Force = false, AllowUpgradeToUnknownVersion = false, AcceptPackageAgreements = false,
        SkipDependencies = true, AuthenticationArguments = new AuthenticationArguments { AuthenticationMode = AuthenticationMode.Silent }
    };

    private static ManagedPackageSnapshot Unavailable(string reason) => new(DateTimeOffset.UtcNow, [], false, reason);
}
