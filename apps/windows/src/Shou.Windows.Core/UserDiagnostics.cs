using System.Collections.Immutable;
using System.Globalization;
using System.Text;

namespace Shou.Windows.Core;

public enum DiagnosticState { Normal, Attention, Unknown, NotConfigured, NotApplicable }
public enum DiagnosticRecordState { PrivateDirectory, Missing, Unsafe, Unavailable }
public sealed record DiagnosticCheck(string Id, DiagnosticState State, string Title, string Explanation, string? NextStep = null);

public interface IUserDiagnostics
{
    Task<DiagnosticReport> CollectAsync(CancellationToken cancellationToken);
}

// Export only modelled system facts; paths, exception messages and arbitrary
// native payloads cannot become support-report fields.
public sealed record DiagnosticReport(DateTimeOffset CreatedAt, string ApplicationVersion, string Platform, string Architecture,
    string SystemVersion, int ProcessorCount, ulong? PhysicalMemoryBytes, long? VolumeCapacityBytes, long? VolumeFreeBytes,
    ImmutableArray<DiagnosticCheck> Checks)
{
    public int FormatVersion => 1;
    public string Status => PhysicalMemoryBytes is null || ProcessorCount < 1 || Checks.Any(check => check.State == DiagnosticState.Unknown) ? "partial" : "complete";

    public static DiagnosticReport Create(string applicationVersion, string architecture, string systemVersion, int processorCount,
        ulong? physicalMemoryBytes, long? capacityBytes, long? freeBytes, DiagnosticRecordState records, DateTimeOffset? now = null)
    {
        var spaceValid = capacityBytes is > 0 && freeBytes is >= 0 && freeBytes <= capacityBytes;
        var lowSpace = spaceValid && (freeBytes < 1_073_741_824 || (double)freeBytes!.Value / capacityBytes!.Value <= .1);
        var capacity = new DiagnosticCheck("disk_capacity", !spaceValid ? DiagnosticState.Unknown : lowSpace ? DiagnosticState.Attention : DiagnosticState.Normal,
            "Available disk space", !spaceValid ? "Disk capacity could not be observed." : lowSpace ? "Low free space can prevent scans and durable operation records." : "Disk capacity was observed without scanning files.",
            !spaceValid ? "Check that the home volume is available, then run diagnostics again." : lowSpace ? "Review large files and old scan indexes, then rescan after freeing space." : null);
        var access = new DiagnosticCheck("disk_access", DiagnosticState.NotApplicable, "Disk access", "This platform does not use the macOS disk-access sentinel.");
        var state = records switch
        {
            DiagnosticRecordState.PrivateDirectory => DiagnosticState.Normal, DiagnosticRecordState.Missing => DiagnosticState.NotConfigured,
            DiagnosticRecordState.Unsafe => DiagnosticState.Attention, _ => DiagnosticState.Unknown
        };
        var explanation = records switch
        {
            DiagnosticRecordState.PrivateDirectory => "The local record directory is private to the current user. Contents and write access were not tested.",
            DiagnosticRecordState.Missing => "Local records have not been created. Diagnostics does not create them.",
            DiagnosticRecordState.Unsafe => "The local record location is not a verified private directory.",
            _ => "The local record directory could not be inspected."
        };
        var record = new DiagnosticCheck("local_records", state, "Local records", explanation,
            records is DiagnosticRecordState.Unsafe or DiagnosticRecordState.Unavailable ? "Review the configured local data location. Existing records and permissions were not changed." : null);
        return new(now ?? DateTimeOffset.UtcNow, applicationVersion, "windows", architecture, systemVersion, Math.Max(0, processorCount),
            physicalMemoryBytes is > 0 ? physicalMemoryBytes : null, spaceValid ? capacityBytes : null, spaceValid ? freeBytes : null, [capacity, access, record]);
    }

    public string Text(Func<string, string> translate)
    {
        var result = new StringBuilder();
        result.AppendLine(translate("Shou Diagnostic Report"));
        result.AppendLine($"{translate("Version")}: {ApplicationVersion}");
        result.AppendLine($"{translate("System")}: {Platform} {SystemVersion} ({Architecture})");
        result.AppendLine($"{translate("Observed at")}: {CreatedAt.ToString("O", CultureInfo.InvariantCulture)}");
        result.AppendLine($"{translate("Processor count")}: {ProcessorCount}");
        result.AppendLine($"{translate("Physical memory (bytes)")}: {PhysicalMemoryBytes?.ToString(CultureInfo.InvariantCulture) ?? translate("Could not verify")}");
        if (VolumeFreeBytes is { } free && VolumeCapacityBytes is { } capacity)
            result.AppendLine($"{translate("Disk free / capacity (bytes)")}: {free} / {capacity}");
        foreach (var check in Checks)
        {
            result.AppendLine();
            result.AppendLine($"{translate(check.Title)}: {translate(StateTitle(check.State))}");
            result.AppendLine(translate(check.Explanation));
            if (check.NextStep is { } next) result.AppendLine(translate(next));
        }
        result.AppendLine();
        result.AppendLine(translate("This report contains bounded system facts, not personal paths or file contents. Nothing is uploaded."));
        return result.ToString();
    }

    public static string StateTitle(DiagnosticState state) => state switch
    {
        DiagnosticState.Normal => "Available", DiagnosticState.Attention => "Needs attention", DiagnosticState.Unknown => "Could not verify",
        DiagnosticState.NotConfigured => "Not configured", DiagnosticState.NotApplicable => "Not required", _ => "Could not verify"
    };
}
