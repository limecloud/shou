using Microsoft.UI.Xaml;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

public partial class App : Application
{
    private Window? window;

    public App()
    {
        UnhandledException += (_, args) => NativeDiagnostics.Write(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception error) NativeDiagnostics.Write(error);
        };
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        await AppearanceSettings.LoadAsync();
        window = new MainWindow(args.Arguments.Trim() == "--page monitor" ? "monitor" : "cleanup");
        window.Activate();
        await MonitorTaskbar.PrepareAsync();
    }

    internal void ReloadWindow(string page)
    {
        var previous = window;
        window = new MainWindow(page);
        window.Activate();
        previous?.Close();
    }
}
