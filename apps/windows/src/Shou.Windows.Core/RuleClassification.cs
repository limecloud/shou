using System.Collections.Immutable;
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Shou.Windows.Core;

public sealed record CleanupProtectionContext(string OwnerSid, WindowsPath HomeDirectory, WindowsPath DataDirectory,
    ImmutableArray<WindowsPath> SystemDirectories);

public sealed record RuleCandidate(string Id, string RuleId, string RuleVersion, string RelativePath, WindowsPath Path,
    FileIdentity Identity, long AllocatedBytes, long LogicalBytes, DateTimeOffset NewestModifiedAt, string Risk,
    bool Complete, string State, ImmutableArray<string> BlockedReasons, string? ManifestDigest);

public sealed record ScanRule(JsonElement Definition, string Digest);
public sealed record CleanupScan(int Version, string Id, Workspace Workspace, ScanBudget Budget, string ConfigurationRevision,
    string ConfigurationDigest, ImmutableArray<ScanRule> Rules, ScanSnapshot Scan,
    ImmutableArray<RuleCandidate> Candidates, ImmutableArray<ScanIssue> AnalysisIssues, bool PreviewOnly)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public string WorkspaceId => Workspace.Id;
}

public sealed record RuleClassification(ImmutableArray<RuleCandidate> Candidates, ImmutableArray<ScanIssue> AnalysisIssues);

public sealed class CandidateAnalysisBudget(TimeSpan duration, TimeProvider? timeProvider = null)
{
    public const int MaximumAnalysisOperations = 2_000_000;
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly long started = (timeProvider ?? TimeProvider.System).GetTimestamp();
    private int operations;
    public void Check()
    {
        if (++operations > MaximumAnalysisOperations) throw new ShouException("resource_limit", "Candidate analysis reached its operation budget.");
        if (duration <= TimeSpan.Zero || clock.GetElapsedTime(started) >= duration) throw new ShouException("time_limit", "Candidate analysis reached its time budget.");
    }
}

public sealed class RuleClassifier(CleanupProtectionContext protection, BuiltinRuleCatalog? catalog = null)
{
    private static readonly HashSet<string> ProtectedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".env",
        ".npmrc", ".pypirc", ".netrc", ".git-credentials", ".password-store", "id_rsa", "id_ed25519", "id_ecdsa",
        "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
        "Cargo.toml", "Cargo.lock", "Package.swift", "Package.resolved", "pyproject.toml", "poetry.lock",
        "requirements.txt", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"
    };
    private static readonly HashSet<string> ProtectedExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".swift", ".rs", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".fs", ".vb", ".go", ".py", ".java",
        ".js", ".ts", ".jsx", ".tsx", ".kt", ".rb", ".php", ".sql", ".sqlite", ".sqlite3", ".db", ".db3",
        ".m", ".mm", ".vue", ".svelte", ".dart", ".sh", ".ps1", ".psm1", ".psd1", ".html", ".css", ".scss",
        ".pem", ".p12", ".pfx", ".key", ".vhd", ".vhdx", ".vmdk", ".qcow2", ".sln", ".csproj", ".fsproj", ".vbproj"
    };

    public RuleClassification Classify(Configuration configuration, Workspace workspace,
        CleanupRule rule, ScanSnapshot scan, CandidateAnalysisBudget budget, CancellationToken cancellationToken)
        => Classify(configuration, workspace, rule, scan, new FileTreeIndex(scan), budget, cancellationToken);

    internal RuleClassification Classify(Configuration configuration, Workspace workspace,
        CleanupRule rule, ScanSnapshot scan, FileTreeIndex index, CandidateAnalysisBudget budget, CancellationToken cancellationToken)
    {
        if (!rule.AppliesToWindows || rule.RootReference != workspace.RootRef)
            throw new ShouException("invalid_rule", "The rule root or platform does not match this workspace.");
        if (scan.Root != workspace.Path || scan.RootIdentity != workspace.Identity)
            throw new ShouException("plan_stale", "The workspace identity changed. Register and review the current root.");
        var entries = index.Entries;
        if (!entries.TryGetValue(workspace.Path, out var root) || root.Kind != EntryKind.Directory || root.IsCaseSensitive != workspace.CaseSensitive)
            throw new ShouException("plan_stale", "The workspace case or root metadata changed.");
        var children = index.Children;
        var duplicateFiles = index.DuplicateFiles;
        // Only a current bundled definition can opt into a narrowly identified generated-source layout.
        var rust = rule.Id == RustArtifactPolicy.RuleId && catalog?.RulesFor(workspace).Any(value => value.Digest == rule.Digest) == true;
        var exclusions = configuration.GlobalExclusions.Concat(workspace.Exclusions).Select(pattern => new RulePattern(pattern)).Concat(rule.Exclusions).ToArray();
        var candidates = ImmutableArray.CreateBuilder<RuleCandidate>();
        var analysisIssues = ImmutableArray.CreateBuilder<ScanIssue>();
        void Check()
        {
            cancellationToken.ThrowIfCancellationRequested();
            budget.Check();
        }
        bool Match(RulePattern pattern, FileEntry entry)
        {
            Check();
            var relative = entry.Path.RelativeTo(scan.Root, caseSensitive: true);
            var cases = new List<bool>();
            var parent = entry.Path.Parent;
            while (parent is not null && parent.IsWithin(scan.Root, caseSensitive: true))
            {
                if (!entries.TryGetValue(parent, out var metadata)) throw new ShouException("invalid_snapshot", "Directory case evidence is missing.");
                cases.Add(metadata.IsCaseSensitive);
                if (parent == scan.Root) break;
                parent = parent.Parent;
            }
            cases.Reverse();
            return pattern.Matches(relative, cases);
        }
        bool Excluded(FileEntry entry)
        {
            for (var current = entry; current.Path != scan.Root;)
            {
                if (exclusions.Any(pattern => Match(pattern, current))) return true;
                if (current.Path.Parent is not { } parent || !entries.TryGetValue(parent, out current!)) break;
            }
            return false;
        }
        try
        {
            foreach (var target in entries.Values.Where(entry => entry.Kind == EntryKind.Directory && entry.Path != scan.Root).OrderBy(entry => entry.Path.Value, StringComparer.Ordinal))
            {
                Check();
                var relative = target.Path.RelativeTo(scan.Root, caseSensitive: true);
                if (relative.Split('/').Length > rule.MaxDiscoveryDepth || !rule.Patterns.Any(pattern => Match(pattern, target))) continue;
                var reasons = new HashSet<string>(StringComparer.Ordinal);
                var complete = index.CompletedDirectories.Contains(target.Path);
                if (!complete) reasons.Add("coverage_incomplete");
                for (var ancestor = target.Path.Parent; ancestor is not null; ancestor = ancestor.Parent)
                {
                    Check();
                    if (ProtectedNames.Contains(ancestor.Name) || IsSecretName(ancestor.Name)) reasons.Add("protected_data");
                }
                if (target.Path.SamePath(protection.HomeDirectory) || protection.HomeDirectory.IsWithin(target.Path) ||
                    target.Path.IsWithin(protection.DataDirectory) || protection.DataDirectory.IsWithin(target.Path) ||
                    protection.SystemDirectories.Any(path => target.Path.IsWithin(path) || path.IsWithin(target.Path))) reasons.Add("protected_location");
                if (target.Path.Parent is not { } parentPath || !entries.TryGetValue(parentPath, out var parentEntry)) reasons.Add("project_marker_missing");
                else
                    foreach (var marker in rule.ParentMarkers)
                    {
                        Check();
                        var comparison = parentEntry.IsCaseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
                        var found = children.GetValueOrDefault(parentPath)?.FirstOrDefault(entry => string.Equals(entry.Path.Name, marker, comparison));
                        if (found is null || found.Kind != EntryKind.File || found.LinkCount != 1 || found.Identity.OwnerSid != protection.OwnerSid) reasons.Add("project_marker_missing");
                    }
                var manifest = new List<FileEntry>();
                var pending = new Stack<FileEntry>();
                var identities = new HashSet<FileIdentity>();
                var allocated = 0L;
                var logical = 0L;
                var newest = target.LastWriteUtc;
                pending.Push(target);
                while (pending.TryPop(out var entry))
                {
                    Check();
                    manifest.Add(entry);
                    if (entry.Identity.OwnerSid != protection.OwnerSid) reasons.Add("foreign_owner");
                    if (entry.Identity.VolumeSerialNumber != workspace.Identity.VolumeSerialNumber) reasons.Add("cross_volume");
                    if (entry.Kind is not (EntryKind.Directory or EntryKind.File)) reasons.Add("unsupported_entry");
                    if (entry.Kind == EntryKind.File && (entry.LinkCount != 1 || duplicateFiles.Contains(entry.Identity))) reasons.Add("multiple_links");
                    if (ProtectedNames.Contains(entry.Path.Name) || IsSecretName(entry.Path.Name) ||
                        ProtectedExtensions.Contains(Extension(entry.Path.Name)) && !(rust && RustArtifactPolicy.IsGeneratedSource(target, entry, entries))) reasons.Add("protected_data");
                    if (Excluded(entry)) reasons.Add("excluded");
                    if (entry.LogicalBytes < 0 || entry.AllocatedBytes < 0 || entry.LastWriteUtc.Offset != TimeSpan.Zero || entry.ChangeUtc.Offset != TimeSpan.Zero) reasons.Add("unsupported_metadata");
                    else
                    {
                        logical = checked(logical + entry.LogicalBytes);
                        if (identities.Add(entry.Identity)) allocated = checked(allocated + entry.AllocatedBytes);
                        if (entry.LastWriteUtc > newest) newest = entry.LastWriteUtc;
                    }
                    if (children.TryGetValue(entry.Path, out var nested))
                        foreach (var child in nested) pending.Push(child);
                }
                if (allocated < rule.MinimumAllocatedBytes) reasons.Add("below_minimum_size");
                if (rule.MinimumNewestAgeDays is { } days && (newest > scan.StartedUtc || scan.StartedUtc - newest < TimeSpan.FromDays(days))) reasons.Add("newer_than_retention");
                var digest = complete ? ManifestDigest(manifest) : null;
                var idBytes = SHA256.HashData(Encoding.UTF8.GetBytes(scan.Id + "\n" + rule.Digest + "\n" + relative));
                candidates.Add(new("candidate_" + Convert.ToHexStringLower(idBytes)[..32], rule.Id, rule.Version, relative, target.Path,
                    target.Identity, allocated, logical, newest, rule.DeclaredRisk == "high" || target.Path.Name.Equals("node_modules", StringComparison.OrdinalIgnoreCase) ? "high" : "review",
                    complete, reasons.Count == 0 ? "review" : "blocked", reasons.Order(StringComparer.Ordinal).ToImmutableArray(), digest));
            }
        }
        catch (ShouException error) when (error.Code is "time_limit" or "resource_limit") { analysisIssues.Add(new(scan.Root, error.Code)); }
        catch (OverflowException) { analysisIssues.Add(new(scan.Root, "unsupported_metadata")); }
        return new(candidates.ToImmutable(), analysisIssues.ToImmutable());
    }

    private static string Extension(string name) => name.LastIndexOf('.') is var index && index >= 0 ? name[index..] : "";
    private static bool IsSecretName(string name) => name.StartsWith(".env.", StringComparison.OrdinalIgnoreCase);

    internal static string ManifestDigest(IEnumerable<FileEntry> manifest)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> length = stackalloc byte[4];
        foreach (var entry in manifest.OrderBy(entry => entry.Path.Value, StringComparer.Ordinal))
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(entry, ContractJson.Options);
            BinaryPrimitives.WriteInt32LittleEndian(length, bytes.Length);
            hash.AppendData(length);
            hash.AppendData(bytes);
        }
        return "sha256:" + Convert.ToHexStringLower(hash.GetHashAndReset());
    }
}
