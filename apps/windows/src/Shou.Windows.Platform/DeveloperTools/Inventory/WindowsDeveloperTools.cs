using Microsoft.Management.Deployment;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsDeveloperTools : IDeveloperTools
{
    // Discovery and review do not open the existing Windows uninstall gates.
    // Native generated-installer acceptance is required before exposing mutation.
    public static bool PublicExecutionAvailable => false;
    public static DeveloperToolPackage? PackageFor(DeveloperToolInstallation installation, DeveloperToolCatalog catalog)
    {
        if (installation.Source != "WinGet" || installation.Version is null) return null;
        var matches = catalog.Tools.Where(tool => tool.Id == installation.ToolId).SelectMany(tool => tool.Packages)
            .Where(package => package.Provider == "winget" && installation.Evidence.StartsWith(package.Token + ":", StringComparison.Ordinal)).ToArray();
        return matches.Length == 1 ? matches[0] : null;
    }
    public static DeveloperToolCatalog LoadCatalog()
    {
        using var stream = typeof(WindowsDeveloperTools).Assembly.GetManifestResourceStream("Shou.Windows.Resources.developer-tools.json")
            ?? throw new ShouException("resource_unavailable", "Developer tool catalog is missing.");
        using var bytes = new MemoryStream(); stream.CopyTo(bytes);
        return DeveloperToolCatalog.Decode(bytes.ToArray());
    }
    public async Task<DeveloperToolInspection> InspectAsync(DeveloperToolPackage package, CancellationToken cancellationToken)
    {
        if (!package.Valid || package.Provider != "winget") throw Failure("developer_tool_source_unavailable");
        return await Task.Run(async () =>
        {
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            budget.CancelAfter(TimeSpan.FromSeconds(60));
            var (_, catalog) = await WindowsManagedPackageUpdates.ConnectAsync(budget.Token, CompositeSearchBehavior.AllCatalogs).ConfigureAwait(false);
            return Observe(package, await FindAsync(catalog, package, budget.Token).ConfigureAwait(false));
        }, cancellationToken).ConfigureAwait(false);
    }
    public async Task<ManagedPackageMutationResult> PerformAsync(DeveloperToolAction action, DeveloperToolInspection expected, DateTimeOffset expiresAt, CancellationToken cancellationToken)
    {
        if (!PublicExecutionAvailable) return new(false, false, false, "developer_tool_native_acceptance_pending");
        return await PerformCoreAsync(action, expected, expiresAt, cancellationToken).ConfigureAwait(false);
    }
    private static Task<ManagedPackageMutationResult> PerformCoreAsync(DeveloperToolAction action, DeveloperToolInspection expected, DateTimeOffset expiresAt, CancellationToken cancellationToken) =>
        Task.Run(async () =>
        {
            using var preparation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            preparation.CancelAfter(TimeSpan.FromSeconds(60));
            var (manager, catalog) = await WindowsManagedPackageUpdates.ConnectAsync(preparation.Token, CompositeSearchBehavior.AllCatalogs).ConfigureAwait(false);
            var package = await FindAsync(catalog, expected.Package, preparation.Token).ConfigureAwait(false);
            if (Observe(expected.Package, package) != expected || !expected.Allows(action) || DateTimeOffset.UtcNow >= expiresAt)
                return new ManagedPackageMutationResult(false, false, false, "developer_tool_changed");
            cancellationToken.ThrowIfCancellationRequested();
            if (action == DeveloperToolAction.Install)
            {
                var target = package.DefaultInstallVersion;
                var key = WindowsManagedPackageUpdates.TargetId(package, expected.AvailableVersion!, target.Channel) ?? throw Failure("developer_tool_changed");
                var result = await manager.InstallPackageAsync(package, WindowsManagedPackageUpdates.Options(expected.Scope, key)).AsTask().ConfigureAwait(false);
                return new ManagedPackageMutationResult(result.Status == InstallResultStatus.Ok, true, result.RebootRequired,
                    result.Status == InstallResultStatus.Ok ? null : "developer_tool_installer_failed");
            }
            var uninstall = await manager.UninstallPackageAsync(package, new UninstallOptions
            {
                Force = false, PackageUninstallMode = PackageUninstallMode.Silent,
                PackageUninstallScope = expected.Scope == ManagedPackageScope.User ? PackageUninstallScope.User : PackageUninstallScope.System
            }).AsTask().ConfigureAwait(false);
            return new ManagedPackageMutationResult(uninstall.Status == UninstallResultStatus.Ok, true, uninstall.RebootRequired,
                uninstall.Status == UninstallResultStatus.Ok ? null : "developer_tool_uninstaller_failed");
        }, cancellationToken);

    private static async Task<CatalogPackage> FindAsync(PackageCatalog catalog, DeveloperToolPackage package, CancellationToken cancellationToken)
    {
        var options = new FindPackagesOptions { ResultLimit = 2 };
        options.Filters.Add(new PackageMatchFilter { Field = PackageMatchField.Id, Option = PackageFieldMatchOption.Equals, Value = package.Token });
        var result = await catalog.FindPackagesAsync(options).AsTask(cancellationToken).ConfigureAwait(false);
        if (result.Status != FindPackagesResultStatus.Ok || result.WasLimitExceeded || result.Matches.Count != 1 || result.Matches[0].CatalogPackage.Id != package.Token) throw Failure("package_identity_unverified");
        return result.Matches[0].CatalogPackage;
    }
    private static DeveloperToolInspection Observe(DeveloperToolPackage reference, CatalogPackage package)
    {
        var target = package.DefaultInstallVersion;
        if (target is null || target.PackageCatalog.Info.Id != ManagedPackageUpdateService.OfficialCatalogId) throw Failure("package_source_unverified");
        var installed = WindowsManagedPackageUpdates.Observe(package);
        var scope = installed?.Scope ?? ManagedPackageScope.User;
        var key = WindowsManagedPackageUpdates.TargetId(package, target.Version, target.Channel);
        var targetSupported = key is not null && target.Channel.Length == 0 && target.GetCatalogPackageMetadata().Agreements.Count == 0;
        if (targetSupported && installed is null && !target.HasApplicableInstaller(WindowsManagedPackageUpdates.Options(scope, key!))) scope = ManagedPackageScope.System;
        targetSupported = targetSupported && target.HasApplicableInstaller(WindowsManagedPackageUpdates.Options(scope, key!));
        var issue = scope == ManagedPackageScope.Unknown || package.InstalledVersion is not null && installed is null ||
            installed is { InstalledVersion.Length: 0 } || installed?.InstalledVersion.Equals("unknown", StringComparison.OrdinalIgnoreCase) == true
            ? "package_identity_unverified" : null;
        return new(reference, installed?.InstalledVersion, targetSupported ? target.Version : null, ManagedPackageUpdateService.OfficialCatalogId,
            installed?.InstallationIdentity ?? "not_installed", scope, issue,
            package.InstalledVersion?.GetMetadata(PackageVersionMetadataField.InstalledLocation));
    }
    private static ShouException Failure(string code) => new(code, "The exact official WinGet package could not be verified.");
}
