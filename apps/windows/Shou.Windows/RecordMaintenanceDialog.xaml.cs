using System.Windows;
using Shou.Windows.Services;

namespace Shou.Windows;

public partial class RecordMaintenanceDialog : Window
{
    public RecordMaintenanceDialog(Window? owner, RecordMaintenanceSummary preview)
    {
        InitializeComponent(); Owner = owner;
        PreviewSummary.Text = F("{0} 条扫描记录 · {1}",preview.RemovableCount,MainViewModel.Bytes(preview.RemovableBytes));
        RetainedSummary.Text = F("保留 {0} 条派生记录 · 当前派生记录共 {1}",preview.RetainedCount,MainViewModel.Bytes(preview.TotalBytes));
        CollectButton.IsEnabled = preview.CanCollect;
        IssueNotice.Text = preview.IssueCount > 0 ? F("{0} 项记录检查需要核实，已保留全部候选。请稍后重新检查。",preview.IssueCount)
            : preview.RemovableCount == 0 ? T("目前没有可回收的扫描记录。") : "";
    }

    private void CollectClicked(object sender, RoutedEventArgs args)
    {
        if (CollectButton.IsEnabled) DialogResult = true;
    }

    internal void VerifyLayout()
    {
        foreach (var size in new[] { new Size(580, 450), new Size(440, 380) })
        {
            Measure(size); Arrange(new Rect(new Point(0, 0), size)); UpdateLayout();
        }
    }
}
