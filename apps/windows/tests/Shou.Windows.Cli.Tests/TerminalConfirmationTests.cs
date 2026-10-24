using System.Collections.Immutable;
using Shou.Windows.Cli;
using Shou.Windows.Core;

namespace Shou.Windows.Cli.Tests;

public sealed class TerminalConfirmationTests
{
    private static readonly string PlanId = "plan_" + new string('1', 32);
    private static CleanupReview Review(CleanupAction action = CleanupAction.Permanent) => new(PlanId, "sha256:" + new string('2', 64), action,
        DateTimeOffset.UtcNow + TimeSpan.FromMinutes(1), [new("item_" + new string('3', 32), WindowsPath.Parse("C:/Users/Dev/项目 with spaces/target"), "dev.cache", "high", 8192, 2)]);

    [Theory]
    [InlineData(CleanupAction.Permanent, "PURGE ", true)]
    [InlineData(CleanupAction.Trash, "TRASH ", true)]
    [InlineData(CleanupAction.Permanent, "TRASH ", false)]
    [InlineData(CleanupAction.Trash, "PURGE ", false)]
    [InlineData(CleanupAction.Permanent, "purge ", false)]
    public async Task ConfirmationRequiresTheCurrentPlanAndExactActionPhrase(CleanupAction action, string prefix, bool expected)
    {
        string? displayed = null;
        var confirmation = new TerminalCleanupConfirmation((message, _) => { displayed = message; return Task.FromResult<string?>(prefix + PlanId); }, "en");
        Assert.Equal(expected, await confirmation.RequestAsync(Review(action), default));
        Assert.NotNull(displayed);
        Assert.Contains(PlanId, displayed);
        Assert.Contains("sha256:" + new string('2', 64), displayed);
        Assert.Contains("项目 with spaces", displayed);
        Assert.Contains("8192", displayed);
        Assert.Contains("high", displayed);
        Assert.Equal(action == CleanupAction.Permanent, displayed.Contains("Permanent deletion cannot be undone.", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("yes")]
    [InlineData("PURGE plan_old")]
    [InlineData("PURGE")]
    public async Task MissingOrUnrelatedInputDoesNotConfirm(string? response)
    {
        var confirmation = new TerminalCleanupConfirmation((_, _) => Task.FromResult(response), "en");
        Assert.False(await confirmation.RequestAsync(Review(), default));
    }

    [Fact]
    public async Task LocalePromptUsesSharedResourcesAndCannotRunTerminalEscapeSequences()
    {
        var review = Review();
        review = review with { Items = review.Items.SetItem(0, review.Items[0] with { RuleId = "test\u001b[2J" }) };
        var confirmation = new TerminalCleanupConfirmation((message, _) =>
        {
            Assert.Contains("请核对", message);
            Assert.Contains("无法撤销", message);
            Assert.DoesNotContain('\u001b', message);
            Assert.Contains("\\u001B", message);
            return Task.FromResult<string?>("PURGE " + PlanId);
        }, "zh-CN");
        Assert.True(await confirmation.RequestAsync(review, default));
    }

    [Fact]
    public async Task ACorrectPhraseCannotConfirmAfterCallerCancellation()
    {
        using var cancellation = new CancellationTokenSource();
        var confirmation = new TerminalCleanupConfirmation((_, _) =>
        {
            cancellation.Cancel();
            return Task.FromResult<string?>("PURGE " + PlanId);
        }, "en");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => confirmation.RequestAsync(Review(), cancellation.Token));
    }

    [Fact]
    public async Task NoInteractiveTerminalDoesNotFallBackToPipedApproval()
    {
        var confirmation = new TerminalCleanupConfirmation((_, _) => throw new ShouException("confirmation_required", "fixture has no TTY"), "en");
        Assert.Equal("confirmation_required", (await Assert.ThrowsAsync<ShouException>(() => confirmation.RequestAsync(Review(), default))).Code);
    }

    [Fact]
    public async Task OversizedInputCannotSupplyConfirmation()
    {
        var confirmation = new TerminalCleanupConfirmation((_, _) => Task.FromResult<string?>("PURGE " + PlanId + new string(' ', 257)), "en");
        Assert.False(await confirmation.RequestAsync(Review(), default));
    }

    [Fact]
    public void CandidateSelectionIsExplicitRepeatedBoundedAndDoesNotSelectEverything()
    {
        var scan = "scan_" + new string('1', 32);
        var first = "candidate_" + new string('2', 32);
        var second = "candidate_" + new string('3', 32);
        var request = CommandDiscovery.Parse(["plan", "create", "--scan-id", scan, "--candidate", first, "--candidate", second, "--mode", "permanent"]);
        request.Validate();
        Assert.Equal(new[] { first, second }, request.All("candidate"));
        Assert.Equal(CleanupAction.Permanent, request.Action);
        Assert.Throws<ShouException>(() => CommandDiscovery.Parse(["plan", "create", "--scan-id", scan]));
        request = CommandDiscovery.Parse(["plan", "create", "--scan-id", scan, "--candidate", first]);
        Assert.Equal(CleanupAction.Trash, request.Action);
        var repeated = CommandDiscovery.Parse(["plan", "create", "--scan-id", scan, "--candidate", first, "--candidate", first]);
        Assert.Throws<ShouException>(() => repeated.Validate());
    }

    [Fact]
    public void DiscoveryDoesNotAdvertiseUnacceptedNativeExecutionAsAvailable()
    {
        var spec = Assert.Single(CommandDiscovery.Matching("plan execute"));
        Assert.Equal(Shou.Windows.Platform.NativeWindowsSupport.IsSupported, spec.Available);
        Assert.Equal(CliServices.MutationAvailable ? null : "unsupported_native_host", spec.UnavailableReason);
        Assert.Equal(Shou.Windows.Platform.NativeWindowsSupport.IsSupported, CliServices.MutationAvailable);
        Assert.Equal(!CliServices.MutationAvailable, CommandDiscovery.Help("plan execute").Contains("Unavailable", StringComparison.Ordinal));
    }
}
