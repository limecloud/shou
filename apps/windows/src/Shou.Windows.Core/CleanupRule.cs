using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;

namespace Shou.Windows.Core;

public sealed class CleanupRule
{
    public JsonElement Definition { get; }
    public string Id { get; }
    public string Version { get; }
    public string Name { get; }
    public string RootReference { get; }
    public int MaxDiscoveryDepth { get; }
    public bool AppliesToWindows { get; }
    public ImmutableArray<RulePattern> Patterns { get; }
    public ImmutableArray<RulePattern> Exclusions { get; }
    public ImmutableArray<string> ParentMarkers { get; }
    public long MinimumAllocatedBytes { get; }
    public int? MinimumNewestAgeDays { get; }
    public string DeclaredRisk { get; }
    public string Digest { get; }

    internal CleanupRule(JsonElement definition)
    {
        Definition = definition;
        Id = definition.GetProperty("id").GetString()!;
        Version = definition.GetProperty("version").GetString()!;
        Name = definition.GetProperty("name").GetString()!;
        var scope = definition.GetProperty("scope");
        RootReference = scope.GetProperty("root_ref").GetString()!;
        MaxDiscoveryDepth = (int)scope.GetProperty("max_depth").GetDecimal();
        AppliesToWindows = definition.GetProperty("platforms").EnumerateArray().Any(item => item.GetString() == "windows");
        var match = definition.GetProperty("match");
        Patterns = match.GetProperty("relative_patterns").EnumerateArray().Select(item => new RulePattern(item.GetString()!, target: true)).ToImmutableArray();
        Exclusions = definition.GetProperty("exclude").GetProperty("relative_patterns").EnumerateArray().Select(item => new RulePattern(item.GetString()!)).ToImmutableArray();
        ParentMarkers = match.TryGetProperty("project_markers", out var markers)
            ? markers.GetProperty("all_of").EnumerateArray().Select(item => item.GetString()!).ToImmutableArray() : [];
        var conditions = definition.GetProperty("conditions");
        MinimumAllocatedBytes = (long)conditions.GetProperty("min_allocated_bytes").GetDecimal();
        MinimumNewestAgeDays = conditions.TryGetProperty("newest_descendant_modified_days_at_least", out var age) ? (int)age.GetDecimal() : null;
        DeclaredRisk = definition.GetProperty("risk").GetProperty("declared_level").GetString()!;
        using var canonical = new MemoryStream();
        using (var writer = new Utf8JsonWriter(canonical)) WriteCanonical(writer, definition);
        Digest = "sha256:" + Convert.ToHexStringLower(SHA256.HashData(canonical.ToArray()));
    }

    private static void WriteCanonical(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject().Where(property => property.Name != "$schema").OrderBy(property => property.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteCanonical(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray()) WriteCanonical(writer, item);
                writer.WriteEndArray();
                break;
            case JsonValueKind.Number:
                writer.WriteNumberValue((long)value.GetDecimal());
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }
}
