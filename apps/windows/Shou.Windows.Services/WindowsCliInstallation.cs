using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;

namespace Shou.Windows.Services;

public sealed record CliInstallationPreview(string Launcher, string Executable, string Digest, bool AlreadyCurrent, bool OnPath);

/// <summary>A user-owned native command; never changes PATH or shell configuration.</summary>
public sealed class WindowsCliInstallation(string template, string executable, string directory)
{
    public const string TargetFileName = "shou.target";
    public const string TargetHeader = "Shou CLI target v1\n";
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shou", "CLI");
    public static string BundledTemplate => Path.Combine(AppContext.BaseDirectory, "CLI", "shou-cli-launcher.exe");
    private readonly string template = Absolute(template);
    private readonly string executable = Absolute(executable);
    private readonly string directory = Absolute(directory);

    public CliInstallationPreview Preview()
    {
        var launcher = Path.Combine(directory, "shou.exe");
        var image = Image(template);
        var engine = EngineIdentity();
        var imageOffset = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(image.AsSpan(60, 4));
        if (Machine(image.AsSpan(imageOffset + 4, 2)) != engine.Machine)
            throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        var target = Target();
        RejectLinks(directory);
        var current = Directory.Exists(directory);
        if (File.Exists(directory)) throw new IOException(T("CLI 安装位置已被占用，现有内容已保留。"));
        if (current)
        {
            var entries = Directory.EnumerateFileSystemEntries(directory).Take(3).Select(Path.GetFileName).Order(StringComparer.Ordinal).ToArray();
            if (!entries.SequenceEqual(new[] { "shou.exe", TargetFileName }) ||
                !Read(launcher, 4 * 1024 * 1024).SequenceEqual(image) ||
                !Read(Path.Combine(directory, TargetFileName), 32768).SequenceEqual(target))
                throw new IOException(T("已有 shou 命令与本次安装不同，现有内容已保留。请先手动备份并处理原入口。"));
        }
        var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n',
            launcher, executable, engine.Digest, Convert.ToHexStringLower(SHA256.HashData(image)), Convert.ToHexStringLower(SHA256.HashData(target)), current.ToString()))));
        var onPath = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Any(value => string.Equals(value.Trim('"').TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), directory.TrimEnd(Path.DirectorySeparatorChar), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal));
        return new(launcher, executable, digest, current, onPath);
    }

    public CliInstallationPreview Install(string reviewedDigest, CancellationToken cancellation = default)
    {
        var preview = Preview();
        if (preview.Digest != reviewedDigest) throw new IOException(T("CLI 或安装位置已变化，请重新审阅安装。"));
        cancellation.ThrowIfCancellationRequested();
        if (preview.AlreadyCurrent) return preview;
        var parent = Path.GetDirectoryName(directory) ?? throw new IOException(T("请选择不含跳转或控制字符的本地绝对 CLI 路径。"));
        RejectLinks(parent); Directory.CreateDirectory(parent); RejectLinks(parent);
        var staged = Path.Combine(parent, ".shou-cli-install-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staged);
        try
        {
            Write(Path.Combine(staged, "shou.exe"), Image(template));
            Write(Path.Combine(staged, TargetFileName), Target());
            if (Preview().Digest != reviewedDigest) throw new IOException(T("CLI 或安装位置已变化，请重新审阅安装。"));
            cancellation.ThrowIfCancellationRequested();
            // Publishing the directory together refuses a concurrently created destination.
            Directory.Move(staged, directory);
        }
        finally
        {
            if (Directory.Exists(staged)) { RejectLinks(staged); Directory.Delete(staged, recursive: true); }
        }
        return preview with { AlreadyCurrent = false };
    }

    private byte[] Target()
    {
        var value = Encoding.UTF8.GetBytes(TargetHeader + executable + "\n");
        if (value.Length > 32768) throw new IOException(T("请选择不含跳转或控制字符的本地绝对 CLI 路径。"));
        return value;
    }

    private (string Digest, ushort Machine) EngineIdentity()
    {
        RejectLinks(executable);
        using var stream = new FileStream(executable, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length is < 64 or > 536870912 || !Path.GetFileName(executable).Equals("shou.exe", StringComparison.OrdinalIgnoreCase))
            throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        Span<byte> header = stackalloc byte[64]; stream.ReadExactly(header);
        var offset = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(header[60..]);
        if (header[0] != 'M' || header[1] != 'Z' || offset < 64 || offset > stream.Length - 24)
            throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        stream.Position = offset; stream.ReadExactly(header[..6]);
        if (!header[..4].SequenceEqual("PE\0\0"u8)) throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        var machine = Machine(header[4..6]);
        stream.Position = 0; return (Convert.ToHexStringLower(SHA256.HashData(stream)), machine);
    }

    private static string Absolute(string value)
    {
        if (!Path.IsPathFullyQualified(value) || value.Any(char.IsControl) || value.Length > 16000 ||
            value.Replace('\\', '/').Split('/').Any(part => part is "." or "..")) throw new IOException(T("请选择不含跳转或控制字符的本地绝对 CLI 路径。"));
        if (OperatingSystem.IsWindows() && (value.StartsWith("\\", StringComparison.Ordinal) || value.StartsWith("//", StringComparison.Ordinal) || value.Skip(2).Contains(':')))
            throw new IOException(T("请选择不含跳转或控制字符的本地绝对 CLI 路径。"));
        if (OperatingSystem.IsWindows() && GetDriveType(Path.GetPathRoot(value)!) != 3)
            throw new IOException(T("请选择不含跳转或控制字符的本地绝对 CLI 路径。"));
        return Path.GetFullPath(value);
    }

    [DllImport("kernel32.dll", EntryPoint = "GetDriveTypeW", CharSet = CharSet.Unicode)]
    private static extern uint GetDriveType(string root);

    private static void RejectLinks(string path)
    {
        for (string? current = path; current is not null; current = Path.GetDirectoryName(current))
        {
            FileAttributes attributes;
            try { attributes = File.GetAttributes(current); }
            catch (FileNotFoundException) { continue; }
            catch (DirectoryNotFoundException) { continue; }
            if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Offline | (FileAttributes)0x00440000)) != 0)
                throw new IOException(T("CLI 文件或上级目录包含链接或未下载文件，现有内容已保留。"));
        }
    }

    private static byte[] Read(string path, int limit)
    {
        RejectLinks(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > limit) throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
    }

    private static byte[] Image(string path)
    {
        var bytes = Read(path, 4 * 1024 * 1024);
        if (bytes.Length < 64 || bytes[0] != 'M' || bytes[1] != 'Z') throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        var offset = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(60, 4));
        if (offset < 64 || offset > bytes.Length - 24 || !bytes.AsSpan(offset, 4).SequenceEqual("PE\0\0"u8))
            throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        _ = Machine(bytes.AsSpan(offset + 4, 2));
        return bytes;
    }

    private static ushort Machine(ReadOnlySpan<byte> bytes)
    {
        var value = System.Buffers.Binary.BinaryPrimitives.ReadUInt16LittleEndian(bytes);
        if (value is not (0x8664 or 0xaa64)) throw new IOException(T("缺少有效的随包 Windows CLI 或启动器，请安装完整发行版。"));
        return value;
    }

    private static void Write(string path, byte[] bytes)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        stream.Write(bytes); stream.Flush(true);
    }
}
