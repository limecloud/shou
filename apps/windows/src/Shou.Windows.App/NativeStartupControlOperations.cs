using Shou.Windows.Core;
using Shou.Windows.Platform;
using Shou.Windows.Presentation;

namespace Shou.Windows.App;

internal sealed class NativeStartupControlOperations : IStartupControlOperations
{
    public bool ExecutionAvailable => WindowsStartupControlMutation.PublicExecutionAvailable;
    public Task<StartupControlReview> InspectAsync(string taskPath, StartupControlAction action, CancellationToken token) =>
        WindowsStartupControlInspector.CreateReviewer().InspectAsync(taskPath, action, token);
    public Task<StartupControlExecution> ExecuteAsync(StartupControlReview review, IStartupControlConfirmation confirmation, CancellationToken token)
    {
        if (!ExecutionAvailable) throw new ShouException("unsupported_capability", "Startup changes require a matching native Windows 11 process.");
        return Service().ExecuteAsync(review, confirmation, token);
    }
    public Task<StartupControlExecution> ReadAsync(string operationId, CancellationToken token) => Service().ShowAsync(operationId, token);
    private static StartupControlService Service()
    {
        var store = WindowsRecordStore.ForCurrentUser();
        return new(store, WindowsStartupControlInspector.CreateReviewer(), new WindowsStartupControlMutation(), store.OwnerSid);
    }
}
