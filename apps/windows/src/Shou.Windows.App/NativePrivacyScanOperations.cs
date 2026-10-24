using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class NativePrivacyScanOperations : IPrivacyScanOperations
{
    private readonly PrivacyScanService service;
    private readonly PrivacyCleanupService cleanup;
    public NativePrivacyScanOperations()
    {
        var store = WindowsRecordStore.ForCurrentUser();
        var directories = new WindowsUserDirectories(WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
            WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)), WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)));
        var policy = new WindowsPrivacySourcePolicy(directories);
        service = new(store, RuleResources.CreateValidator(), policy, new WindowsFileSystem(), new WindowsPrivacyDatabaseInspection(policy, store.OwnerSid),
            new PrivacyBrowserActivity(new WindowsApplicationProcesses()), store.OwnerSid, directories.Home, store.Directory);
        cleanup = new(store, RuleResources.CreateValidator(), service, new WindowsPrivacyDatabaseInspection(policy, store.OwnerSid),
            new PrivacyBrowserActivity(new WindowsApplicationProcesses()), new WindowsPrivacyMutation(policy), store.OwnerSid);
    }
    public Task<PrivacyScan> ScanAsync(PrivacyTimeRange range, CancellationToken cancellationToken) =>
        Task.Run(() => service.ScanAsync(range, cancellationToken), cancellationToken);
    public Task<PrivacyPlan> CreatePlanAsync(string scanId, string[] sourceIds, bool acknowledgeSignOut, CancellationToken token) =>
        Task.Run(() => cleanup.CreatePlanAsync(scanId, sourceIds, acknowledgeSignOut, token), token);
    public Task<PrivacyReceipt> ReadReceiptAsync(string planId, CancellationToken token) => Task.Run(() => cleanup.ReadReceiptAsync(planId, token), token);
    public Task<System.Collections.Immutable.ImmutableArray<PrivacyReceipt>> ReadHistoryAsync(CancellationToken token) => Task.Run(() => cleanup.HistoryAsync(cancellationToken: token), token);
    public Task<PrivacyReceipt> ExecuteAsync(string planId, IPrivacyConfirmation confirmation, CancellationToken token) => Task.Run(async () =>
    {
        var consent = await cleanup.ConfirmAsync(planId, confirmation, token).ConfigureAwait(false);
        return await cleanup.ExecuteAsync(planId, consent, token).ConfigureAwait(false);
    }, token);
}
