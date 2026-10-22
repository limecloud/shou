using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace Shou.Windows;

/// <summary>Secrets live only in PasswordBox and the request-scoped stdin payload.</summary>
public sealed class AIConnectionDialog : Window
{
    public JsonObject? Request { get; private set; }
    public AIConnectionDialog(Window owner, JsonObject? existing, JsonNode?[] providers)
    {
        Owner=owner; Title=existing is null ? "添加 AI 配置方案" : "编辑 AI 配置方案";
        Width=640; Height=760; MinWidth=480; MinHeight=440;
        WindowStartupLocation=WindowStartupLocation.CenterOwner; ShowInTaskbar=false;
        var root=new DockPanel { Margin=new Thickness(24) };
        var buttons=new StackPanel { Orientation=Orientation.Horizontal, HorizontalAlignment=HorizontalAlignment.Right, Margin=new Thickness(0,16,0,0) };
        var cancel=new Button { Content="取消", IsCancel=true };
        var save=new Button { Content="保存连接", IsDefault=true };
        buttons.Children.Add(cancel); buttons.Children.Add(save); DockPanel.SetDock(buttons,Dock.Bottom); root.Children.Add(buttons);
        var panel=new StackPanel(); root.Children.Add(new ScrollViewer { Content=panel, VerticalScrollBarVisibility=ScrollBarVisibility.Auto });
        static string Text(JsonNode? node,string key) => node?[key]?.GetValue<string>() ?? "";
        void Note(string text) => panel.Children.Add(new TextBlock { Text=text, TextWrapping=TextWrapping.Wrap, Margin=new Thickness(0,8,0,8) });
        TextBox Field(string label,string value,Panel parent,int max=2000) {
            parent.Children.Add(new TextBlock { Text=label, Margin=new Thickness(0,12,0,4) });
            var field=new TextBox { Text=value, MaxLength=max, MinHeight=30 }; AutomationProperties.SetName(field,label); parent.Children.Add(field); return field;
        }
        ComboBox Choice(string label,string[] values,string selected,Panel parent) {
            parent.Children.Add(new TextBlock { Text=label, Margin=new Thickness(0,12,0,4) });
            var field=new ComboBox { ItemsSource=values,SelectedItem=values.Contains(selected) ? selected : values[0],MinHeight=30 }; AutomationProperties.SetName(field,label); parent.Children.Add(field); return field;
        }
        PasswordBox Secret(string label,Panel parent) {
            parent.Children.Add(new TextBlock { Text=label+"（留空保留已保存密钥）",Margin=new Thickness(0,12,0,4) });
            var field=new PasswordBox { MaxLength=2560,MinHeight=30 }; AutomationProperties.SetName(field,label); parent.Children.Add(field); return field;
        }
        Note("每个方案必须配置主模型。开启决策服务时由 Jev 协助节省 token；关闭后由主模型直接接管。保存不会发送网络请求；默认使用 Windows 凭据管理器，无需反复授权。");
        var name=Field("方案名称",Text(existing,"name"),panel,100);
        Note("主模型（必需）");
        var mainPanel=new StackPanel(); panel.Children.Add(mainPanel);
        var protocol=Choice("主模型协议",["responses","chat_completions","anthropic"],Text(existing,"api_protocol"),mainPanel);
        var baseUrl=Field("主模型 API 基础地址",Text(existing,"base_url") is { Length:>0 } url ? url : "https://api.openai.com/v1",mainPanel);
        var model=Field("主模型名称",Text(existing,"model"),mainPanel,200);
        var mainAuth=Choice("主模型认证",["系统凭据","本地私有文件","指定环境变量","无需认证"],Text(existing,"authentication") switch { "local"=>"本地私有文件","environment"=>"指定环境变量","none"=>"无需认证",_=>"系统凭据" },mainPanel);
        var mainEnv=Field("主模型环境变量名",Text(existing,"environment_variable"),mainPanel,120);
        var mainKey=Secret("主模型 API Key",mainPanel);
        var decision=new CheckBox { Content="启用决策服务（Jev 协助主模型）",IsChecked=existing is null || existing["decision"] is JsonObject && Text(existing,"routing_strategy")!="main_only",Margin=new Thickness(0,20,0,4) }; panel.Children.Add(decision);
        Note("关闭后保留决策服务配置和密钥，由主模型处理调查。Jev 不可单独使用。");
        var decisionPanel=new StackPanel(); panel.Children.Add(decisionPanel);
        var installed=providers.OfType<JsonObject>().ToArray();
        var provider=new ComboBox { ItemsSource=installed, DisplayMemberPath="[name]", MinHeight=30 }; AutomationProperties.SetName(provider,"决策服务提供方"); decisionPanel.Children.Add(provider);
        var oldDecision=existing?["decision"];
        var providerId=Text(oldDecision,"provider") is { Length:>0 } configured ? configured : "jev";
        provider.SelectedItem=installed.FirstOrDefault(p=>Text(p,"id")==providerId);
        var decisionUrl=Field("决策服务 API 基础地址",Text(oldDecision,"base_url"),decisionPanel);
        var decisionModel=Field("决策服务模型",Text(oldDecision,"model"),decisionPanel,200);
        var decisionAuth=Choice("决策服务认证",["系统凭据","本地私有文件","指定环境变量","无需认证"],Text(oldDecision,"authentication") switch { "local"=>"本地私有文件","environment"=>"指定环境变量","none"=>"无需认证",_=>"系统凭据" },decisionPanel);
        var decisionEnv=Field("决策服务环境变量名",Text(oldDecision,"environment_variable"),decisionPanel,120);
        var decisionKey=Secret("决策服务 API Key",decisionPanel);
        provider.SelectionChanged+=(_,_)=> { if(provider.SelectedItem is JsonObject p) { decisionUrl.Text=Text(p["default_connection"],"base_url"); decisionModel.Text=Text(p["default_connection"],"model"); decisionEnv.Text=Text(p["default_connection"],"environment_variable"); decisionKey.Clear(); } };
        if(existing is null && installed.Length>0) provider.SelectedItem=installed[0];
        Note("仅列出当前已实现的适配器。切换提供方会使用独立凭据；尚未实现的服务不会被自动替代。本地私有文件由用户权限保护，不使用系统凭据加密；密钥不会写入连接资料或调查历史。");
        var error=new TextBlock { TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,12,0,0) }; panel.Children.Add(error);
        void Availability() {
            decisionPanel.IsEnabled=decision.IsChecked==true;
            mainEnv.IsEnabled=(string?)mainAuth.SelectedItem=="指定环境变量"; mainKey.IsEnabled=(string?)mainAuth.SelectedItem is "系统凭据" or "本地私有文件";
            decisionEnv.IsEnabled=(string?)decisionAuth.SelectedItem=="指定环境变量"; decisionKey.IsEnabled=(string?)decisionAuth.SelectedItem is "系统凭据" or "本地私有文件";
        }
        decision.Checked+=(_,_)=>Availability(); decision.Unchecked+=(_,_)=>Availability();
        mainAuth.SelectionChanged+=(_,_)=>Availability(); decisionAuth.SelectionChanged+=(_,_)=>Availability(); Availability();
        static string Authentication(ComboBox value) => (string?)value.SelectedItem switch { "本地私有文件"=>"local","指定环境变量"=>"environment","无需认证"=>"none",_=>"keychain" };
        static bool ValidUrl(string value) => Uri.TryCreate(value,UriKind.Absolute,out var url) && (url.Scheme=="https" || url.Scheme=="http" && url.IsLoopback) && string.IsNullOrEmpty(url.UserInfo) && string.IsNullOrEmpty(url.Query) && string.IsNullOrEmpty(url.Fragment);
        save.Click+=(_,_)=> {
            if(string.IsNullOrWhiteSpace(name.Text)) { error.Text="填写配置名称。"; return; }
            if(!ValidUrl(baseUrl.Text.Trim()) || string.IsNullOrWhiteSpace(model.Text) || decision.IsChecked==true && (!ValidUrl(decisionUrl.Text.Trim()) || string.IsNullOrWhiteSpace(decisionModel.Text) || provider.SelectedItem is not JsonObject)) { error.Text="主模型为必需配置。填写有效的 HTTPS 基础地址和模型名；启用决策服务时选择已安装的提供方。"; return; }
            var profile=new JsonObject { ["id"]=existing?["id"]?.DeepClone() ?? JsonValue.Create("connection_"+Guid.NewGuid().ToString("N")),["name"]=name.Text.Trim(),["api_protocol"]=(string?)protocol.SelectedItem,["base_url"]=baseUrl.Text.Trim(),["model"]=model.Text.Trim(),["main_model_enabled"]=true,["authentication"]=Authentication(mainAuth),["environment_variable"]=mainEnv.Text.Trim(),["routing_strategy"]=decision.IsChecked==true ? "decision_first" : "main_only" };
            if(decision.IsChecked==true || oldDecision is not null) profile["decision"]=decision.IsChecked==true ? new JsonObject { ["provider"]=Text(provider.SelectedItem as JsonObject,"id"),["base_url"]=decisionUrl.Text.Trim(),["model"]=decisionModel.Text.Trim(),["authentication"]=Authentication(decisionAuth),["environment_variable"]=decisionEnv.Text.Trim() } : oldDecision!.DeepClone();
            Request=new JsonObject { ["profile"]=profile };
            if(mainKey.IsEnabled && mainKey.Password.Length>0) Request["model_key"]=mainKey.Password;
            if(decision.IsChecked==true && decisionKey.IsEnabled && decisionKey.Password.Length>0) Request["decision_key"]=decisionKey.Password;
            DialogResult=true;
        };
        Closed+=(_,_)=> { mainKey.Clear(); decisionKey.Clear(); };
        Content=root;
    }
}
