using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Shou.Windows.Core;

public enum PrivacyBrowser { Chrome, Chromium, Edge, Brave, Firefox }
public enum PrivacyDataKind { History, Cookies }
public enum PrivacyDatabaseLocation { History, LegacyCookies, NetworkCookies, FirefoxHistory, FirefoxCookies }
public enum PrivacyTimeRange { LastHour, LastDay, LastSevenDays, AllTime }
public enum PrivacySourceState { Ready, Empty, BrowserRunning, ActivityUnknown, PermissionRequired, SchemaUnsupported, Unavailable, Excluded }

public sealed record PrivacyWindow(PrivacyTimeRange Range, DateTimeOffset? Start, DateTimeOffset End)
{
    public static PrivacyWindow Create(PrivacyTimeRange range, DateTimeOffset end)
    {
        if (!Enum.IsDefined(range) || end.Offset != TimeSpan.Zero) throw new ShouException("invalid_argument", "Choose a valid privacy range and UTC boundary.");
        return new(range, range == PrivacyTimeRange.AllTime ? null : end - (range switch
        {
            PrivacyTimeRange.LastHour => TimeSpan.FromHours(1), PrivacyTimeRange.LastDay => TimeSpan.FromDays(1), _ => TimeSpan.FromDays(7)
        }), end);
    }

    public void Validate()
    {
        if (Start is { Offset: var offset } && offset != TimeSpan.Zero || this != Create(Range, End))
            throw new ShouException("invalid_argument", "Privacy boundaries must match the fixed UTC scan range.");
    }

    public (long? Start, long End) IntegerMicroseconds(bool chromium)
    {
        Validate();
        long Convert(DateTimeOffset value, bool lower)
        {
            var ticks = checked(value.UtcTicks - DateTimeOffset.UnixEpoch.UtcTicks);
            var microseconds = Math.DivRem(ticks, 10, out var remainder);
            if (lower && remainder > 0) microseconds++;
            if (!lower && remainder < 0) microseconds--;
            return checked(microseconds + (chromium ? 11_644_473_600_000_000L : 0L));
        }
        return (Start is { } start ? Convert(start, true) : null, Convert(End, false));
    }
}

public sealed record PrivacyBrowserRoot(PrivacyBrowser Browser, WindowsPath Anchor, string RelativePath)
{
    public WindowsPath Path => Anchor.Append(RelativePath);
}

/// <summary>Metadata for one fixed database, never an arbitrary user-supplied path or a browsing row.</summary>
public sealed record PrivacySourceDefinition(string Id, PrivacyBrowser Browser, string Profile, PrivacyDataKind Kind,
    PrivacyDatabaseLocation Location, WindowsPath Path);
public sealed record PrivacyDiscoveryIssue(PrivacyBrowser? Browser, string Code);
public sealed record PrivacyDiscovery(ImmutableArray<PrivacySourceDefinition> Sources, ImmutableArray<PrivacyDiscoveryIssue> Issues, bool Complete);
public sealed record PrivacyFileEvidence(FileEntry Entry, string SecurityDigest);
public sealed record PrivacyDatabaseObservation(long RecordCount, string SchemaDigest, ImmutableArray<PrivacyFileEvidence> Evidence);
public sealed record PrivacySourceObservation(PrivacySourceDefinition Source, PrivacySourceState State, long? RecordCount,
    string? Reason, string? SchemaDigest, ImmutableArray<PrivacyFileEvidence> Evidence);
public sealed record PrivacyScan(int Version, string Id, DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, PrivacyWindow Window,
    string ConfigurationDigest, ImmutableArray<PrivacySourceObservation> Sources, ImmutableArray<PrivacyDiscoveryIssue> Issues, bool Complete, string Digest);

public interface IPrivacyDatabaseInspection
{
    Task<PrivacyDatabaseObservation> InspectAsync(PrivacySourceDefinition source, PrivacyWindow window, CancellationToken cancellationToken);
}
public interface IPrivacyBrowserActivity
{
    Task<ActivityObservation> InspectAsync(PrivacyBrowser browser, CancellationToken cancellationToken);
}

/// <summary>Fixed stable-channel locations use actual Local/Roaming AppData, including redirected directories.</summary>
public sealed class WindowsPrivacySourcePolicy(WindowsUserDirectories directories)
{
    public ImmutableArray<PrivacyBrowserRoot> Roots { get; } =
    [
        new(PrivacyBrowser.Chrome, directories.LocalAppData, "Google/Chrome/User Data"),
        new(PrivacyBrowser.Chromium, directories.LocalAppData, "Chromium/User Data"),
        new(PrivacyBrowser.Edge, directories.LocalAppData, "Microsoft/Edge/User Data"),
        new(PrivacyBrowser.Brave, directories.LocalAppData, "BraveSoftware/Brave-Browser/User Data"),
        new(PrivacyBrowser.Firefox, directories.RoamingAppData, "Mozilla/Firefox/Profiles")
    ];

    public PrivacySourceDefinition Create(PrivacyBrowser browser, string profile, PrivacyDatabaseLocation location)
    {
        if (!Enum.IsDefined(browser) || !Enum.IsDefined(location)) throw Invalid();
        WindowsPath.ValidateComponent(profile);
        if (profile.Length > 128 || browser != PrivacyBrowser.Firefox && profile != "Default" &&
            !Regex.IsMatch(profile, "^Profile [0-9]{1,9}$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)) throw Invalid();
        if ((browser == PrivacyBrowser.Firefox) != (location is PrivacyDatabaseLocation.FirefoxHistory or PrivacyDatabaseLocation.FirefoxCookies)) throw Invalid();
        var suffix = location switch
        {
            PrivacyDatabaseLocation.History => "History", PrivacyDatabaseLocation.LegacyCookies => "Cookies",
            PrivacyDatabaseLocation.NetworkCookies => "Network/Cookies", PrivacyDatabaseLocation.FirefoxHistory => "places.sqlite", _ => "cookies.sqlite"
        };
        var kind = location is PrivacyDatabaseLocation.History or PrivacyDatabaseLocation.FirefoxHistory ? PrivacyDataKind.History : PrivacyDataKind.Cookies;
        var path = Roots.Single(root => root.Browser == browser).Path.Append(profile + "/" + suffix);
        var id = "privacy_source_" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(browser + "\n" + profile + "\n" + location)))[..32];
        return new(id, browser, profile, kind, location, path);
    }

    public PrivacyBrowserRoot Validate(PrivacySourceDefinition source)
    {
        if (source is null || source != Create(source.Browser, source.Profile, source.Location)) throw Invalid();
        return Roots.Single(root => root.Browser == source.Browser);
    }
    private static ShouException Invalid() => new("privacy_source_invalid", "The privacy source is outside fixed browser profile locations.");
}

/// <summary>Bounded metadata-only discovery. Each failed/changed profile remains a gap rather than an empty result.</summary>
public sealed class PrivacySourceDiscovery(WindowsPrivacySourcePolicy policy, IWindowsFileSystem files, string ownerSid, TimeProvider? timeProvider = null)
{
    public const int MaximumEntries = 2048;
    public const int MaximumProfiles = 256;
    public const int MaximumSources = 768;
    public async Task<PrivacyDiscovery> DiscoverAsync(CancellationToken cancellationToken = default)
    {
        var clock = timeProvider ?? TimeProvider.System;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10), clock);
        using var stopped = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = stopped.Token;
        var sources = ImmutableArray.CreateBuilder<PrivacySourceDefinition>();
        var issues = ImmutableArray.CreateBuilder<PrivacyDiscoveryIssue>();
        var entries = 0;
        var profiles = 0;
        var identities = new HashSet<FileIdentity>();
        void Limit() { if (++entries > MaximumEntries) throw new ShouException("privacy_source_limit", "Privacy discovery reached its metadata budget."); }
        void Require(FileEntry entry, WindowsPath path)
        {
            if (entry.Path != path || entry.Kind != EntryKind.Directory || entry.Identity.OwnerSid != ownerSid)
                throw new ShouException("privacy_identity_unavailable", "The browser profile identity is unavailable.");
        }
        foreach (var root in policy.Roots)
        {
            try
            {
                token.ThrowIfCancellationRequested(); Limit();
                FileEntry before;
                try { before = await files.InspectAsync(root.Path, token); }
                catch (ShouException error) when (error.Code == "not_found") { continue; }
                Require(before, root.Path);
                var staged = new List<PrivacySourceDefinition>();
                var names = new HashSet<string>(before.IsCaseSensitive ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase);
                await foreach (var child in files.ReadDirectoryAsync(root.Path, token))
                {
                    Limit(); token.ThrowIfCancellationRequested();
                    if (child.Path.Parent != root.Path || !names.Add(child.Path.Name)) throw new ShouException("source_changed", "Browser profile enumeration changed.");
                    if (root.Browser != PrivacyBrowser.Firefox && child.Path.Name != "Default" &&
                        !Regex.IsMatch(child.Path.Name, "^Profile [0-9]{1,9}$", RegexOptions.CultureInvariant | RegexOptions.NonBacktracking)) continue;
                    if (child.ErrorCode is not null || child.Entry is not { } observed) { issues.Add(new(root.Browser, "read_failed")); continue; }
                    if (observed.Kind == EntryKind.File) continue;
                    try
                    {
                        Require(observed, child.Path);
                        if (++profiles > MaximumProfiles) throw new ShouException("privacy_source_limit", "Too many browser profiles.");
                        Limit(); var current = await files.InspectAsync(child.Path, token); Require(current, child.Path);
                        if (current.Identity != observed.Identity || current.IsCaseSensitive != observed.IsCaseSensitive || !identities.Add(current.Identity))
                            throw new ShouException("source_changed", "The browser profile changed or aliases an earlier profile.");
                        var locations = root.Browser == PrivacyBrowser.Firefox
                            ? new[] { PrivacyDatabaseLocation.FirefoxHistory, PrivacyDatabaseLocation.FirefoxCookies }
                            : [PrivacyDatabaseLocation.History, PrivacyDatabaseLocation.LegacyCookies, PrivacyDatabaseLocation.NetworkCookies];
                        foreach (var location in locations)
                        {
                            var source = policy.Create(root.Browser, child.Path.Name, location);
                            Limit();
                            FileEntry entry;
                            try { entry = await files.InspectAsync(source.Path, token); }
                            catch (ShouException error) when (error.Code == "not_found") { continue; }
                            if (entry.Kind != EntryKind.File || entry.Path != source.Path || entry.Identity.OwnerSid != ownerSid || entry.LinkCount != 1)
                            { issues.Add(new(root.Browser, "privacy_identity_unavailable")); continue; }
                            staged.Add(source);
                            if (staged.Count + sources.Count > MaximumSources) throw new ShouException("privacy_source_limit", "Too many privacy sources.");
                        }
                    }
                    catch (ShouException error) when (error.Code != "privacy_source_limit") { issues.Add(new(root.Browser, SafeReason(error))); }
                }
                Limit(); var after = await files.InspectAsync(root.Path, token); Require(after, root.Path);
                if (after != before) throw new ShouException("source_changed", "The browser profile root changed during discovery.");
                sources.AddRange(staged);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { issues.Add(new(root.Browser, "time_limit")); break; }
            catch (ShouException error)
            { issues.Add(new(root.Browser, SafeReason(error))); if (error.Code == "privacy_source_limit") break; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { issues.Add(new(root.Browser, error is UnauthorizedAccessException ? "permission_denied" : "read_failed")); }
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new(sources.OrderBy(source => source.Path.Value, StringComparer.Ordinal).ToImmutableArray(), issues.Distinct().ToImmutableArray(), issues.Count == 0);
    }
    internal static string SafeReason(ShouException error) => error.Code is "permission_denied" or "source_changed" or "privacy_source_limit" or "privacy_identity_unavailable"
        ? error.Code : "read_failed";
}
