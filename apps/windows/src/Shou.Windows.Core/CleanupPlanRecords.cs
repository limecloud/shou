using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core;

internal sealed class CleanupPlanRecords(CleanupRecordCodec codec)
{
    private sealed record Envelope(int FormatVersion, CleanupPlan Plan, ImmutableArray<FileManifestReference> Manifests, string Digest);
    private static string Digest(Envelope value) => RecordJson.Digest(value with { Digest = "" });

    internal async Task SaveAsync(IRecordLease lease, CleanupPlan plan, CancellationToken token)
    {
        codec.ValidatePlan(plan);
        if (plan.Items.Sum(item => item.Manifest.Length) <= FileManifestRecords.PageSize)
        {
            await lease.WriteAsync(plan.Id, codec.EncodePlan(plan), token).ConfigureAwait(false);
            return;
        }
        var manifests = ImmutableArray.CreateBuilder<FileManifestReference>();
        var compact = ImmutableArray.CreateBuilder<CleanupPlanItem>();
        for (var index = 0; index < plan.Items.Length; index++)
        {
            // One page at a time is written under the existing lease; no complete JSON manifest is materialized.
            var reference = await FileManifestRecords.WriteAsync(plan.Items[index].Manifest, plan.Id + "_" + index.ToString(System.Globalization.CultureInfo.InvariantCulture), lease, token).ConfigureAwait(false);
            manifests.Add(reference);
            compact.Add(plan.Items[index] with { Manifest = [] });
        }
        var envelope = new Envelope(1, plan with { Items = compact.ToImmutable() }, manifests.ToImmutable(), "");
        envelope = envelope with { Digest = Digest(envelope) };
        token.ThrowIfCancellationRequested();
        await lease.WriteAsync(plan.Id, RecordJson.Encode(envelope, CleanupRecordCodec.MaximumPlanBytes), token).ConfigureAwait(false);
    }

    internal async Task<CleanupPlan> ReadAsync(IRecordReadLease lease, string id, CancellationToken token)
    {
        var bytes = await lease.ReadAsync(id, CleanupRecordCodec.MaximumPlanBytes, token).ConfigureAwait(false)
            ?? throw new ShouException("invalid_argument", "The plan does not exist.");
        try
        {
            using var document = JsonDocument.Parse(bytes);
            if (!document.RootElement.TryGetProperty("format_version", out _)) return codec.DecodePlan(bytes, id);
            var value = JsonSerializer.Deserialize<Envelope>(bytes, ContractJson.Options) ?? throw FileManifestRecords.Corrupt();
            if (value.FormatVersion != 1 || value.Plan.Id != id || value.Plan.Items.IsDefaultOrEmpty || value.Plan.Items.Length > CleanupRecordCodec.MaximumPlanItems ||
                value.Plan.Budget is null || value.Manifests.IsDefault || value.Manifests.Length != value.Plan.Items.Length ||
                value.Manifests.Any(manifest => manifest is null || manifest.Count is < 1 or > 1_000_000) ||
                value.Manifests.Sum(manifest => (long)manifest.Count) > value.Plan.Budget.MaxEntries || value.Digest != Digest(value)) throw FileManifestRecords.Corrupt();
            var items = value.Plan.Items.ToBuilder();
            for (var index = 0; index < items.Count; index++)
            {
                if (!items[index].Manifest.IsEmpty) throw FileManifestRecords.Corrupt();
                var prefix = id + "_" + index.ToString(System.Globalization.CultureInfo.InvariantCulture);
                var entries = await FileManifestRecords.ReadAsync<FileEntry>(value.Manifests[index], prefix, lease, token).ConfigureAwait(false);
                items[index] = items[index] with { Manifest = entries };
            }
            var plan = value.Plan with { Items = items.ToImmutable() };
            codec.ValidatePlan(plan);
            return plan;
        }
        catch (Exception error) when (error is JsonException or ArgumentException or InvalidOperationException or NullReferenceException or OverflowException)
        { throw FileManifestRecords.Corrupt(error); }
        catch (ShouException error) when (error.Code != "store_corrupt") { throw FileManifestRecords.Corrupt(error); }
    }

}
