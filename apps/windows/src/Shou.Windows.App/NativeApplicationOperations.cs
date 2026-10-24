using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class NativeApplicationOperations : IApplicationUninstallOperations
{
    public bool ExecutionAvailable => WindowsApplicationUninstallMutation.PublicExecutionAvailable;
    private readonly ApplicationUninstallReviewer reviewer = new(new(new WindowsApplicationInventory()), new WindowsApplicationUninstallInspector(), new WindowsApplicationActivity());
    public Task<ApplicationUninstallReview> InspectAsync(string applicationId, CancellationToken cancellationToken) => reviewer.InspectAsync(applicationId, cancellationToken);
    public Task<ApplicationUninstallPlan> CreatePlanAsync(string applicationId, string reviewDigest, bool allowInstallerDataChanges, CancellationToken cancellationToken)
    {
        var store = WindowsRecordStore.ForCurrentUser();
        return new ApplicationUninstallPlanner(store, reviewer, store.OwnerSid).CreateAsync(applicationId, reviewDigest, allowInstallerDataChanges, cancellationToken);
    }

    public async Task<ApplicationUninstallExecution> ExecuteAsync(string planId, IApplicationUninstallConfirmation confirmation, CancellationToken cancellationToken)
    {
        if (!ExecutionAvailable) throw new ShouException("unsupported_capability", "System uninstall requires a matching native Windows 11 process.");
        var service = ExecutionService();
        var consent = await service.ConfirmAsync(planId, confirmation, cancellationToken).ConfigureAwait(false);
        return await service.ExecuteAsync(planId, consent, cancellationToken).ConfigureAwait(false);
    }

    public Task<ApplicationUninstallExecution> ReadExecutionAsync(string planId, CancellationToken cancellationToken) =>
        ExecutionService().ShowAsync(planId, cancellationToken);

    private ApplicationUninstallService ExecutionService()
    {
        var store = WindowsRecordStore.ForCurrentUser();
        return new(store, reviewer, store.OwnerSid, new WindowsApplicationUninstallMutation());
    }
}
