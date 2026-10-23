using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsApplicationActivity : IApplicationUninstallActivity
{
    private readonly ApplicationActivityService service = new(new WindowsFileSystem(), new WindowsFileUseActivity(), new WindowsApplicationProcesses());
    public Task<ActivityObservation> InspectAsync(ApplicationUninstallObservation installation, CancellationToken cancellationToken) =>
        service.InspectAsync(installation, cancellationToken);
}
