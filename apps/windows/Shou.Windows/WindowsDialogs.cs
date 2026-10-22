using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Shou.Windows.Services;

namespace Shou.Windows;

public sealed class WindowsDialogs(Window owner)
{
    public void PreviewFile(BridgeProcessClient client, string scanId, string path) => new FilePreviewDialog(owner, client, scanId, path).ShowDialog();
    public void InspectHistory(BridgeProcessClient client, string executionId) => new HistoryInspectionDialog(owner, client, executionId).ShowDialog();
    public JsonNode? AuthorPersonalRule(BridgeProcessClient client,WorkspaceRow workspace,CancellationToken cancellation,JsonObject? original=null)
    {
        var dialog=new RuleAuthoringDialog(owner,client,workspace,cancellation,original);
        return dialog.ShowDialog()==true ? dialog.SavedRule : null;
    }
    public string? ChooseRuleExport(string id)
    {
        var picker=new SaveFileDialog { Title="导出个人规则",FileName=id+".rule.json",Filter="清理规则|*.rule.json;*.json",DefaultExt=".rule.json",AddExtension=true,OverwritePrompt=true };
        return picker.ShowDialog(owner)==true ? picker.FileName : null;
    }
    public JsonObject? EditAIConnection(JsonObject? existing, JsonNode?[] providers) {
        var dialog=new AIConnectionDialog(owner,existing,providers);
        return dialog.ShowDialog()==true ? dialog.Request : null;
    }
    public bool ConfirmAIConfigurationDeletion(string name) => MessageBox.Show(owner,
        name+"\n\n从可用配置中移除，保留调查历史及其密钥。可在“已删除配置”中恢复。",
        "删除 AI 配置方案？",MessageBoxButton.OKCancel,MessageBoxImage.Question,MessageBoxResult.Cancel)==MessageBoxResult.OK;
    public void RevealFolder(string path) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
    public void RevealItem(string path)
    {
        var start = new System.Diagnostics.ProcessStartInfo(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = false };
        start.ArgumentList.Add("/select,"); start.ArgumentList.Add(path);
        System.Diagnostics.Process.Start(start);
    }
    public void OpenStartupSettings() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:startupapps") { UseShellExecute = true });
    public void OpenApplicationSettings() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:appsfeatures") { UseShellExecute = true });
    public void OpenStartupConsole(bool services)
    {
        var start=new System.Diagnostics.ProcessStartInfo(System.IO.Path.Combine(Environment.SystemDirectory,"mmc.exe")) { UseShellExecute=false };
        start.ArgumentList.Add(System.IO.Path.Combine(Environment.SystemDirectory,services ? "services.msc" : "taskschd.msc"));
        System.Diagnostics.Process.Start(start);
    }
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
            challenge["operation"]?.GetValue<string>() is not ("trash" or "restore" or "permanent" or "purge" or "history.clear" or "workspace.remove" or "startup.enable" or "startup.disable" or "privacy.delete")) return Task.FromResult(false);
        var operation = challenge["operation"]!.GetValue<string>();
        if (challenge["review"]?["action"]?.GetValue<string>() != operation) return Task.FromResult(false);
        var (caption, heading, warning) = operation switch
        {
            "privacy.delete" => ("永久清理隐私记录", "永久删除以下浏览器记录？", "此操作只处理本次扫描中选定的来源和时间范围。记录不会进入回收站，无法通过历史恢复。Cookie 清理可能使你退出网站登录。请先关闭相关浏览器。"),
            "workspace.remove" => ("停止包含文件夹", "停止在一键扫描中包含以下额外文件夹？", "已保存的规则绑定、规则选择和该工作区的排除将解除。文件与清理历史保留。如需再次扫描，可以重新包含此文件夹。"),
            "startup.enable" => ("确认启用启动项", "启用以下计划任务？", "仅修改所选当前用户任务的启用配置。不会立即启动任务。执行前重新核验完整定义，执行后读取配置确认结果。"),
            "startup.disable" => ("确认停用启动项", "停用以下计划任务？", "仅修改所选当前用户任务的启用配置。已经运行的实例会继续运行。执行前重新核验完整定义，执行后读取配置确认结果。"),
            "history.clear" => ("清理操作记录", "删除以下本地操作记录？", "仅删除记录，文件保持原位。删除记录后将无法通过 Shou 恢复或核验。未结束的操作记录会保留。"),
            "restore" => ("确认恢复", "恢复以下具体项目？", "恢复遇到同名目标时停止，不会覆盖。"),
            "permanent" => ("确认永久删除", "永久删除以下具体项目？", "此操作不可撤销，删除后无法通过历史恢复。请先停止相关应用、构建和包管理任务。"),
            "purge" => ("确认永久删除", "永久删除以下已记录的回收站项目？", "此操作不可撤销，删除后无法恢复。只处理以下记录中的具体项目。"),
            _ => ("确认移入回收站", "将以下具体项目移入系统回收站？", "移入回收站不会立即释放磁盘空间。请先停止相关应用、构建和包管理任务。")
        };
        var accepted = false;
        var dialog = new Window { Owner = owner, Title = caption, Width = 680, Height = 540, MinWidth = 500, MinHeight = 380, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var panel = new DockPanel { Margin = new Thickness(24) };
        var title = new TextBlock { Text = heading, FontSize = 22, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) };
        DockPanel.SetDock(title, Dock.Top); panel.Children.Add(title);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = "取消", IsCancel = true, IsDefault = true };
        var confirm = new Button { Content = caption };
        confirm.Click += (_, _) => { accepted = confirm.IsEnabled && !cancellation.IsCancellationRequested && DateTimeOffset.UtcNow < expiry; dialog.DialogResult = accepted; };
        buttons.Children.Add(cancel); buttons.Children.Add(confirm); DockPanel.SetDock(buttons, Dock.Bottom); panel.Children.Add(buttons);
        var text = new StringBuilder(warning + "\n\n");
        if (operation == "privacy.delete")
        {
            var irreversible = new CheckBox { Content = "我理解这些记录将永久删除，无法恢复。", Margin = new Thickness(0, 6, 0, 0) };
            var signOut = new CheckBox { Content = "我同意清理 Cookie，并理解可能退出网站登录。", Margin = new Thickness(0, 6, 0, 0) };
            var requiresSignOut = challenge["review"]?["requires_sign_out"]?.GetValue<bool>() == true;
            confirm.IsEnabled = false;
            void UpdateConsent(object sender, RoutedEventArgs args) => confirm.IsEnabled = irreversible.IsChecked == true && (!requiresSignOut || signOut.IsChecked == true);
            irreversible.Checked += UpdateConsent; irreversible.Unchecked += UpdateConsent;
            signOut.Checked += UpdateConsent; signOut.Unchecked += UpdateConsent;
            var consents = new StackPanel(); consents.Children.Add(irreversible);
            if (requiresSignOut) consents.Children.Add(signOut);
            DockPanel.SetDock(consents, Dock.Bottom); panel.Children.Add(consents);
            string Time(string field) => DateTimeOffset.TryParse(challenge["review"]?[field]?.GetValue<string>(), out var date) ? date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz") : "不限";
            text.AppendLine("扫描时间范围：" + Time("range_start") + " 至 " + Time("range_end"));
            text.AppendLine();
        }
        if (challenge["review"]?["items"] is JsonArray items)
        {
            foreach (var item in items)
            {
                text.AppendLine(item?["path"]?.GetValue<string>());
                if (operation == "privacy.delete" && item?["records"] is JsonValue records) text.AppendLine("记录数：" + records.GetValue<long>());
                if (operation == "purge") text.AppendLine("原始路径：" + item?["original_path"]?.GetValue<string>());
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
