namespace Shou.Windows.Cli.Tests;

public sealed class CommandCompletionTests
{
    [Theory]
    [InlineData("bash")]
    [InlineData("zsh")]
    [InlineData("powershell")]
    public void CompletionIncludesCurrentRegistryWithoutInvokingTheProduct(string shell)
    {
        var script = CommandCompletion.Script(shell);
        foreach (var spec in CommandDiscovery.Matching(""))
            foreach (var word in spec.Command.Split(' ')) Assert.Contains(word, script);
        Assert.DoesNotContain("Invoke-Expression", script);
        Assert.DoesNotContain("shou capabilities", script);
        Assert.Equal(script, CommandCompletion.Script(shell));
    }
}
