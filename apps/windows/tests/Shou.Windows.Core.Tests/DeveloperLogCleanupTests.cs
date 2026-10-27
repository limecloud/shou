using System.Text;

namespace Shou.Windows.Core.Tests;

public sealed class DeveloperLogCleanupTests
{
    private sealed class Clock : TimeProvider
    {
        internal DateTimeOffset Now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }
    private sealed class Platform : IDeveloperLogCleaning
    {
        internal DeveloperLogInspection Value = new("nginx", new(WindowsPath.Parse(@"C:\Generated\access.log"),
            new(1, new string('A', 32), "S-1-5-21-123"), EntryKind.File, 8192, 8192, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow), true);
        internal int Dispatches;
        internal bool NoChange;
        public Task<DeveloperLogInspection> InspectAsync(CancellationToken cancellationToken) => Task.FromResult(Value);
        public Task ClearAsync(DeveloperLogInspection expected, CancellationToken cancellationToken)
        { Dispatches++; if (!NoChange) Value = Value with { File = Value.File with { LogicalBytes = 0, AllocatedBytes = 0 } }; return Task.CompletedTask; }
    }
    [Fact]
    public async Task ClearsOnceAndJournalsOnlyMetadata()
    {
        var platform = new Platform(); var store = new MemoryRecordStore(); var service = new DeveloperLogCleanup(platform, () => store);
        var plan = await service.PrepareAsync();
        Assert.Equal("succeeded", (await service.ExecuteAsync(plan, plan.Id)).State);
        Assert.Equal(0, platform.Value.File.LogicalBytes); Assert.Equal(1, platform.Dispatches);
        Assert.Contains("developer_log_intent_" + plan.Id, store.Records.Keys);
        Assert.Contains("developer_log_result_" + plan.Id, store.Records.Keys);
        Assert.DoesNotContain("log body", string.Join("", store.Records.Values.Select(bytes => Encoding.UTF8.GetString(bytes))));
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, plan.Id));
    }
    [Theory]
    [InlineData("append")][InlineData("replace")][InlineData("expiry")][InlineData("confirmation")][InlineData("journal")][InlineData("new_review")]
    public async Task ChangedReviewsAndJournalFailurePreventMutation(string change)
    {
        var platform = new Platform(); var clock = new Clock(); var store = new MemoryRecordStore();
        var service = new DeveloperLogCleanup(platform, () => store, clock); var plan = await service.PrepareAsync();
        switch (change)
        {
            case "append": platform.Value = platform.Value with { File = platform.Value.File with { LogicalBytes = 9000 } }; break;
            case "replace": platform.Value = platform.Value with { File = platform.Value.File with { Identity = new(1, new string('B', 32), "S-1-5-21-123") } }; break;
            case "expiry": clock.Now += TimeSpan.FromMinutes(3); break;
            case "journal": store.FailWrite = true; break;
            case "new_review": await service.PrepareAsync(); break;
        }
        await Assert.ThrowsAsync<ShouException>(() => service.ExecuteAsync(plan, change == "confirmation" ? "wrong" : plan.Id));
        Assert.Equal(0, platform.Dispatches);
    }
    [Fact]
    public async Task UnverifiedResultDoesNotClaimSpaceReclaimed()
    {
        var platform = new Platform { NoChange = true }; var service = new DeveloperLogCleanup(platform, () => new MemoryRecordStore());
        var plan = await service.PrepareAsync(); Assert.Equal("unknown", (await service.ExecuteAsync(plan, plan.Id)).State);
    }
}
