using System.Collections.Immutable;
using Shou.Windows.Core;
using Fixture = Shou.Windows.Core.Tests.CleanupTests.Fixture;

namespace Shou.Windows.Core.Tests;

public sealed class CleanupActivityTests
{
    private sealed class Files : ICleanupFileUse
    {
        public ImmutableArray<WindowsPath> Paths;
        public Func<CancellationToken, Task<ActivityObservation>> Read = _ => Task.FromResult(new ActivityObservation(ActivityState.Idle));
        public Task<ActivityObservation> InspectAsync(ImmutableArray<WindowsPath> paths, CancellationToken cancellationToken)
        { Paths = paths; return Read(cancellationToken); }
    }
    private sealed class Processes : IProcessInventory
    {
        public int Calls;
        public ImmutableArray<string> Names;
        public Func<CancellationToken, Task<ProcessInventory>> Read = _ => Task.FromResult(new ProcessInventory(true, []));
        public Task<ProcessInventory> InspectAsync(ImmutableArray<string> executableNames, CancellationToken cancellationToken) { Calls++; Names = executableNames; return Read(cancellationToken); }
    }

    [Theory]
    [InlineData("cargo.exe")]
    [InlineData("RuSt-AnAlYzEr.ExE")]
    [InlineData("node.exe")]
    [InlineData("MSBuild.exe")]
    [InlineData("dotnet.exe")]
    [InlineData("javaw.exe")]
    [InlineData("python3.exe")]
    [InlineData("clang-cl.exe")]
    public async Task ExactKnownToolNamesBlockEvenWhenRegisteredFilesAreNotInUse(string name)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var files = new Files();
        var processes = new Processes { Read = _ => Task.FromResult(new ProcessInventory(true, [new(42, name, plan.Items[0].Context.Single(entry => entry.Path == plan.Items[0].Path.Parent))])) };
        var result = await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default);
        Assert.Equal(ActivityState.Active, result.State);
        Assert.Equal("known_build_process_running", result.Reason);
        Assert.Contains(plan.Items[0].Path.Parent!.Append("Cargo.toml"), files.Paths);
        Assert.Contains(plan.Items[0].Path.Append("cache.bin"), files.Paths);
        Assert.Equal(files.Paths.Length, files.Paths.Distinct().Count());
        Assert.Contains("node.exe", processes.Names);
    }

    [Theory]
    [InlineData("C:/Users/Dev/Projects/project-0", ActivityState.Active)]
    [InlineData("C:/Users/Dev/Projects/project-0/src", ActivityState.Active)]
    [InlineData("C:/Users/Dev/Projects", ActivityState.Active)]
    [InlineData("c:/users/dev/projects/PROJECT-0", ActivityState.Active)]
    [InlineData("C:/Users/Dev/Projects/project-01", ActivityState.Idle)]
    [InlineData("D:/Unrelated", ActivityState.Idle)]
    public async Task ToolWorkingDirectoryMustOverlapTheProjectRatherThanJustSharingAStringPrefix(string path, ActivityState expected)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var directory = plan.Items[0].Context.Single(entry => entry.Path == plan.Items[0].Path.Parent) with { Path = WindowsPath.Parse(path) };
        var processes = new Processes { Read = _ => Task.FromResult(new ProcessInventory(true, [new(42, "node.exe", directory)])) };
        Assert.Equal(expected, (await new CleanupActivityService(new Files(), processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
    }

    [Fact]
    public async Task MissingOrForeignScopeIsUnknownButExitedProcessesAndTheShouHostDoNotBlockThemselves()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var processes = new Processes { Read = _ => Task.FromResult(new ProcessInventory(true, [new(42, "dotnet.exe")])) };
        var service = new CleanupActivityService(new Files(), processes);
        Assert.Equal(ActivityState.Unknown, (await service.InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
        var directory = plan.Items[0].Context[0] with { Identity = new(1, new string('0', 32), "S-1-5-21-2000") };
        processes.Read = _ => Task.FromResult(new ProcessInventory(true, [new(42, "dotnet.exe", directory)]));
        Assert.Equal(ActivityState.Unknown, (await service.InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
        processes.Read = _ => Task.FromResult(new ProcessInventory(true, [new(42, "dotnet.exe", Exited: true), new(43, "dotnet.exe", IsCurrentProcess: true)]));
        Assert.Equal(ActivityState.Idle, (await service.InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
    }

    [Theory]
    [InlineData("D:/Unrelated", ActivityState.Idle)]
    [InlineData("C:/Users/Dev/Projects/project-01", ActivityState.Idle)]
    [InlineData("C:/Users/Dev/Projects/project-0", ActivityState.Unknown)]
    [InlineData("C:/Users/Dev/Projects", ActivityState.Unknown)]
    public async Task VerifiedForeignOwnerDirectoriesDoNotGloballyBlockUnrelatedProjects(string path, ActivityState expected)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var directory = plan.Items[0].Context[0] with
        { Path = WindowsPath.Parse(path), Identity = new(1, new string('0', 32), "S-1-5-32-544") };
        var processes = new Processes { Read = _ => Task.FromResult(new ProcessInventory(true, [new(42, "node.exe", directory)])) };
        Assert.Equal(expected, (await new CleanupActivityService(new Files(), processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
    }

    [Fact]
    public async Task CompleteNonMatchingSnapshotAndIdleFilesAreBothRequiredForIdle()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var files = new Files();
        var processes = new Processes
        {
            Read = _ => Task.FromResult(new ProcessInventory(true, [new(7, "cargo.exe.backup"), new(9, "not-node.exe"), new(12, "shou.exe")]))
        };
        Assert.Equal(ActivityState.Idle, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
        processes.Read = _ => Task.FromResult(new ProcessInventory(false, []));
        Assert.Equal(ActivityState.Unknown, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
    }

    [Theory]
    [InlineData(ActivityState.Unknown, true, ActivityState.Unknown)]
    [InlineData(ActivityState.Active, false, ActivityState.Active)]
    [InlineData(ActivityState.Idle, false, ActivityState.Unknown)]
    public async Task ActiveEvidenceAndUnknownCoverageDoNotBecomeIdle(ActivityState fileState, bool complete, ActivityState expected)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var files = new Files { Read = _ => Task.FromResult(new ActivityObservation(fileState)) };
        var processes = new Processes { Read = _ => Task.FromResult(new ProcessInventory(complete, [])) };
        Assert.Equal(expected, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
        files.Read = _ => Task.FromResult(new ActivityObservation(ActivityState.Unknown));
        processes.Read = _ => Task.FromResult(new ProcessInventory(false, [new(99, "cargo.exe", plan.Items[0].Context.Single(entry => entry.Path == plan.Items[0].Path.Parent))]));
        Assert.Equal(ActivityState.Active, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("path")]
    [InlineData("control")]
    [InlineData("null")]
    [InlineData("default")]
    [InlineData("too_many")]
    public async Task InvalidInventoryCannotProveTheAbsenceOfActivity(string kind)
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var observations = kind switch
        {
            "duplicate" => ImmutableArray.Create(new ProcessObservation(7, "unrelated.exe"), new ProcessObservation(7, "another.exe")),
            "path" => [new ProcessObservation(7, "C:/cargo.exe")],
            "control" => [new ProcessObservation(7, "tool\n.exe")],
            "null" => [null!],
            "too_many" => Enumerable.Range(0, CleanupActivityService.MaximumProcesses + 1).Select(index => new ProcessObservation((uint)index, "unrelated.exe")).ToImmutableArray(),
            _ => default
        };
        var processes = new Processes { Read = _ => Task.FromResult(new ProcessInventory(true, observations)) };
        var result = await new CleanupActivityService(new Files(), processes).InspectAsync(fixture.Workspace, plan.Items[0], default);
        Assert.Equal(ActivityState.Unknown, result.State);
        Assert.Equal("process_inventory_invalid", result.Reason);
    }

    [Fact]
    public async Task InaccessibleAdaptersAndInvalidFileResultsRemainUnknown()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var files = new Files { Read = _ => throw new UnauthorizedAccessException() };
        var processes = new Processes();
        Assert.Equal(ActivityState.Unknown, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
        files.Read = _ => Task.FromResult(new ActivityObservation((ActivityState)99));
        Assert.Equal(ActivityState.Unknown, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
        files.Read = _ => Task.FromResult(new ActivityObservation(ActivityState.Idle));
        processes.Read = _ => throw new ShouException("permission_denied", "fixture");
        Assert.Equal(ActivityState.Unknown, (await new CleanupActivityService(files, processes).InspectAsync(fixture.Workspace, plan.Items[0], default)).State);
    }

    [Fact]
    public async Task InvalidScopeDoesNotStartAnySystemObservation()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var files = new Files();
        var processes = new Processes();
        var service = new CleanupActivityService(files, processes);
        var result = await service.InspectAsync(fixture.Workspace, plan.Items[0] with { Path = WindowsPath.Parse("C:/Elsewhere/target") }, default);
        Assert.Equal(ActivityState.Unknown, result.State);
        result = await service.InspectAsync(fixture.Workspace, plan.Items[0] with
        {
            Manifest = plan.Items[0].Manifest.SetItem(1, plan.Items[0].Manifest[1] with { Path = WindowsPath.Parse("C:/Elsewhere/private.bin") })
        }, default);
        Assert.Equal(ActivityState.Unknown, result.State);
        Assert.True(files.Paths.IsDefault);
        Assert.Equal(0, processes.Calls);
    }

    [Fact]
    public async Task OneDeadlineBoundsBothReadOnlyAdaptersAndDoesNotReportIdle()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        var clock = new ManualDeadlineClock();
        var pending = new TaskCompletionSource<ActivityObservation>(TaskCreationOptions.RunContinuationsAsynchronously);
        var files = new Files { Read = _ => pending.Task };
        var result = new CleanupActivityService(files, new Processes(), clock).InspectAsync(fixture.Workspace, plan.Items[0], default);
        Assert.False(result.IsCompleted);
        clock.Expire();
        var observed = await result;
        Assert.Equal(ActivityState.Unknown, observed.State);
        Assert.Equal("activity_time_limit", observed.Reason);
        pending.SetResult(new(ActivityState.Idle));
    }

    [Fact]
    public async Task CallerCancellationPropagatesInsteadOfBecomingUnknown()
    {
        var fixture = await Fixture.Create();
        var plan = await fixture.Plan();
        using var cancelled = new CancellationTokenSource();
        var files = new Files { Read = async token => { await Task.Delay(Timeout.InfiniteTimeSpan, token); return new(ActivityState.Idle); } };
        var result = new CleanupActivityService(files, new Processes()).InspectAsync(fixture.Workspace, plan.Items[0], cancelled.Token);
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => result);
    }
}
