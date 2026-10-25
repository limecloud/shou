using System.Globalization;

namespace Shou.Windows.Core;

public sealed class RulePattern
{
    private readonly string[] parts;

    public RulePattern(string pattern, bool target = false)
    {
        if (string.IsNullOrEmpty(pattern)) throw new ShouException("invalid_rule", "A relative pattern is required.");
        parts = pattern.Split('/');
        if (string.IsNullOrEmpty(pattern) || pattern.EnumerateRunes().Count() > 512 ||
            pattern.Any(c => char.IsControl(c) || "\\:$~{}[]`".Contains(c)) ||
            parts.Any(part => part.Length == 0 || part is "." or ".." || part.Contains("**", StringComparison.Ordinal) && part != "**") ||
            target && !parts.Any(part => part.Any(c => c is not ('*' or '?'))))
            throw new ShouException("invalid_rule", "The relative pattern is unsafe or selects an unrestricted root.");
    }

    public bool Matches(string relativePath, IReadOnlyList<bool>? caseSensitiveParents = null)
    {
        if (relativePath == ".") return false;
        WindowsPath.ValidateRelative(relativePath);
        return PrefixStates(relativePath, caseSensitiveParents).Contains(parts.Length);
    }

    internal IEnumerable<string> LiteralChildren(string relativePath, IReadOnlyList<bool> cases) =>
        PrefixStates(relativePath, cases).Where(index => index < parts.Length && !parts[index].Contains('*') && !parts[index].Contains('?')).Select(index => parts[index]);

    internal bool CouldMatchDescendant(string relativePath, IReadOnlyList<bool> cases) =>
        PrefixStates(relativePath, cases).Any(index => index < parts.Length);

    internal bool RequiresEnumeration(string relativePath, IReadOnlyList<bool> cases) =>
        PrefixStates(relativePath, cases).Any(index => index < parts.Length && (parts[index].Contains('*') || parts[index].Contains('?')));

    private HashSet<int> PrefixStates(string relativePath, IReadOnlyList<bool>? cases)
    {
        var path = relativePath == "." ? [] : relativePath.Split('/');
        if (cases is not null && path.Length != cases.Count || path.Length > 64)
            throw new ShouException("invalid_argument", "The path or its directory case information is outside the supported range.");
        var states = new HashSet<int> { 0 };
        void Expand(HashSet<int> values)
        {
            for (var index = 0; index < parts.Length; index++)
                if (values.Contains(index) && parts[index] == "**") values.Add(index + 1);
        }
        Expand(states);
        for (var depth = 0; depth < path.Length; depth++)
        {
            var next = new HashSet<int>();
            foreach (var index in states)
                if (index < parts.Length)
                {
                    if (parts[index] == "**") next.Add(index);
                    else if (Segment(parts[index], path[depth], cases?[depth] == true)) next.Add(index + 1);
                }
            Expand(next);
            states = next;
        }
        return states;
    }

    private static bool Segment(string pattern, string value, bool sensitive)
    {
        var comparison = sensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        if (!pattern.Contains('*') && !pattern.Contains('?')) return string.Equals(pattern, value, comparison);
        var expected = Elements(pattern);
        var actual = Elements(value);
        var current = new bool[actual.Length + 1];
        current[0] = true;
        foreach (var element in expected)
        {
            var next = new bool[current.Length];
            if (element == "*") next[0] = current[0];
            for (var index = 1; index < current.Length; index++)
                next[index] = element == "*" ? current[index] || next[index - 1] : current[index - 1] &&
                    (element == "?" || string.Equals(element, actual[index - 1], comparison));
            current = next;
        }
        return current[^1];
    }

    private static string[] Elements(string text)
    {
        var result = new List<string>();
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext()) result.Add(elements.GetTextElement());
        return result.ToArray();
    }
}
