using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;

namespace Shou.Windows;

public partial class StorageCoverageDialog : Window
{
    public StorageCoverageSummary Summary { get; }
    public ObservableCollection<StorageCoverageItem> VisibleItems { get; }=[];
    public string MeasurementSummary => F("已检查 {0} 项 · 覆盖问题 {1} 项",Summary.EntryCount,Summary.Items.Count);
    public StorageCoverageDialog(Window? owner,StorageCoverageSummary summary)
    {
        Summary=summary;InitializeComponent();Owner=owner;DataContext=this;
        ShowSystem.Visibility=summary.Items.Any(item=>item.SystemManaged) ? Visibility.Visible : Visibility.Collapsed;
        FilterItems();
    }
    private void FilterItems()
    {
        VisibleItems.Clear();
        foreach(var item in Summary.Items.Where(item=>ShowSystem.IsChecked==true || !item.SystemManaged))VisibleItems.Add(item);
        EmptyNotice.Text=Summary.Items.Count==0 ? Summary.EmptyMessage : T("当前隐藏的系统管理位置无需调整权限，可勾选后查看。");
        EmptyNotice.Visibility=VisibleItems.Count==0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void FilterChanged(object sender,RoutedEventArgs args) { if(IsInitialized)FilterItems(); }
    private void CopyClicked(object sender,RoutedEventArgs args)
    {
        if(sender is Button { DataContext: StorageCoverageItem { AbsolutePath: { } path } })Clipboard.SetText(path);
    }
    private void RevealClicked(object sender,RoutedEventArgs args)
    {
        if(sender is not Button { DataContext: StorageCoverageItem { CanReveal:true,AbsolutePath: { } path } })return;
        try { new WindowsDialogs(this).RevealItem(path); }
        catch(Exception error) when(error is System.ComponentModel.Win32Exception or InvalidOperationException or System.IO.IOException)
        { MessageBox.Show(this,T("无法在资源管理器中显示此位置，可复制路径后检查。"),T("扫描覆盖详情"),MessageBoxButton.OK,MessageBoxImage.Information); }
    }
    private void RescanClicked(object sender,RoutedEventArgs args) => DialogResult=true;
    internal void VerifyLayout()
    {
        foreach(var showSystem in new[] { false,true })
        {
            ShowSystem.IsChecked=showSystem;FilterItems();
            if(VisibleItems.Count!=Summary.Items.Count(item=>showSystem || !item.SystemManaged))throw new InvalidOperationException("Coverage filter lost scan notes.");
            foreach(var size in new[] { new Size(740,640),new Size(520,460) })
            { Measure(size);Arrange(new Rect(new Point(0,0),size));UpdateLayout(); }
        }
    }
}
