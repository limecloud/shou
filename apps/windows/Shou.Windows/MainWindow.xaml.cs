using System.ComponentModel;
using System.Windows;
using System.Windows.Input;

namespace Shou.Windows;

public partial class MainWindow : Window
{
    private bool closing;
    public MainWindow()
    {
        InitializeComponent();
        Loaded += async (_, _) => { if (DataContext is MainViewModel model) await model.InitializeAsync(); };
        Closing += ClosingWindow;
    }
    private async void ClosingWindow(object? sender, CancelEventArgs e)
    {
        if (closing || DataContext is not MainViewModel { IsBusy: true } model) return;
        e.Cancel = true; model.CancelCommand.Execute(null);
        await model.WhenIdleAsync(); closing = true; Close();
    }
    private async void OpenStorageNode(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is MainViewModel model) await model.OpenStorageNodeAsync();
    }
}
