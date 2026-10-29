using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (WindowsSystemAuthorizationWorker.RunIfRequestedAsync(args).GetAwaiter().GetResult() is { } workerExit) { Environment.ExitCode = workerExit; return; }
        try
        {
            NativeDiagnostics.Initialize();
            using var diagnostic = Shou.Windows.Core.OperationDiagnostics.Start("application.lifetime");
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(initialization =>
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                _ = new App();
            });
            diagnostic.Complete("closed");
        }
        catch (Exception error)
        {
            NativeDiagnostics.Write(error);
            Environment.ExitCode = 1;
        }
    }
}
