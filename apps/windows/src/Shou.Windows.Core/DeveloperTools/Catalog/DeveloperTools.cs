using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

public sealed record DeveloperToolPackage(string Provider, string Kind, string Token)
{
    public string Id => $"{Provider}:{Kind}:{Token}";
    public bool Valid => !string.IsNullOrEmpty(Token) && !Token.Contains("..", StringComparison.Ordinal) && (Provider switch
    {
        "homebrew" => Kind is "formula" or "cask" && Regex.IsMatch(Token, @"\A[a-z0-9][a-z0-9+_.@-]{0,199}\z", RegexOptions.CultureInvariant),
        "winget" => Kind == "package" && Token.Contains('.', StringComparison.Ordinal) && Regex.IsMatch(Token, @"\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}\z", RegexOptions.CultureInvariant),
        _ => false
    });
}
public sealed record DeveloperToolCategory(string Id, string Title);
public sealed record DeveloperToolDefinition(string Id, string Name, string Category, string Homepage, ImmutableArray<DeveloperToolPackage> Packages,
    ImmutableArray<string> Commands, ImmutableArray<string> NpmPackages)
{
    public bool IsAI => Category is "ai" or "ai-coding";
}
public sealed record DeveloperToolCatalog(int SchemaVersion, ImmutableArray<DeveloperToolCategory> Categories, ImmutableArray<DeveloperToolDefinition> Tools)
{
    public static DeveloperToolCatalog Decode(ReadOnlySpan<byte> data)
    {
        try
        {
            if (data.Length > 256 * 1024) throw Invalid();
            using var document = JsonDocument.Parse(data.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
            var root = document.RootElement;
            if (!Fields(root, "schemaVersion", "categories", "tools") ||
                root.GetProperty("categories").ValueKind != JsonValueKind.Array || root.GetProperty("tools").ValueKind != JsonValueKind.Array ||
                root.GetProperty("categories").EnumerateArray().Any(c => !Fields(c, "id", "title")) ||
                root.GetProperty("tools").EnumerateArray().Any(t => !Fields(t, "id", "name", "category", "homepage", "packages", "commands", "npmPackages") ||
                    t.GetProperty("packages").ValueKind != JsonValueKind.Array || t.GetProperty("packages").EnumerateArray().Any(p => !Fields(p, "provider", "kind", "token")))) throw Invalid();
            var catalog = JsonSerializer.Deserialize<DeveloperToolCatalog>(data, new JsonSerializerOptions
            { PropertyNameCaseInsensitive = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow }) ?? throw Invalid();
            if (catalog.SchemaVersion != 1 || catalog.Categories.IsDefaultOrEmpty || catalog.Categories.Length > 32 || catalog.Tools.IsDefaultOrEmpty || catalog.Tools.Length > 256 ||
                catalog.Categories.Any(c => c is null) || catalog.Tools.Any(t => t is null)) throw Invalid();
            var categories = catalog.Categories.Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
            if (categories.Count != catalog.Categories.Length || catalog.Tools.Select(t => t.Id).Distinct(StringComparer.Ordinal).Count() != catalog.Tools.Length ||
                catalog.Categories.Any(c => !Identifier(c.Id) || !Text(c.Title)) || catalog.Tools.Any(t => !Identifier(t.Id) || !Text(t.Name) || !categories.Contains(t.Category) ||
                    t.Packages.IsDefault || t.Packages.Length > 16 || t.Packages.Any(p => p is null || !p.Valid) || t.Packages.Distinct().Count() != t.Packages.Length ||
                    t.Commands.IsDefault || t.Commands.Length > 8 || t.Commands.Any(c => c is null || !Regex.IsMatch(c, @"\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z", RegexOptions.CultureInvariant)) ||
                    t.NpmPackages.IsDefault || t.NpmPackages.Length > 8 || t.NpmPackages.Any(c => c is null || c.Contains("..", StringComparison.Ordinal) || !Regex.IsMatch(c, @"\A@?[a-z0-9][a-z0-9._/-]{0,199}\z", RegexOptions.CultureInvariant)) ||
                    !Uri.TryCreate(t.Homepage, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length != 0)) throw Invalid();
            return catalog;
        }
        catch (JsonException) { throw Invalid(); }
    }
    private static bool Fields(JsonElement value, params string[] expected) => value.ValueKind == JsonValueKind.Object &&
        value.EnumerateObject().Count() == expected.Length && value.EnumerateObject().Select(p => p.Name).ToHashSet(StringComparer.Ordinal).SetEquals(expected);
    private static bool Identifier(string text) => text is not null && Regex.IsMatch(text, @"\A[a-z][a-z0-9-]{0,63}\z", RegexOptions.CultureInvariant);
    private static bool Text(string text) => !string.IsNullOrEmpty(text) && text.Length <= 256 && !text.Any(char.IsControl);
    private static ShouException Invalid() => new("unsupported_schema", "The developer tool catalog is invalid.");
}
public sealed record DeveloperToolInstallation(string ToolId, string Source, string? Version, string Path, string Evidence, string Status, ImmutableArray<string> LaunchPaths = default)
{
    public string Id => ToolId + "\0" + Source + "\0" + Path;
}
public sealed record DeveloperToolInventory(ImmutableArray<DeveloperToolInstallation> Installations, DateTimeOffset ObservedAt, ImmutableArray<string> Issues);
public interface IDeveloperToolDiscovery
{
    Task<DeveloperToolInventory> ScanAsync(DeveloperToolCatalog catalog, CancellationToken cancellationToken);
}
public enum DeveloperToolAction { Install, Uninstall }
public sealed record DeveloperToolInspection(DeveloperToolPackage Package, string? InstalledVersion, string? AvailableVersion,
    string SourceIdentity, string InstallationIdentity, ManagedPackageScope Scope, string? Issue, string? InstallationPath = null)
{
    public bool Installed => InstalledVersion is not null;
    public bool Allows(DeveloperToolAction action) => Issue is null && Scope != ManagedPackageScope.Unknown &&
        (action == DeveloperToolAction.Install ? !Installed && AvailableVersion is not null : Installed && InstallationIdentity.Length > 0);
}
public interface IDeveloperTools
{
    Task<DeveloperToolInspection> InspectAsync(DeveloperToolPackage package, CancellationToken cancellationToken);
    Task<ManagedPackageMutationResult> PerformAsync(DeveloperToolAction action, DeveloperToolInspection expected, DateTimeOffset expiresAt, CancellationToken cancellationToken);
}
public sealed class DeveloperToolPlan
{
    internal DeveloperToolPlan(string toolId, DeveloperToolAction action, DeveloperToolInspection inspection, DateTimeOffset expiresAt)
    { ToolId = toolId; Action = action; Inspection = inspection; ExpiresAt = expiresAt; }
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string ToolId { get; }
    public DeveloperToolAction Action { get; }
    public DeveloperToolInspection Inspection { get; }
    public DateTimeOffset ExpiresAt { get; }
}
public sealed record DeveloperToolResult(DeveloperToolPlan Plan, string State, string? Issue, string? ObservedVersion, bool RestartRequired);

public sealed class DeveloperToolService(DeveloperToolCatalog catalog, IDeveloperTools platform, Func<IRecordStore> makeStore, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly SemaphoreSlim operation = new(1, 1);
    private DeveloperToolPlan? current;
    public async Task<DeveloperToolInspection> InspectAsync(string toolId, DeveloperToolPackage package, CancellationToken cancellationToken = default)
    {
        if (!package.Valid || !catalog.Tools.Any(t => t.Id == toolId && t.Packages.Contains(package))) throw Failure("developer_tool_source_unavailable");
        var value = await platform.InspectAsync(package, cancellationToken).ConfigureAwait(false);
        if (value.Package != package || value.SourceIdentity.Length == 0 || value.InstalledVersion is { Length: > 256 } || value.AvailableVersion is { Length: > 256 }) throw Failure("package_identity_unverified");
        return value;
    }
    public async Task<DeveloperToolPlan> PrepareAsync(string toolId, DeveloperToolAction action, DeveloperToolInspection expected, CancellationToken cancellationToken = default)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            current = null;
            var fresh = await InspectAsync(toolId, expected.Package, cancellationToken).ConfigureAwait(false);
            if (fresh != expected || !fresh.Allows(action)) throw Failure("developer_tool_changed");
            return current = new(toolId, action, fresh, clock.GetUtcNow().AddMinutes(2));
        }
        finally { operation.Release(); }
    }
    public async Task<DeveloperToolResult> ExecuteAsync(DeveloperToolPlan plan, string confirmedId, CancellationToken cancellationToken = default)
    {
        await operation.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var saved = current; current = null;
            if (!ReferenceEquals(saved, plan) || confirmedId != plan.Id || clock.GetUtcNow() >= plan.ExpiresAt) throw Failure("confirmation_required");
            var store = makeStore();
            await using var lease = await store.AcquireLeaseAsync(cancellationToken).ConfigureAwait(false);
            var fresh = await InspectAsync(plan.ToolId, plan.Inspection.Package, cancellationToken).ConfigureAwait(false);
            if (fresh != plan.Inspection || !fresh.Allows(plan.Action) || clock.GetUtcNow() >= plan.ExpiresAt) throw Failure("developer_tool_changed");
            await lease.WriteAsync($"developer_tool_intent_{plan.Id}", JsonSerializer.SerializeToUtf8Bytes(plan), cancellationToken).ConfigureAwait(false);
            ManagedPackageMutationResult mutation;
            try { mutation = await platform.PerformAsync(plan.Action, fresh, plan.ExpiresAt, cancellationToken).ConfigureAwait(false); }
            catch (Exception error) when (error is not OutOfMemoryException) { mutation = new(false, true, false, "developer_tool_outcome_unknown"); }
            DeveloperToolInspection? after = null;
            try
            {
                using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(60));
                after = await InspectAsync(plan.ToolId, fresh.Package, verification.Token).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OutOfMemoryException) { }
            var verified = mutation.Succeeded && after is { Issue: null } && after.SourceIdentity == fresh.SourceIdentity && after.Scope == fresh.Scope &&
                (plan.Action == DeveloperToolAction.Install ? after.InstalledVersion == fresh.AvailableVersion : !after.Installed);
            var result = new DeveloperToolResult(plan, verified ? "succeeded" : mutation.Started ? "unknown" : "not_started", verified ? null : mutation.ErrorCode ?? "developer_tool_unverified", after?.InstalledVersion, mutation.RestartRequired);
            await lease.WriteAsync($"developer_tool_result_{plan.Id}", JsonSerializer.SerializeToUtf8Bytes(result), CancellationToken.None).ConfigureAwait(false);
            return result;
        }
        finally { operation.Release(); }
    }
    private static ShouException Failure(string code) => new(code, "Inspect the exact developer tool source and review the operation again.");
}
