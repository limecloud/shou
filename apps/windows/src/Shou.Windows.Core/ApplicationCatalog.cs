using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;

namespace Shou.Windows.Core;

public enum ApplicationSource { CurrentUserRegistry, MachineRegistry64, MachineRegistry32, CurrentUserMsix }
public enum ApplicationSourceState { Complete, Partial, Unavailable, NotRead }
public enum ApplicationSort { Name, RegisteredSize }

public sealed record ApplicationDiscoveryBudget(int MaxEntries = 4000, TimeSpan? MaxDuration = null)
{
    public TimeSpan Duration => MaxDuration ?? TimeSpan.FromSeconds(10);
    public void Validate()
    {
        if (MaxEntries is < 1 or > 20_000 || Duration <= TimeSpan.Zero || Duration > TimeSpan.FromMinutes(1))
            throw new ShouException("invalid_argument", "Choose an application discovery budget within 20,000 entries and 60 seconds.");
    }
}

// Registration metadata is a discovery clue. It does not establish file ownership or authorize uninstall.
public sealed record ApplicationRegistration(ApplicationSource Source, string RegistrationKey, string DisplayName,
    string? Version = null, string? Publisher = null, string? InstallLocation = null, long? RegisteredEstimatedBytes = null,
    bool Hidden = false, bool IsUpdate = false, bool IsSystemPackage = false, bool UsesWindowsInstaller = false);
public sealed record ApplicationSourceCoverage(ApplicationSource Source, ApplicationSourceState State, int? InspectedEntries,
    ImmutableArray<string> Issues);
public sealed record ApplicationInventory(ImmutableArray<ApplicationRegistration> Registrations, ImmutableArray<ApplicationSourceCoverage> Sources);

public interface IApplicationInventory
{
    Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken cancellationToken);
}

public sealed record InstalledApplication(string Id, ApplicationSource Source, string RegistrationKey, string Name,
    string? Version, string? Publisher, WindowsPath? RegisteredInstallLocation, long? RegisteredEstimatedBytes,
    bool IsSystemPackage, ImmutableArray<string> Issues, bool UsesWindowsInstaller = false);
public sealed record ApplicationCatalogSnapshot(string Id, DateTimeOffset ObservedAt, ScanState State,
    ImmutableArray<InstalledApplication> Applications, ImmutableArray<ApplicationSourceCoverage> Sources,
    ImmutableArray<string> Limitations);
public sealed record ApplicationQuery(string Search = "", ApplicationSort Sort = ApplicationSort.Name, int Offset = 0, int Limit = 100)
{
    public void Validate()
    {
        if (Search is null || Search.Length > 256 || Search.Any(char.IsControl) || !Enum.IsDefined(Sort) || Offset is < 0 or > 20_000 || Limit is < 1 or > 500)
            throw new ShouException("invalid_argument", "Choose a search up to 256 characters, a supported sort and a page of 1 to 500 applications.");
    }
}
public sealed record ApplicationCatalogPage(string SnapshotId, DateTimeOffset ObservedAt, ScanState State, int Total, int Offset,
    ImmutableArray<InstalledApplication> Items, bool HasNext, ImmutableArray<ApplicationSourceCoverage> Sources, ImmutableArray<string> Limitations);

public sealed class ApplicationCatalog(IApplicationInventory inventory, TimeProvider? timeProvider = null)
{
    public async Task<ApplicationCatalogSnapshot> ReadAsync(ApplicationDiscoveryBudget? budget = null, CancellationToken cancellationToken = default)
    {
        budget ??= new();
        budget.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        var observedAt = (timeProvider ?? TimeProvider.System).GetUtcNow();
        var raw = await inventory.ReadAsync(budget, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (raw.Registrations.IsDefault || raw.Sources.IsDefault || raw.Registrations.Length > budget.MaxEntries ||
            raw.Sources.Length != Enum.GetValues<ApplicationSource>().Length || raw.Sources.Select(source => source.Source).Distinct().Count() != raw.Sources.Length ||
            raw.Sources.Any(source => !Enum.IsDefined(source.Source) || !Enum.IsDefined(source.State) || source.InspectedEntries < 0 ||
                source.State == ApplicationSourceState.Complete && source.InspectedEntries is null || source.Issues.IsDefault) ||
            raw.Sources.Sum(source => (long?)source.InspectedEntries) > budget.MaxEntries)
            throw new ShouException("application_inventory_invalid", "The application inventory did not describe bounded source coverage.");
        var sources = raw.Sources.ToDictionary(source => source.Source);
        var applications = ImmutableArray.CreateBuilder<InstalledApplication>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in raw.Registrations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Enum.IsDefined(item.Source)) throw new ShouException("application_inventory_invalid", "An application has an unknown source.");
            if (item.Hidden || item.IsUpdate) continue;
            if (!Valid(item.RegistrationKey, 2048) || !Valid(item.DisplayName, 512) || !OptionalValid(item.Version, 256) ||
                !OptionalValid(item.Publisher, 512) || item.RegisteredEstimatedBytes < 0)
            { MarkPartial(item.Source, "invalid_registration_metadata"); continue; }
            var id = ApplicationId(item.Source, item.RegistrationKey);
            if (!seen.Add(id)) { MarkPartial(item.Source, "duplicate_registration"); continue; }
            WindowsPath? location = null;
            var issues = ImmutableArray.CreateBuilder<string>();
            if (!string.IsNullOrWhiteSpace(item.InstallLocation))
            {
                try { location = WindowsPath.Parse(item.InstallLocation); }
                catch (ShouException) { issues.Add("invalid_registered_location"); }
            }
            applications.Add(new(id, item.Source, item.RegistrationKey, item.DisplayName.Trim(), item.Version?.Trim(), item.Publisher?.Trim(),
                location, item.RegisteredEstimatedBytes, item.IsSystemPackage, issues.ToImmutable(), item.UsesWindowsInstaller));
        }
        var coverage = sources.Values.OrderBy(source => source.Source).ToImmutableArray();
        return new("applications_" + Guid.NewGuid().ToString("N"), observedAt,
            coverage.All(source => source.State == ApplicationSourceState.Complete && source.Issues.IsEmpty) ? ScanState.Complete : ScanState.Partial,
            applications.ToImmutable(), coverage, ["registered_sources_only", "portable_applications_not_discovered", "other_users_not_enumerated",
                "registered_sizes_are_not_measured", "registration_is_not_file_ownership", "uninstall_unavailable"]);

        void MarkPartial(ApplicationSource source, string issue)
        {
            var current = sources[source];
            sources[source] = current with { State = ApplicationSourceState.Partial, Issues = current.Issues.Contains(issue) ? current.Issues : current.Issues.Add(issue) };
        }
    }

    public static ApplicationCatalogPage Page(ApplicationCatalogSnapshot snapshot, ApplicationQuery? query = null)
    {
        query ??= new();
        query.Validate();
        var matching = snapshot.Applications.Where(item => new[] { item.Name, item.Version, item.Publisher, item.RegistrationKey, item.RegisteredInstallLocation?.Value }
            .Any(value => value?.Contains(query.Search, StringComparison.OrdinalIgnoreCase) == true)).ToArray();
        var ordered = query.Sort == ApplicationSort.RegisteredSize
            ? matching.OrderBy(item => item.RegisteredEstimatedBytes is null).ThenByDescending(item => item.RegisteredEstimatedBytes)
                .ThenBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ThenBy(item => item.Id, StringComparer.Ordinal)
            : matching.OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase).ThenBy(item => item.Id, StringComparer.Ordinal);
        var items = ordered.Skip(query.Offset).Take(query.Limit).ToImmutableArray();
        return new(snapshot.Id, snapshot.ObservedAt, snapshot.State, matching.Length, query.Offset, items,
            query.Offset + items.Length < matching.Length, snapshot.Sources, snapshot.Limitations);
    }

    public static string ApplicationId(ApplicationSource source, string registrationKey) => "application_" +
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{source}\n{registrationKey}")));

    public static bool IsApplicationId(string? value) => value is { Length: 76 } && value.StartsWith("application_", StringComparison.Ordinal) &&
        value[12..].All(character => char.IsAsciiDigit(character) || character is >= 'a' and <= 'f');

    private static bool Valid(string? value, int maximum)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximum) return false;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (char.IsControl(character) || character is '\u202a' or '\u202b' or '\u202c' or '\u202d' or '\u202e' or '\u2066' or '\u2067' or '\u2068' or '\u2069') return false;
            if (!char.IsSurrogate(character)) continue;
            if (!char.IsHighSurrogate(character) || index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1])) return false;
            index++;
        }
        return true;
    }
    private static bool OptionalValid(string? value, int maximum) => string.IsNullOrEmpty(value) || Valid(value, maximum);
}
