using System.Collections.Immutable;

namespace Shou.Windows.Core;

public enum ManagedPackageScope { Unknown, User, System }
public enum ManagedPackageUpdateOutcome { Verified, Failed, Unknown, NotStarted }
public sealed record ManagedPackageUpdate(string Id, string Name, string InstalledVersion, string? AvailableVersion,
    string InstallationIdentity, ManagedPackageScope Scope, string CatalogId, string TargetChannel, bool CanUpgrade, string? Reason);
public sealed record ManagedPackageSnapshot(DateTimeOffset ObservedAt, ImmutableArray<ManagedPackageUpdate> Packages, bool Complete, string? Reason);
public sealed record ManagedPackageMutationResult(bool Succeeded, bool Started, bool RestartRequired, string? ErrorCode);
public sealed record ManagedPackageUpdateResult(ManagedPackageUpdate Package, ManagedPackageUpdateOutcome Outcome,
    string? ObservedVersion, bool RestartRequired, string? ErrorCode);

public interface IManagedPackageUpdates
{
    Task<ManagedPackageSnapshot> ReadAsync(CancellationToken cancellationToken);
    Task<ManagedPackageMutationResult> UpgradeAsync(ManagedPackageUpdate expected, DateTimeOffset authorizationExpiresAt, CancellationToken cancellationToken);
}

public sealed class ManagedPackageUpdatePlan
{
    internal ManagedPackageUpdatePlan(ImmutableArray<ManagedPackageUpdate> packages, DateTimeOffset expiresAt)
    { Packages = packages; ExpiresAt = expiresAt; }
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public ImmutableArray<ManagedPackageUpdate> Packages { get; }
    public DateTimeOffset ExpiresAt { get; }
}

// The exact displayed selection is re-read before issuing a short-lived, single-use plan.
// A package manager completion alone never establishes that the requested version is installed.
public sealed class ManagedPackageUpdateService(IManagedPackageUpdates platform, TimeProvider? timeProvider = null)
{
    public const string OfficialCatalogId = "Microsoft.Winget.Source_8wekyb3d8bbwe";
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly SemaphoreSlim operation = new(1, 1);
    private ManagedPackageUpdatePlan? currentPlan;

    public async Task<ManagedPackageSnapshot> ReadAsync(CancellationToken cancellationToken = default) =>
        Validate(await platform.ReadAsync(cancellationToken).ConfigureAwait(false));

    public async Task<ManagedPackageUpdatePlan> PrepareAsync(IEnumerable<ManagedPackageUpdate> selection, CancellationToken cancellationToken = default)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            currentPlan = null;
            var selected = selection.ToImmutableArray();
            if (selected.Length is < 1 or > 512 || selected.Select(p => p.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != selected.Length || selected.Any(p => !p.CanUpgrade))
                throw new ShouException("package_update_selection_invalid", "Choose an exact, supported package update selection.");
            var fresh = await ReadAsync(cancellationToken).ConfigureAwait(false);
            RequireSelection(fresh, selected);
            currentPlan = new(selected, clock.GetUtcNow().AddMinutes(2));
            return currentPlan;
        }
        finally { operation.Release(); }
    }

    public async Task<ImmutableArray<ManagedPackageUpdateResult>> ExecuteAsync(ManagedPackageUpdatePlan plan, string confirmedPlanId, CancellationToken cancellationToken = default)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!ReferenceEquals(currentPlan, plan) || confirmedPlanId != plan.Id || clock.GetUtcNow() >= plan.ExpiresAt)
                throw new ShouException("package_update_plan_stale", "Review the exact package update selection again.");
            currentPlan = null; // Consume before preflight or any platform mutation; never replay a failed attempt.
            RequireSelection(await ReadAsync(cancellationToken).ConfigureAwait(false), plan.Packages);
            var results = ImmutableArray.CreateBuilder<ManagedPackageUpdateResult>();
            foreach (var package in plan.Packages)
            {
                if (cancellationToken.IsCancellationRequested || clock.GetUtcNow() >= plan.ExpiresAt)
                { results.Add(new(package, ManagedPackageUpdateOutcome.NotStarted, null, false, cancellationToken.IsCancellationRequested ? "cancelled" : "package_update_plan_stale")); continue; }
                try
                {
                    RequireSelection(await ReadAsync(cancellationToken).ConfigureAwait(false), [package]);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                { results.Add(new(package, ManagedPackageUpdateOutcome.NotStarted, null, false, "cancelled")); continue; }
                catch (Exception error) when (error is ShouException or IOException)
                { results.Add(new(package, ManagedPackageUpdateOutcome.NotStarted, null, false, "package_update_changed")); continue; }

                ManagedPackageMutationResult mutation;
                try { mutation = await platform.UpgradeAsync(package, plan.ExpiresAt, cancellationToken).ConfigureAwait(false); }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    // Cancellation or transport loss after dispatch may have changed the installation.
                    mutation = new(false, true, false, "package_update_outcome_unknown");
                }
                string? observed = null;
                try
                {
                    // Completion verification must still run after the user requests stop.
                    using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                    var after = await ReadAsync(verification.Token).ConfigureAwait(false);
                    var installed = after.Packages.SingleOrDefault(p => p.Id == package.Id && p.Scope == package.Scope);
                    if (after.Complete) observed = installed?.InstalledVersion;
                }
                catch (Exception error) when (error is not OutOfMemoryException) { }
                var outcome = mutation.Succeeded && observed == package.AvailableVersion ? ManagedPackageUpdateOutcome.Verified :
                    !mutation.Started ? ManagedPackageUpdateOutcome.NotStarted :
                    observed == package.InstalledVersion && !mutation.Succeeded ? ManagedPackageUpdateOutcome.Failed : ManagedPackageUpdateOutcome.Unknown;
                results.Add(new(package, outcome, observed, mutation.RestartRequired, mutation.ErrorCode));
                if (outcome == ManagedPackageUpdateOutcome.Unknown)
                {
                    foreach (var remaining in plan.Packages.Skip(results.Count))
                        results.Add(new(remaining, ManagedPackageUpdateOutcome.NotStarted, null, false, "package_update_previous_unknown"));
                    break;
                }
            }
            return results.ToImmutable();
        }
        finally { operation.Release(); }
    }

    private static void RequireSelection(ManagedPackageSnapshot snapshot, ImmutableArray<ManagedPackageUpdate> selected)
    {
        if (!snapshot.Complete || selected.Any(expected => !snapshot.Packages.Any(current => current == expected && current.CanUpgrade)))
            throw new ShouException("package_update_changed", "Package identity, source or target version changed. Check updates again.");
    }

    private static ManagedPackageSnapshot Validate(ManagedPackageSnapshot snapshot)
    {
        static bool Text(string? value, int limit, bool empty = false) => value is not null && value.Length <= limit &&
            (empty || value.Length > 0) && !value.Any(char.IsControl);
        if (snapshot.Packages.IsDefault || snapshot.Packages.Length > 512 ||
            snapshot.Packages.Select(p => p.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != snapshot.Packages.Length ||
            snapshot.Packages.Any(p => !Text(p.Id, 256) || !Text(p.Name, 256) || !Text(p.InstalledVersion, 128) ||
                !Text(p.InstallationIdentity, 128) || p.CatalogId != OfficialCatalogId || !Text(p.TargetChannel, 128, true) ||
                p.AvailableVersion is not null && !Text(p.AvailableVersion, 128) ||
                !Enum.IsDefined(p.Scope) || p.CanUpgrade && (p.Scope == ManagedPackageScope.Unknown || !Text(p.AvailableVersion, 128) ||
                    p.AvailableVersion == p.InstalledVersion || p.Reason is not null)))
            throw new ShouException("package_update_invalid_inventory", "The package manager returned an ambiguous or unsupported inventory.");
        return snapshot;
    }
}
