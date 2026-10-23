using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(initialization =>
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                _ = new App();
            });
        }
        catch (Exception error)
        {
            NativeDiagnostics.Write(error);
            Environment.ExitCode = 1;
        }
    }
}
