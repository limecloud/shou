using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Combines native file-use evidence with bounded known-tool process observations.</summary>
public sealed class WindowsCleanupActivity : ICleanupActivity
{
    private readonly CleanupActivityService service = new(new WindowsFileUseActivity(), new WindowsProcessInventory());

    public Task<ActivityObservation> InspectAsync(Workspace workspace, CleanupPlanItem item, CancellationToken cancellationToken) =>
        service.InspectAsync(workspace, item, cancellationToken);
}
