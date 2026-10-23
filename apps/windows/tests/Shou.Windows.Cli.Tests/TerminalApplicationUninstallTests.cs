using Shou.Windows.Cli;
using Shou.Windows.Core;

namespace Shou.Windows.Cli.Tests;

public sealed class TerminalApplicationUninstallTests
{
    private const string PlanId = "uninstall_plan_11111111111111111111111111111111";
    private static ApplicationUninstallPlan Plan()
    {
        var now = DateTimeOffset.UtcNow;
        var application = new InstalledApplication("application_" + new string('0', 64), ApplicationSource.CurrentUserRegistry,
            "{00000000-0000-0000-0000-000000000001}", "示例 with spaces", "1.0", null, null, null, false, [], true);
        var review = new ApplicationUninstallReview(application, new(new(ApplicationInstallerKind.Msi, application.RegistrationKey,
            MsiInstallationContext.UserUnmanaged, "S-1-5-21-1000", "{00000000-0000-0000-0000-000000000002}"),
            application.Name, "1.0", null, null, false, []), new(ActivityState.Idle, "fixture"), now, [], ["installer_may_stop_managed_processes"], "sha256:" + new string('1', 64));
        return new(1, PlanId, "S-1-5-21-1000", now, now + TimeSpan.FromMinutes(15), review, true, "sha256:" + new string('2', 64));
    }

    [Theory]
    [InlineData("UNINSTALL ", true)]
    [InlineData("PURGE ", false)]
    [InlineData("uninstall ", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public async Task OnlyTheCurrentUninstallPhraseConfirmsAndExactInstallerFactsAreShown(string? prefix, bool expected)
    {
        var confirmation = new TerminalApplicationUninstallConfirmation((message, _) =>
        {
            Assert.Contains(PlanId, message);
            Assert.Contains("示例 with spaces", message);
            Assert.Contains("sha256:" + new string('2', 64), message);
            Assert.Contains("{00000000-0000-0000-0000-000000000002}", message);
            Assert.Contains("stop managed apps or services", message);
            Assert.Contains("cannot restore", message);
            return Task.FromResult(prefix is null ? null : prefix + PlanId);
        }, "en");
        Assert.Equal(expected, await confirmation.RequestAsync(Plan(), default));
    }

    [Fact]
    public async Task ChinesePromptEscapesTerminalControlTextAndRejectsOversizedApproval()
    {
        var plan = Plan();
        plan = plan with { Review = plan.Review with { Application = plan.Review.Application with { Name = "test\u001b[2J" } } };
        var confirmation = new TerminalApplicationUninstallConfirmation((message, _) =>
        {
            Assert.Contains("系统安装程序", message);
            Assert.Contains("无法恢复", message);
            Assert.DoesNotContain('\u001b', message);
            return Task.FromResult<string?>("UNINSTALL " + PlanId + new string(' ', 257));
        }, "zh-CN");
        Assert.False(await confirmation.RequestAsync(plan, default));
    }

    [Fact]
    public async Task CancellationCannotBeOverriddenByACorrectPhrase()
    {
        using var cancellation = new CancellationTokenSource();
        var confirmation = new TerminalApplicationUninstallConfirmation((_, _) =>
        { cancellation.Cancel(); return Task.FromResult<string?>("UNINSTALL " + PlanId); }, "en");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => confirmation.RequestAsync(Plan(), cancellation.Token));
    }

    [Fact]
    public void ExecutionDiscoveryRemainsDisabledAndHasNoUnattendedApprovalOption()
    {
        var command = Assert.Single(CommandDiscovery.Matching("applications uninstall"));
        Assert.False(command.Available);
        Assert.False(CliServices.ApplicationUninstallAvailable);
        Assert.Equal("native_acceptance_pending", command.UnavailableReason);
        Assert.Equal(new[] { "uninstall-plan-id" }, command.Required);
        Assert.Empty(command.Optional);
        Assert.Throws<ShouException>(() => CommandDiscovery.Parse(["applications", "uninstall", "--uninstall-plan-id", PlanId, "--yes"]));
    }
}
