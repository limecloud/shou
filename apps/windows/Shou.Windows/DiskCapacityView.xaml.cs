using System.Windows;
using System.Windows.Controls;
using Shou.Windows.Services;

namespace Shou.Windows;

public partial class DiskCapacityView : UserControl
{
    public static readonly DependencyProperty DirectoryPathProperty = DependencyProperty.Register(nameof(DirectoryPath), typeof(string), typeof(DiskCapacityView), new PropertyMetadata("", PathChanged));
    public static readonly DependencyProperty RefreshKeyProperty = DependencyProperty.Register(nameof(RefreshKey), typeof(object), typeof(DiskCapacityView), new PropertyMetadata(null, (owner, _) => ((DiskCapacityView)owner).Refresh()));
    public string DirectoryPath { get => (string)GetValue(DirectoryPathProperty); set => SetValue(DirectoryPathProperty, value); }
    public object? RefreshKey { get => GetValue(RefreshKeyProperty); set => SetValue(RefreshKeyProperty, value); }
    private bool refreshing, refreshAgain;
    private int generation;

    public DiskCapacityView()
    {
        InitializeComponent();
        Loaded += (_, _) => { Application.Current.Activated += AppActivated; Refresh(); };
        Unloaded += (_, _) => { Application.Current.Activated -= AppActivated; generation++; };
    }

    private static void PathChanged(DependencyObject owner, DependencyPropertyChangedEventArgs args)
    {
        var view = (DiskCapacityView)owner;
        view.generation++; view.CapacityLabel.Text = T("正在读取磁盘容量…"); view.UsageBar.Visibility = Visibility.Collapsed;
        view.ToolTip = args.NewValue as string;
        view.Refresh();
    }

    private void AppActivated(object? sender, EventArgs args) => Refresh();
    private void RefreshClicked(object sender, RoutedEventArgs args) => Refresh();
    private async void Refresh()
    {
        if (!IsLoaded) return;
        if (refreshing) { refreshAgain = true; return; }
        refreshing = true;
        try
        {
            do
            {
                refreshAgain = false;
                var requested = DirectoryPath; var version = generation;
                DiskCapacity? capacity;
                try { capacity = await Task.Run(() => DiskCapacityReader.Read(requested)); }
                catch (Exception) { capacity = null; }
                if (IsLoaded && version == generation) ShowCapacity(capacity);
            } while (refreshAgain && IsLoaded);
        }
        finally { refreshing = false; }
    }

    private void ShowCapacity(DiskCapacity? capacity)
    {
        CapacityLabel.Text = capacity is null ? T("磁盘容量暂不可用，可稍后刷新。") : F("磁盘空间 · 可用 {0} / 总计 {1}",MainViewModel.Bytes(capacity.AvailableBytes),MainViewModel.Bytes(capacity.TotalBytes));
        UsageBar.Visibility = capacity is null ? Visibility.Collapsed : Visibility.Visible;
        UsageBar.Value = capacity?.UsedPercentage ?? 0;
        ToolTip = DirectoryPath + T("\n容量以当前用户可用空间为准，可能随其他应用写入而变化。移入回收站不会立即释放空间。");
    }

    internal void VerifyLayout()
    {
        foreach (var capacity in new DiskCapacity?[] { new(1_000_000_000, 250_000_000), new(1_000_000_000, 0), null })
        {
            ShowCapacity(capacity);
            Measure(new Size(320, 100)); Arrange(new Rect(0, 0, 320, 100)); UpdateLayout();
        }
    }
}
