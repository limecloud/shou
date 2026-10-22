namespace Shou.Windows.Services;

public sealed record UiChoice(string Id, string Name);

/// <summary>Authentication identifiers remain invariant when display language changes.</summary>
public static class AiAuthenticationChoices
{
    public static UiChoice[] Create() => [new("keychain", UiText.T("系统凭据")), new("local", UiText.T("本地私有文件")), new("environment", UiText.T("指定环境变量")), new("none", UiText.T("无需认证"))];
}
