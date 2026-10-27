using System.Collections.Immutable;
using System.Text.Json;
using Microsoft.Management.Deployment;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

public sealed class WindowsDeveloperToolInventory : IDeveloperToolDiscovery
{
    public Task<DeveloperToolInventory> ScanAsync(DeveloperToolCatalog catalog, CancellationToken cancellationToken) => ScanAsync(catalog, cancellationToken, null);
    public Task<DeveloperToolInventory> ScanAsync(DeveloperToolCatalog catalog, CancellationToken cancellationToken, IProgress<DeveloperToolInventory>? progress) =>
        Task.Run(async () =>
        {
            var rows = new List<DeveloperToolInstallation>(); var issues = new List<string>();
            var directories = SearchDirectories(issues);
            var commands = catalog.Tools.SelectMany(t => t.Commands.Select(c => (Command: c, Tool: t))).ToArray();
            foreach (var directory in directories)
            {
                cancellationToken.ThrowIfCancellationRequested();
                foreach (var (command, tool) in commands)
                foreach (var extension in new[] { ".exe", ".cmd", ".bat", ".ps1", "" })
                {
                    var path = System.IO.Path.Combine(directory, command + extension);
                    var row = Observe(path, tool);
                    if (row is not null) rows.Add(row);
                }
            }
            progress?.Report(Snapshot(rows, issues));
            try
            {
                using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); budget.CancelAfter(TimeSpan.FromSeconds(60));
                var (_, source) = await WindowsManagedPackageUpdates.ConnectAsync(budget.Token).ConfigureAwait(false);
                var result = await source.FindPackagesAsync(new FindPackagesOptions { ResultLimit = 513 }).AsTask(budget.Token).ConfigureAwait(false);
                if (result.Status != FindPackagesResultStatus.Ok) throw new ShouException("package_catalog_unavailable", "WinGet inventory is unavailable.");
                if (result.WasLimitExceeded || result.Matches.Count > 512) issues.Add("The developer tool search reached its directory budget.");
                foreach (var match in result.Matches.Take(512))
                {
                    var package = match.CatalogPackage; var installed = package.InstalledVersion;
                    if (installed is null) continue;
                    foreach (var tool in catalog.Tools.Where(t => t.Packages.Any(p => p.Provider == "winget" && p.Token == package.Id)))
                    {
                        var path = installed.GetMetadata(PackageVersionMetadataField.InstalledLocation);
                        rows.Add(new(tool.Id, "WinGet", installed.Version, string.IsNullOrEmpty(path) ? "winget:" + package.Id : path,
                            package.Id + ":" + installed.GetMetadata(PackageVersionMetadataField.InstalledScope), "registered"));
                    }
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (Exception error) when (error is not OutOfMemoryException) { issues.Add("WinGet inventory could not be read."); }
            cancellationToken.ThrowIfCancellationRequested();
            return Snapshot(rows, issues);
        }, cancellationToken);

    private static DeveloperToolInventory Snapshot(List<DeveloperToolInstallation> rows, List<string> issues)
    {
        var merged = rows.GroupBy(r => r.ToolId + "\0" + r.Path, StringComparer.OrdinalIgnoreCase).Select(group => group.OrderBy(r => r.Source == "WinGet" ? 0 : 1).First() with
        { LaunchPaths = group.SelectMany(r => r.LaunchPaths.IsDefault ? [] : r.LaunchPaths).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToImmutableArray() });
        return new DeveloperToolInventory(merged.OrderBy(r => r.ToolId, StringComparer.Ordinal).ThenBy(r => r.Path, StringComparer.OrdinalIgnoreCase).Take(4096).ToImmutableArray(),
            DateTimeOffset.UtcNow, issues.Distinct(StringComparer.Ordinal).ToImmutableArray());
    }

    private static string[] SearchDirectories(List<string> issues)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var directories = new List<string>();
        foreach (var kind in new[] { EnvironmentVariableTarget.Process, EnvironmentVariableTarget.User, EnvironmentVariableTarget.Machine })
            directories.AddRange((Environment.GetEnvironmentVariable("PATH", kind) ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Take(128));
        directories.AddRange(new[] { System.IO.Path.Combine(local, "Microsoft", "WinGet", "Links"), System.IO.Path.Combine(roaming, "npm"),
            System.IO.Path.Combine(home, ".local", "bin"), System.IO.Path.Combine(home, ".cargo", "bin"), System.IO.Path.Combine(home, ".bun", "bin"),
            System.IO.Path.Combine(home, ".deno", "bin"), System.IO.Path.Combine(home, "scoop", "shims") });
        foreach (var variable in new[] { "NVM_HOME", "NVM_SYMLINK", "FNM_DIR" })
        {
            var value = Environment.GetEnvironmentVariable(variable);
            if (string.IsNullOrEmpty(value) || !System.IO.Path.IsPathFullyQualified(value)) continue;
            directories.Add(value);
            try
            {
                foreach (var child in Directory.EnumerateDirectories(value).Take(64))
                { directories.Add(child); directories.Add(System.IO.Path.Combine(child, "installation")); }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { issues.Add("Some developer tool locations could not be read."); }
        }
        return directories.Where(p => System.IO.Path.IsPathFullyQualified(p) && !p.StartsWith(@"\\", StringComparison.Ordinal))
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(256).ToArray();
    }
    internal static DeveloperToolInstallation? Observe(string path, DeveloperToolDefinition tool)
    {
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists || file.Attributes.HasFlag(FileAttributes.Directory)) return null;
            var resolved = file.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? file.FullName;
            string? version = null; var source = "Executable path";
            var manifests = new List<string>();
            var ancestor = System.IO.Path.GetDirectoryName(resolved);
            if (ancestor is not null)
                manifests.AddRange(tool.NpmPackages.Select(name => System.IO.Path.Combine(ancestor, "node_modules", name.Replace('/', System.IO.Path.DirectorySeparatorChar), "package.json")));
            for (var index = 0; index < 8 && ancestor is not null; index++, ancestor = System.IO.Path.GetDirectoryName(ancestor))
                manifests.Add(System.IO.Path.Combine(ancestor, "package.json"));
            foreach (var manifest in manifests)
            {
                try
                {
                    using var stream = File.OpenRead(manifest);
                    var data = new byte[256 * 1024 + 1]; var count = 0;
                    while (count < data.Length) { var read = stream.Read(data, count, data.Length - count); if (read == 0) break; count += read; }
                    if (count > 256 * 1024) continue;
                    using var json = JsonDocument.Parse(data.AsMemory(0, count), new JsonDocumentOptions { MaxDepth = 32 });
                    if (json.RootElement.ValueKind != JsonValueKind.Object || !json.RootElement.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String || !tool.NpmPackages.Contains(name.GetString() ?? "")) continue;
                    if (json.RootElement.TryGetProperty("version", out var observed) && observed.ValueKind == JsonValueKind.String && observed.GetString() is { Length: > 0 and <= 256 } text && !text.Any(char.IsControl))
                    {
                        version = text; resolved = System.IO.Path.GetDirectoryName(manifest)!;
                        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                        var roots = new[] { (System.IO.Path.Combine(home, ".bun", "install", "global"), "Bun storage"),
                            (System.IO.Path.Combine(home, ".nvm", "versions", "node"), "nvm storage"),
                            (System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm"), "npm storage") };
                        source = roots.FirstOrDefault(root => resolved.StartsWith(root.Item1 + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)).Item2 ?? "Node package";
                        break;
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
            }
            return new(tool.Id, source, version, resolved, file.Length + ":" + file.LastWriteTimeUtc.Ticks, version is null ? "detected" : "registered", [path]);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException) { return null; }
    }
}
