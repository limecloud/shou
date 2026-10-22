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
        Activated += async (_, _) => { if (IsLoaded && DataContext is MainViewModel { IsBusy: false } model) await model.RefreshExternalChangesAsync(); };
        Closing += ClosingWindow;
    }
    private async void ClosingWindow(object? sender, CancelEventArgs e)
    {
        if (closing || DataContext is not MainViewModel model) return;
        if (!model.IsBusy && !model.HasAiWork) return;
        e.Cancel = true;
        if(model.HasAiWork && MessageBox.Show(this,T("退出将停止 AI 调查，未提交的回答不会保存。已有证据与规则草稿会保留。是否退出？"),T("停止调查并退出"),MessageBoxButton.OKCancel,MessageBoxImage.Question,MessageBoxResult.Cancel)!=MessageBoxResult.OK) return;
        await model.StopAiAsync();
        if(model.IsBusy) model.CancelCommand.Execute(null);
        await model.WhenIdleAsync(); closing = true; Close();
    }
    private async void StorageTreeExpanded(object sender,RoutedEventArgs e)
    {
        if(DataContext is MainViewModel model && e.OriginalSource is System.Windows.Controls.TreeViewItem { DataContext: StorageRow row }) await model.LoadStorageChildrenAsync(row);
    }
    private async void CleanupGroupSelected(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if (DataContext is MainViewModel model && e.NewValue is CleanupGroupRow group) await model.SelectCleanupGroupAsync(group);
    }
    private async void StorageTreeSelection(object sender, RoutedPropertyChangedEventArgs<object> e)
    {
        if(DataContext is MainViewModel model && e.NewValue is StorageRow row) {
            if(row.Kind=="more" && e.OriginalSource is System.Windows.Controls.TreeView tree) {
                var parentPath=row.Path.TrimEnd('/');
                var parent=FindStorageParent(model.StorageTree,parentPath);
                if(parent is not null) await model.LoadStorageChildrenAsync(parent,true);
            } else if(row.Kind is "file" or "directory") model.SelectedStorageNode=row;
        }
    }
    private static StorageRow? FindStorageParent(IEnumerable<StorageRow> nodes,string path) {
        foreach(var node in nodes) { if(node.Path==path) return node; var child=FindStorageParent(node.Children,path); if(child is not null) return child; } return null;
    }
    private async void OpenStorageNode(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is MainViewModel model) await model.OpenStorageNodeAsync();
    }
    private async void StorageSelectionClicked(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (DataContext is MainViewModel model && sender is FrameworkElement { DataContext: StorageRow row }) await model.ToggleStorageSelectionAsync(row);
    }
}
