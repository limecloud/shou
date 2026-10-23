using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class RuleTests
{
    private static RuleSchemaValidator Validator() => new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));
    private static JsonNode Example() => JsonNode.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Examples/rust-target.rule.json")))!;
    private static byte[] Bytes(JsonNode node) => Encoding.UTF8.GetBytes(node.ToJsonString());

    [Fact]
    public void ParsesTheSharedRuleExampleWithoutInferringWindowsApplicability()
    {
        var rule = Validator().Parse(Bytes(Example()));
        Assert.Equal("dev.rust-target", rule.Id);
        Assert.Equal("developer-workspaces", rule.RootReference);
        Assert.Equal(104857600, rule.MinimumAllocatedBytes);
        Assert.Equal(14, rule.MinimumNewestAgeDays);
        Assert.False(rule.AppliesToWindows);
        Assert.True(rule.Patterns[0].Matches("target"));
        Assert.Equal(new[] { "Cargo.toml" }, rule.ParentMarkers.ToArray());
    }

    [Fact]
    public void ParsesAllSharedExamplesAndWindowsApplicabilityExplicitly()
    {
        var validator = Validator();
        foreach (var path in Directory.EnumerateFiles(Path.Combine(AppContext.BaseDirectory, "Examples"), "*.rule.json"))
        {
            var source = JsonNode.Parse(File.ReadAllBytes(path))!;
            _ = validator.Parse(Bytes(source));
            source["platforms"] = new JsonArray("windows");
            Assert.True(validator.Parse(Bytes(source)).AppliesToWindows);
        }
    }

    [Theory]
    [InlineData("schema_version", "2.0")]
    [InlineData("id", "../unsafe")]
    [InlineData("version", "1.0")]
    [InlineData("name", "")]
    public void RejectsInvalidTopLevelFields(string field, string value)
    {
        var input = Example();
        input[field] = value;
        Assert.False(Validator().Validate(Bytes(input)).IsValid);
    }

    [Fact]
    public void RejectsMissingUnknownDuplicateAndNullProperties()
    {
        var input = Example();
        input["scope"]!["follow_symlinks"] = true;
        input["risk"]!["execute"] = "shell command";
        input.AsObject().Remove("description");
        var result = Validator().Validate(Bytes(input));
        Assert.False(result.IsValid);
        Assert.Contains(result.Issues, issue => issue.Code == "required");
        Assert.Contains(result.Issues, issue => issue.Code == "unknown_field");
        Assert.Contains(result.Issues, issue => issue.Code == "unexpected_constant");
        Assert.False(Validator().Validate(Encoding.UTF8.GetBytes("{\"id\":1,\"id\":2}")).IsValid);
        input = Example();
        input["scope"] = null;
        Assert.False(Validator().Validate(Bytes(input)).IsValid);
    }

    [Theory]
    [InlineData("**")]
    [InlineData("**/*")]
    [InlineData("../target")]
    [InlineData("C:/target")]
    [InlineData("target/**bad")]
    [InlineData("target/{a,b}")]
    [InlineData("$HOME/target")]
    public void RejectsPatternsThatEscapeOrSelectTheWholeRoot(string pattern)
    {
        var input = Example();
        input["match"]!["relative_patterns"] = new JsonArray(pattern);
        var result = Validator().Validate(Bytes(input));
        Assert.Contains(result.Issues, issue => issue.Code == "invalid_pattern");
    }

    [Fact]
    public void MarkersCannotBeGlobsOrPaths()
    {
        var input = Example();
        input["match"]!["project_markers"]!["all_of"] = new JsonArray("../Cargo.toml");
        Assert.Contains(Validator().Validate(Bytes(input)).Issues, issue => issue.Code == "invalid_marker");
    }

    [Fact]
    public void SemanticDigestIgnoresObjectOrderWhitespaceAndEditorHints()
    {
        var input = Example();
        var original = Validator().Parse(Bytes(input));
        var reordered = new JsonObject(input.AsObject().Reverse().Select(property => new KeyValuePair<string, JsonNode?>(property.Key, property.Value?.DeepClone())));
        reordered["$schema"] = "https://example.invalid/editor-hint-only.json";
        var changedFormatting = Validator().Parse(Encoding.UTF8.GetBytes(reordered.ToJsonString(new JsonSerializerOptions { WriteIndented = true })));
        Assert.Equal(original.Digest, changedFormatting.Digest);
        reordered["conditions"]!["min_allocated_bytes"] = 1;
        Assert.NotEqual(original.Digest, Validator().Parse(Bytes(reordered)).Digest);
    }

    [Fact]
    public async Task InvalidOversizedArraysAreBoundedBeforeUniquenessChecks()
    {
        var input = Example();
        input["exclude"]!["relative_patterns"] = new JsonArray(Enumerable.Range(0, 10_000).Select(index => JsonValue.Create("x" + index)).ToArray());
        var result = await Task.Run(() => Validator().Validate(Bytes(input))).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(result.IsValid);
        Assert.Contains(result.Issues, issue => issue.Code == "above_maximum");
    }

    [Fact]
    public void RejectsOversizedPayloadAndUnsupportedSchemaVocabulary()
    {
        Assert.Contains(Validator().Validate(new byte[262_145]).Issues, issue => issue.Code == "resource_limit");
        Assert.Throws<ShouException>(() => new RuleSchemaValidator(Encoding.UTF8.GetBytes("{\"type\":\"object\",\"oneOf\":[]}")));
        Assert.Throws<ShouException>(() => new RuleSchemaValidator(Encoding.UTF8.GetBytes("{\"$ref\":\"https://example.invalid/schema\"}")));
    }

    [Theory]
    [InlineData("**/target", "target", true)]
    [InlineData("**/target", "project/nested/target", true)]
    [InlineData("**/target", "project/target/file", false)]
    [InlineData("Cache/*", "cache/item", true)]
    [InlineData("a/**/cache", "a/cache", true)]
    [InlineData("a/**/cache", "a/b/c/cache", true)]
    [InlineData("a/?", "a/📁", true)]
    [InlineData("a/?", "a/两个", false)]
    public void MatchesBoundedRelativeSegments(string pattern, string path, bool matches) =>
        Assert.Equal(matches, new RulePattern(pattern).Matches(path));

    [Fact]
    public void HonorsEachParentsCaseSensitivityWithoutNormalizingUnicode()
    {
        var pattern = new RulePattern("Project/Cache");
        Assert.True(pattern.Matches("project/Cache", [false, true]));
        Assert.False(pattern.Matches("project/cache", [false, true]));
        Assert.False(new RulePattern("café").Matches("cafe\u0301"));
    }
}
