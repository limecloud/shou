using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class NativePrivacyScanOperations : IPrivacyScanOperations
{
    private readonly PrivacyScanService service;
    public NativePrivacyScanOperations()
    {
        var store = WindowsRecordStore.ForCurrentUser();
        var directories = new WindowsUserDirectories(WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
            WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)), WindowsPath.Parse(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)));
        var policy = new WindowsPrivacySourcePolicy(directories);
        service = new(store, RuleResources.CreateValidator(), policy, new WindowsFileSystem(), new WindowsPrivacyDatabaseInspection(policy, store.OwnerSid),
            new PrivacyBrowserActivity(new WindowsApplicationProcesses()), store.OwnerSid, directories.Home, store.Directory);
    }
    public Task<PrivacyScan> ScanAsync(PrivacyTimeRange range, CancellationToken cancellationToken) =>
        Task.Run(() => service.ScanAsync(range, cancellationToken), cancellationToken);
}
