using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Shou.Windows.Core;
using Windows.ApplicationModel;
using Windows.Management.Deployment;

namespace Shou.Windows.Platform;

internal sealed record StartupPackage(string? FullName, WindowsPath? Root, bool Excluded = false, string? Error = null);
internal interface IPackagedStartupReader
{
    IEnumerable<StartupPackage> ReadPackages(CancellationToken token);
    byte[] ReadManifest(StartupPackage package, CancellationToken token);
    bool IsCurrent(StartupPackage package, CancellationToken token);
}

internal static class WindowsPackagedStartupTasks
{
    internal const int MaximumManifestBytes = 4 * 1024 * 1024;
    private static readonly XNamespace Foundation = "http://schemas.microsoft.com/appx/manifest/foundation/windows10";
    private static readonly XNamespace Desktop = "http://schemas.microsoft.com/appx/manifest/desktop/windows10";
    private static readonly XNamespace Uap5 = "http://schemas.microsoft.com/appx/manifest/uap/windows10/5";

    internal static StartupInventory Read(int limit, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        return Read(new RegisteredPackageStartupReader(), limit, token);
    }

    internal static StartupInventory Read(IPackagedStartupReader reader, int limit, CancellationToken token)
    {
        if (limit is < 1 or > 10_000) throw new ArgumentOutOfRangeException(nameof(limit));
        var items = ImmutableArray.CreateBuilder<StartupRegistration>();
        var issues = new HashSet<string>(StringComparer.Ordinal);
        var inspected = 0;
        try
        {
            using var packages = reader.ReadPackages(token).GetEnumerator();
            while (true)
            {
                token.ThrowIfCancellationRequested();
                if (!packages.MoveNext()) break;
                if (inspected == limit) { issues.Add("entry_limit"); break; }
                inspected++;
                var package = packages.Current;
                if (package.Error is { } packageError) { issues.Add(packageError); continue; }
                if (package.Excluded) continue;
                try
                {
                    if (package.Root is null || !DisplayText(package.FullName, 512)) throw InvalidMetadata();
                    if (inspected == limit) { issues.Add("entry_limit"); break; }
                    var bytes = reader.ReadManifest(package, token);
                    token.ThrowIfCancellationRequested();
                    // Parse into a private candidate set. A changed registration publishes none of this package.
                    var parsed = Parse(package, bytes, limit - inspected, token);
                    inspected += parsed.Sources[0].InspectedEntries!.Value;
                    token.ThrowIfCancellationRequested();
                    if (!reader.IsCurrent(package, token)) { issues.Add("registration_changed"); continue; }
                    items.AddRange(parsed.Registrations);
                    issues.UnionWith(parsed.Sources[0].Issues);
                }
                catch (Exception error) when (ReadFailure(error)) { issues.Add(ErrorCode(error)); }
            }
        }
        catch (Exception error) when (ReadFailure(error)) { issues.Add(ErrorCode(error)); }
        token.ThrowIfCancellationRequested();
        return Result(items.ToImmutable(), inspected, issues);
    }

    internal static StartupInventory Parse(StartupPackage package, byte[] bytes, int limit, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        if (limit is < 0 or > 10_000) throw new ArgumentOutOfRangeException(nameof(limit));
        if (package.Root is null || !DisplayText(package.FullName, 512) || package.FullName!.Contains('!') || bytes.Length is 0 or > MaximumManifestBytes) throw InvalidMetadata();
        var manifest = package.Root.Append("AppxManifest.xml");
        try
        {
            using var input = new MemoryStream(bytes, writable: false);
            using var reader = XmlReader.Create(input, new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaximumManifestBytes
            });
            var root = XDocument.Load(reader, LoadOptions.None).Root;
            if (root?.Name != Foundation + "Package" || root.Elements(Foundation + "Applications").Count() > 1) throw InvalidMetadata();
            var items = ImmutableArray.CreateBuilder<StartupRegistration>();
            var issues = new HashSet<string>(StringComparer.Ordinal);
            var taskIds = new HashSet<string>(StringComparer.Ordinal);
            var inspected = 0;
            foreach (var app in root.Element(Foundation + "Applications")?.Elements(Foundation + "Application") ?? [])
            {
                if (!TakeEntry()) break;
                var appId = (string?)app.Attribute("Id");
                if (!DisplayText(appId, 64) || appId!.Contains('!') || app.Elements(Foundation + "Extensions").Count() > 1)
                { issues.Add("invalid_registration_metadata"); continue; }
                foreach (var extension in app.Element(Foundation + "Extensions")?.Elements() ?? [])
                {
                    if (!TakeEntry()) break;
                    if ((string?)extension.Attribute("Category") != "windows.startupTask") continue;
                    if (extension.Name != Desktop + "Extension" && extension.Name != Uap5 + "Extension")
                    { issues.Add("unsupported_startup_declaration"); continue; }
                    var declarations = extension.Elements(extension.Name.Namespace + "StartupTask").ToArray();
                    if (declarations.Length != 1) { issues.Add("invalid_registration_metadata"); continue; }
                    if (!TakeEntry()) break;
                    var task = declarations[0];
                    var taskId = (string?)task.Attribute("TaskId");
                    if (!DisplayText(taskId, 32767) || char.IsWhiteSpace(taskId![0]) || char.IsWhiteSpace(taskId[^1]) || task.HasElements)
                    { issues.Add("invalid_registration_metadata"); continue; }
                    // A bounded key binds the exact installed version, app and case-sensitive task ID.
                    var key = package.FullName + "!" + appId + "!" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(taskId)));
                    if (!taskIds.Add(taskId)) { issues.Add("duplicate_registration"); continue; }
                    var itemIssues = ImmutableArray<string>.Empty;
                    var display = (string?)task.Attribute("DisplayName");
                    if (!DisplayText(display, 256) || display!.StartsWith("ms-resource:", StringComparison.OrdinalIgnoreCase))
                    {
                        display = taskId.Length <= 512 ? taskId : appId;
                        itemIssues = itemIssues.Add("task_name_unresolved");
                    }
                    var command = (string?)extension.Attribute("Executable") ?? (string?)app.Attribute("Executable");
                    var executable = Executable(package.Root, command);
                    if (executable is null) itemIssues = itemIssues.Add("executable_unresolved");
                    items.Add(new(StartupSource.PackagedStartupTasks, key, display!, executable?.Value,
                        manifest.Value, itemIssues));
                }
            }
            token.ThrowIfCancellationRequested();
            return Result(items.ToImmutable(), inspected, issues);

            bool TakeEntry()
            {
                token.ThrowIfCancellationRequested();
                if (inspected == limit) { issues.Add("entry_limit"); return false; }
                inspected++;
                return true;
            }
        }
        catch (XmlException) { throw InvalidMetadata(); }
    }

    private static WindowsPath? Executable(WindowsPath root, string? command)
    {
        if (string.IsNullOrEmpty(command) || command.Contains('%') || command.Contains('$') ||
            !(command.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || command.EndsWith(".com", StringComparison.OrdinalIgnoreCase))) return null;
        try { return root.Append(command.Replace('\\', '/')); }
        catch (ShouException) { return null; }
    }
    private static bool DisplayText(string? value, int limit) => !string.IsNullOrWhiteSpace(value) && value.Length <= limit &&
        !value.Any(character => char.IsControl(character) || character is '\u202a' or '\u202b' or '\u202c' or '\u202d' or '\u202e' or '\u2066' or '\u2067' or '\u2068' or '\u2069') && ValidUnicode(value);
    private static bool ValidUnicode(string value)
    {
        for (var index = 0; index < value.Length; index++)
            if (char.IsSurrogate(value[index]) && (!char.IsHighSurrogate(value[index]) || ++index == value.Length || !char.IsLowSurrogate(value[index]))) return false;
        return true;
    }
    private static StartupInventory Result(ImmutableArray<StartupRegistration> items, int count, HashSet<string> issues) =>
        new(items, [new(StartupSource.PackagedStartupTasks, issues.Count == 0 ? StartupSourceState.Complete : StartupSourceState.Partial,
            count, (issues.Count > 16 ? issues.Order(StringComparer.Ordinal).Take(15).Append("additional_issues") :
                issues.Order(StringComparer.Ordinal)).ToImmutableArray())]);
    internal static bool ReadFailure(Exception error) => error is ShouException or IOException or UnauthorizedAccessException or COMException or ArgumentException or InvalidOperationException;
    internal static string ErrorCode(Exception error) => error is UnauthorizedAccessException || error is COMException { HResult: unchecked((int)0x80070005) }
        ? "permission_denied" : error is ShouException known ? known.Code : "package_read_failed";
    private static ShouException InvalidMetadata() => new("invalid_registration_metadata", "A packaged startup declaration is invalid or exceeds its read limit.");
}

internal sealed class RegisteredPackageStartupReader : IPackagedStartupReader
{
    private readonly PackageManager manager = new();
    public IEnumerable<StartupPackage> ReadPackages(CancellationToken token)
    {
        foreach (var package in manager.FindPackagesForUser(string.Empty))
        {
            token.ThrowIfCancellationRequested();
            StartupPackage observed;
            try
            {
                observed = Excluded(package) ? new(null, null, Excluded: true) :
                    new(package.Id.FullName, Location(package));
            }
            catch (Exception error) when (WindowsPackagedStartupTasks.ReadFailure(error))
            { observed = new(null, null, Error: WindowsPackagedStartupTasks.ErrorCode(error)); }
            yield return observed;
        }
    }
    public byte[] ReadManifest(StartupPackage package, CancellationToken token) => WindowsFileSystem.ReadMetadataFile(
        package.Root!.Append("AppxManifest.xml"), WindowsPackagedStartupTasks.MaximumManifestBytes, requireSingleLink: false, token);
    public bool IsCurrent(StartupPackage package, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var current = manager.FindPackageForUser(string.Empty, package.FullName!);
        return current is not null && !Excluded(current) && current.Id.FullName == package.FullName &&
            Location(current).SamePath(package.Root!, caseSensitive: true);
    }
    private static bool Excluded(Package package) => package.IsFramework || package.IsResourcePackage || package.IsBundle;
    private static WindowsPath Location(Package package) => WindowsPath.Parse(package.InstalledLocation?.Path ??
        throw new ShouException("package_location_unavailable", "The registered package location is unavailable."));
}
