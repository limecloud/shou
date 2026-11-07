using System.Text.Json;

namespace Shou.Windows.Core;

public static class BundledAgentSkills
{
    public const string DefaultName="shou-rule-authoring";
    public const string CleanupName="shou-cleanup-assistant";
    private static Dictionary<string,Dictionary<string,string>> Load()
    {
        using var stream=typeof(BundledAgentSkills).Assembly.GetManifestResourceStream("Shou.AgentSkills.json") ?? throw new ShouException("resource_unavailable","Bundled Skills are unavailable.");
        return JsonSerializer.Deserialize<Dictionary<string,Dictionary<string,string>>>(stream) ?? throw new ShouException("resource_unavailable","Bundled Skills are unavailable.");
    }
    public static string[] Names => Load().Keys.Order(StringComparer.Ordinal).ToArray();
    public static IReadOnlyDictionary<string,string> Files(string name) => Load().TryGetValue(name,out var files) ? files : throw new ShouException("invalid_argument","Unknown bundled Skill.");
    public static string Read(string name,string file="SKILL.md") => Files(name).TryGetValue(file,out var content) ? content : throw new ShouException("invalid_argument","Unknown bundled Skill file.");
}
