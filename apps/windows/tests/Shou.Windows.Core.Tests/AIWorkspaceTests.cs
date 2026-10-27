using System.Text;

namespace Shou.Windows.Core.Tests;

public sealed class AIWorkspaceTests
{
    [Theory]
    [InlineData("mcp", "fixture")]
    [InlineData("configuration", "fixture-provider")]
    public void JsonSummariesExposeOnlyDeclarationNames(string kind, string expected)
    {
        var data = Encoding.UTF8.GetBytes("""{"mcpServers":{"fixture":{"command":"secret-command","args":["secret-argument"],"env":{"TOKEN":"secret-key"}}},"provider":{"fixture-provider":{"apiKey":"secret-key"}}}""");
        Assert.Equal(new[] { expected }, AIWorkspaceSummary.Names(data, "json", kind).ToArray());
    }
    [Theory]
    [InlineData("mcp", "fixture")]
    [InlineData("configuration", "fixture-provider")]
    public void TomlSummariesReadDeclarationsWithoutValues(string kind, string expected)
    {
        var data = Encoding.UTF8.GetBytes("[mcp_servers.fixture]\nenv={TOKEN=\"secret-key\"}\n[model_providers.fixture-provider]\napi_key=\"secret-key\"\n");
        Assert.Equal(new[] { expected }, AIWorkspaceSummary.Names(data, "toml", kind).ToArray());
    }
    [Fact]
    public void SummariesRejectOversizedOrNonObjectJson()
    {
        Assert.Throws<ShouException>(() => AIWorkspaceSummary.Names(new byte[262_145], "json", "mcp"));
        Assert.Throws<ShouException>(() => AIWorkspaceSummary.Names(Encoding.UTF8.GetBytes("[]"), "json", "mcp"));
        Assert.Throws<ShouException>(() => AIWorkspaceSummary.Names(Encoding.UTF8.GetBytes("value='''\n[mcp_servers.fake]\n'''"), "toml", "mcp"));
    }
}
