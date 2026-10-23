using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ApplicationActivityTests
{
    private sealed class Files : ICleanupFileUse
    {
        public ImmutableArray<WindowsPath> Paths;
        public Func<Task<ActivityObservation>> Read = () => Task.FromResult(new ActivityObservation(ActivityState.Idle));
        public Task<ActivityObservation> InspectAsync(ImmutableArray<WindowsPath> paths, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Paths = paths; return Read(); }
    }
    private sealed class Processes : IProcessInventory
    {
        public ImmutableArray<string> Names;
        public ProcessInventory Result = new(true, []);
        public Task<ProcessInventory> InspectAsync(ImmutableArray<string> executableNames, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Names = executableNames; return Task.FromResult(Result); }
    }
    private sealed class Fixture
    {
        public MemoryFileSystem FileSystem = new();
        public Files Files = new();
        public Processes Processes = new();
        public ApplicationUninstallObservation Installation;
        public ApplicationActivityService Service => new(FileSystem, Files, Processes);
        public Fixture()
        {
            var root = FileSystem.Add("C:/Example", EntryKind.Directory);
            FileSystem.Add("C:/Example/app.exe");
            FileSystem.Add("C:/Example/worker.COM");
            FileSystem.Add("C:/Example/library.dll");
            FileSystem.Add("C:/Example/data.bin");
            Installation = new(new(ApplicationInstallerKind.Msi, "{00000000-0000-0000-0000-000000000001}", MsiInstallationContext.Machine, null,
                "{00000000-0000-0000-0000-000000000002}"), "Example", "1.0", "Publisher", root, false, []);
        }
        public Task<ActivityObservation> InspectAsync() => Service.InspectAsync(Installation, default);
    }

    [Fact]
    public async Task IdleRequiresCompleteDirectoryFilesAndProcessCoverage()
    {
        var fixture = new Fixture();
        var result = await fixture.InspectAsync();
        Assert.Equal(ActivityState.Idle, result.State);
        Assert.Equal("no_observed_installation_users", result.Reason);
        Assert.Equal(4, fixture.Files.Paths.Length);
        Assert.Contains(WindowsPath.Parse("C:/Example/library.dll"), fixture.Files.Paths);
        Assert.Equal(new[] { "app.exe", "worker.COM" }, fixture.Processes.Names);
    }

    [Theory]
    [InlineData("C:/Example/app.exe", false, false, ActivityState.Active)]
    [InlineData("c:/EXAMPLE/APP.EXE", false, false, ActivityState.Active)]
    [InlineData("C:/Example/sub/app.exe", false, false, ActivityState.Active)]
    [InlineData("C:/Example2/app.exe", false, false, ActivityState.Idle)]
    [InlineData("D:/Other/app.exe", false, false, ActivityState.Idle)]
    [InlineData("C:/Example/app.exe", true, false, ActivityState.Idle)]
    [InlineData("C:/Example/app.exe", false, true, ActivityState.Active)]
    public async Task MatchingNameNeedsAnExactImageScopeAndTheShouProcessIsIncluded(string image, bool exited, bool current, ActivityState expected)
    {
        var fixture = new Fixture();
        fixture.Processes.Result = new(true, [new(42, "app.exe", Exited: exited, IsCurrentProcess: current, ExecutablePath: WindowsPath.Parse(image))]);
        Assert.Equal(expected, (await fixture.InspectAsync()).State);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingOrMismatchedImageIsUncertainty(bool wrongName)
    {
        var fixture = new Fixture();
        fixture.Processes.Result = new(true, [new(42, "app.exe", ExecutablePath: wrongName ? WindowsPath.Parse("C:/Example/other.exe") : null)]);
        Assert.Equal(ActivityState.Unknown, (await fixture.InspectAsync()).State);
    }

    [Fact]
    public async Task UnrelatedExecutableNamesDoNotRequirePrivateProcessReads()
    {
        var fixture = new Fixture();
        fixture.Processes.Result = new(true, [new(42, "unrelated.exe")]);
        Assert.Equal(ActivityState.Idle, (await fixture.InspectAsync()).State);
        Assert.DoesNotContain("unrelated.exe", fixture.Processes.Names);
    }

    [Theory]
    [InlineData(ActivityState.Unknown, true, ActivityState.Unknown)]
    [InlineData(ActivityState.Idle, false, ActivityState.Unknown)]
    [InlineData(ActivityState.Active, false, ActivityState.Active)]
    public async Task UnknownCoverageNeverBecomesIdleAndObservedFileUseStillBlocks(ActivityState fileState, bool complete, ActivityState expected)
    {
        var fixture = new Fixture();
        fixture.Files.Read = () => Task.FromResult(new ActivityObservation(fileState));
        fixture.Processes.Result = new(complete, []);
        Assert.Equal(expected, (await fixture.InspectAsync()).State);
    }

    [Theory]
    [InlineData("missing_root")]
    [InlineData("protected")]
    [InlineData("missing_identity")]
    [InlineData("partial_directory")]
    [InlineData("hard_link")]
    [InlineData("reparse_point")]
    [InlineData("changed_identity")]
    [InlineData("too_many_executables")]
    public async Task UnverifiableInstallationCannotReachIdle(string issue)
    {
        var fixture = new Fixture();
        switch (issue)
        {
            case "missing_root": fixture.Installation = fixture.Installation with { InstalledRoot = null }; break;
            case "protected": fixture.Installation = fixture.Installation with { IsProtected = true }; break;
            case "missing_identity": fixture.Installation = fixture.Installation with { Identity = null }; break;
            case "partial_directory": fixture.FileSystem.Denied.Add(WindowsPath.Parse("C:/Example").Value); break;
            case "hard_link":
                var file = WindowsPath.Parse("C:/Example/data.bin").Value;
                fixture.FileSystem.Entries[file] = fixture.FileSystem.Entries[file] with { LinkCount = 2 };
                break;
            case "reparse_point": fixture.FileSystem.Add("C:/Example/link", EntryKind.ReparsePoint); break;
            case "changed_identity": fixture.Installation = fixture.Installation with { InstalledRoot = fixture.Installation.InstalledRoot! with { Identity = new(1, new string('f', 32), "S-1-5-21-1000") } }; break;
            default:
                for (var index = 0; index < ApplicationActivityService.MaximumExecutableNames; index++) fixture.FileSystem.Add($"C:/Example/app{index}.exe");
                break;
        }
        Assert.Equal(ActivityState.Unknown, (await fixture.InspectAsync()).State);
        Assert.True(fixture.Files.Paths.IsDefault);
        Assert.True(fixture.Processes.Names.IsDefault);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DirectoryAdditionsOrFileReplacementDuringActivityInspectionInvalidateEvidence(bool directoryChanged)
    {
        var fixture = new Fixture();
        fixture.Files.Read = () =>
        {
            var path = WindowsPath.Parse(directoryChanged ? "C:/Example" : "C:/Example/app.exe").Value;
            var entry = fixture.FileSystem.Entries[path];
            fixture.FileSystem.Entries[path] = directoryChanged ? entry with { ChangeUtc = entry.ChangeUtc.AddSeconds(1) }
                : entry with { Identity = new(1, new string('e', 32), entry.Identity.OwnerSid) };
            return Task.FromResult(new ActivityObservation(ActivityState.Idle));
        };
        var result = await fixture.InspectAsync();
        Assert.Equal(ActivityState.Unknown, result.State);
        Assert.Equal("installation_changed_during_activity_check", result.Reason);
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("invalid_name")]
    [InlineData("null")]
    [InlineData("default")]
    public async Task InvalidProcessInventoryDoesNotProveIdle(string issue)
    {
        var fixture = new Fixture();
        fixture.Processes.Result = new(true, issue switch
        {
            "duplicate" => [new(42, "other.exe"), new(42, "another.exe")],
            "invalid_name" => [new(42, "app.exe\n")],
            "null" => [null!],
            _ => default
        });
        Assert.Equal(ActivityState.Unknown, (await fixture.InspectAsync()).State);
    }

    [Fact]
    public async Task CancellationDoesNotStartAnInstallationScan()
    {
        var fixture = new Fixture();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Service.InspectAsync(fixture.Installation, cancellation.Token));
        Assert.Empty(fixture.FileSystem.Enumerated);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeadlineOrCallerCancellationBoundsAnAdapterThatReturnsLate(bool callerCancellation)
    {
        var fixture = new Fixture();
        var clock = new ManualDeadlineClock();
        using var cancellation = new CancellationTokenSource();
        var pending = new TaskCompletionSource<ActivityObservation>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Files.Read = () => pending.Task;
        var work = new ApplicationActivityService(fixture.FileSystem, fixture.Files, fixture.Processes, clock).InspectAsync(fixture.Installation, cancellation.Token);
        Assert.False(work.IsCompleted);
        if (callerCancellation)
        {
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work);
        }
        else
        {
            clock.Expire();
            var result = await work;
            Assert.Equal(ActivityState.Unknown, result.State);
            Assert.Equal("application_activity_time_limit", result.Reason);
        }
        pending.SetResult(new(ActivityState.Idle));
    }
}
