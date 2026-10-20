using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Shou.Windows;

public sealed class WindowsDialogs(Window owner)
{
    public string? ChooseFolder()
    {
        var picker = new OpenFolderDialog { Title = "选择需要分析或清理的本地目录" };
        return picker.ShowDialog(owner) == true ? picker.FolderName : null;
    }
    public string? ChooseRule()
    {
        var picker = new OpenFileDialog { Title = "导入声明式清理规则", Filter = "清理规则|*.rule.json;*.json" };
        return picker.ShowDialog(owner) == true ? picker.FileName : null;
    }
    public Task<bool> ConfirmAsync(JsonObject challenge, CancellationToken cancellation)
    {
        if (cancellation.IsCancellationRequested || challenge["review"]?["items"] is not JsonArray { Count: > 0 } ||
            !DateTimeOffset.TryParse(challenge["expires_at"]?.GetValue<string>(), out var expiry) || expiry <= DateTimeOffset.UtcNow ||
            challenge["operation"]?.GetValue<string>() is not ("trash" or "restore")) return Task.FromResult(false);
        var restore = challenge["operation"]?.GetValue<string>() == "restore";
        var accepted = false;
        var dialog = new Window { Owner = owner, Title = restore ? "确认恢复" : "确认移入回收站", Width = 680, Height = 540, MinWidth = 500, MinHeight = 380, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var panel = new DockPanel { Margin = new Thickness(24) };
        var title = new TextBlock { Text = restore ? "恢复以下具体项目？" : "将以下具体项目移入系统回收站？", FontSize = 22, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) };
        DockPanel.SetDock(title, Dock.Top); panel.Children.Add(title);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = "取消", IsCancel = true, IsDefault = true };
        var confirm = new Button { Content = restore ? "确认恢复" : "确认移入回收站" };
        confirm.Click += (_, _) => { accepted = !cancellation.IsCancellationRequested && DateTimeOffset.UtcNow < expiry; dialog.DialogResult = accepted; };
        buttons.Children.Add(cancel); buttons.Children.Add(confirm); DockPanel.SetDock(buttons, Dock.Bottom); panel.Children.Add(buttons);
        var text = new StringBuilder(restore ? "恢复遇到同名目标时停止，不会覆盖。\n\n" : "移入回收站不会立即释放磁盘空间。请先停止相关应用、构建和包管理任务。\n\n");
        if (challenge["review"]?["items"] is JsonArray items)
        {
            foreach (var item in items)
            {
                text.AppendLine(item?["path"]?.GetValue<string>());
                if (item?["bytes"] is JsonValue bytes) text.AppendLine("占用估算：" + MainViewModel.Bytes(bytes.GetValue<long>()));
                if (item?["risk"] is JsonValue risk) text.AppendLine("风险：" + risk.GetValue<string>());
                foreach (var key in new[] { "rebuild_notes", "limitations" })
                    if (item?[key] is JsonArray notes) foreach (var note in notes) text.AppendLine("· " + note?.GetValue<string>());
                text.AppendLine();
            }
        }
        else return Task.FromResult(false);
        panel.Children.Add(new TextBox { Text = text.ToString(), IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0) });
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => { if (DateTimeOffset.UtcNow >= expiry) dialog.Close(); };
        using var registration = cancellation.Register(() => dialog.Dispatcher.InvokeAsync(dialog.Close));
        dialog.Content = panel;
        timer.Start();
        try { dialog.ShowDialog(); }
        finally { timer.Stop(); }
        return Task.FromResult(accepted);
    }
}
