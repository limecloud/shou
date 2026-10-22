using System.Buffers.Binary;
using Shou.Windows.Services;

internal static class CliInstallationChecks
{
    private static void Require(bool condition) { if (!condition) throw new Exception("CLI installation check failed."); }
    private static void Refused(Action action)
    {
        try { action(); }
        catch (IOException) { return; }
        throw new Exception("Conflicting CLI installation was accepted.");
    }
    private static string Canonical(DirectoryInfo directory)
    {
        if (directory.Parent is not { } parent) return directory.FullName;
        return directory.ResolveLinkTarget(true) is DirectoryInfo target
            ? Canonical(target) : Path.Combine(Canonical(parent), directory.Name);
    }
    private static byte[] Image(byte marker = 1)
    {
        var bytes = new byte[256]; bytes[0] = (byte)'M'; bytes[1] = (byte)'Z';
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(60), 64);
        "PE\0\0"u8.CopyTo(bytes.AsSpan(64)); BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(68), 0x8664);
        bytes[^1] = marker; return bytes;
    }

    public static async Task Run(Func<string, Func<Task>, Task> check)
    {
        await check("CLI 只读预览、独占目录发布及相同安装往返", () =>
        {
            var fixture = Directory.CreateTempSubdirectory("shou-cli-install-");
            try
            {
                var root = Canonical(fixture);
                var package = Directory.CreateDirectory(Path.Combine(root, "package 中文 & %PATH% ' quoted"));
                var template = Path.Combine(package.FullName, "shou-cli-launcher.exe");
                var engine = Path.Combine(package.FullName, "shou.exe");
                File.WriteAllBytes(template, Image()); File.WriteAllBytes(engine, Image(2));
                var destination = Path.Combine(root, "new parent", "user's CLI 中文");
                var installer = new WindowsCliInstallation(template, engine, destination);
                var preview = installer.Preview();
                Require(!preview.AlreadyCurrent && !Directory.Exists(Path.GetDirectoryName(destination)));
                Refused(() => installer.Install("foreign-digest"));
                using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
                try { installer.Install(preview.Digest, cancelled.Token); throw new Exception("Cancelled CLI installation was accepted."); }
                catch (OperationCanceledException) { }
                Require(!Directory.Exists(Path.GetDirectoryName(destination)));
                var result = installer.Install(preview.Digest);
                Require(result.Launcher == Path.Combine(destination, "shou.exe") && File.ReadAllBytes(result.Launcher).SequenceEqual(Image()));
                var manifest = Path.Combine(destination, WindowsCliInstallation.TargetFileName);
                Require(File.ReadAllText(manifest) == WindowsCliInstallation.TargetHeader + engine + "\n");
                var current = installer.Preview(); Require(current.AlreadyCurrent);
                Require(installer.Install(current.Digest).AlreadyCurrent);
                Require(Directory.GetFileSystemEntries(destination).Length == 2 && Directory.GetDirectories(Path.GetDirectoryName(destination)!, ".shou-cli-install-*").Length == 0);
                Require(File.ReadAllBytes(template).SequenceEqual(Image()) && File.ReadAllBytes(engine).SequenceEqual(Image(2)));
            }
            finally { fixture.Delete(true); }
            return Task.CompletedTask;
        });
        await check("CLI 变更复核、并发占位、个人修改及未知条目保留", () =>
        {
            var fixture = Directory.CreateTempSubdirectory("shou-cli-install-");
            try
            {
                var root = Canonical(fixture); var template = Path.Combine(root, "launcher.exe"); var engine = Path.Combine(root, "shou.exe");
                File.WriteAllBytes(template, Image()); File.WriteAllBytes(engine, Image(2));
                var destination = Path.Combine(root, "CLI"); var installer = new WindowsCliInstallation(template, engine, destination);
                var preview = installer.Preview(); File.WriteAllBytes(engine, Image(3));
                Refused(() => installer.Install(preview.Digest)); Require(!Directory.Exists(destination));
                preview = installer.Preview(); File.WriteAllBytes(template, Image(4));
                Refused(() => installer.Install(preview.Digest)); Require(!Directory.Exists(destination));
                preview = installer.Preview(); Directory.CreateDirectory(destination); File.WriteAllText(Path.Combine(destination, "keep.txt"), "generated concurrent entry");
                Refused(() => installer.Install(preview.Digest)); Require(File.ReadAllText(Path.Combine(destination, "keep.txt")) == "generated concurrent entry");
                var installed = new WindowsCliInstallation(template, engine, Path.Combine(root, "installed"));
                var result = installed.Install(installed.Preview().Digest);
                File.WriteAllBytes(result.Launcher, "personal command; keep"u8.ToArray());
                Refused(() => installed.Preview()); Require(File.ReadAllText(result.Launcher) == "personal command; keep");
                Require(Directory.GetDirectories(root, ".shou-cli-install-*").Length == 0);
            }
            finally { fixture.Delete(true); }
            return Task.CompletedTask;
        });
        await check("CLI 安装拒绝非法 PE、路径跳转及链接且不执行输入文件", () =>
        {
            var fixture = Directory.CreateTempSubdirectory("shou-cli-install-");
            try
            {
                var root = Canonical(fixture); var template = Path.Combine(root, "launcher.exe"); var engine = Path.Combine(root, "shou.exe");
                File.WriteAllBytes(template, Image()); File.WriteAllBytes(engine, Image(2));
                Refused(() => new WindowsCliInstallation(template, engine, "relative/CLI"));
                Refused(() => new WindowsCliInstallation(template, engine, root + "/child/../CLI"));
                var installer = new WindowsCliInstallation(template, engine, Path.Combine(root, "CLI"));
                File.WriteAllBytes(template, "not an executable"u8.ToArray()); Refused(() => installer.Preview());
                File.WriteAllBytes(template, Image());
                var incompatible = Image(2); BinaryPrimitives.WriteUInt16LittleEndian(incompatible.AsSpan(68), 0xaa64);
                File.WriteAllBytes(engine, incompatible); Refused(() => installer.Preview());
                File.WriteAllBytes(engine, Image(2));
                using (var large = new FileStream(engine, FileMode.Open, FileAccess.Write)) large.SetLength(6 * 1024 * 1024);
                Require(!installer.Preview().AlreadyCurrent); // Real Swift engines exceed the launcher size limit.
                if (!OperatingSystem.IsWindows())
                {
                    var linked = Path.Combine(root, "linked"); Directory.CreateSymbolicLink(linked, root);
                    Refused(() => new WindowsCliInstallation(template, engine, Path.Combine(linked, "CLI")).Preview());
                    File.Delete(linked);
                    var linkedImage = Path.Combine(root, "linked.exe"); File.CreateSymbolicLink(linkedImage, template);
                    Refused(() => new WindowsCliInstallation(linkedImage, engine, Path.Combine(root, "CLI")).Preview());
                }
                Require(!Directory.Exists(Path.Combine(root, "CLI")));
            }
            finally { fixture.Delete(true); }
            return Task.CompletedTask;
        });
    }
}
