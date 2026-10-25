using Shou.Windows.Core;
using static Shou.Windows.Platform.Tests.WindowsFileSystemTests;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsCleanupScannerTests
{
    private static CleanupRule Rule(WindowsPath root)
    {
        var validator = RuleResources.CreateValidator();
        var catalog = RuleResources.CreateCatalog(validator, new(root, root.Append("Local"), root.Append("Roaming")));
        return catalog.Rule(catalog.Templates.Single(item => item.Id == "shou.builtin.rust-target"), "developer-workspaces");
    }

    [WindowsFact]
    public async Task FindsUnicodeTargetInWideDirectoryAndRechecksSelectionWithoutSourceEnumeration()
    {
        using var fixture = new NativeFixture();
        fixture.Write("项目/Cargo.toml", [1, 2, 3]);
        for (var i = 0; i < 200; i++) fixture.Write($"项目/source-{i}.rs", [9, 8, 7]);
        var payload = fixture.Write("项目/TARGET/generated.bin", [4, 5, 6]);
        var root = WindowsPath.Parse(fixture.Root);
        var scanner = new CleanupScanner(new WindowsFileSystem());
        var scan = await scanner.ScanCleanupAsync(root, [Rule(root)], new(80), null, null, default);
        var target = root.Append("项目/target");
        Assert.True(scan.IsCompleteAt(target));
        Assert.False(scan.IsCompleteAt(root));
        Assert.Equal(ScanScope.RuleTargets, scan.Scope);
        var selected = await scanner.ScanCleanupAsync(root, [Rule(root)], new(40), [target], null, default);
        Assert.True(selected.IsScopeComplete);
        Assert.True(selected.IsCompleteAt(target));
        Assert.DoesNotContain(selected.Entries, entry => entry.Entry.Path.Name.StartsWith("source-", StringComparison.Ordinal));
        Assert.Equal(new byte[] { 4, 5, 6 }, File.ReadAllBytes(payload));
        Assert.Equal(new byte[] { 9, 8, 7 }, File.ReadAllBytes(Path.Combine(fixture.Root, "项目/source-199.rs")));
    }

    [WindowsFact]
    public async Task JunctionTargetCannotExposeOutsideBytesOrPositiveCoverage()
    {
        using var fixture = new NativeFixture();
        using var outside = new NativeFixture();
        fixture.Write("project/Cargo.toml", [1, 2, 3]);
        var payload = outside.Write("private.bin", [9, 8, 7]);
        var root = WindowsPath.Parse(fixture.Root);
        var target = root.Append("project/target");
        FixtureNative.CreateJunction(target.Value, outside.Root);
        try
        {
            var scan = await new CleanupScanner(new WindowsFileSystem()).ScanCleanupAsync(root, [Rule(root)], new(), [target], null, default);
            Assert.False(scan.IsCompleteAt(target));
            Assert.DoesNotContain(scan.Entries, entry => entry.Entry.Path.Name == "private.bin");
            Assert.NotEmpty(scan.Issues);
            Assert.Equal(new byte[] { 9, 8, 7 }, File.ReadAllBytes(payload));
        }
        finally { Directory.Delete(target.Value); }
    }

    [WindowsFact]
    public async Task LockedTargetKeepsIndependentSiblingCoverage()
    {
        using var fixture = new NativeFixture();
        fixture.Write("first/Cargo.toml", [1, 2, 3]);
        var lockedPath = fixture.Write("first/target/locked.bin", [9, 8, 7]);
        fixture.Write("second/Cargo.toml", [1, 2, 3]);
        fixture.Write("second/target/generated.bin", [4, 5, 6]);
        using var locked = new FileStream(lockedPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        var root = WindowsPath.Parse(fixture.Root);
        var scan = await new CleanupScanner(new WindowsFileSystem()).ScanCleanupAsync(root, [Rule(root)], new(), null, null, default);
        Assert.False(scan.IsCompleteAt(root.Append("first/target")));
        Assert.True(scan.IsCompleteAt(root.Append("second/target")));
        Assert.Contains(scan.Issues, issue => issue.Code == "active_or_inaccessible");
    }
}
