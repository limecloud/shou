using System.Collections.Immutable;

namespace Shou.Windows.Core;

public sealed record CleanupReviewSource(CleanupScan Scan, RuleCandidate Candidate, string RuleName, string Category, bool CaseSensitive);

public sealed record CleanupProjectGroup(WindowsPath Path, bool IdentifiedProject, ImmutableArray<CleanupReviewSource> Sources)
{
    public long AllocatedBytes => CleanupReviewProjection.SumBytes(Sources);
}

/// <summary>Projects immutable scan evidence for review. Grouping never grants selection or execution authority.</summary>
public sealed class CleanupReviewProjection
{
    public ImmutableArray<CleanupReviewSource> Sources { get; }
    public ImmutableArray<CleanupProjectGroup> Projects { get; }

    public CleanupReviewProjection(ImmutableArray<CleanupScan> snapshots, IReadOnlyDictionary<string, string>? builtinCategories = null,
        BuiltinRuleCatalog? catalog = null)
    {
        var sources = new List<CleanupReviewSource>();
        var claimed = new Dictionary<string, List<CleanupReviewSource>>(StringComparer.OrdinalIgnoreCase);
        foreach (var scan in snapshots.OrderBy(value => value.Id, StringComparer.Ordinal))
        {
            var names = scan.Rules.ToDictionary(rule => rule.Definition.GetProperty("id").GetString()!,
                rule => rule.Definition.GetProperty("name").GetString()!, StringComparer.Ordinal);
            var sensitive = SensitiveDirectories(scan);
            foreach (var candidate in scan.Candidates)
            {
                var category = !candidate.RuleId.StartsWith(BuiltinRuleCatalog.Prefix, StringComparison.Ordinal) ? "personal" :
                    builtinCategories?.GetValueOrDefault(candidate.RuleId) ?? "other";
                sources.Add(new(scan, candidate, names.GetValueOrDefault(candidate.RuleId) ?? candidate.RuleId, category,
                    IsCaseSensitive(scan, candidate.Path, sensitive)));
            }
        }
        var unique = ImmutableArray.CreateBuilder<CleanupReviewSource>();
        // Parents precede children so overlapping roots and rules count each displayed target once.
        foreach (var source in sources.OrderBy(value => value.Candidate.Path.Value.Count(c => c == '\\'))
            .ThenBy(value => value.Candidate.Path.Value, StringComparer.Ordinal).ThenBy(value => value.Scan.Id, StringComparer.Ordinal)
            .ThenBy(value => value.Candidate.RuleId, StringComparer.Ordinal))
        {
            var overlaps = false;
            for (var path = source.Candidate.Path; path is not null; path = path.Parent)
                if (claimed.TryGetValue(path.Value, out var matches) && matches.Any(other =>
                    source.Candidate.Path.IsWithin(other.Candidate.Path, source.CaseSensitive || other.CaseSensitive)))
                { overlaps = true; break; }
            if (overlaps) continue;
            if (!claimed.TryGetValue(source.Candidate.Path.Value, out var samePath)) claimed[source.Candidate.Path.Value] = samePath = [];
            samePath.Add(source);
            unique.Add(source);
        }
        Sources = unique.ToImmutable();
        Projects = BuildProjects(snapshots, catalog);
    }

    private ImmutableArray<CleanupProjectGroup> BuildProjects(ImmutableArray<CleanupScan> snapshots, BuiltinRuleCatalog? catalog)
    {
        var markers = (catalog?.Templates ?? []).Where(template => template.Location == "projects" && template.Marker is not null)
            .Select(template => template.Marker!).Concat(["Package.swift", "go.mod"]).ToArray();
        var projectRules = (catalog?.Templates ?? []).Where(template => template.Location == "projects")
            .Select(template => template.Id).ToHashSet(StringComparer.Ordinal);
        var rootsByScan = snapshots.ToDictionary(scan => scan.Id, scan =>
        {
            var sensitive = SensitiveDirectories(scan);
            return scan.Scan.Entries.Where(value => value.Entry.Kind == EntryKind.File && value.Entry.LinkCount == 1 &&
                    value.Entry.Path.IsWithin(scan.Workspace.Path, scan.Workspace.CaseSensitive, includeRoot: false) &&
                    markers.Contains(value.Entry.Path.Name, IsCaseSensitive(scan, value.Entry.Path, sensitive) ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase))
                .Select(value => value.Entry.Path.Parent!).Distinct().GroupBy(path => path.Value, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.OrderBy(path => path.Value, StringComparer.Ordinal).ToArray(), StringComparer.OrdinalIgnoreCase);
        }, StringComparer.Ordinal);
        var groups = new List<(WindowsPath Root, bool CaseSensitive, bool Identified, List<CleanupReviewSource> Sources)>();
        var groupsByPath = new Dictionary<string, List<int>>(StringComparer.OrdinalIgnoreCase);
        foreach (var source in Sources)
        {
            WindowsPath? root = null;
            var observed = rootsByScan[source.Scan.Id];
            for (var ancestor = source.Candidate.Path.Parent; ancestor is not null; ancestor = ancestor.Parent)
                if (observed.TryGetValue(ancestor.Value, out var matches) &&
                    (root = matches.FirstOrDefault(path => path.SamePath(ancestor, source.CaseSensitive))) is not null) break;
            var builtin = source.Category is "build" or "dependencies" || projectRules.Contains(source.Candidate.RuleId);
            // Windows registrations have no project category. Personal rules need an observed project marker
            // and a scope disjoint from all canonical shared-cache locations; names and root references are insufficient.
            var personal = source.Category == "personal" && root is not null && catalog is not null &&
                !catalog.Locations.Any(location => location.Path.IsWithin(source.Scan.Workspace.Path) || source.Scan.Workspace.Path.IsWithin(location.Path));
            if (!builtin && !personal) continue;
            var path = root ?? source.Scan.Workspace.Path;
            if (!groupsByPath.TryGetValue(path.Value, out var indexes)) groupsByPath[path.Value] = indexes = [];
            var index = indexes.FindIndex(value => groups[value].Root.SamePath(path, groups[value].CaseSensitive || source.CaseSensitive));
            if (index < 0)
            {
                indexes.Add(groups.Count);
                groups.Add((path, source.CaseSensitive, root is not null, [source]));
            }
            else
            {
                var group = groups[indexes[index]];
                group.Sources.Add(source);
                groups[indexes[index]] = (group.Root, group.CaseSensitive || source.CaseSensitive, group.Identified || root is not null, group.Sources);
            }
        }
        return groups.Select(group => new CleanupProjectGroup(group.Root, group.Identified,
                group.Sources.OrderBy(value => value.Candidate.Path.Value, StringComparer.Ordinal).ToImmutableArray()))
            .OrderByDescending(group => group.AllocatedBytes).ThenBy(group => group.Path.Value, StringComparer.Ordinal).ToImmutableArray();
    }

    private static HashSet<string> SensitiveDirectories(CleanupScan scan) => scan.Scan.Entries
        .Where(value => value.Entry.Kind == EntryKind.Directory && value.Entry.IsCaseSensitive)
        .Select(value => value.Entry.Path.Value).ToHashSet(StringComparer.OrdinalIgnoreCase);

    private static bool IsCaseSensitive(CleanupScan scan, WindowsPath path, HashSet<string> sensitive)
    {
        if (scan.Workspace.CaseSensitive) return true;
        for (var ancestor = path; ancestor is not null; ancestor = ancestor.Parent)
            if (sensitive.Contains(ancestor.Value)) return true;
        return false;
    }

    internal static long SumBytes(IEnumerable<CleanupReviewSource> sources) => sources.Aggregate(0L, (total, source) =>
        source.Candidate.AllocatedBytes > long.MaxValue - total ? long.MaxValue : total + source.Candidate.AllocatedBytes);
}
