using System.Collections.Immutable;
using Shou.Windows.Core;
using static Shou.Windows.Platform.Tests.WindowsFileSystemTests;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsCleanupTests
{
    private sealed record Observed(Workspace Workspace, CleanupPlanItem Item);

    private static async Task<Observed> Observe(NativeFixture fixture)
    {
        var root = WindowsPath.Parse(fixture.Root);
        var snapshot = await new StorageScanner(new WindowsFileSystem()).ScanAsync(root, new(), null, default);
        Assert.True(snapshot.IsComplete);
        var target = root.Append("project/target");
        var manifest = snapshot.Entries.Select(item => item.Entry).Where(entry => entry.Path.IsWithin(target, caseSensitive: true))
            .OrderBy(entry => entry.Path.Value, StringComparer.Ordinal).ToImmutableArray();
        var context = snapshot.Entries.Select(item => item.Entry)
            .Where(entry => entry.Path == root || entry.Path == target.Parent || entry.Path == root.Append("project/Cargo.toml"))
            .ToImmutableArray();
        var rootEntry = snapshot.Entries.Single(item => item.Entry.Path == root).Entry;
        var workspace = new Workspace(RecordKey.New("ws"), "developer-workspaces", root, rootEntry.Identity, rootEntry.IsCaseSensitive, [], DateTimeOffset.UtcNow);
        var item = new CleanupPlanItem(RecordKey.New("item"), RecordKey.New("scan"), RecordKey.New("candidate"), "dev.fixture", "1.0.0", "project/target", target,
            manifest, context, "sha256:" + new string('0', 64), manifest.Sum(entry => entry.AllocatedBytes), manifest.Sum(entry => entry.LogicalBytes), "review");
        return new(workspace, item);
    }

    private static void Populate(NativeFixture fixture)
    {
        fixture.Write("project/Cargo.toml", System.Text.Encoding.UTF8.GetBytes("[package]\nname='generated'\n"));
        fixture.Write("project/src/main.rs", [9, 8, 7]);
        fixture.Write("project/target/cache.bin", [1, 2, 3]);
        fixture.Write("project/target/子目录 with spaces/nested.bin", [4, 5, 6]);
        Directory.CreateDirectory(Path.Combine(fixture.Root, "project/target/empty"));
    }

    [WindowsFact]
    public async Task RemovesOnlyTheFrozenTreeAndKeepsSourcesAndMarkers()
    {
        using var fixture = new NativeFixture();
        Populate(fixture);
        var observed = await Observe(fixture);
        var result = await new WindowsCleanupMutation().ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, default);
        Assert.Equal(CleanupMutationOutcome.Completed, result.Outcome);
        Assert.Equal(observed.Item.Manifest.Length, result.RemovedEntries);
        Assert.False(Directory.Exists(observed.Item.Path.Value));
        Assert.Equal(new byte[] { 9, 8, 7 }, File.ReadAllBytes(Path.Combine(fixture.Root, "project/src/main.rs")));
        Assert.True(File.Exists(Path.Combine(fixture.Root, "project/Cargo.toml")));
    }

    [WindowsFact]
    public async Task NewDescendantsAndChangedMarkersRefuseTheWholeTargetBeforeMutation()
    {
        using var fixture = new NativeFixture();
        Populate(fixture);
        var observed = await Observe(fixture);
        var added = fixture.Write("project/target/new-private.bin", [8, 8, 8]);
        var port = new WindowsCleanupMutation();
        var result = await port.ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, default);
        Assert.Equal(CleanupMutationOutcome.Failed, result.Outcome);
        Assert.Equal(0, result.RemovedEntries);
        Assert.Equal(new byte[] { 8, 8, 8 }, File.ReadAllBytes(added));
        File.Delete(added);
        observed = await Observe(fixture);
        fixture.Write("project/Cargo.toml", [1, 2, 3, 4, 5]);
        result = await port.ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, default);
        Assert.Equal(CleanupMutationOutcome.Failed, result.Outcome);
        Assert.Equal(0, result.RemovedEntries);
        Assert.True(File.Exists(Path.Combine(fixture.Root, "project/target/cache.bin")));
    }

    [WindowsFact]
    public async Task ReplacedTargetsAndJunctionsNeverExposeOutsideFilesToDeletion()
    {
        using var fixture = new NativeFixture();
        using var outside = new NativeFixture();
        Populate(fixture);
        var observed = await Observe(fixture);
        var saved = Path.Combine(fixture.Root, "project/original-target");
        Directory.Move(observed.Item.Path.Value, saved);
        outside.Write("private.bin", [7, 7, 7]);
        FixtureNative.CreateJunction(observed.Item.Path.Value, outside.Root);
        try
        {
            var result = await new WindowsCleanupMutation().ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, default);
            Assert.Equal(CleanupMutationOutcome.Failed, result.Outcome);
            Assert.Equal(0, result.RemovedEntries);
            Assert.Equal(new byte[] { 7, 7, 7 }, File.ReadAllBytes(Path.Combine(outside.Root, "private.bin")));
            Assert.True(File.Exists(Path.Combine(saved, "cache.bin")));
        }
        finally { Directory.Delete(observed.Item.Path.Value); }
    }

    [WindowsFact]
    public async Task HardLinksOrLockedFilesAreRejectedBeforeTheFirstDisposition()
    {
        using var fixture = new NativeFixture();
        Populate(fixture);
        var observed = await Observe(fixture);
        var source = Path.Combine(fixture.Root, "project/target/cache.bin");
        var link = Path.Combine(fixture.Root, "kept-link.bin");
        Assert.True(FixtureNative.CreateHardLink(link, source, 0));
        var port = new WindowsCleanupMutation();
        var result = await port.ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, default);
        Assert.Equal(CleanupMutationOutcome.Failed, result.Outcome);
        Assert.Equal(0, result.RemovedEntries);
        File.Delete(link);
        observed = await Observe(fixture);
        using (var locked = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
        {
            result = await port.ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, default);
            Assert.Equal(CleanupMutationOutcome.Failed, result.Outcome);
            Assert.Equal(0, result.RemovedEntries);
        }
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(source));
    }

    [WindowsFact]
    public async Task CancellationAndUnsupportedTrashNeverStartDeletion()
    {
        using var fixture = new NativeFixture();
        Populate(fixture);
        var observed = await Observe(fixture);
        var port = new WindowsCleanupMutation();
        using var stopped = new CancellationTokenSource();
        stopped.Cancel();
        var result = await port.ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Permanent, stopped.Token);
        Assert.Equal(CleanupMutationOutcome.Cancelled, result.Outcome);
        Assert.Equal(0, result.RemovedEntries);
        Assert.Equal("unsupported_capability", (await Assert.ThrowsAsync<ShouException>(() => port.ApplyAsync(observed.Workspace, observed.Item, CleanupAction.Trash, default))).Code);
        Assert.True(File.Exists(Path.Combine(fixture.Root, "project/target/cache.bin")));
    }

    [WindowsFact]
    public async Task RestartManagerObservesFixtureFileUseWithoutStoppingTheOwner()
    {
        using var fixture = new NativeFixture();
        Populate(fixture);
        var observed = await Observe(fixture);
        var path = Path.Combine(fixture.Root, "project/target/cache.bin");
        var activity = new WindowsFileUseActivity();
        var resources = observed.Item.Manifest.Concat(observed.Item.Context).Where(entry => entry.Kind == EntryKind.File)
            .Select(entry => entry.Path).Distinct().ToImmutableArray();
        using (var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
        {
            var result = await activity.InspectAsync(resources, default);
            Assert.Equal(ActivityState.Active, result.State);
            locked.Position = 0;
            Assert.Equal(1, locked.ReadByte());
        }
        Assert.Equal(ActivityState.Idle, (await activity.InspectAsync(resources, default)).State);
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(path));
    }
}
