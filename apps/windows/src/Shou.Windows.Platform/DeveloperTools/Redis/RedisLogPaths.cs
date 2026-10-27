namespace Shou.Windows.Platform;

internal sealed class RedisLogPaths : IDeveloperLogPaths
{
    public string ToolId => "redis";
    public IEnumerable<DeveloperLogTarget> UnderInstallation(string root) => [
        new(System.IO.Path.Combine(root, "redis.log"), "Service Log"),
        new(System.IO.Path.Combine(root, "logs", "redis.log"), "Service Log")];
}
