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
        var path = relativePath.Split('/');
        if (path.Length > 64 || caseSensitiveParents is not null && caseSensitiveParents.Count != path.Length)
            throw new ShouException("invalid_argument", "The path or its directory case information is outside the supported range.");
        var states = new bool[parts.Length + 1, path.Length + 1];
        states[0, 0] = true;
        for (var i = 0; i < parts.Length; i++)
        {
            for (var j = 0; j <= path.Length; j++)
            {
                if (!states[i, j]) continue;
                if (parts[i] == "**")
                {
                    states[i + 1, j] = true;
                    if (j < path.Length) states[i, j + 1] = true;
                }
                else if (j < path.Length && Segment(parts[i], path[j], caseSensitiveParents?[j] == true))
                    states[i + 1, j + 1] = true;
            }
        }
        return states[parts.Length, path.Length];
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
