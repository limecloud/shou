using System.Collections.Immutable;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

public sealed record RuleIssue(string Path, string Code);
public sealed record RuleValidationResult(bool IsValid, ImmutableArray<RuleIssue> Issues);

/// <summary>Only the vocabulary in the bundled closed schema; external references are never fetched.</summary>
public sealed class RuleSchemaValidator
{
    public const int MaximumRuleBytes = 262_144;
    private readonly JsonElement schema;
    private static readonly HashSet<string> Keywords = new(StringComparer.Ordinal)
    {
        "$schema", "$ref", "$defs", "title", "description", "type", "const", "enum",
        "additionalProperties", "required", "properties", "items", "minItems", "maxItems", "uniqueItems",
        "minLength", "maxLength", "pattern", "minimum", "maximum"
    };

    public RuleSchemaValidator(ReadOnlyMemory<byte> bundledSchema)
    {
        using var document = JsonDocument.Parse(bundledSchema, DocumentOptions);
        schema = document.RootElement.Clone();
        CheckVocabulary(schema);
    }

    private static JsonDocumentOptions DocumentOptions => new()
    {
        MaxDepth = 64, AllowDuplicateProperties = false, AllowTrailingCommas = false, CommentHandling = JsonCommentHandling.Disallow
    };

    public RuleValidationResult Validate(ReadOnlyMemory<byte> json)
    {
        if (json.Length > MaximumRuleBytes) return new(false, [new("$", "resource_limit")]);
        var issues = ImmutableArray.CreateBuilder<RuleIssue>();
        try
        {
            using var document = JsonDocument.Parse(json, DocumentOptions);
            Check(document.RootElement, schema, "$", issues);
            if (issues.Count == 0) CheckPatterns(document.RootElement, issues);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException) { issues.Add(new("$", "invalid_json")); }
        return new(issues.Count == 0, issues.ToImmutable());
    }

    public JsonElement ExportSchema() => schema;

    public CleanupRule Parse(ReadOnlyMemory<byte> json)
    {
        var validation = Validate(json);
        if (!validation.IsValid)
            throw new ShouException(validation.Issues.Any(issue => issue.Code == "resource_limit") ? "resource_limit" : "invalid_rule",
                "Rule validation failed: " + string.Join(", ", validation.Issues.Take(16).Select(issue => issue.Path + ": " + issue.Code)));
        using var document = JsonDocument.Parse(json, DocumentOptions);
        return new(document.RootElement.Clone());
    }

    private void Check(JsonElement value, JsonElement shape, string path, ImmutableArray<RuleIssue>.Builder issues)
    {
        if (shape.TryGetProperty("$ref", out var reference))
        {
            var target = schema;
            var pointer = reference.GetString() ?? "";
            if (!pointer.StartsWith("#/$defs/", StringComparison.Ordinal)) throw Unsupported();
            foreach (var part in pointer[2..].Split('/'))
                if (!target.TryGetProperty(part, out target)) throw Unsupported();
            Check(value, target, path, issues);
            return;
        }
        if (shape.TryGetProperty("const", out var constant) && !JsonElement.DeepEquals(value, constant)) issues.Add(new(path, "unexpected_constant"));
        if (shape.TryGetProperty("enum", out var choices) && !choices.EnumerateArray().Any(item => JsonElement.DeepEquals(item, value))) issues.Add(new(path, "unsupported_value"));
        if (shape.TryGetProperty("type", out var type) && !MatchesType(value, type.GetString()))
        {
            issues.Add(new(path, "unexpected_type"));
            return;
        }
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                if (shape.TryGetProperty("required", out var required))
                    foreach (var key in required.EnumerateArray())
                        if (!value.TryGetProperty(key.GetString()!, out _)) issues.Add(new(path + "." + key.GetString(), "required"));
                shape.TryGetProperty("properties", out var properties);
                foreach (var property in value.EnumerateObject())
                {
                    if (properties.ValueKind == JsonValueKind.Object && properties.TryGetProperty(property.Name, out var child))
                        Check(property.Value, child, path + "." + property.Name, issues);
                    else if (shape.TryGetProperty("additionalProperties", out var additional) && additional.ValueKind == JsonValueKind.False)
                        issues.Add(new(path + "." + property.Name, "unknown_field"));
                }
                break;
            case JsonValueKind.Array:
                var items = value.EnumerateArray().ToArray();
                Bound(items.Length, shape, "minItems", "maxItems", path, issues);
                if (shape.TryGetProperty("maxItems", out var maximumItems) && items.Length > maximumItems.GetInt32()) return;
                if (shape.TryGetProperty("uniqueItems", out var unique) && unique.ValueKind == JsonValueKind.True)
                    for (var index = 0; index < items.Length; index++)
                        if (items.Take(index).Any(previous => JsonElement.DeepEquals(previous, items[index]))) issues.Add(new(path + $"[{index}]", "duplicate_item"));
                if (shape.TryGetProperty("items", out var itemShape))
                    for (var index = 0; index < items.Length; index++) Check(items[index], itemShape, path + $"[{index}]", issues);
                break;
            case JsonValueKind.String:
                var text = value.GetString()!;
                Bound(text.EnumerateRunes().Count(), shape, "minLength", "maxLength", path, issues);
                if (shape.TryGetProperty("pattern", out var pattern) && !Regex.IsMatch(text, pattern.GetString()!, RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(100)))
                    issues.Add(new(path, "invalid_format"));
                break;
            case JsonValueKind.Number:
                if (value.TryGetDecimal(out var number)) Bound(number, shape, "minimum", "maximum", path, issues);
                else issues.Add(new(path, "invalid_number"));
                break;
        }
    }

    private static bool MatchesType(JsonElement value, string? type) => type switch
    {
        "object" => value.ValueKind == JsonValueKind.Object,
        "array" => value.ValueKind == JsonValueKind.Array,
        "string" => value.ValueKind == JsonValueKind.String,
        "boolean" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
        "integer" => value.ValueKind == JsonValueKind.Number && value.TryGetDecimal(out var number) && decimal.Truncate(number) == number,
        _ => throw Unsupported()
    };

    private static void Bound(decimal value, JsonElement shape, string minimum, string maximum, string path, ImmutableArray<RuleIssue>.Builder issues)
    {
        if (shape.TryGetProperty(minimum, out var min) && value < min.GetDecimal()) issues.Add(new(path, "below_minimum"));
        if (shape.TryGetProperty(maximum, out var max) && value > max.GetDecimal()) issues.Add(new(path, "above_maximum"));
    }

    private static void CheckPatterns(JsonElement rule, ImmutableArray<RuleIssue>.Builder issues)
    {
        foreach (var (parent, target) in new[] { ("match", true), ("exclude", false) })
            foreach (var pattern in rule.GetProperty(parent).GetProperty("relative_patterns").EnumerateArray())
                try { _ = new RulePattern(pattern.GetString()!, target); }
                catch (ShouException) { issues.Add(new("$." + parent + ".relative_patterns", "invalid_pattern")); }
        if (rule.GetProperty("match").TryGetProperty("project_markers", out var markers))
            foreach (var marker in markers.GetProperty("all_of").EnumerateArray())
                try
                {
                    var text = marker.GetString()!;
                    _ = new RulePattern(text);
                    if (text.Contains('/') || text.Contains('*') || text.Contains('?')) throw new ShouException("invalid_rule", "Invalid marker.");
                }
                catch (ShouException) { issues.Add(new("$.match.project_markers.all_of", "invalid_marker")); }
    }

    private static void CheckVocabulary(JsonElement shape)
    {
        if (shape.ValueKind != JsonValueKind.Object) throw Unsupported();
        foreach (var property in shape.EnumerateObject())
        {
            if (!Keywords.Contains(property.Name)) throw Unsupported();
            if (property.Name == "$ref" && property.Value.GetString()?.StartsWith("#/$defs/", StringComparison.Ordinal) != true) throw Unsupported();
            if (property.Name is "properties" or "$defs")
                foreach (var child in property.Value.EnumerateObject()) CheckVocabulary(child.Value);
            else if (property.Name == "items") CheckVocabulary(property.Value);
        }
    }

    private static ShouException Unsupported() => new("unsupported_schema", "The bundled rule schema requires an unsupported validator capability.");
}
