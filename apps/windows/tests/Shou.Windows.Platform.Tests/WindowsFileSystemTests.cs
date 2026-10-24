using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsFileSystemTests
{
    [WindowsFact]
    public async Task ReadsNativeFileIdOwnerAndAllocatedSize()
    {
        using var fixture = new NativeFixture();
        var path = fixture.Write("开发者 文件.bin", new byte[8192]);
        var entry = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(path), default);
        Assert.Equal(EntryKind.File, entry.Kind);
        Assert.Equal(8192, entry.LogicalBytes);
        Assert.True(entry.AllocatedBytes >= 0);
        Assert.Equal(32, entry.Identity.FileId.Length);
        Assert.Equal(WindowsIdentity.GetCurrent().User!.Value, entry.Identity.OwnerSid);
    }

    [WindowsFact]
    public async Task ScansUnicodePathsAndPreservesEveryFixtureByte()
    {
        using var fixture = new NativeFixture();
        fixture.Write("项目/文件.bin", new byte[8192]);
        fixture.Write("kept.txt", [1, 2, 3]);
        var snapshot = await new StorageScanner(new WindowsFileSystem()).ScanAsync(WindowsPath.Parse(fixture.Root), new(), null, default);
        Assert.True(snapshot.IsComplete);
        Assert.Equal(4, snapshot.Entries.Length);
        Assert.Equal(8195, snapshot.LogicalBytes);
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(Path.Combine(fixture.Root, "kept.txt")));
    }

    [WindowsFact]
    public async Task DeduplicatesNativeHardLinks()
    {
        using var fixture = new NativeFixture();
        var first = fixture.Write("a.bin", new byte[8192]);
        var second = Path.Combine(fixture.Root, "b.bin");
        Assert.True(FixtureNative.CreateHardLink(second, first, 0), $"Hard-link fixture failed: {Marshal.GetLastWin32Error()}");
        var snapshot = await new StorageScanner(new WindowsFileSystem()).ScanAsync(WindowsPath.Parse(fixture.Root), new(), null, default);
        Assert.True(snapshot.IsComplete);
        var files = snapshot.Entries.Where(item => item.Entry.Kind == EntryKind.File).ToArray();
        Assert.Equal(2, files.Length);
        Assert.Equal(files[0].Entry.Identity, files[1].Entry.Identity);
        Assert.Equal(files[0].Entry.AllocatedBytes, files.Sum(item => item.AttributedAllocatedBytes));
    }

    [WindowsFact]
    public async Task JunctionsCannotExposeOutsideFiles()
    {
        using var fixture = new NativeFixture();
        using var outside = new NativeFixture();
        outside.Write("private.bin", [9, 8, 7]);
        var junction = Path.Combine(fixture.Root, "junction");
        FixtureNative.CreateJunction(junction, outside.Root);
        try
        {
            var fs = new WindowsFileSystem();
            var snapshot = await new StorageScanner(fs).ScanAsync(WindowsPath.Parse(fixture.Root), new(), null, default);
            Assert.False(snapshot.IsComplete);
            Assert.Contains(snapshot.Entries, item => item.Entry.Kind == EntryKind.ReparsePoint);
            Assert.DoesNotContain(snapshot.Entries, item => item.Entry.Path.Name == "private.bin");
            var error = await Assert.ThrowsAsync<ShouException>(() => fs.InspectAsync(WindowsPath.Parse(Path.Combine(junction, "private.bin")), default).AsTask());
            Assert.Equal("unsafe_path", error.Code);
        }
        finally { Directory.Delete(junction); }
        Assert.Equal(new byte[] { 9, 8, 7 }, File.ReadAllBytes(Path.Combine(outside.Root, "private.bin")));
    }

    [WindowsFact]
    public async Task LockedFilesKeepOtherResultsAndExplicitCoverageGaps()
    {
        using var fixture = new NativeFixture();
        var path = fixture.Write("locked.bin", [4, 5, 6]);
        fixture.Write("readable.bin", [1, 2, 3]);
        using var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        var snapshot = await new StorageScanner(new WindowsFileSystem()).ScanAsync(WindowsPath.Parse(fixture.Root), new(), null, default);
        Assert.False(snapshot.IsComplete);
        Assert.Contains(snapshot.Entries, item => item.Entry.Path.Name == "readable.bin");
        Assert.Contains(snapshot.Issues, issue => issue.Path.Name == "locked.bin" && issue.Code == "active_or_inaccessible");
    }

    [WindowsFact]
    public async Task HandlesPathsBeyondTheWin32ShortPathLimit()
    {
        using var fixture = new NativeFixture();
        var relative = string.Join('/', Enumerable.Repeat("generated-long-directory", 12)) + "/file.bin";
        var path = fixture.Write(relative, [1, 2, 3]);
        Assert.True(path.Length > 260);
        var entry = await new WindowsFileSystem().InspectAsync(WindowsPath.Parse(path), default);
        Assert.Equal(3, entry.LogicalBytes);
    }

    [Fact]
    public void LanguageResourcesAreEmbeddedAndRetainTypedFormatting()
    {
        Assert.Equal("Space Analysis", new TextCatalog("en").Get("Space Analysis"));
        Assert.Equal("空间分析", new TextCatalog("zh-CN").Get("Space Analysis"));
        Assert.DoesNotContain("%lld", new TextCatalog("en").Format("%lld applications found", 3));
        Assert.Contains("3", new TextCatalog("en").Format("%lld applications found", 3));
    }

    [Fact]
    public void SchemaIsBundledWithoutNetworkOrWorkingDirectoryDependencies()
    {
        var validator = RuleResources.CreateValidator();
        Assert.Equal("object", validator.ExportSchema().GetProperty("type").GetString());
        Assert.False(validator.Validate(System.Text.Encoding.UTF8.GetBytes("{}")).IsValid);
    }

    [WindowsFact]
    public async Task RuleReadingIsBoundedAndDoesNotChangeTheSource()
    {
        using var fixture = new NativeFixture();
        var content = System.Text.Encoding.UTF8.GetBytes("{\"name\":\"规则 Unicode\"}");
        var path = fixture.Write("规则 with spaces.json", content);
        var fs = new WindowsFileSystem();
        Assert.Equal(content, await fs.ReadRuleFileAsync(WindowsPath.Parse(path), default));
        Assert.Equal(content, File.ReadAllBytes(path));
        var large = fixture.Write("oversized.json", new byte[RuleSchemaValidator.MaximumRuleBytes + 1]);
        var error = await Assert.ThrowsAsync<ShouException>(() => fs.ReadRuleFileAsync(WindowsPath.Parse(large), default).AsTask());
        Assert.Equal("resource_limit", error.Code);
        using var locked = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.Read);
        error = await Assert.ThrowsAsync<ShouException>(() => fs.ReadRuleFileAsync(WindowsPath.Parse(path), default).AsTask());
        Assert.Equal("active_or_inaccessible", error.Code);
    }

    [WindowsFact]
    public async Task RuleReadingRejectsHardLinksAndJunctionAncestors()
    {
        using var fixture = new NativeFixture();
        using var outside = new NativeFixture();
        var original = fixture.Write("original.json", [1, 2, 3]);
        var linked = Path.Combine(fixture.Root, "linked.json");
        Assert.True(FixtureNative.CreateHardLink(linked, original, 0));
        var fs = new WindowsFileSystem();
        var error = await Assert.ThrowsAsync<ShouException>(() => fs.ReadRuleFileAsync(WindowsPath.Parse(linked), default).AsTask());
        Assert.Equal("unsafe_path", error.Code);
        outside.Write("private.json", [9, 8, 7]);
        var junction = Path.Combine(fixture.Root, "junction");
        FixtureNative.CreateJunction(junction, outside.Root);
        try
        {
            error = await Assert.ThrowsAsync<ShouException>(() => fs.ReadRuleFileAsync(WindowsPath.Parse(Path.Combine(junction, "private.json")), default).AsTask());
            Assert.Equal("unsafe_path", error.Code);
        }
        finally { Directory.Delete(junction); }
        Assert.Equal(new byte[] { 9, 8, 7 }, File.ReadAllBytes(Path.Combine(outside.Root, "private.json")));
    }

    internal sealed class NativeFixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "shou-native-generated-" + Guid.NewGuid().ToString("N"));
        public NativeFixture() => new DirectoryInfo(Root).Create(PrivateDirectorySecurity());
        internal static DirectorySecurity PrivateDirectorySecurity()
        {
            using var identity = WindowsIdentity.GetCurrent();
            var security = new DirectorySecurity();
            security.SetOwner(identity.User!);
            security.SetAccessRuleProtection(true, false);
            foreach (var sid in new[] { identity.User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            return security;
        }
        public string CreateDirectory(string relative)
        {
            var directory = new DirectoryInfo(Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (directory.FullName == Root) return Root;
            if (!directory.Exists)
            {
                CreateDirectory(Path.GetRelativePath(Root, directory.Parent!.FullName));
                // Elevated tokens may default new objects to the Administrators group owner.
                directory.Create(PrivateDirectorySecurity());
            }
            return directory.FullName;
        }
        public string Write(string relative, byte[] content)
        {
            var path = Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar));
            CreateDirectory(Path.GetRelativePath(Root, Path.GetDirectoryName(path)!));
            File.WriteAllBytes(path, content);
            SetFileOwner(relative);
            return path;
        }
        public void SetFileOwner(string relative)
        {
            var file = new FileInfo(Path.Combine(Root, relative.Replace('/', Path.DirectorySeparatorChar)));
            var security = file.GetAccessControl(AccessControlSections.Owner);
            using var identity = WindowsIdentity.GetCurrent();
            security.SetOwner(identity.User!);
            file.SetAccessControl(security);
        }
        public void Dispose()
        {
            for (var attempt = 0; ; attempt++)
            {
                try { Directory.Delete(Root, recursive: true); return; }
                // A just-exited generated child can briefly retain its current-directory handle.
                catch (IOException error) when (attempt < 20 && (error.HResult & 0xFFFF) is 32 or 33)
                { Thread.Sleep(50); }
            }
        }
    }

    internal static class FixtureNative
    {
        [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateHardLink(string path, string existing, nint security);

        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, nint security, uint creation, uint flags, nint template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputSize,
            nint output, uint outputSize, out uint returned, nint overlapped);

        internal static void CreateJunction(string path, string target)
        {
            Directory.CreateDirectory(path);
            using var handle = CreateFile(path, 0x40000000, 7, 0, 3, 0x02200000, 0);
            Assert.False(handle.IsInvalid);
            var substitute = System.Text.Encoding.Unicode.GetBytes(@"\??\" + target + '\0');
            var print = System.Text.Encoding.Unicode.GetBytes(target + '\0');
            var buffer = new byte[16 + substitute.Length + print.Length];
            BitConverter.GetBytes(0xA0000003u).CopyTo(buffer, 0);
            BitConverter.GetBytes(checked((ushort)(8 + substitute.Length + print.Length))).CopyTo(buffer, 4);
            BitConverter.GetBytes(checked((ushort)(substitute.Length - 2))).CopyTo(buffer, 10);
            BitConverter.GetBytes(checked((ushort)substitute.Length)).CopyTo(buffer, 12);
            BitConverter.GetBytes(checked((ushort)(print.Length - 2))).CopyTo(buffer, 14);
            substitute.CopyTo(buffer, 16);
            print.CopyTo(buffer, 16 + substitute.Length);
            Assert.True(DeviceIoControl(handle, 0x000900A4, buffer, (uint)buffer.Length, 0, 0, out _, 0),
                $"Junction fixture failed: {Marshal.GetLastWin32Error()}");
        }
    }
}
