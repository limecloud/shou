namespace Shou.Windows.Platform;

internal sealed class NginxLogPaths : IDeveloperLogPaths
{
    public string ToolId => "nginx";
    public IEnumerable<DeveloperLogTarget> UnderInstallation(string root) => [
        new(System.IO.Path.Combine(root, "logs", "access.log"), "Access Log"),
        new(System.IO.Path.Combine(root, "logs", "error.log"), "Error Log")];
}
