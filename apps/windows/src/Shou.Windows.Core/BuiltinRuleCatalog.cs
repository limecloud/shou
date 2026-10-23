using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

public sealed record WindowsUserDirectories(WindowsPath Home, WindowsPath LocalAppData, WindowsPath RoamingAppData);
public sealed record BuiltinLocation(string Id, string Title, string Category, WindowsPath Path);
public sealed record BuiltinTemplate(string Id, string Version, string Name, string Category, ImmutableArray<string> Patterns,
    string? Marker, string Risk, string RebuildNote, string Limitation, string Location, ImmutableArray<string> Platforms);

/// <summary>Bundled definitions are the only source of built-in rules. Local bindings hold preferences, never definitions.</summary>
public sealed class BuiltinRuleCatalog
{
    public const string Prefix = "shou.builtin.";
    private readonly RuleSchemaValidator validator;
    public WindowsUserDirectories Directories { get; }
    public ImmutableArray<BuiltinTemplate> Templates { get; }
    public ImmutableArray<BuiltinLocation> Locations { get; }
    public ImmutableArray<string> ProjectPaths { get; }

    public BuiltinRuleCatalog(RuleSchemaValidator validator, WindowsUserDirectories directories,
        ReadOnlyMemory<byte> templates, ReadOnlyMemory<byte> locations, ReadOnlyMemory<byte> projects)
    {
        this.validator = validator;
        Directories = directories;
        try
        {
            using var locationJson = Resource(locations);
            var declaredLocations = locationJson.RootElement.EnumerateArray().ToArray();
            if (declaredLocations.Length is < 1 or > 256) throw Invalid();
            var locationIds = new HashSet<string>(StringComparer.Ordinal);
            var locationPaths = new HashSet<WindowsPath>();
            Locations = declaredLocations.Select(value =>
            {
                Fields(value, "id", "title", "category", "relativePath", "platform");
                var id = value.GetProperty("id").GetString()!;
                var relative = value.GetProperty("relativePath").GetString()!;
                ExactRelative(relative);
                var path = relative.StartsWith("AppData/Local/", StringComparison.Ordinal) ? directories.LocalAppData.Append(relative[14..]) :
                    relative.StartsWith("AppData/Roaming/", StringComparison.Ordinal) ? directories.RoamingAppData.Append(relative[16..]) : directories.Home.Append(relative);
                var title = value.GetProperty("title").GetString()!;
                var category = value.GetProperty("category").GetString()!;
                if (!ValidReference(id) || !locationIds.Add(id) || !locationPaths.Add(path) || title.Length is < 1 or > 120 ||
                    value.GetProperty("platform").GetString() != "windows" || category is not ("application" or "browser" or "developer" or "system")) throw Invalid();
                return new BuiltinLocation(id, title, category, path);
            }).ToImmutableArray();

            using var projectJson = Resource(projects);
            ProjectPaths = projectJson.RootElement.EnumerateArray().Select(value => value.GetString()!).ToImmutableArray();
            if (ProjectPaths.Length is < 1 or > 64 || ProjectPaths.Distinct(StringComparer.Ordinal).Count() != ProjectPaths.Length) throw Invalid();
            foreach (var path in ProjectPaths) ExactRelative(path);

            using var templateJson = Resource(templates);
            var declaredTemplates = templateJson.RootElement.EnumerateArray().ToArray();
            if (declaredTemplates.Length is < 1 or > ConfigurationCodec.MaximumRules) throw Invalid();
            var ids = new HashSet<string>(StringComparer.Ordinal);
            Templates = declaredTemplates.Select(value =>
            {
                Fields(value, "id", "version", "name", "category", "patterns", "marker", "risk", "rebuildNote", "limitation", "location", "applicationBundleIdentifiers", "platforms");
                var location = value.GetProperty("location").GetString()!;
                var platforms = value.TryGetProperty("platforms", out var supported) ? supported.EnumerateArray().Select(item => item.GetString()!).ToImmutableArray() :
                    location == "projects" ? ImmutableArray.Create("macos", "windows") : ImmutableArray.Create("macos");
                var template = new BuiltinTemplate(value.GetProperty("id").GetString()!, value.TryGetProperty("version", out var version) ? version.GetString()! : "1.0.0",
                    value.GetProperty("name").GetString()!, value.GetProperty("category").GetString()!,
                    value.GetProperty("patterns").EnumerateArray().Select(item => item.GetString()!).ToImmutableArray(),
                    value.TryGetProperty("marker", out var marker) ? marker.GetString() : null, value.GetProperty("risk").GetString()!, value.GetProperty("rebuildNote").GetString()!,
                    value.GetProperty("limitation").GetString()!, location, platforms);
                if (!template.Id.StartsWith(Prefix, StringComparison.Ordinal) || !ids.Add(template.Id) || !platforms.Contains("windows") ||
                    location != "projects" && !locationIds.Contains(location) || template.Category is not ("cache" or "build" or "dependencies" or "logs" or "application" or "browser" or "developer" or "system")) throw Invalid();
                _ = Rule(template, "catalog-validation");
                return template;
            }).ToImmutableArray();
            if (Locations.Any(location => !Templates.Any(template => template.Location == location.Id))) throw Invalid();
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or ArgumentException or NullReferenceException or ShouException)
        { throw new ShouException("resource_unavailable", "The bundled Windows rule catalog is invalid or unavailable.", error); }
    }

    public ImmutableArray<CleanupRule> RulesFor(Workspace workspace)
    {
        var exact = Locations.Where(location => location.Path.SamePath(workspace.Path, caseSensitive: true)).Select(location => location.Id).ToHashSet(StringComparer.Ordinal);
        // Ambiguous spelling and overlapping cache roots never become generic project scopes.
        if (exact.Count == 0 && Locations.Any(location => location.Path.IsWithin(workspace.Path) || workspace.Path.IsWithin(location.Path))) return [];
        return Templates.Where(template => exact.Count > 0 ? exact.Contains(template.Location) : template.Location == "projects")
            .Select(template => Rule(template, workspace.RootRef)).ToImmutableArray();
    }

    public CleanupRule Rule(BuiltinTemplate template, string rootReference)
    {
        var match = new JsonObject { ["kind"] = "directory", ["relative_patterns"] = JsonSerializer.SerializeToNode(template.Patterns) };
        if (template.Marker is { } marker) match["project_markers"] = new JsonObject { ["location"] = "parent", ["all_of"] = new JsonArray(marker) };
        var rule = new JsonObject
        {
            ["schema_version"] = "1.0", ["id"] = template.Id, ["version"] = template.Version, ["name"] = template.Name,
            ["description"] = template.RebuildNote, ["platforms"] = JsonSerializer.SerializeToNode(template.Platforms),
            ["scope"] = new JsonObject { ["root_ref"] = rootReference, ["max_depth"] = 24, ["follow_symlinks"] = false, ["cross_filesystems"] = false },
            ["match"] = match, ["conditions"] = new JsonObject { ["min_allocated_bytes"] = 0 },
            ["exclude"] = new JsonObject { ["relative_patterns"] = new JsonArray() },
            ["risk"] = new JsonObject { ["declared_level"] = template.Risk, ["rebuild_note"] = template.RebuildNote, ["limitations"] = new JsonArray(template.Limitation) },
            ["action"] = new JsonObject { ["type"] = "trash" }
        };
        return validator.Parse(Encoding.UTF8.GetBytes(rule.ToJsonString()));
    }

    public static bool ValidBinding(RuleBinding binding) => binding.RuleId is { Length: <= 128 } && binding.RuleId.StartsWith(Prefix, StringComparison.Ordinal) &&
        Regex.IsMatch(binding.RuleId, "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking) &&
        binding.Version is { Length: <= 32 } && Regex.IsMatch(binding.Version, "^[0-9]+\\.[0-9]+\\.[0-9]+$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking) && RecordJson.IsDigest(binding.Digest);
    private static bool ValidReference(string value) => value.Length <= 64 && ConfigurationCodec.ValidRootRef(value);
    private static void ExactRelative(string path)
    {
        WindowsPath.ValidateRelative(path);
        if (path.Contains('*') || path.Contains('?')) throw Invalid();
    }
    private static JsonDocument Resource(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.Length is < 2 or > 2_097_152) throw Invalid();
        return JsonDocument.Parse(bytes, new() { MaxDepth = 32 });
    }
    private static void Fields(JsonElement value, params string[] names)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Invalid();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in value.EnumerateObject()) if (!names.Contains(property.Name) || !seen.Add(property.Name)) throw Invalid();
    }
    private static ShouException Invalid() => new("invalid_rule", "The bundled rule metadata is invalid.");
}
