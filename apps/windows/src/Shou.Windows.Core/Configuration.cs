using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

public sealed record Workspace(string Id, string RootRef, WindowsPath Path, FileIdentity Identity,
    bool CaseSensitive, ImmutableArray<string> Exclusions, DateTimeOffset AddedAt)
{
    public bool SameRegistration(Workspace other) => Id == other.Id && RootRef == other.RootRef && Path == other.Path &&
        Identity == other.Identity && CaseSensitive == other.CaseSensitive && AddedAt == other.AddedAt &&
        Exclusions.SequenceEqual(other.Exclusions, StringComparer.Ordinal);
}

public sealed record RuleRecord(JsonElement Rule, string Digest, DateTimeOffset ImportedAt, string Provenance);
public sealed record RuleBinding(string WorkspaceId, string RuleId, string Version, string Digest, bool Enabled);
public sealed record Configuration(int Version, string Revision, ImmutableArray<Workspace> Workspaces,
    ImmutableArray<RuleRecord> Rules, ImmutableArray<RuleBinding> Bindings, ImmutableArray<string> GlobalExclusions)
{
    public static Configuration Empty { get; } = new(1, "config_unconfigured", [], [], [], []);
}

public sealed record ExclusionSettings(ImmutableArray<string> GlobalPatterns, string? WorkspaceId, ImmutableArray<string> WorkspacePatterns)
{
    public ImmutableArray<string> EffectivePatterns => GlobalPatterns.Concat(WorkspacePatterns).Distinct(StringComparer.Ordinal).ToImmutableArray();
}

public sealed class ConfigurationCodec(RuleSchemaValidator validator)
{
    public const int MaximumBytes = 16_777_216;
    public const int MaximumWorkspaces = 256;
    public const int MaximumRules = 512;
    public const int MaximumBindings = 4096;
    public const int MaximumExclusions = 1024;

    public Configuration Decode(byte[]? bytes)
    {
        if (bytes is null) return Configuration.Empty;
        if (bytes.Length > MaximumBytes) throw Corrupt();
        try
        {
            var configuration = JsonSerializer.Deserialize<Configuration>(bytes, ContractJson.Options) ?? throw Corrupt();
            Validate(configuration);
            return configuration;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or ArgumentException)
        { throw Corrupt(error); }
        catch (ShouException error) when (error.Code != "store_corrupt") { throw Corrupt(error); }
    }

    public byte[] Encode(Configuration configuration)
    {
        Validate(configuration);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(configuration, ContractJson.Options);
        if (bytes.Length > MaximumBytes) throw new ShouException("resource_limit", "The configuration exceeds its storage budget.");
        return bytes;
    }

    public string Digest(Configuration configuration) => "sha256:" + Convert.ToHexStringLower(SHA256.HashData(Encode(configuration)));

    public void Validate(Configuration configuration)
    {
        if (configuration.Version != 1 || !ValidId(configuration.Revision, "config") ||
            configuration.Workspaces.IsDefault || configuration.Rules.IsDefault || configuration.Bindings.IsDefault || configuration.GlobalExclusions.IsDefault ||
            configuration.Workspaces.Length > MaximumWorkspaces || configuration.Rules.Length > MaximumRules || configuration.Bindings.Length > MaximumBindings)
            throw Corrupt();
        ValidateExclusions(configuration.GlobalExclusions);
        var workspaceIds = new HashSet<string>(StringComparer.Ordinal);
        var rootRefs = new HashSet<string>(StringComparer.Ordinal);
        var roots = new HashSet<FileIdentity>();
        foreach (var workspace in configuration.Workspaces)
        {
            if (workspace is null || !ValidId(workspace.Id, "ws") || !workspaceIds.Add(workspace.Id) || !rootRefs.Add(workspace.RootRef) ||
                !ValidRootRef(workspace.RootRef) || workspace.Path is null || workspace.Path.IsVolumeRoot || workspace.Identity is null ||
                !roots.Add(workspace.Identity) || workspace.AddedAt.Offset != TimeSpan.Zero) throw Corrupt();
            ValidateExclusions(workspace.Exclusions);
        }
        var rules = new Dictionary<(string, string), CleanupRule>();
        foreach (var record in configuration.Rules)
        {
            if (record is null || record.ImportedAt.Offset != TimeSpan.Zero || record.Provenance is not ("local_file" or "user_draft")) throw Corrupt();
            CleanupRule rule;
            try { rule = validator.Parse(Encoding.UTF8.GetBytes(record.Rule.GetRawText())); }
            catch (ShouException error) { throw Corrupt(error); }
            if (rule.Id.StartsWith("shou.builtin.", StringComparison.Ordinal) || record.Digest != rule.Digest || !rules.TryAdd((rule.Id, rule.Version), rule)) throw Corrupt();
        }
        var bindings = new HashSet<(string, string)>();
        foreach (var binding in configuration.Bindings)
        {
            if (binding is null || binding.RuleId is null || !bindings.Add((binding.WorkspaceId, binding.RuleId)) ||
                configuration.Workspaces.FirstOrDefault(workspace => workspace.Id == binding.WorkspaceId) is not { } root) throw Corrupt();
            if (binding.RuleId.StartsWith(BuiltinRuleCatalog.Prefix, StringComparison.Ordinal))
            {
                if (!BuiltinRuleCatalog.ValidBinding(binding)) throw Corrupt();
                continue;
            }
            if (!rules.TryGetValue((binding.RuleId, binding.Version), out var rule) || binding.Digest != rule.Digest || !rule.AppliesToWindows || root.RootRef != rule.RootReference) throw Corrupt();
        }
    }

    public static bool ValidRootRef(string value) => value is { Length: >= 1 and <= 80 } &&
        Regex.IsMatch(value, "^[a-z][a-z0-9-]*$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    private static bool ValidId(string value, string prefix) => value == "config_unconfigured" && prefix == "config" || RecordKey.IsId(value, prefix);

    private static void ValidateExclusions(ImmutableArray<string> patterns)
    {
        if (patterns.IsDefault || patterns.Length > MaximumExclusions || patterns.Any(pattern => pattern is null) || patterns.Distinct(StringComparer.Ordinal).Count() != patterns.Length) throw Corrupt();
        try { foreach (var pattern in patterns) _ = new RulePattern(pattern); }
        catch (ShouException error) { throw Corrupt(error); }
    }

    private static ShouException Corrupt(Exception? inner = null) => new("store_corrupt", "The configuration is invalid or unsupported.", inner);
}
