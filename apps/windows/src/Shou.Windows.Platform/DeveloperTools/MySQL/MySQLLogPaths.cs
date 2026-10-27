namespace Shou.Windows.Platform;

internal sealed class MySQLLogPaths : IDeveloperLogPaths
{
    public string ToolId => "mysql";
    public IEnumerable<DeveloperLogTarget> UnderInstallation(string root)
    {
        if (System.IO.Path.GetFileName(root).Equals("bin", StringComparison.OrdinalIgnoreCase)) root = System.IO.Path.GetDirectoryName(root)!;
        var data = System.IO.Path.Combine(root, "data");
        // Error logs may be named after the machine; no recursive data-directory scan.
        if (!Directory.Exists(data)) return [];
        try { return Directory.EnumerateFiles(data, "*.err", SearchOption.TopDirectoryOnly).Take(16).Select(path => new DeveloperLogTarget(path, "Error Log")).ToArray(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
    }
}
