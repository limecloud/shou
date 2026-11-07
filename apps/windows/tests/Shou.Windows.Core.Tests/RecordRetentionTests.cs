using System.Collections.Immutable;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

public sealed class RecordRetentionTests
{
    private static string Id(string prefix, int number) => prefix + "_" + number.ToString("x32");
    private static RuleSchemaValidator Validator() => new(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Contracts/rule.schema.json")));

    [Fact]
    public async Task LatestAndGraceProtectionApplyToWholePublicationsAndExplainSoftQuota()
    {
        var store = new MemoryRecordStore(); var first = Id("analysis", 1); var second = Id("analysis", 2);
        store.Records[first] = [1]; store.Records[first + "_p0_" + new string('a', 24)] = [2, 3];
        store.Records[second] = [4]; store.Records[second + "_p0_" + new string('b', 24)] = [5, 6];
        store.Records["configuration"] = [7];
        var service = new RecordRetentionService(store, Validator());
        var policy = new RecordRetentionPolicy(MaximumBytes: 0, MaximumAgeDays: 0, GraceSeconds: 0);
        var preview = await service.PreviewAsync(policy);
        Assert.Equal(2, preview.Records.Length); Assert.Equal(first, preview.Records[0].Key);
        Assert.Equal(3, preview.RemovableBytes); Assert.Equal(4, preview.QuotaExcessBytes);
        Assert.Equal(3, preview.RetentionReasons.Single(reason => reason.Reason == "latest_scan").ByteCount);
        Assert.Equal(preview.TotalBytes, preview.Collections.Sum(value => value.TotalBytes));
        await service.CollectAsync(policy, preview.Records);
        Assert.True(store.Records.ContainsKey(second)); Assert.True(store.Records.ContainsKey("configuration"));
        store.ModifiedAt = DateTimeOffset.UtcNow;
        var recent = await service.PreviewAsync(new(KeepLatestScans: false, MaximumBytes: 0, MaximumAgeDays: 0));
        Assert.Empty(recent.Records); Assert.Contains(recent.RetentionReasons, value => value.Reason == "grace_period");
    }

    [Fact]
    public async Task StaleOrDuplicatedReviewIsRejectedAndUnknownPlanProtectsScans()
    {
        var store = new MemoryRecordStore(); var scan = Id("scan", 1); store.Records[scan] = [1];
        var service = new RecordRetentionService(store, Validator());
        var policy = new RecordRetentionPolicy(KeepLatestScans: false, MaximumBytes: 0, MaximumAgeDays: 0, GraceSeconds: 0);
        var preview = await service.PreviewAsync(policy);
        Assert.Single(preview.Records);
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => service.CollectAsync(policy, [preview.Records[0], preview.Records[0]]))).Code);
        store.Records[scan] = [9];
        Assert.Equal("plan_stale", (await Assert.ThrowsAsync<ShouException>(() => service.CollectAsync(policy, preview.Records))).Code);
        store.Records[Id("plan", 1)] = [0];
        var blocked = await service.PreviewAsync(policy);
        Assert.Empty(blocked.Records); Assert.Single(blocked.Issues); Assert.True(store.Records.ContainsKey(scan));
    }

    [Fact]
    public async Task ValidPlanAndExecutionReferencesProtectScansEvenWhenLatestIsDisabled()
    {
        var fixture = await CleanupTests.Fixture.Create(); var plan = await fixture.Plan();
        var service = new RecordRetentionService(fixture.Store, fixture.Validator, fixture.Clock);
        var preview = await service.PreviewAsync(new(KeepLatestScans: false, MaximumBytes: 0, MaximumAgeDays: 0, GraceSeconds: 0));
        Assert.Empty(preview.Issues); Assert.DoesNotContain(preview.Records, record => record.Key == plan.Sources[0].ScanId);
        Assert.Contains(preview.RetentionReasons, reason => reason.Reason == "history_dependency");
    }

    [Fact]
    public void VolumeObservationsKeepNegativeChangesAndMissingMeasurements()
    {
        Assert.Equal(-400, new CleanupVolumeObservation(1, "C:/", 900, 500).Change);
        Assert.Null(new CleanupVolumeObservation(1, "C:/", null, 500).Change);
        Assert.Null(new CleanupVolumeObservation(1, "C:/", 900, -1).Change);
    }
}
