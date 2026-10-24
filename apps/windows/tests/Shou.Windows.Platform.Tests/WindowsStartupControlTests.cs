using System.Runtime.InteropServices;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsStartupControlTests
{
    private const string Sid = "S-1-5-21-100-200-300-1001";
    private const string TaskPath = @"\Generated\Fixture";
    private static readonly DateTimeOffset Now = new(2026, 10, 23, 10, 0, 0, TimeSpan.Zero);
    private sealed class Clock : TimeProvider { public DateTimeOffset Now = WindowsStartupControlTests.Now; public override DateTimeOffset GetUtcNow() => Now; }
    private static string Xml(bool enabled, string? principal = null, string extra = "", string trigger = "<LogonTrigger/>") =>
        "<Task xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Description>private-secret</Description></RegistrationInfo>" +
        "<Triggers>" + trigger + "</Triggers><Principals><Principal id=\"Author\">" +
        (principal ?? "<UserId>" + Sid + "</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel>") +
        "</Principal></Principals><Settings><Enabled>" + enabled.ToString().ToLowerInvariant() + "</Enabled>" + extra +
        "</Settings><Actions><Exec><Command>C:\\Generated\\fixture.exe</Command><Arguments>--private-secret</Arguments></Exec></Actions></Task>";
    private sealed class Handle : IStartupTaskControlHandle
    {
        public string PathValue = TaskPath;
        public bool EnabledValue;
        public string? Owner = Sid;
        public string Extra = "";
        public int Calls;
        public bool FailPostRead;
        public Action<bool>? OnSet;
        public Action? OnRead;
        public string Path { get { OnRead?.Invoke(); return PathValue; } }
        public string Xml { get { if (FailPostRead && Calls > 0) throw new COMException("private-secret"); OnRead?.Invoke(); return WindowsStartupControlTests.Xml(EnabledValue, extra: Extra); } }
        public bool Enabled { get { OnRead?.Invoke(); return EnabledValue; } }
        public string? OwnerSid { get { OnRead?.Invoke(); return Owner; } }
        public void SetEnabled(bool enabled) { Calls++; EnabledValue = enabled; OnSet?.Invoke(enabled); }
        public void Dispose() { }
    }
    private sealed class Inspector(StartupControlTask facts) : IStartupControlInspector
    {
        public Task<StartupControlTask> InspectAsync(string taskPath, CancellationToken token) => Task.FromResult(facts);
    }
    private static Task<StartupControlReview> Review(Handle handle) => new StartupControlReviewer(
        new Inspector(WindowsStartupControlInspector.Read(handle, Sid, default)), Sid, new Clock()).InspectAsync(TaskPath, StartupControlAction.Enable);

    [Fact]
    public void FingerprintExcludesOnlyTheTaskEnabledSwitchAndDoesNotExposeDefinitionPayloads()
    {
        var off = WindowsStartupControlInspector.Parse(TaskPath, Xml(false), Sid, false, Sid);
        var on = WindowsStartupControlInspector.Parse(TaskPath, Xml(true), Sid, true, Sid);
        Assert.Equal(off.DefinitionDigest, on.DefinitionDigest);
        Assert.NotEqual(off.DefinitionDigest, WindowsStartupControlInspector.Parse(TaskPath, Xml(false, extra: "<Hidden>true</Hidden>"), Sid, false, Sid).DefinitionDigest);
        var serialized = System.Text.Json.JsonSerializer.Serialize(off, ContractJson.Options);
        Assert.DoesNotContain("private-secret", serialized);
        Assert.True(off.OwnerMatchesActor && off.PrincipalMatchesActor && off.InteractiveToken && off.LeastPrivilege);
    }

    [Theory]
    [InlineData("\r\n")]
    [InlineData("\n")]
    public void SchedulerOmittingTheDefaultEnabledSettingDoesNotChangeTheDefinitionDigest(string newline)
    {
        var disabledXml = Xml(false, extra: "<Hidden>false</Hidden>").Replace("><", ">" + newline + "  <", StringComparison.Ordinal);
        var enabledXml = disabledXml.Replace("  <Enabled>false</Enabled>" + newline, "", StringComparison.Ordinal);
        var disabled = WindowsStartupControlInspector.Parse(TaskPath, disabledXml, Sid, false, Sid);
        var enabled = WindowsStartupControlInspector.Parse(TaskPath, enabledXml, Sid, true, Sid);
        Assert.Equal(disabled.DefinitionDigest, enabled.DefinitionDigest);
        Assert.NotEqual(enabled.DefinitionDigest, WindowsStartupControlInspector.Parse(TaskPath,
            enabledXml.Replace("--private-secret", "--private-secret  ", StringComparison.Ordinal), Sid, true, Sid).DefinitionDigest);
    }

    [Theory]
    [InlineData("<UserId>S-1-5-18</UserId><LogonType>InteractiveToken</LogonType>", false, true, false)]
    [InlineData("<UserId>DOMAIN\\user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel>", false, true, true)]
    [InlineData("<GroupId>S-1-5-32-545</GroupId><LogonType>Group</LogonType>", false, false, false)]
    [InlineData("<UserId>S-1-5-21-100-200-300-1001</UserId><LogonType>Password</LogonType><RunLevel>LeastPrivilege</RunLevel>", true, false, true)]
    [InlineData("<UserId>S-1-5-21-100-200-300-1001</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel>", true, true, false)]
    [InlineData("<UserId>S-1-5-21-100-200-300-1001</UserId><UserId>S-1-5-18</UserId><LogonType>InteractiveToken</LogonType>", false, true, false)]
    public void PrincipalEligibilityNeverResolvesAccountNamesOrGuessesElevation(string principal, bool same, bool interactive, bool ordinary)
    {
        var value = WindowsStartupControlInspector.Parse(TaskPath, Xml(false, principal), Sid, false, Sid);
        Assert.Equal(same, value.PrincipalMatchesActor);
        Assert.Equal(interactive, value.InteractiveToken);
        Assert.Equal(ordinary, value.LeastPrivilege);
    }

    [Fact]
    public void OmittedRunLevelNeedsAnIndependentNativeLeastPrivilegeObservation()
    {
        var xml = Xml(false, "<UserId>" + Sid + "</UserId><LogonType>InteractiveToken</LogonType>");
        Assert.False(WindowsStartupControlInspector.Parse(TaskPath, xml, Sid, false, Sid).LeastPrivilege);
        Assert.True(WindowsStartupControlInspector.Parse(TaskPath, xml, Sid, false, Sid, 0).LeastPrivilege);
        Assert.False(WindowsStartupControlInspector.Parse(TaskPath, xml, Sid, false, Sid, 1).LeastPrivilege);
        Assert.False(WindowsStartupControlInspector.Parse(TaskPath, Xml(false), Sid, false, Sid, 1).LeastPrivilege);
        Assert.False(WindowsStartupControlInspector.Parse(TaskPath, Xml(false, "<RunLevel>LeastPrivilege</RunLevel><RunLevel>LeastPrivilege</RunLevel>"), Sid, false, Sid, 0).LeastPrivilege);
    }

    [Fact]
    public void OtherOwnersAndMicrosoftLocationsRemainProtected()
    {
        var facts = WindowsStartupControlInspector.Parse(@"\Microsoft\Fixture", Xml(false), Sid, false, "S-1-5-18");
        Assert.False(facts.OwnerMatchesActor);
        Assert.True(facts.ProtectedLocation);
    }

    [Fact]
    public void DisabledStartupTriggersDoNotPreventInspectingTheTaskSwitch()
    {
        var facts = WindowsStartupControlInspector.Parse(TaskPath, Xml(false, trigger: "<LogonTrigger><Enabled>false</Enabled></LogonTrigger>"), Sid, false, Sid);
        Assert.False(facts.Enabled);
        Assert.True(facts.InteractiveToken);
    }

    [Theory]
    [InlineData("<CalendarTrigger/>")]
    [InlineData("")]
    public void NonStartupDefinitionsCannotBeControlled(string trigger) => Assert.Throws<ShouException>(() =>
        WindowsStartupControlInspector.Parse(TaskPath, Xml(false, trigger: trigger), Sid, false, Sid));

    [Fact]
    public void DefinitionEnabledDisagreementAndEntityInputCannotBecomeControlFacts()
    {
        Assert.Throws<ShouException>(() => WindowsStartupControlInspector.Parse(TaskPath, Xml(false), Sid, true, Sid));
        Assert.Throws<ShouException>(() => WindowsStartupControlInspector.Parse(TaskPath, "<!DOCTYPE Task [<!ENTITY data SYSTEM 'file:///not-read'>]>" + Xml(false), Sid, false, Sid));
    }

    [Fact]
    public async Task SetterRunsOnceAfterExactPreflightAndReturnsIndependentPostObservation()
    {
        var handle = new Handle(); var review = await Review(handle);
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(30), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.Applied, result.Outcome);
        Assert.True(result.ObservedEnabled);
        Assert.True(result.DefinitionMatches);
        Assert.Equal(1, handle.Calls);
    }

    [Theory]
    [InlineData("definition")]
    [InlineData("enabled")]
    [InlineData("owner")]
    [InlineData("actor")]
    public async Task ChangedPreflightCannotInvokeTheTaskSetter(string change)
    {
        var handle = new Handle(); var review = await Review(handle);
        if (change == "definition") handle.Extra = "<Hidden>true</Hidden>";
        if (change == "enabled") handle.EnabledValue = true;
        if (change == "owner") handle.Owner = "S-1-5-18";
        var result = WindowsStartupControlMutation.Apply(handle, () => change == "actor" ? "S-1-5-18" : Sid,
            review, Now.AddSeconds(30), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.NotStarted, result.Outcome);
        Assert.Equal(0, handle.Calls);
    }

    [Fact]
    public async Task ActorChangeImmediatelyBeforeSetterIsRejected()
    {
        var handle = new Handle(); var review = await Review(handle); var calls = 0;
        var result = WindowsStartupControlMutation.Apply(handle, () => ++calls == 1 ? Sid : "S-1-5-18", review, Now.AddSeconds(30), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.NotStarted, result.Outcome);
        Assert.Equal("startup_actor_changed", result.Reason);
        Assert.Equal(0, handle.Calls);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(0)]
    [InlineData(301)]
    public async Task InvalidAuthorizationLifetimeCannotDispatch(int seconds)
    {
        var handle = new Handle(); var review = await Review(handle);
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(seconds), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.NotStarted, result.Outcome);
        Assert.Equal(0, handle.Calls);
    }

    [Fact]
    public async Task StopAfterSetterDoesNotSkipPostObservationOrUndoTheSwitch()
    {
        var handle = new Handle(); var review = await Review(handle); using var stop = new CancellationTokenSource();
        handle.OnSet = _ => stop.Cancel();
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(30), new Clock(), stop.Token);
        Assert.Equal(StartupControlNativeOutcome.Applied, result.Outcome);
        Assert.True(result.DefinitionMatches);
        Assert.True(result.ObservedEnabled);
        Assert.Equal(1, handle.Calls);
    }

    [Fact]
    public async Task SetterExceptionCannotBeReportedAsNotStartedOrRolledBack()
    {
        var handle = new Handle(); var review = await Review(handle);
        handle.OnSet = _ => throw new COMException("private-secret");
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(30), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.Unknown, result.Outcome);
        Assert.True(handle.EnabledValue);
        Assert.Equal(1, handle.Calls);
    }

    [Fact]
    public async Task ChangedDefinitionAfterSetterIsAnIndependentNegativeObservation()
    {
        var handle = new Handle(); var review = await Review(handle);
        handle.OnSet = _ => handle.Extra = "<Hidden>true</Hidden>";
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(30), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.Applied, result.Outcome);
        Assert.True(result.ObservedEnabled);
        Assert.False(result.DefinitionMatches);
    }

    [Fact]
    public async Task FailedPostReadRetainsAppliedReportWithUnknownObservedState()
    {
        var handle = new Handle(); var review = await Review(handle); handle.FailPostRead = true;
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(30), new Clock(), default);
        Assert.Equal(StartupControlNativeOutcome.Applied, result.Outcome);
        Assert.Null(result.ObservedEnabled);
        Assert.Null(result.DefinitionMatches);
    }

    [Fact]
    public async Task CancellationDuringPreflightPreventsSetter()
    {
        var handle = new Handle(); var review = await Review(handle); using var stop = new CancellationTokenSource();
        handle.OnRead = stop.Cancel;
        var result = WindowsStartupControlMutation.Apply(handle, () => Sid, review, Now.AddSeconds(30), new Clock(), stop.Token);
        Assert.Equal(StartupControlNativeOutcome.NotStarted, result.Outcome);
        Assert.Equal(0, handle.Calls);
    }
}
