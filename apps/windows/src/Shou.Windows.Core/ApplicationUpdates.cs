using System.Globalization;
using System.Text.Json;

namespace Shou.Windows.Core;

public enum ApplicationUpdateState { NewerCatalogVersion, SameCatalogVersion, InstalledVersionNewer, Unsupported, Unknown }
public sealed record ApplicationUpdateSource(string Id, string Name, string OfficialPage);
public sealed record ApplicationUpdateObservation(int FormatVersion, DateTimeOffset ObservedAt, string ApplicationId, string ApplicationName,
    string? InstalledVersion, ApplicationUpdateSource? Source, string? CatalogVersion, ApplicationUpdateState State, string? Reason)
{
    public string Status => State == ApplicationUpdateState.Unknown && Reason != "not_checked" ? "partial" : "complete";
}
public interface IApplicationUpdateCatalog
{
    Task<byte[]> ReadAsync(CancellationToken cancellationToken);
}

// Registration matching observes a supported stable channel; it does not
// establish installer provenance, local code signatures or package compatibility.
public sealed class ApplicationUpdateChecker(ApplicationCatalog applications, IApplicationUpdateCatalog catalog)
{
    public const int MaximumMetadataBytes = 1_048_576;
    public static readonly ApplicationUpdateSource VisualStudioCode = new("vscode-stable-releases", "Visual Studio Code", "https://code.visualstudio.com/updates");

    public static ApplicationUpdateSource? SourceFor(InstalledApplication application) => !application.IsSystemPackage && application.Issues.IsEmpty &&
        application.Publisher == "Microsoft Corporation" && !application.UsesWindowsInstaller &&
        (application.Source == ApplicationSource.MachineRegistry64 && application.RegistrationKey.Equals("{EA457B21-F73E-494C-ACAB-524FDE069978}_is1", StringComparison.OrdinalIgnoreCase) && application.Name == "Microsoft Visual Studio Code" ||
         application.Source == ApplicationSource.CurrentUserRegistry && application.RegistrationKey.Equals("{771FD6B0-FA20-440A-A002-3B3BAC16DC50}_is1", StringComparison.OrdinalIgnoreCase) && application.Name == "Microsoft Visual Studio Code (User)") ? VisualStudioCode : null;

    public async Task<ApplicationUpdateObservation> SourceAsync(string applicationId, InstalledApplication? expected, CancellationToken token)
    {
        var app = await Current(applicationId, token).ConfigureAwait(false); RequireSame(app, expected);
        var source = SourceFor(app);
        return new(1, DateTimeOffset.UtcNow, app.Id, app.Name, app.Version, source, null,
            source is null ? ApplicationUpdateState.Unsupported : ApplicationUpdateState.Unknown, source is null ? "no_supported_source" : "not_checked");
    }

    public async Task<ApplicationUpdateObservation> CheckAsync(string applicationId, InstalledApplication? expected, CancellationToken token)
    {
        var app = await Current(applicationId, token).ConfigureAwait(false); RequireSame(app, expected);
        var source = SourceFor(app);
        if (source is null) return Result(ApplicationUpdateState.Unsupported, "no_supported_source");
        byte[] bytes;
        try { bytes = await catalog.ReadAsync(token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is ShouException or HttpRequestException or IOException or OperationCanceledException)
        {
            RequireSame(await Current(applicationId, token).ConfigureAwait(false), app);
            return Result(ApplicationUpdateState.Unknown, error is ShouException known && known.Code is "update_response_too_large" or "update_redirect_refused" or "update_invalid_response" ? known.Code : "update_network_unavailable");
        }
        token.ThrowIfCancellationRequested(); RequireSame(await Current(applicationId, token).ConfigureAwait(false), app);
        if (bytes.Length is 0 or > MaximumMetadataBytes) return Result(ApplicationUpdateState.Unknown, "update_response_too_large");
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
            var root = document.RootElement;
            if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return Result(ApplicationUpdateState.Unknown, "update_channel_unverified");
            var version = root.GetProperty("tag_name").GetString();
            if (version is null || root.GetProperty("html_url").GetString() != "https://github.com/microsoft/vscode/releases/tag/" + version ||
                Compare(app.Version, version) is not { } comparison) return Result(ApplicationUpdateState.Unknown, "update_version_unverified");
            return Result(comparison < 0 ? ApplicationUpdateState.NewerCatalogVersion : comparison > 0 ? ApplicationUpdateState.InstalledVersionNewer : ApplicationUpdateState.SameCatalogVersion, null, version);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException) { return Result(ApplicationUpdateState.Unknown, "update_invalid_response"); }

        ApplicationUpdateObservation Result(ApplicationUpdateState state, string? reason, string? version = null) =>
            new(1, DateTimeOffset.UtcNow, app.Id, app.Name, app.Version, source, version, state, reason);
    }

    private async Task<InstalledApplication> Current(string id, CancellationToken token)
    {
        if (!ApplicationCatalog.IsApplicationId(id)) throw new ShouException("invalid_argument", "Choose an exact application identifier.");
        var snapshot = await applications.ReadAsync(cancellationToken: token).ConfigureAwait(false);
        if (snapshot.State != ScanState.Complete) throw new ShouException("application_discovery_incomplete", "Refresh a complete application inventory before checking its catalog.");
        return snapshot.Applications.SingleOrDefault(app => app.Id == id) ?? throw new ShouException("application_changed", "Application changed. Scan applications again before checking its catalog version.");
    }

    private static void RequireSame(InstalledApplication current, InstalledApplication? expected)
    {
        if (expected is not null && RecordJson.Digest(current) != RecordJson.Digest(expected)) throw new ShouException("application_changed", "Application changed. Scan applications again before checking its catalog version.");
    }

    public static int? Compare(string? installed, string? available)
    {
        static int[]? Parts(string? value)
        {
            if (value is null || value.Length > 79) return null;
            var parts = value.Split('.');
            if (parts.Length is < 1 or > 8 || parts.Any(part => part.Length is < 1 or > 9 || part.Any(c => !char.IsAsciiDigit(c)))) return null;
            return parts.Select(part => int.Parse(part, NumberStyles.None, CultureInfo.InvariantCulture)).ToArray();
        }
        var a = Parts(installed); var b = Parts(available); if (a is null || b is null) return null;
        for (var index = 0; index < Math.Max(a.Length, b.Length); index++)
        {
            var difference = (index < a.Length ? a[index] : 0).CompareTo(index < b.Length ? b[index] : 0);
            if (difference != 0) return difference;
        }
        return 0;
    }
}
