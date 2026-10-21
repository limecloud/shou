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
        SpaceMap.Inspect += async (path,open) => { if(DataContext is MainViewModel model) await model.FocusStorageAsync(path,open); };
        Loaded += async (_, _) => { if (DataContext is MainViewModel model) await model.InitializeAsync(); };
        Closing += ClosingWindow;
    }
    private async void ClosingWindow(object? sender, CancelEventArgs e)
    {
        if (closing || DataContext is not MainViewModel { IsBusy: true } model) return;
        e.Cancel = true; model.CancelCommand.Execute(null);
        await model.WhenIdleAsync(); closing = true; Close();
    }
    private async void StorageTreeExpanded(object sender,RoutedEventArgs e)
    {
        if(DataContext is MainViewModel model && e.OriginalSource is System.Windows.Controls.TreeViewItem { DataContext: StorageRow row }) await model.LoadStorageChildrenAsync(row);
    }
    private async void StorageTreeSelection(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if(DataContext is MainViewModel model && e.NewValue is StorageRow row) {
            if(row.Kind=="more" && e.OriginalSource is System.Windows.Controls.TreeView tree) {
                var parentPath=row.Path.TrimEnd('/');
                var parent=FindStorageParent(model.StorageTree,parentPath);
                if(parent is not null) await model.LoadStorageChildrenAsync(parent,true);
            } else if(row.Eligible) model.SelectedStorageNode=row;
        }
    }
    private static StorageRow? FindStorageParent(IEnumerable<StorageRow> nodes,string path) {
        foreach(var node in nodes) { if(node.Path==path) return node; var child=FindStorageParent(node.Children,path); if(child is not null) return child; } return null;
    }
    private async void OpenStorageNode(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is MainViewModel model) await model.OpenStorageNodeAsync();
    }
}
