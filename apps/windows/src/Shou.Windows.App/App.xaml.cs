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
        // Unpackaged WinUI launches do not populate LaunchActivatedEventArgs.Arguments.
        var command = Environment.GetCommandLineArgs().Skip(1).ToArray();
        var monitorRequested = command is ["--page", "monitor"] || args.Arguments.Trim() == "--page monitor";
        MonitorTaskbar.InitializeIdentity();
        window = new MainWindow(monitorRequested ? "monitor" : "cleanup");
        window.Activate();
        MonitorTaskbar.Prepare();
    }

    internal void ReloadWindow(string page)
    {
        var previous = window;
        window = new MainWindow(page);
        window.Activate();
        previous?.Close();
    }
}
