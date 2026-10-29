using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class ApplicationShortcutTests
{
    private sealed class Inspector(WindowsPath root, ApplicationShortcutReview review) : IApplicationShortcutInspector
    {
        public ImmutableArray<WindowsPath> Roots => [root];
        public ApplicationShortcutReview Current = review;
        public string? Failure;
        public Task<ApplicationShortcutReview> InspectAsync(WindowsPath path, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return Failure is { } code ? Task.FromException<ApplicationShortcutReview>(new ShouException(code, "Keep this shortcut.")) : Task.FromResult(Current);
        }
    }
    [Fact]
    public async Task ExactShortcutFileReusesDurableCleanupAndNeverIncludesTargetOrSiblings()
    {
        var fixture = await CleanupTests.Fixture.Create();
        var root = fixture.Workspace.Path;
        var file = root.Append("Generated.lnk"); fixture.Files.Add(file.Value);
        var expected = new ApplicationShortcutReview(fixture.Files.Entries[file.Value], fixture.Files.Entries[root.Value],
            WindowsPath.Parse("C:/Absent/Generated.exe"), "sha256:" + new string('a', 64), fixture.Clock.Now);
        var inspector = new Inspector(root, expected);
        var shortcuts = new ApplicationShortcutService(inspector, fixture.Files, fixture.Clock);
        var snapshot = await shortcuts.SnapshotAsync(expected, default);
        var cleanup = new CleanupService(fixture.Store, fixture.Validator, new StorageScanner(fixture.Files), fixture.Protection,
            fixture.Activity, fixture.Mutation, fixture.Clock, storageFiles: fixture.Files);
        var plan = await cleanup.CreateStoragePlanAsync(snapshot, [file]);
        Assert.Equal(expected.File, Assert.Single(Assert.Single(plan.Items).Manifest));
        var result = await cleanup.ExecuteAsync(plan.Id, await cleanup.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()));
        Assert.Equal(CleanupExecutionState.Completed, result.State);
        Assert.False(fixture.Files.Entries.ContainsKey(file.Value));
        Assert.True(fixture.Files.Entries.ContainsKey(root.Append("project-0/Cargo.toml").Value));
        Assert.DoesNotContain(plan.Items.SelectMany(item => item.Manifest), entry => entry.Path == expected.Target);
        Assert.Equal("plan_consumed", (await Assert.ThrowsAsync<ShouException>(() => cleanup.ConfirmAsync(plan.Id, new CleanupTests.Confirmation()))).Code);
    }

    [Fact]
    public async Task ReappearingTargetsChangedContentReplacedIdentityAndExpiredReviewCannotPrepareDeletion()
    {
        var fixture = await CleanupTests.Fixture.Create(); var root = fixture.Workspace.Path;
        var file = root.Append("Generated.lnk"); fixture.Files.Add(file.Value);
        var expected = new ApplicationShortcutReview(fixture.Files.Entries[file.Value], fixture.Files.Entries[root.Value],
            WindowsPath.Parse("C:/Absent/Generated.exe"), "sha256:" + new string('a', 64), fixture.Clock.Now);
        var inspector = new Inspector(root, expected); var service = new ApplicationShortcutService(inspector, fixture.Files, fixture.Clock);
        inspector.Failure = "shortcut_target_present";
        await Assert.ThrowsAsync<ShouException>(() => service.SnapshotAsync(expected, default));
        inspector.Failure = null;
        foreach (var changed in new[] { expected with { ContentDigest = "sha256:" + new string('b', 64) },
            expected with { Target = WindowsPath.Parse("C:/Other/Generated.exe") }, expected with { File = expected.File with { LinkCount = 2 } } })
        {
            inspector.Current = changed;
            await Assert.ThrowsAsync<ShouException>(() => service.SnapshotAsync(expected, default));
        }
        inspector.Current = expected; fixture.Clock.Now = fixture.Clock.Now.AddMinutes(15);
        await Assert.ThrowsAsync<ShouException>(() => service.SnapshotAsync(expected, default));
        Assert.True(fixture.Files.Entries.ContainsKey(file.Value));
        Assert.Equal(0, fixture.Mutation.Calls);
    }
}
