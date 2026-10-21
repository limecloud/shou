using System.IO;
using System.Windows;
using Shou.Windows.Services;

namespace Shou.Windows;

public partial class App : Application
{
    public App()
    {
        if (Environment.GetEnvironmentVariable("SHOU_PACKAGE_VERIFICATION_REPORT") is { } report)
            AppDomain.CurrentDomain.UnhandledException += (_, value) => File.WriteAllText(report, value.ExceptionObject.ToString());
    }

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var verifyPackage = e.Args.Length == 1 && e.Args[0] == "--verify-package";
        try
        {
            var engine = Path.Combine(AppContext.BaseDirectory, "Engine", "shou.exe");
            if (e.Args.Length == 2 && e.Args[0] == "--engine") engine = e.Args[1];
            else if (e.Args.Length != 0 && !verifyPackage) throw new BridgeException("invalid_argument", "源码运行参数为 --engine <shou.exe 的绝对路径>。");
            var window = new MainWindow();
            var client = new BridgeProcessClient(engine);
            window.DataContext = new MainViewModel(client, new WindowsDialogs(window));
            if (verifyPackage)
            {
                // Exercise the shipped WPF resources and bundled engine without
                // scanning user folders or opening an unattended CI window.
                var capabilities = await client.RequestAsync("capabilities");
                if (capabilities["platform"]?.GetValue<string>() != "windows") throw new BridgeException("incompatible_engine", "Windows package requires a Windows engine.");
                window.Measure(new Size(1280, 800));
                window.Arrange(new Rect(0, 0, 1280, 800));
                window.UpdateLayout();
                var report = Environment.GetEnvironmentVariable("SHOU_PACKAGE_VERIFICATION_REPORT") ?? throw new InvalidOperationException("Missing package verification report path.");
                File.WriteAllText(report, System.Text.Json.JsonSerializer.Serialize(new { assembly_version = typeof(App).Assembly.GetName().Version?.ToString(), application_version = capabilities["application_version"]?.GetValue<string>(), wpf_layout_loaded = true }));
                Shutdown(0); return;
            }
            MainWindow = window; window.Show();
        }
        catch (Exception error) { if (verifyPackage) Console.Error.WriteLine(error); else MessageBox.Show(error.Message, "Shou · 启动未完成", MessageBoxButton.OK, MessageBoxImage.Error); Shutdown(1); }
    }
}
