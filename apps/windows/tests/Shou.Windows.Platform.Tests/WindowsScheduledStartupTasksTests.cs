using System.Runtime.InteropServices;
using System.Text.Json;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsScheduledStartupTasksTests
{
    private const string Namespace = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    private static string Xml(string triggers = "<LogonTrigger/>", string actions = "<Exec><Command>C:\\Program Files\\示例\\app.exe</Command><Arguments>--password=private-secret</Arguments></Exec>") =>
        $"<Task xmlns=\"{Namespace}\"><RegistrationInfo><Description>private-secret</Description></RegistrationInfo><Triggers>{triggers}</Triggers><Actions>{actions}</Actions></Task>";
    private static string NonStartup => Xml("<CalendarTrigger/>");

    [Theory]
    [InlineData("<LogonTrigger/>")]
    [InlineData("<BootTrigger/>")]
    [InlineData("<CalendarTrigger/><LogonTrigger/>")]
    public void BootAndLogonDefinitionsExposeOnlyExactRegistrationAndExecutableClue(string triggers)
    {
        var item = WindowsScheduledStartupTasks.Parse(@"\Generated\示例", Xml(triggers));
        Assert.NotNull(item);
        Assert.Equal(StartupSource.ScheduledTasks, item.Source);
        Assert.Equal(@"\Generated\示例", item.RegistrationKey);
        Assert.Equal("示例", item.Name);
        Assert.Equal(@"C:\Program Files\示例\app.exe", item.ExecutablePath);
        Assert.Null(item.DefinitionPath);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(item, ContractJson.Options));
    }

    [Theory]
    [InlineData("<CalendarTrigger/>")]
    [InlineData("<EventTrigger/>")]
    [InlineData("")]
    [InlineData("<LogonTrigger xmlns=\"urn:other\"/>")]
    public void OtherTriggersDoNotBecomeStartupRegistrations(string triggers) => Assert.Null(WindowsScheduledStartupTasks.Parse(@"\Fixture", Xml(triggers)));

    [Theory]
    [InlineData("<Exec><Command>%LOCALAPPDATA%\\app.exe</Command></Exec>")]
    [InlineData("<Exec><Command>relative.exe</Command></Exec>")]
    [InlineData("<Exec><Command>C:\\app.cmd</Command></Exec>")]
    [InlineData("<Exec><Command>C:\\app.exe --secret</Command></Exec>")]
    [InlineData("<Exec><Command>C:\\one.exe</Command><Command>C:\\two.exe</Command></Exec>")]
    [InlineData("<ComHandler><ClassId>private-secret</ClassId></ComHandler>")]
    [InlineData("<Exec><Command>C:\\one.exe</Command></Exec><Exec><Command>C:\\two.exe</Command></Exec>")]
    public void UnresolvedAndMultipleActionsNeverGuessAnApplicationOrExposePayloads(string actions)
    {
        var item = WindowsScheduledStartupTasks.Parse(@"\Fixture", Xml(actions: actions));
        Assert.NotNull(item);
        Assert.Null(item.ExecutablePath);
        Assert.NotEmpty(item.Issues);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(item, ContractJson.Options));
    }

    [Fact]
    public void MalformedOversizedOrEntityDefinitionsAreRejected()
    {
        var invalid = new[]
        {
            "<Task>", "<Task/>", "<!DOCTYPE Task [<!ENTITY secret SYSTEM 'file:///nonexistent'>]>" + Xml(),
            Xml().Replace("<Triggers>", "<Triggers/><Triggers>"), Xml().Replace("<Actions>", "<Actions/><Actions>"),
            Xml() + new string(' ', WindowsScheduledStartupTasks.MaximumXmlCharacters)
        };
        foreach (var xml in invalid)
            Assert.Equal("invalid_registration_metadata", Assert.Throws<ShouException>(() => WindowsScheduledStartupTasks.Parse(@"\Fixture", xml)).Code);
    }

    [Theory]
    [InlineData("relative")]
    [InlineData("\\")]
    [InlineData("\\Folder\\..\\Task")]
    [InlineData("\\Folder\\\\Task")]
    [InlineData("\\Folder/Task")]
    public void SchedulerIdentifiersAreNotInterpretedAsFilesystemPaths(string path) =>
        Assert.Throws<ShouException>(() => WindowsScheduledStartupTasks.Parse(path, Xml()));

    private sealed class Reader(Dictionary<string, Folder> folders) : IScheduledTaskReader
    {
        public List<string> Opened { get; } = [];
        public IScheduledTaskFolder OpenFolder(string path)
        {
            Opened.Add(path);
            return folders.TryGetValue(path, out var folder) ? folder : throw new COMException("Not accessible", unchecked((int)0x80070005));
        }
        public void Dispose() { }
    }
    private sealed class Folder((string Path, string Xml)[]? tasks = null, string[]? folders = null) : IScheduledTaskFolder
    {
        public bool Disposed { get; private set; }
        public int TaskReads { get; private set; }
        public Action? OnRead { get; init; }
        public bool Changed { get; init; }
        public ShouException? Failure { get; init; }
        public int TaskCount => (tasks?.Length ?? 0) + (Changed && TaskReads > 0 ? 1 : 0);
        public int FolderCount => folders?.Length ?? 0;
        public Func<IScheduledTaskProperties>? PropertiesOverride { get; init; }
        public ScheduledTaskRead ReadTask(int index, CancellationToken token)
        {
            TaskReads++;
            OnRead?.Invoke();
            if (Failure is { } failure) throw failure;
            var task = tasks![index - 1];
            return WindowsScheduledStartupTasks.ReadTask(PropertiesOverride?.Invoke() ?? new Properties(task.Path, task.Xml), token);
        }
        public string ReadFolderPath(int index) => folders![index - 1];
        public void Dispose() => Disposed = true;
    }

    private sealed class Properties(string path = @"\Fixture", string? xml = null) : IScheduledTaskProperties
    {
        public Func<string> PathValue { get; init; } = () => path;
        public Func<string> XmlValue { get; init; } = () => xml ?? WindowsScheduledStartupTasksTests.Xml();
        public Func<bool> EnabledValue { get; init; } = () => true;
        public Func<int> StateValue { get; init; } = () => 3;
        public Action? AfterRead { get; init; }
        public int StatusReads { get; private set; }
        public int DefinitionReads { get; private set; }
        private T Read<T>(Func<T> value, bool status)
        {
            if (status) StatusReads++; else DefinitionReads++;
            var result = value();
            AfterRead?.Invoke();
            return result;
        }
        public string Path => Read(PathValue, false);
        public string Xml => Read(XmlValue, false);
        public bool Enabled => Read(EnabledValue, true);
        public int State => Read(StateValue, true);
    }

    [Theory]
    [InlineData(0, ScheduledTaskState.Unknown)]
    [InlineData(1, ScheduledTaskState.Disabled)]
    [InlineData(2, ScheduledTaskState.Queued)]
    [InlineData(3, ScheduledTaskState.Ready)]
    [InlineData(4, ScheduledTaskState.Running)]
    public void PublicTaskStateValuesAreObservedWithoutExposingDefinitionPayloads(int value, ScheduledTaskState expected)
    {
        var properties = new Properties { StateValue = () => value };
        var result = WindowsScheduledStartupTasks.ReadTask(properties, default);
        Assert.Equal(new ScheduledTaskStatus(true, expected), result.Registration!.ScheduledTask);
        Assert.Equal(4, properties.StatusReads);
        Assert.Equal(4, properties.DefinitionReads);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(result, ContractJson.Options));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void TaskEnabledDoesNotInferTriggerConditionsOrOverrideItsSeparatelyObservedEngineState(bool enabled)
    {
        var result = WindowsScheduledStartupTasks.ReadTask(new Properties { EnabledValue = () => enabled, StateValue = () => 4 }, default);
        Assert.Equal(new ScheduledTaskStatus(enabled, ScheduledTaskState.Running), result.Registration!.ScheduledTask);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ChangingTaskStatusPreservesRegistrationButDoesNotPublishEitherStatus(bool changeEnablement)
    {
        var enabledReads = 0;
        var stateReads = 0;
        var properties = new Properties
        {
            EnabledValue = () => !changeEnablement || ++enabledReads == 1,
            StateValue = () => changeEnablement || ++stateReads == 1 ? 3 : 4
        };
        var result = WindowsScheduledStartupTasks.ReadTask(properties, default);
        Assert.Null(result.Registration!.ScheduledTask);
        Assert.Contains("scheduled_task_status_changed", result.Registration.Issues);
        Assert.Equal(4, properties.DefinitionReads);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(5)]
    [InlineData(int.MaxValue)]
    public void UnknownFutureNativeValuesDoNotBecomeInventedStatuses(int state)
    {
        var result = WindowsScheduledStartupTasks.ReadTask(new Properties { StateValue = () => state }, default);
        Assert.Null(result.Registration!.ScheduledTask);
        Assert.Contains("scheduled_task_status_invalid", result.Registration.Issues);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void StatusAccessFailureRetainsRegistrationAfterRecheckingItsDefinition(bool failEnablement)
    {
        var properties = new Properties
        {
            EnabledValue = () => failEnablement ? throw new UnauthorizedAccessException("private-secret") : true,
            StateValue = () => throw new COMException("private-secret", unchecked((int)0x80070005))
        };
        var result = WindowsScheduledStartupTasks.ReadTask(properties, default);
        Assert.Null(result.Registration!.ScheduledTask);
        Assert.Contains("scheduled_task_status_unavailable", result.Registration.Issues);
        Assert.Equal(4, properties.DefinitionReads);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(result, ContractJson.Options));
    }

    [Fact]
    public void UnavailableTaskStatusIsAnExplicitSourceGapWithoutLosingEarlierRegistrations()
    {
        var root = new Folder([(@"\Fixture", Xml())])
        {
            PropertiesOverride = () => new Properties { StateValue = () => throw new COMException("Unavailable") }
        };
        using var reader = new Reader(new() { ["\\"] = root });
        var result = WindowsScheduledStartupTasks.Read(reader, 10, default);
        Assert.Single(result.Registrations);
        Assert.Equal(StartupSourceState.Partial, result.Sources[0].State);
        Assert.Contains("scheduled_task_status_unavailable", result.Sources[0].Issues);
        Assert.True(root.Disposed);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void DefinitionChangesDiscardTheRegistrationAndItsTaskObservation(bool changePath)
    {
        var pathReads = 0;
        var xmlReads = 0;
        var properties = new Properties
        {
            PathValue = () => !changePath || ++pathReads == 1 ? @"\Fixture" : @"\Other",
            XmlValue = () => changePath || ++xmlReads == 1 ? Xml() : Xml("<BootTrigger/>")
        };
        Assert.Equal("registration_changed", Assert.Throws<ShouException>(() => WindowsScheduledStartupTasks.ReadTask(properties, default)).Code);
    }

    [Fact]
    public void AStatusFailureDoesNotBypassDefinitionRevalidation()
    {
        var reads = 0;
        var properties = new Properties
        {
            XmlValue = () => ++reads == 1 ? Xml() : NonStartup,
            StateValue = () => throw new UnauthorizedAccessException()
        };
        Assert.Equal("registration_changed", Assert.Throws<ShouException>(() => WindowsScheduledStartupTasks.ReadTask(properties, default)).Code);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void NonStartupOrInvalidDefinitionsDoNotQueryTaskStatus(bool malformed)
    {
        var properties = new Properties(xml: malformed ? "<Task/>" : NonStartup);
        if (malformed) Assert.Throws<ShouException>(() => WindowsScheduledStartupTasks.ReadTask(properties, default));
        else Assert.Null(WindowsScheduledStartupTasks.ReadTask(properties, default).Registration);
        Assert.Equal(0, properties.StatusReads);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(5)]
    [InlineData(6)]
    [InlineData(7)]
    [InlineData(8)]
    public void CancellationAtEveryNativeObservationBoundaryPreventsPublication(int cancelAt)
    {
        using var cancelled = new CancellationTokenSource();
        var reads = 0;
        var properties = new Properties { AfterRead = () => { if (++reads == cancelAt) cancelled.Cancel(); } };
        Assert.ThrowsAny<OperationCanceledException>(() => WindowsScheduledStartupTasks.ReadTask(properties, cancelled.Token));
    }

    [Fact]
    public void OneBudgetCountsNonStartupTasksAndFolderTraversal()
    {
        var root = new Folder([(@"\Calendar", NonStartup), (@"\Startup", Xml())], [@"\Nested"]);
        var nested = new Folder([(@"\Nested\Task", Xml())]);
        using var reader = new Reader(new() { ["\\"] = root, [@"\Nested"] = nested });
        var result = WindowsScheduledStartupTasks.Read(reader, 6, default);
        Assert.Equal(StartupSourceState.Complete, result.Sources[0].State);
        Assert.Equal(6, result.Sources[0].InspectedEntries);
        Assert.Equal(2, result.Registrations.Length);
        Assert.True(root.Disposed && nested.Disposed);
    }

    [Fact]
    public void EntryLimitRetainsPublishedTasksAndDoesNotReadTheNextDefinition()
    {
        var root = new Folder([(@"\One", Xml()), (@"\Two", Xml())]);
        using var reader = new Reader(new() { ["\\"] = root });
        var result = WindowsScheduledStartupTasks.Read(reader, 2, default);
        Assert.Single(result.Registrations);
        Assert.Equal(1, root.TaskReads);
        Assert.Equal(2, result.Sources[0].InspectedEntries);
        Assert.Contains("entry_limit", result.Sources[0].Issues);
    }

    [Fact]
    public void InaccessibleSubfolderDoesNotEraseEarlierTasksOrPretendCoverageIsComplete()
    {
        using var reader = new Reader(new() { ["\\"] = new([(@"\One", Xml())], [@"\Denied"]) });
        var result = WindowsScheduledStartupTasks.Read(reader, 10, default);
        Assert.Single(result.Registrations);
        Assert.Equal(StartupSourceState.Partial, result.Sources[0].State);
        Assert.Contains("permission_denied", result.Sources[0].Issues);
    }

    [Fact]
    public void ChangedCollectionAndChangedDefinitionHaveExplicitGaps()
    {
        var changed = new Folder([(@"\One", Xml())]) { Changed = true };
        using var reader = new Reader(new() { ["\\"] = changed });
        var result = WindowsScheduledStartupTasks.Read(reader, 10, default);
        Assert.Contains("source_changed", result.Sources[0].Issues);
        using var changedReader = new Reader(new() { ["\\"] = new([(@"\One", Xml())]) { Failure = new("registration_changed", "Changed") } });
        var failed = WindowsScheduledStartupTasks.Read(changedReader, 10, default);
        Assert.Empty(failed.Registrations);
        Assert.Contains("registration_changed", failed.Sources[0].Issues);
    }

    [Fact]
    public void ForeignTaskOrFolderPathsCannotExpandTraversal()
    {
        using var reader = new Reader(new() { ["\\"] = new([(@"\Other\Task", Xml())], [@"\Other\Nested"]) });
        var result = WindowsScheduledStartupTasks.Read(reader, 10, default);
        Assert.Empty(result.Registrations);
        Assert.Equal(new[] { "\\" }, reader.Opened);
        Assert.Contains("source_changed", result.Sources[0].Issues);
        Assert.Contains("registration_changed", result.Sources[0].Issues);
    }

    [Fact]
    public void CancelledNativeReadCannotPublishAndReleasesTheCurrentFolder()
    {
        using var cancelled = new CancellationTokenSource();
        var root = new Folder([(@"\One", Xml())]) { OnRead = cancelled.Cancel };
        using var reader = new Reader(new() { ["\\"] = root });
        Assert.ThrowsAny<OperationCanceledException>(() => WindowsScheduledStartupTasks.Read(reader, 10, cancelled.Token));
        Assert.True(root.Disposed);
        Assert.Equal(1, root.TaskReads);
    }

    [Fact]
    public void PreCancellationNeverConnectsToTheScheduler()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => WindowsScheduledStartupTasks.Read(10, cancelled.Token));
    }

    [Fact]
    public void DepthLimitMakesDeepSubtreesExplicitlyPartial()
    {
        var folders = new Dictionary<string, Folder>();
        var path = "\\";
        for (var depth = 0; depth <= WindowsScheduledStartupTasks.MaximumDepth; depth++)
        {
            var child = path == "\\" ? @"\F" : path + @"\F";
            folders[path] = new(folders: [child]);
            path = child;
        }
        using var reader = new Reader(folders);
        var result = WindowsScheduledStartupTasks.Read(reader, 1000, default);
        Assert.Equal(WindowsScheduledStartupTasks.MaximumDepth + 1, reader.Opened.Count);
        Assert.Contains("depth_limit", result.Sources[0].Issues);
    }

    [WindowsFact]
    public void LocalSchedulerReadIsBoundedAndNeverSerializesDefinitionArguments()
    {
        var result = WindowsScheduledStartupTasks.Read(10, default);
        Assert.Single(result.Sources);
        Assert.InRange(result.Sources[0].InspectedEntries!.Value, 1, 10);
        Assert.All(result.Registrations, item => Assert.Equal(StartupSource.ScheduledTasks, item.Source));
        Assert.All(result.Registrations.Where(item => item.ScheduledTask is not null), item => Assert.True(Enum.IsDefined(item.ScheduledTask!.State)));
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(result, ContractJson.Options));
        foreach (var item in document.RootElement.GetProperty("registrations").EnumerateArray())
        {
            Assert.False(item.TryGetProperty("arguments", out _));
            Assert.False(item.TryGetProperty("xml", out _));
            Assert.False(item.TryGetProperty("command_line", out _));
        }
    }
}
