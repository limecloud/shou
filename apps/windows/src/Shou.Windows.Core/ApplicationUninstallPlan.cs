using System.Text.Json;

namespace Shou.Windows.Core;

public sealed record ApplicationUninstallPlan(int Version, string Id, string OwnerSid, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt,
    ApplicationUninstallReview Review, bool AllowInstallerDataChanges, string Digest)
{
    public bool ExecutionAvailable => false;
}

public sealed class ApplicationUninstallPlanner(IRecordStore store, ApplicationUninstallReviewer reviewer, string ownerSid, TimeProvider? timeProvider = null)
{
    public const int MaximumPlanBytes = 131_072;
    public static readonly TimeSpan PlanLifetime = TimeSpan.FromMinutes(15);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;

    public async Task<ApplicationUninstallPlan> CreateAsync(string applicationId, string reviewDigest, bool allowInstallerDataChanges,
        CancellationToken cancellationToken = default)
    {
        if (!ApplicationUninstallReviewer.Sid(ownerSid) || !ApplicationCatalog.IsApplicationId(applicationId) || !RecordJson.IsDigest(reviewDigest))
            throw new ShouException("invalid_argument", "Choose a valid application and the digest of its reviewed installation.");
        if (!allowInstallerDataChanges) throw new ShouException("installer_data_consent_required", "Explicitly review and allow data changes performed by this application's system installer before preparing a plan.");
        var review = await reviewer.InspectAsync(applicationId, cancellationToken).ConfigureAwait(false);
        if (review.Digest != reviewDigest) throw new ShouException("application_changed", "The installation changed after review. Inspect it again before preparing a plan.");
        if (!review.CanPreparePlan) throw new ShouException("unsupported_capability", "This installation cannot currently produce an uninstall plan. Read the review's blocking reasons.");
        var now = clock.GetUtcNow();
        var plan = new ApplicationUninstallPlan(1, RecordKey.New("uninstall_plan"), ownerSid, now, now + PlanLifetime, review, true, "");
        plan = plan with { Digest = Digest(plan) };
        var bytes = Encode(plan);
        await using var lease = await store.AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
        if (await lease.ReadAsync(plan.Id, MaximumPlanBytes, cancellationToken).ConfigureAwait(false) is not null)
            throw new ShouException("version_conflict", "An uninstall plan with this identifier already exists.");
        await lease.WriteAsync(plan.Id, bytes, cancellationToken).ConfigureAwait(false);
        return plan;
    }

    public async Task<ApplicationUninstallPlan> ShowAsync(string planId, CancellationToken cancellationToken = default)
    {
        if (!RecordKey.IsId(planId, "uninstall_plan")) throw new ShouException("invalid_argument", "Choose a valid uninstall plan identifier.");
        var bytes = await store.ReadAsync(planId, MaximumPlanBytes, cancellationToken).ConfigureAwait(false)
            ?? throw new ShouException("not_found", "The uninstall plan does not exist.");
        return Decode(bytes, planId);
    }

    private byte[] Encode(ApplicationUninstallPlan plan) { Validate(plan, plan.Id); return RecordJson.Encode(plan, MaximumPlanBytes); }
    internal ApplicationUninstallPlan Decode(byte[] bytes, string planId)
    {
        try
        {
            if (bytes.Length > MaximumPlanBytes) throw Corrupt();
            var plan = JsonSerializer.Deserialize<ApplicationUninstallPlan>(bytes, ContractJson.Options) ?? throw Corrupt();
            Validate(plan, planId);
            return plan;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or NullReferenceException or ShouException)
        { throw new ShouException("corrupt_record", "The uninstall plan is invalid; no installation was changed.", error); }
    }
    private void Validate(ApplicationUninstallPlan plan, string planId)
    {
        if (plan.Version != 1 || plan.Id != planId || !RecordKey.IsId(plan.Id, "uninstall_plan") || !ApplicationUninstallReviewer.Sid(ownerSid) ||
            plan.OwnerSid != ownerSid || !plan.AllowInstallerDataChanges || plan.CreatedAt.Offset != TimeSpan.Zero || plan.ExpiresAt.Offset != TimeSpan.Zero ||
            plan.ExpiresAt - plan.CreatedAt != PlanLifetime || plan.Review is null || plan.Review.Application is null ||
            !ApplicationCatalog.IsApplicationId(plan.Review.Application.Id) || plan.Review.Application.Id != ApplicationCatalog.ApplicationId(plan.Review.Application.Source, plan.Review.Application.RegistrationKey) ||
            plan.Review.BlockingReasons.IsDefault || !plan.Review.BlockingReasons.IsEmpty || plan.Review.Warnings.IsDefault ||
            plan.Review.Warnings.Length > 32 || plan.Review.Warnings.Any(warning => !ApplicationUninstallReviewer.Code(warning)) ||
            plan.Review.ObservedAt.Offset != TimeSpan.Zero || plan.Review.ObservedAt > plan.CreatedAt || plan.CreatedAt - plan.Review.ObservedAt > TimeSpan.FromMinutes(1) ||
            plan.Review.Installation?.Identity is null || plan.Review.Installation.InstalledRoot is null || plan.Review.Installation.InstalledRoot.Path.IsVolumeRoot ||
            plan.Review.Application.IsSystemPackage || plan.Review.Installation.IsProtected ||
            !plan.Review.Installation.Issues.IsEmpty ||
            plan.Review.Activity is not { State: ActivityState.Idle, Reason: { } reason } || !ApplicationUninstallReviewer.Code(reason) ||
            plan.Review.Installation.Identity.Context != MsiInstallationContext.Machine && plan.Review.Installation.Identity.UserSid != ownerSid) throw Corrupt();
        try { ApplicationUninstallReviewer.ValidateObservation(plan.Review.Application, plan.Review.Installation); }
        catch (ShouException) { throw Corrupt(); }
        if (plan.Review.Digest != ApplicationUninstallReviewer.Digest(plan.Review) || plan.Digest != Digest(plan)) throw Corrupt();
    }
    private static string Digest(ApplicationUninstallPlan plan) => RecordJson.Digest(plan with { Digest = "" });
    private static ShouException Corrupt() => new("corrupt_record", "The uninstall plan is invalid; no installation was changed.");
}
