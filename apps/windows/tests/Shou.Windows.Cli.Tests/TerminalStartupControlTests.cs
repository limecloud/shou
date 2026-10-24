using Shou.Windows.Core;
using Shou.Windows.Cli;

namespace Shou.Windows.Cli.Tests;

public sealed class TerminalStartupControlTests
{
    private static StartupControlReview Review()
    {
        var now = DateTimeOffset.UtcNow;
        return new(1, "startup_control_" + new string('1', 32), StartupControlAction.Enable,
            new(@"\Generated\示例 with spaces", "sha256:" + new string('a', 64), "S-1-5-21-1000", false, true, true, true, true, false, []),
            now, now.AddMinutes(5), [], "sha256:" + new string('b', 64));
    }
    [Theory]
    [InlineData("STARTUP ENABLE ", true)]
    [InlineData("STARTUP DISABLE ", false)]
    [InlineData("startup enable ", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public async Task OnlyExactCurrentTaskActionPhraseConfirms(string? prefix, bool expected)
    {
        var review = Review();
        var confirmation = new TerminalStartupControlConfirmation((message, _) =>
        {
            Assert.Contains("示例 with spaces", message);
            Assert.Contains(review.Digest, message);
            Assert.Contains("Running instances are not stopped", message);
            return Task.FromResult(prefix is null ? null : prefix + review.Id);
        }, "en");
        Assert.Equal(expected, await confirmation.RequestAsync(review, default));
    }
    [Fact]
    public async Task StopCannotBeOverriddenByCorrectApproval()
    {
        var review = Review(); using var stop = new CancellationTokenSource();
        var confirmation = new TerminalStartupControlConfirmation((_, _) => { stop.Cancel(); return Task.FromResult<string?>("STARTUP ENABLE " + review.Id); }, "en");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => confirmation.RequestAsync(review, stop.Token));
    }
    [Fact]
    public void PublicCommandCannotBypassConfirmationOrNativeAcceptance()
    {
        var command = Assert.Single(CommandDiscovery.Matching("startup control"));
        Assert.Equal(Shou.Windows.Platform.NativeWindowsSupport.IsSupported, command.Available);
        Assert.Equal(Shou.Windows.Platform.NativeWindowsSupport.IsSupported, CliServices.StartupControlAvailable);
        Assert.Empty(command.Optional);
        Assert.Throws<ShouException>(() => CommandDiscovery.Parse(["startup", "control", "--task-path", @"\Fixture", "--action", "enable", "--review-digest", Review().Digest, "--yes"]));
    }
}
