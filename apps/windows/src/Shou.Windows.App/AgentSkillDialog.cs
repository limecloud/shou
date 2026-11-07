using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.App;

internal sealed class AgentSkillDialog : ContentDialog
{
    private readonly TextCatalog text = new();
    private readonly ComboBox skill = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox agent = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox destination = new() { IsReadOnly = true };
    private readonly TextBox output = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    internal AgentSkillDialog(XamlRoot root)
    {
        XamlRoot = root; Title = text.Get("External AI Tools…"); CloseButtonText = text.Get("Done");
        FontSize = (double)Application.Current.Resources["ShouBodyFontSize"];
        DefaultButton = ContentDialogButton.Close;
        var panel = new StackPanel { Spacing = 12, MinWidth = 400, MaxWidth = 560 };
        Content = panel;
        panel.Children.Add(new TextBlock { Text = text.Get("Install an assistant for investigating disk usage or authoring reusable cleanup rules."), TextWrapping = TextWrapping.Wrap });
        skill.Header = text.Get("Skill");
        skill.Items.Add(new ComboBoxItem { Content = text.Get("Cleanup assistant"), Tag = BundledAgentSkills.CleanupName });
        skill.Items.Add(new ComboBoxItem { Content = text.Get("Rule authoring"), Tag = BundledAgentSkills.DefaultName });
        skill.SelectedIndex = 0;
        agent.Header = text.Get("Agent"); agent.ItemsSource = new[] { "Codex", "Claude Code" }; agent.SelectedIndex = 0;
        destination.Header = text.Get("Install Directory");
        agent.SelectionChanged += (_, _) => UpdatePath();
        UpdatePath();
        panel.Children.Add(skill); panel.Children.Add(agent); panel.Children.Add(destination);
        panel.Children.Add(new TextBlock { Text = text.Get("Existing files with local changes are preserved."), TextWrapping = TextWrapping.Wrap });
        var install = new Button { Content = text.Get("Install Skill"), HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(install, "skills.install");
        install.Click += async (_, _) =>
        {
            install.IsEnabled = false; skill.IsEnabled = agent.IsEnabled = false;
            var selectedSkill = SelectedSkill; var selectedAgent = SelectedAgent;
            try
            {
                var result = await Task.Run(() => AgentSkillInstallation.Install(selectedAgent, selectedSkill));
                status.Text = text.Get("Skill installed") + "\n" + result.Directory + "\n" +
                    (selectedAgent == "codex" ? "$" : "/") + selectedSkill;
                if (result.BackupDirectory is { } backup) status.Text += "\n" + backup;
            }
            catch (Exception error) { NativeDiagnostics.Write(error); status.Text = text.Get("Skill installation failed. Existing files were preserved."); }
            finally { install.IsEnabled = true; skill.IsEnabled = agent.IsEnabled = true; }
        };
        panel.Children.Add(install);
        output.Header = text.Get("Export Skill…");
        output.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), BundledAgentSkills.CleanupName + ".zip");
        panel.Children.Add(output);
        var export = new Button { Content = text.Get("Export Skill…"), HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(export, "skills.export");
        export.Click += async (_, _) =>
        {
            export.IsEnabled = false; var path = output.Text; var selectedSkill = SelectedSkill;
            try { await Task.Run(() => AgentSkillInstallation.Export(path, selectedSkill)); status.Text = text.Get("Skill exported") + "\n" + path; }
            catch (Exception error) { NativeDiagnostics.Write(error); status.Text = text.Get("Skill installation failed. Existing files were preserved."); }
            finally { export.IsEnabled = true; }
        };
        panel.Children.Add(export); panel.Children.Add(status);
        panel.Children.Add(new TextBlock { Text = text.Get("Make the Shou CLI available as shou, or use its full path in the request."), TextWrapping = TextWrapping.Wrap });
        var copy = new Button { Content = text.Get("Copy Request"), HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(copy, "skills.copy-request");
        copy.Click += (_, _) =>
        {
            var invocation = (SelectedAgent == "codex" ? "$" : "/") + SelectedSkill;
            const string cli = "shou";
            var request = invocation + "\n" + cli + " capabilities --json\n" +
                cli + " skills read --skill " + SelectedSkill + " --json\n" +
                text.Get(SelectedSkill == BundledAgentSkills.DefaultName
                    ? "Investigate rebuildable artifacts and retention. Reuse existing rules or preview disabled drafts. Ask about unresolved purpose; do not enable rules or execute cleanup."
                    : "Investigate disk usage, explain purpose, activity, rebuild cost and retention, and ask about unresolved items. Review independent batches through Shou plans and current confirmation. Do not bypass unavailable operations; verify receipts and volume space changes.");
            var data = new global::Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(request);
            global::Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
        };
        panel.Children.Add(copy);
    }
    private string SelectedAgent => agent.SelectedIndex == 0 ? "codex" : "claude-code";
    private string SelectedSkill => (string)((ComboBoxItem)skill.SelectedItem).Tag;
    private void UpdatePath() => destination.Text = AgentSkillInstallation.DefaultDirectory(SelectedAgent);
}
