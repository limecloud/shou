using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Only installs bundled instructions. Never edits agent settings or starts a client.</summary>
public static class AgentSkillInstallation
{
    private const string ManifestName=".shou-skill-manifest.json";
    private sealed record Manifest(string Skill,Dictionary<string,string> Files);
    private static readonly JsonSerializerOptions ManifestOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public sealed record Result(string Agent,string Directory,string State,string? BackupDirectory);
    public static string DefaultDirectory(string agent)
    {
        if (agent is not ("codex" or "claude-code")) throw Invalid();
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),agent == "codex" ? ".agents" : ".claude","skills");
    }
    public static Result Install(string agent,string skill=BundledAgentSkills.DefaultName,string? directory=null)
    {
        _=DefaultDirectory(agent);
        var files=BundledAgentSkills.Files(skill);
        var selected=directory ?? DefaultDirectory(agent);
        if (!Path.IsPathFullyQualified(selected)) throw Invalid();
        var parent=Path.GetFullPath(selected);
        var destination=Path.Combine(parent,skill);
        RejectLinks(destination);
        var desired=files.ToDictionary(pair=>pair.Key,pair=>Digest(Encoding.UTF8.GetBytes(pair.Value)),StringComparer.Ordinal);
        var state="installed";
        Dictionary<string,string>? existing=null;
        byte[]? reviewedManifest=null;
        if (Directory.Exists(destination))
        {
            existing=Inventory(destination);
            if (Equal(existing,desired)) return new(agent,destination,"already_current",null);
            Manifest? saved;
            try { reviewedManifest=ReadFile(Path.Combine(destination,ManifestName),32768); saved=JsonSerializer.Deserialize<Manifest>(reviewedManifest,ManifestOptions); }
            catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { throw Conflict(); }
            if (saved is null || saved.Skill != skill || saved.Files is null || !Equal(saved.Files,existing)) throw Conflict();
            state="updated";
        }
        Directory.CreateDirectory(parent); RejectLinks(parent);
        var staged=Path.Combine(parent,"."+skill+"-install-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staged);
        string? backup=null;
        foreach (var (relative,content) in files)
        {
            var path=Path.Combine(staged,relative.Replace('/',Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var stream=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None);
            stream.Write(Encoding.UTF8.GetBytes(content));
        }
        File.WriteAllBytes(Path.Combine(staged,ManifestName),JsonSerializer.SerializeToUtf8Bytes(new Manifest(skill,desired),ManifestOptions));
        RejectLinks(destination);
        if (existing is not null)
        {
            if (!Equal(existing,Inventory(destination)) || reviewedManifest is null ||
                !reviewedManifest.AsSpan().SequenceEqual(ReadFile(Path.Combine(destination,ManifestName),32768))) throw Conflict();
            backup=Path.Combine(parent,"."+skill+"-backup-"+Guid.NewGuid().ToString("N"));
            Directory.Move(destination,backup);
        }
        else if (Directory.Exists(destination) || File.Exists(destination)) throw Conflict();
        try { Directory.Move(staged,destination); }
        catch { if (backup is not null && !Directory.Exists(destination)) Directory.Move(backup,destination); throw; }
        return new(agent,destination,state,backup);
    }

    public static void Export(string output,string skill=BundledAgentSkills.DefaultName)
    {
        var files=BundledAgentSkills.Files(skill);
        if (!Path.IsPathFullyQualified(output)) throw Invalid();
        var path=Path.GetFullPath(output);
        if (!path.EndsWith(".zip",StringComparison.OrdinalIgnoreCase)) throw Invalid();
        RejectLinks(path);
        using var stream=new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None);
        using var zip=new ZipArchive(stream,ZipArchiveMode.Create);
        foreach (var (relative,content) in files)
        {
            var entry=zip.CreateEntry(skill+"/"+relative);
            using var writer=new StreamWriter(entry.Open(),new UTF8Encoding(false)); writer.Write(content);
        }
    }
    private static Dictionary<string,string> Inventory(string directory)
    {
        var values=new Dictionary<string,string>(StringComparer.Ordinal);
        var pending=new Stack<string>(); pending.Push(directory); var count=0;
        while (pending.TryPop(out var parent))
        {
            RejectLinks(parent);
            foreach (var path in Directory.EnumerateFileSystemEntries(parent))
            {
                if (++count>128) throw Conflict(); RejectLinks(path);
                if (Directory.Exists(path)) { pending.Push(path); continue; }
                var relative=Path.GetRelativePath(directory,path).Replace(Path.DirectorySeparatorChar,'/');
                if (relative != ManifestName) values.Add(relative,Digest(ReadFile(path,262144)));
            }
        }
        return values;
    }
    private static byte[] ReadFile(string path,int limit)
    {
        RejectLinks(path);
        using var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);
        if (stream.Length>limit) throw Conflict();
        var bytes=new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
    }
    private static void RejectLinks(string path)
    {
        for (var current=Path.GetFullPath(path); !string.IsNullOrEmpty(current); current=Path.GetDirectoryName(current))
        {
            try { if ((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0) throw Invalid(); }
            catch (FileNotFoundException) {} catch (DirectoryNotFoundException) {}
        }
    }
    private static bool Equal(Dictionary<string,string> a,Dictionary<string,string> b) => a.Count==b.Count && a.All(pair=>b.TryGetValue(pair.Key,out var value) && pair.Value==value);
    private static string Digest(byte[] bytes)=>"sha256:"+Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static ShouException Invalid()=>new("invalid_argument","Choose a bundled Skill and an absolute path without links.");
    private static ShouException Conflict()=>new("version_conflict","The installed Skill has local changes. Existing files were preserved.");
}
