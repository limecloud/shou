using System.IO;
using System.Windows;
using Shou.Windows.Services;

namespace Shou.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var engine = Path.Combine(AppContext.BaseDirectory, "Engine", "shou.exe");
            if (e.Args.Length == 2 && e.Args[0] == "--engine") engine = e.Args[1];
            else if (e.Args.Length != 0) throw new BridgeException("invalid_argument", "源码运行参数为 --engine <shou.exe 的绝对路径>。");
            var window = new MainWindow();
            window.DataContext = new MainViewModel(new BridgeProcessClient(engine), new WindowsDialogs(window));
            MainWindow = window; window.Show();
        }
        catch (Exception error) { MessageBox.Show(error.Message, "Shou · 启动未完成", MessageBoxButton.OK, MessageBoxImage.Error); Shutdown(1); }
    }
}
