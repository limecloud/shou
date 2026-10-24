using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

internal static class CleanupScanRecords
{
    private sealed record ObservedEntry(MeasuredEntry Measurement, bool CompleteDirectory);
    private sealed record Envelope(int FormatVersion, CleanupScan Scan, FileManifestReference Entries, string Digest);
    private static string Digest(Envelope value) => RecordJson.Digest(value with { Digest = "" });

    internal static void Write(IRecordTransaction transaction, CleanupScan scan, CancellationToken token)
    {
        if (scan.Scan.Entries.Length <= FileManifestRecords.PageSize)
        {
            transaction.Write(scan.Id, RecordJson.Encode(scan, CleanupScanService.MaximumSnapshotBytes));
            return;
        }
        var completed = scan.Scan.CompletedDirectories.ToHashSet();
        var entries = scan.Scan.Entries.Select(entry => new ObservedEntry(entry, completed.Contains(entry.Entry.Path))).ToImmutableArray();
        var reference = FileManifestRecords.Write(entries, scan.Id, (key, bytes) => transaction.Write(key, bytes), token);
        var compact = scan with { Scan = scan.Scan with { Entries = [], CompletedDirectories = [] } };
        var envelope = new Envelope(1, compact, reference, "");
        token.ThrowIfCancellationRequested();
        transaction.Write(scan.Id, RecordJson.Encode(envelope with { Digest = Digest(envelope) }, CleanupScanService.MaximumSnapshotBytes));
    }

    internal static async Task<CleanupScan> ReadAsync(byte[] bytes, string id, IRecordReadLease lease,
        CleanupScanService service, CancellationToken token)
    {
        try
        {
            using var document = JsonDocument.Parse(bytes);
            if (!document.RootElement.TryGetProperty("format_version", out _)) return service.Decode(bytes, id, token);
            var value = JsonSerializer.Deserialize<Envelope>(bytes, ContractJson.Options) ?? throw FileManifestRecords.Corrupt();
            if (value.FormatVersion != 1 || value.Scan.Id != id || !value.Scan.Scan.Entries.IsEmpty ||
                !value.Scan.Scan.CompletedDirectories.IsEmpty || value.Digest != Digest(value)) throw FileManifestRecords.Corrupt();
            var entries = await FileManifestRecords.ReadAsync<ObservedEntry>(value.Entries, id, lease, token).ConfigureAwait(false);
            var scan = value.Scan with { Scan = value.Scan.Scan with
            {
                Entries = entries.Select(entry => entry.Measurement).ToImmutableArray(),
                CompletedDirectories = entries.Where(entry => entry.CompleteDirectory).Select(entry => entry.Measurement.Entry.Path)
                    .OrderBy(path => path.Value, StringComparer.Ordinal).ToImmutableArray()
            } };
            service.ValidateRecord(scan, id, token);
            return scan;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException or NullReferenceException or OverflowException)
        { throw FileManifestRecords.Corrupt(error); }
        catch (ShouException error) when (error.Code != "store_corrupt") { throw FileManifestRecords.Corrupt(error); }
    }
}
