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
    public bool ReviewCliInstallation(CliInstallationPreview preview,CancellationToken cancellation)
    {
        if(cancellation.IsCancellationRequested)return false;
        var message=F("将在以下位置创建用户级 shou 命令：\n{0}\n\n每次运行都调用：\n{1}\n\n请将完整 Shou 发行目录保留在此位置。已有不同内容会保留；不修改 PATH、终端配置或系统设置，不需要管理员权限。",preview.Launcher,preview.Executable);
        return MessageBox.Show(owner,message,T("安装 CLI 命令"),MessageBoxButton.OKCancel,MessageBoxImage.Information,MessageBoxResult.Cancel)==MessageBoxResult.OK && !cancellation.IsCancellationRequested;
    }
    public string AgentRuleSetup(BridgeProcessClient client, JsonNode setup, string? directory, CancellationToken cancellation)
    {
        var dialog=new AgentRuleSetupDialog(owner,client,setup,directory,cancellation);
        dialog.ShowDialog(); return dialog.Outcome;
    }
    public void PreviewFile(BridgeProcessClient client, string scanId, string path) => new FilePreviewDialog(owner, client, scanId, path).ShowDialog();
    public void ReviewApplicationData(BridgeProcessClient client) => new ApplicationDataDialog(owner,client).ShowDialog();
    public void InspectHistory(BridgeProcessClient client, string executionId) => new HistoryInspectionDialog(owner, client, executionId).ShowDialog();
    public bool ReviewStorageCoverage(StorageCoverageSummary summary) => new StorageCoverageDialog(owner,summary).ShowDialog()==true;
    public bool ReviewRecordMaintenance(RecordMaintenanceSummary preview, CancellationToken cancellation)
    {
        if (cancellation.IsCancellationRequested) return false;
        var dialog = new RecordMaintenanceDialog(owner, preview);
        using var stop = cancellation.Register(() => dialog.Dispatcher.BeginInvoke(new Action(() => { if (dialog.IsVisible) dialog.DialogResult = false; })));
        return dialog.ShowDialog() == true && preview.CanCollect && !cancellation.IsCancellationRequested;
    }
    public JsonNode? AuthorPersonalRule(BridgeProcessClient client,WorkspaceRow workspace,CancellationToken cancellation,JsonObject? original=null)
    {
        var dialog=new RuleAuthoringDialog(owner,client,workspace,cancellation,original);
        return dialog.ShowDialog()==true ? dialog.SavedRule : null;
    }
    public string? ChooseRuleExport(string id)
    {
        var picker=new SaveFileDialog { Title=T("导出个人规则"),FileName=id+".rule.json",Filter=T("清理规则|*.rule.json;*.json"),DefaultExt=".rule.json",AddExtension=true,OverwritePrompt=true };
        return picker.ShowDialog(owner)==true ? picker.FileName : null;
    }
    public JsonObject? EditAIConnection(JsonObject? existing, JsonNode?[] providers) {
        var dialog=new AIConnectionDialog(owner,existing,providers);
        return dialog.ShowDialog()==true ? dialog.Request : null;
    }
    public bool ConfirmAIConfigurationDeletion(string name) => MessageBox.Show(owner,
        name+T("\n\n从可用配置中移除，保留调查历史及其密钥。可在“已删除配置”中恢复。"),
        T("删除 AI 配置方案？"),MessageBoxButton.OKCancel,MessageBoxImage.Question,MessageBoxResult.Cancel)==MessageBoxResult.OK;
    public void RevealFolder(string path) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
    public void RevealItem(string path)
    {
        var start = new System.Diagnostics.ProcessStartInfo(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe")) { UseShellExecute = false };
        start.ArgumentList.Add("/select,"); start.ArgumentList.Add(path);
        System.Diagnostics.Process.Start(start);
    }
    public void OpenStartupSettings() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:startupapps") { UseShellExecute = true });
    public void OpenApplicationSettings() => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:appsfeatures") { UseShellExecute = true });
    private static void OpenSite(string address) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(address) { UseShellExecute = true });
    public void OpenDocumentation(bool chinese) => OpenSite(chinese ? "https://github.com/limecloud/shou/blob/main/docs/zh-CN/engineering/windows.md" : "https://github.com/limecloud/shou/blob/main/docs/engineering/windows.md");
    public void OpenReleases() => OpenSite("https://github.com/limecloud/shou/releases");
    public void OpenFeedback() => OpenSite("https://github.com/limecloud/shou/issues");
    public void OpenSource() => OpenSite("https://github.com/limecloud/shou");
    public void RestartDesktop()
    {
        if (MessageBox.Show(owner, T("重新打开将应用已保存的语言设置，并清空本次扫描选择与未保存的输入。规则和操作历史会保留。是否继续？"), T("重新打开 Shou"), MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Application path unavailable.");
        var start = new System.Diagnostics.ProcessStartInfo(executable) { UseShellExecute = false };
        foreach (var value in Environment.GetCommandLineArgs().Skip(1)) start.ArgumentList.Add(value);
        if (System.Diagnostics.Process.Start(start) is null) throw new System.IO.IOException("Application restart did not start.");
        Application.Current.Shutdown();
    }
    public void OpenStartupConsole(bool services)
    {
        var start=new System.Diagnostics.ProcessStartInfo(System.IO.Path.Combine(Environment.SystemDirectory,"mmc.exe")) { UseShellExecute=false };
        start.ArgumentList.Add(System.IO.Path.Combine(Environment.SystemDirectory,services ? "services.msc" : "taskschd.msc"));
        System.Diagnostics.Process.Start(start);
    }
    public string? ChooseFolder()
    {
        var picker = new OpenFolderDialog { Title = T("选择需要分析或清理的本地目录") };
        return picker.ShowDialog(owner) == true ? picker.FolderName : null;
    }
    public string? ChooseRule()
    {
        var picker = new OpenFileDialog { Title = T("导入声明式清理规则"), Filter = T("清理规则|*.rule.json;*.json") };
        return picker.ShowDialog(owner) == true ? picker.FileName : null;
    }
    public Task<bool> ConfirmAsync(JsonObject challenge, CancellationToken cancellation)
    {
        if (cancellation.IsCancellationRequested || challenge["review"]?["items"] is not JsonArray { Count: > 0 } ||
            !DateTimeOffset.TryParse(challenge["expires_at"]?.GetValue<string>(), out var expiry) || expiry <= DateTimeOffset.UtcNow ||
            challenge["operation"]?.GetValue<string>() is not ("trash" or "restore" or "permanent" or "purge" or "history.clear" or "workspace.remove" or "startup.enable" or "startup.disable" or "privacy.delete" or "applications.close" or "applications.uninstall" or "applications.data-clean" or "applications.package-data-clear" or "tools.clean" or "skills.install" or "skills.export")) return Task.FromResult(false);
        var operation = challenge["operation"]!.GetValue<string>();
        if (challenge["review"]?["action"]?.GetValue<string>() != operation) return Task.FromResult(false);
        var (caption, heading, warning) = operation switch
        {
            "skills.install" => (T("Install Skill"), T("安装外部 AI Skill？"), T("只把随包 Skill 安装到以下目录，不启动 AI 工具、不修改其配置、不发送网络请求，也不启用清理规则。已有个人修改会保留；更新 Shou 管理的旧版本时先保存同级备份。")),
            "skills.export" => (T("Export Skill ZIP…"), T("导出外部 AI Skill？"), T("只向以下位置新建包含随包 Skill 的 ZIP，不覆盖已有文件。上传并启用需在 WorkBuddy 中自行完成；导出不会安装或启动 AI 工具，也不会清理文件。")),
            "applications.uninstall" => (T("确认卸载应用"), T("卸载以下应用？"), T("请先保存工作并退出相关应用。将由 Windows Installer、Windows 包管理器或登记的应用卸载程序处理，可能显示后续提示或请求 Windows 管理员授权。卸载器可能删除应用数据或要求重启，无法通过 Shou 恢复。停止只结束等待，已经启动的卸载器可能继续运行；结果不明时请先在 Windows 中核实，不要重复卸载。")),
            "applications.data-clean" => (T("永久清理应用数据"), T("永久删除以下应用数据？"), T("所选目录包含个人数据，可能包括设置、登录状态、浏览器资料和本地数据库。此操作不会卸载应用，不进入回收站，无法恢复。未登记的便携或自定义安装仍可能使用这些数据。只处理以下确切目录，不自动重试。")),
            "applications.package-data-clear" => (T("清空 MSIX 应用数据"),T("由 Windows 清空以下应用的全部数据？"),T("请先保存工作并退出应用。Windows 将清空所选包的全部本地、漫游和临时数据及设置，可能清除登录状态和未同步内容。应用保留，无法通过 Shou 恢复。此为整包操作，文件清理的排除规则不限制其范围；需要保留任何内容时请取消。停止只结束等待，已经启动的 Windows 操作可能继续；请先核实结果，不要重复操作。")),
            "tools.clean" => (T("永久清理工具存储"), T("通过所属工具永久清理此项？"), T("请先停止相关构建、环境和包管理任务。以下操作由工具自身执行，不进入回收站，无法通过 Shou 恢复。取消、超时或失败时可能已经发生部分变更，请先检查所属工具的当前状态。只执行当前审阅的固定操作，不自动重试。")),
            "applications.close" => (T("正常关闭并刷新"), T("请求正常关闭以下应用？"), T("请先保存工作。应用可能显示保存提示或拒绝退出。只向本次核验的当前用户、当前登录会话中的窗口发送正常关闭请求，不会强制结束进程。随后复核活动并刷新受影响目录；清理文件仍需另行审阅确认。")),
            "privacy.delete" => (T("永久清理隐私记录"), T("永久删除以下浏览器记录？"), T("此操作只处理本次扫描中选定的来源和时间范围。记录不会进入回收站，无法通过历史恢复。Cookie 清理可能使你退出网站登录。请先关闭相关浏览器。")),
            "workspace.remove" => (T("停止包含文件夹"), T("停止在一键扫描中包含以下额外文件夹？"), T("已保存的规则绑定、规则选择和该工作区的排除将解除。文件与清理历史保留。如需再次扫描，可以重新包含此文件夹。")),
            "startup.enable" => (T("确认启用启动项"), T("启用以下计划任务？"), T("仅修改所选当前用户任务的启用配置。不会立即启动任务。执行前重新核验完整定义，执行后读取配置确认结果。")),
            "startup.disable" => (T("确认停用启动项"), T("停用以下计划任务？"), T("仅修改所选当前用户任务的启用配置。已经运行的实例会继续运行。执行前重新核验完整定义，执行后读取配置确认结果。")),
            "history.clear" => (T("清理操作记录"), T("删除以下本地操作记录？"), T("仅删除记录，文件保持原位。删除记录后将无法通过 Shou 恢复或核验。未结束的操作记录会保留。")),
            "restore" => (T("确认恢复"), T("恢复以下具体项目？"), T("恢复遇到同名目标时停止，不会覆盖。")),
            "permanent" => (T("确认永久删除"), T("永久删除以下具体项目？"), T("此操作不可撤销，删除后无法通过历史恢复。请先停止相关应用、构建和包管理任务。")),
            "purge" => (T("确认永久删除"), T("永久删除以下已记录的回收站项目？"), T("此操作不可撤销，删除后无法恢复。只处理以下记录中的具体项目。")),
            _ => (T("确认移入回收站"), T("将以下具体项目移入系统回收站？"), T("移入回收站不会立即释放磁盘空间。请先停止相关应用、构建和包管理任务。"))
        };
        var accepted = false;
        var dialog = new Window { Owner = owner, Title = caption, Width = 680, Height = 540, MinWidth = 500, MinHeight = 380, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false };
        var panel = new DockPanel { Margin = new Thickness(24) };
        var title = new TextBlock { Text = heading, FontSize = 22, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) };
        DockPanel.SetDock(title, Dock.Top); panel.Children.Add(title);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var cancel = new Button { Content = T("取消"), IsCancel = true, IsDefault = true };
        var confirm = new Button { Content = caption };
        confirm.Click += (_, _) => { accepted = confirm.IsEnabled && !cancellation.IsCancellationRequested && DateTimeOffset.UtcNow < expiry; dialog.DialogResult = accepted; };
        buttons.Children.Add(cancel); buttons.Children.Add(confirm); DockPanel.SetDock(buttons, Dock.Bottom); panel.Children.Add(buttons);
        var text = new StringBuilder(warning + "\n\n");
        if (operation == "tools.clean") text.AppendLine(MainViewModel.ToolImpact(challenge["review"]?["tool"]?.GetValue<string>() ?? ""));
        if (operation == "applications.uninstall")
        {
            var consent = new CheckBox { Content = new TextBlock { Text = T("我理解卸载器可能删除应用数据，并且无法通过 Shou 恢复。"), TextWrapping = TextWrapping.Wrap }, Margin = new Thickness(0, 6, 0, 0) };
            confirm.IsEnabled = false;
            consent.Checked += (_, _) => confirm.IsEnabled = true; consent.Unchecked += (_, _) => confirm.IsEnabled = false;
            DockPanel.SetDock(consent, Dock.Bottom); panel.Children.Add(consent);
        }
        if (operation == "applications.package-data-clear")
        {
            var consent=new CheckBox { Content=new TextBlock { Text=T("我同意永久清空以上应用的全部个人数据和设置。"),TextWrapping=TextWrapping.Wrap },Margin=new Thickness(0,6,0,0) };
            confirm.IsEnabled=false;
            consent.Checked+=(_,_)=>confirm.IsEnabled=true;consent.Unchecked+=(_,_)=>confirm.IsEnabled=false;
            DockPanel.SetDock(consent,Dock.Bottom);panel.Children.Add(consent);
        }
        if (operation == "privacy.delete")
        {
            var irreversible = new CheckBox { Content = T("我理解这些记录将永久删除，无法恢复。"), Margin = new Thickness(0, 6, 0, 0) };
            var signOut = new CheckBox { Content = T("我同意清理 Cookie，并理解可能退出网站登录。"), Margin = new Thickness(0, 6, 0, 0) };
            var requiresSignOut = challenge["review"]?["requires_sign_out"]?.GetValue<bool>() == true;
            confirm.IsEnabled = false;
            void UpdateConsent(object sender, RoutedEventArgs args) => confirm.IsEnabled = irreversible.IsChecked == true && (!requiresSignOut || signOut.IsChecked == true);
            irreversible.Checked += UpdateConsent; irreversible.Unchecked += UpdateConsent;
            signOut.Checked += UpdateConsent; signOut.Unchecked += UpdateConsent;
            var consents = new StackPanel(); consents.Children.Add(irreversible);
            if (requiresSignOut) consents.Children.Add(signOut);
            DockPanel.SetDock(consents, Dock.Bottom); panel.Children.Add(consents);
            string Time(string field) => DateTimeOffset.TryParse(challenge["review"]?[field]?.GetValue<string>(), out var date) ? date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz") : T("不限");
            text.AppendLine(T("扫描时间范围：") + Time("range_start") + T(" 至 ") + Time("range_end"));
            text.AppendLine();
        }
        if (challenge["review"]?["items"] is JsonArray items)
        {
            foreach (var item in items)
            {
                if (operation == "applications.package-data-clear")
                {
                    text.AppendLine(item?["application"]?.GetValue<string>());
                    text.AppendLine(T("版本：") + item?["version"]?.GetValue<string>());
                    text.AppendLine(T("包系列：") + item?["package_family"]?.GetValue<string>());
                }
                text.AppendLine(item?["path"]?.GetValue<string>());
                if (operation == "applications.uninstall")
                {
                    text.AppendLine(T("版本：") + item?["version"]?.GetValue<string>());
                    text.AppendLine(T("登记发布者：") + item?["publisher"]?.GetValue<string>());
                    text.AppendLine(T("所属卸载器：") + item?["installer"]?.GetValue<string>());
                    text.AppendLine(T("注册标识：") + item?["registration"]?.GetValue<string>());
                }
                if (operation == "privacy.delete" && item?["records"] is JsonValue records) text.AppendLine(T("记录数：") + records.GetValue<long>());
                if (operation == "purge") text.AppendLine(T("原始路径：") + item?["original_path"]?.GetValue<string>());
                if (item?["bytes"] is JsonValue bytes) text.AppendLine(T("占用估算：") + MainViewModel.Bytes(bytes.GetValue<long>()));
                if (operation is not ("applications.uninstall" or "applications.package-data-clear") && item?["risk"] is JsonValue risk) text.AppendLine(T("风险：") + risk.GetValue<string>());
                foreach (var key in new[] { "rebuild_notes", "limitations" })
                    if (operation != "tools.clean" && item?[key] is JsonArray notes) foreach (var note in notes) text.AppendLine("· " + note?.GetValue<string>());
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
