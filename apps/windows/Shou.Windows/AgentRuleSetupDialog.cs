using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Shou.Windows;

public sealed class AgentRuleSetupDialog : Window
{
    private readonly BridgeProcessClient client;
    private readonly JsonNode setup;
    private readonly CancellationToken cancellation;
    private readonly ComboBox agent;
    private readonly StackPanel location;
    private readonly TextBox destination;
    private readonly TextBlock guidance, status;
    private readonly Button install, browse, reset, close;
    private CancellationTokenSource? active;
    private bool busy;
    public string Outcome => status.Text;

    public AgentRuleSetupDialog(Window? owner, BridgeProcessClient client, JsonNode setup, string? directory, CancellationToken cancellation)
    {
        Owner=owner; this.client=client; this.setup=setup; this.cancellation=cancellation;
        status=new TextBlock { Margin=new Thickness(0,12,0,0) };
        Title=T("Customize with AI"); Width=780; Height=780; MinWidth=540; MinHeight=480;
        WindowStartupLocation=owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner; ShowInTaskbar=false;
        var root=new DockPanel { Margin=new Thickness(24) };
        var actions=new WrapPanel { HorizontalAlignment=HorizontalAlignment.Right, Margin=new Thickness(0,16,0,0) };
        close=new Button { Content=T("Done"), IsCancel=true }; actions.Children.Add(close);
        var reveal=new Button { Content=T("在资源管理器中显示 Skill") };
        reveal.Click+=(_,_)=> { try { new WindowsDialogs(this).RevealItem(Text(setup["skill"],"entrypoint")); } catch(Exception) { status.Text=T("无法打开 Skill 位置，请检查随包资源。"); } };
        actions.Children.Add(reveal);
        var copy=new Button { Content=T("Copy Request"), IsDefault=true }; actions.Children.Add(copy);
        DockPanel.SetDock(actions,Dock.Bottom); root.Children.Add(actions);
        var scroll=new ScrollViewer { VerticalScrollBarVisibility=ScrollBarVisibility.Auto }; root.Children.Add(scroll);
        var panel=new StackPanel(); scroll.Content=panel;
        panel.Children.Add(new TextBlock { Text=Title, FontSize=24, FontWeight=FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text=T("Shou includes the Skill and CLI. Use your existing agent; no model setup is needed in Shou."), Margin=new Thickness(0,12,0,18) });
        var choices=new WrapPanel(); panel.Children.Add(choices);
        choices.Children.Add(new TextBlock { Text=T("Your AI Agent"), VerticalAlignment=VerticalAlignment.Center, Margin=new Thickness(0,0,12,0) });
        agent=new ComboBox { ItemsSource=new UiChoice[] { new("codex","Codex"), new("claude-code","Claude Code"), new("workbuddy","WorkBuddy") }, DisplayMemberPath="Name", SelectedValuePath="Id", SelectedIndex=0, MinWidth=170, Margin=new Thickness(0,0,12,0) };
        AutomationProperties.SetName(agent,T("Your AI Agent")); choices.Children.Add(agent);
        install=new Button(); choices.Children.Add(install); install.Click+=Install;
        location=new StackPanel(); panel.Children.Add(location);
        location.Children.Add(new TextBlock { Text=T("安装目标（Skill 父目录）"), Margin=new Thickness(0,14,0,4) });
        destination=new TextBox { IsReadOnly=true, TextWrapping=TextWrapping.Wrap }; location.Children.Add(destination);
        AutomationProperties.SetName(destination,T("安装目标（Skill 父目录）"));
        var locations=new WrapPanel { Margin=new Thickness(0,8,0,0) }; location.Children.Add(locations);
        browse=new Button { Content=T("选择其他 Skill 目录…") }; reset=new Button { Content=T("使用默认 Skill 目录") }; locations.Children.Add(browse); locations.Children.Add(reset);
        browse.Click+=(_,_)=> { var picker=new OpenFolderDialog { Title=T("选择 Skill 所在的父目录") }; if(picker.ShowDialog(this)==true) destination.Text=picker.FolderName; };
        reset.Click+=(_,_)=> UpdateAgent();
        guidance=new TextBlock { Margin=new Thickness(0,10,0,12) }; panel.Children.Add(guidance);
        panel.Children.Add(new TextBlock { Text=T("先安装 Skill 或导出 ZIP，再把下方请求复制到已有 AI 工具。规则导入后默认停用；预览、启用并重新扫描后，仍需确认具体文件才能清理。"), Margin=new Thickness(0,0,0,12) });
        var prompt=new TextBox { Text=AgentRuleHandoff.Create(Text(setup["skill"],"entrypoint"),client.ExecutablePath,directory), IsReadOnly=true, TextWrapping=TextWrapping.Wrap, MinHeight=230, VerticalScrollBarVisibility=ScrollBarVisibility.Auto };
        AutomationProperties.SetName(prompt,T("外部 AI 请求")); panel.Children.Add(prompt);
        copy.Click+=(_,_)=> { try { Clipboard.SetText(prompt.Text); status.Text=T("已复制外部 AI 请求，未启动 AI 工具或发送网络请求。"); } catch(Exception) { status.Text=T("复制未完成，请在请求框中手动选择并复制。"); } };
        AutomationProperties.SetLiveSetting(status,AutomationLiveSetting.Polite); panel.Children.Add(status);
        agent.SelectionChanged+=(_,_)=>UpdateAgent(); Closing+=ClosingSetup;
        Content=root; UpdateAgent();
    }

    private static string Text(JsonNode? node,string key) => node?[key]?.GetValue<string>() ?? "";
    private string Agent => (string?)agent.SelectedValue ?? "codex";
    private void UpdateAgent()
    {
        if(busy)return;
        destination.Text=(setup["clients"] as JsonArray)?.FirstOrDefault(value=>Text(value,"id")==Agent)?["directory"]?.GetValue<string>() ?? "";
        install.Content=T(Agent=="workbuddy" ? "Export Skill ZIP…" : "Install Skill");
        guidance.Text=T(Agent switch { "codex"=>"After installation, use $shou-rule-authoring in Codex. Restart Codex if it does not appear.", "claude-code"=>"After installation, use /shou-rule-authoring in a local Claude Code session.", _=>"In WorkBuddy, open Skills → Add Skill → Upload Skill, select the ZIP, enable it, and start a new task." });
        browse.IsEnabled=reset.IsEnabled=Agent!="workbuddy"; status.Text="";
        location.Visibility=Agent=="workbuddy" ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void Install(object sender,RoutedEventArgs args)
    {
        if(busy)return;
        string? output=null;
        if(Agent=="workbuddy")
        {
            var picker=new SaveFileDialog { Title=T("Export Skill ZIP…"), FileName="shou-rule-authoring.zip", Filter="ZIP|*.zip", DefaultExt=".zip", AddExtension=true, OverwritePrompt=true };
            if(picker.ShowDialog(this)!=true)return; output=picker.FileName;
        }
        using var operation=CancellationTokenSource.CreateLinkedTokenSource(cancellation); active=operation; busy=true;
        agent.IsEnabled=install.IsEnabled=browse.IsEnabled=reset.IsEnabled=false; status.Text=T("正在检查 Skill 及目标位置…");
        var incomplete=T("安装或导出未确认完成，请检查目标目录后再试；不会自动重试。Skill 安装不会启用清理规则。");
        try
        {
            var dialogs=new WindowsDialogs(this);
            JsonNode result;
            if(output is not null) result=await client.RequestAsync("skills.export",new() { ["output"]=output },confirm:review=>dialogs.ConfirmAsync(review,operation.Token),cancellation:operation.Token);
            else
            {
                var input=new JsonObject { ["agent"]=Agent,["directory"]=destination.Text };
                var preview=await client.RequestAsync("skills.preview",input,cancellation:operation.Token);
                input["review_digest"]=Text(preview,"digest");
                result=await client.RequestAsync("skills.install",input,confirm:review=>dialogs.ConfirmAsync(review,operation.Token),cancellation:operation.Token);
            }
            status.Text=Text(result,"state") switch {
                "exported" when Text(result,"path").Length>0=>F("Skill ZIP 已导出：{0}。请在 WorkBuddy 中上传并启用。",Text(result,"path")),
                "already_current" when Text(result,"directory").Length>0=>T("Skill is already up to date."),
                "installed" or "updated" when Text(result,"directory").Length>0=>F("Skill 已安装：{0}",Text(result,"directory"))+(Text(result,"backup_directory") is { Length:>0 } backup ? F("\n旧版已保存在：{0}",backup) : ""),
                _=>throw new InvalidOperationException("Invalid Skill setup result.")
            };
        }
        catch(BridgeException error) { status.Text=error.Code is "cancelled" or "request_timeout" or "engine_disconnected" or "engine_failed" or "transport_failed" or "invalid_protocol" ? incomplete : error.Message; }
        catch(Exception) { status.Text=incomplete; }
        finally { busy=false; active=null; agent.IsEnabled=install.IsEnabled=true; browse.IsEnabled=reset.IsEnabled=Agent!="workbuddy"; }
    }

    private void ClosingSetup(object? sender,CancelEventArgs args)
    {
        if(!busy)return; args.Cancel=true; active?.Cancel(); status.Text=T("正在停止，请等待当前操作结束。");
    }

    internal void VerifyLayout()
    {
        foreach(var choice in new[] { "codex","claude-code","workbuddy" })
        {
            agent.SelectedValue=choice;
            foreach(var size in new[] { new Size(780,780),new Size(540,480) }) { Measure(size); Arrange(new Rect(new Point(),size)); UpdateLayout(); }
            if(Agent!=choice || (choice!="workbuddy" && destination.Text.Length==0) || location.Visibility!=(choice=="workbuddy" ? Visibility.Collapsed : Visibility.Visible))throw new InvalidOperationException("External agent setup choices are incomplete.");
        }
    }
}
