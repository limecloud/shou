namespace Shou.Windows.Core;

/// <summary>Local absolute Windows paths, parsed without host-dependent System.IO semantics.</summary>
public sealed record WindowsPath
{
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"
    };

    public string Value { get; }
    public bool IsVolumeRoot => Value.Length == 3;
    public string Name => IsVolumeRoot ? Value : Value[(Value.LastIndexOf('\\') + 1)..];
    public WindowsPath? Parent => IsVolumeRoot ? null : Parse(Value[..Math.Max(3, Value.LastIndexOf('\\'))]);

    private WindowsPath(string value) => Value = value;

    public static WindowsPath Parse(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var path = value.Replace('/', '\\');
        if (path.Length is < 3 or > 32760 || !char.IsAsciiLetter(path[0]) || path[1] != ':' || path[2] != '\\')
            throw Invalid();
        if (path.Length > 3 && path.EndsWith('\\')) path = path[..^1];
        if (path.Length > 3)
            foreach (var part in path[3..].Split('\\')) ValidateComponent(part);
        return new WindowsPath(char.ToUpperInvariant(path[0]) + path[1..]);
    }

    public WindowsPath Append(string relativePath)
    {
        ValidateRelative(relativePath);
        return Parse(Value + (IsVolumeRoot ? "" : "\\") + relativePath.Replace('/', '\\'));
    }

    public bool IsWithin(WindowsPath root, bool caseSensitive = false, bool includeRoot = true)
    {
        var comparison = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        return (includeRoot && string.Equals(Value, root.Value, comparison)) ||
            Value.StartsWith(root.Value + (root.IsVolumeRoot ? "" : "\\"), comparison) && Value.Length > root.Value.Length;
    }

    public bool SamePath(WindowsPath other, bool caseSensitive = false) =>
        string.Equals(Value, other.Value, caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase);

    public string RelativeTo(WindowsPath root, bool caseSensitive = false)
    {
        if (!IsWithin(root, caseSensitive)) throw Invalid();
        if (SamePath(root, caseSensitive)) return ".";
        return Value[(root.Value.Length + (root.IsVolumeRoot ? 0 : 1))..].Replace('\\', '/');
    }

    public static void ValidateRelative(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 32760 || value.Contains('\\')) throw Invalid();
        foreach (var component in value.Split('/')) ValidateComponent(component);
    }

    public static void ValidateComponent(string value)
    {
        if (value.Length is 0 or > 255 || value is "." or ".." || value.EndsWith(' ') || value.EndsWith('.') ||
            value.Any(c => char.IsControl(c) || c is '<' or '>' or ':' or '"' or '/' or '\\' or '|' or '?' or '*') ||
            ReservedNames.Contains(value.Split('.')[0].TrimEnd(' '))) throw Invalid();
        for (var index = 0; index < value.Length; index++)
        {
            if (!char.IsSurrogate(value[index])) continue;
            if (!char.IsHighSurrogate(value[index]) || index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1])) throw Invalid();
            index++;
        }
    }

    public override string ToString() => Value;
    private static ShouException Invalid() => new("invalid_path", "Choose an absolute local Windows path without links, device names or ambiguous components.");
}
