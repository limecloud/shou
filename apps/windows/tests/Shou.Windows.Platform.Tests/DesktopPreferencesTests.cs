using System.Text;
using Shou.Windows.Core;
using Shou.Windows.Platform;

namespace Shou.Windows.Platform.Tests;

public sealed class DesktopPreferencesTests
{
    private sealed class Store : IRecordStore, IRecordTransaction
    {
        public byte[]? Bytes;
        public bool FailWrite;
        public ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken token)
        {
            token.ThrowIfCancellationRequested(); Assert.Equal("desktop_preferences", key);
            if (Bytes?.Length > maximumBytes) throw new ShouException("resource_limit", "Generated record is too large.");
            return ValueTask.FromResult(Bytes);
        }
        public Task<T> UpdateAsync<T>(Func<IRecordTransaction, T> update, CancellationToken token)
        { token.ThrowIfCancellationRequested(); return Task.FromResult(update(this)); }
        public byte[]? Read(string key, int maximumBytes) => Bytes;
        public void Write(string key, ReadOnlyMemory<byte> bytes)
        { if (FailWrite) throw new IOException("Generated disk full"); Bytes = bytes.ToArray(); }
        public Task<IRecordLease> AcquireLeaseAsync(CancellationToken token) => throw new NotSupportedException();
        public Task<IRecordReadLease?> AcquireReadLeaseAsync(CancellationToken token) => throw new NotSupportedException();
    }

    [Fact]
    public async Task DefaultAndSavedPreferencesRoundTripAcrossInstances()
    {
        var store = new Store(); var settings = new WindowsDesktopPreferences(store);
        Assert.Equal(new DesktopPreferences(), await settings.ReadAsync(CancellationToken.None));
        var value = new DesktopPreferences("zh-CN", "dark", true);
        await settings.SaveAsync(value, CancellationToken.None);
        Assert.Equal(value, await new WindowsDesktopPreferences(store).ReadAsync(CancellationToken.None));
    }

    [Theory]
    [InlineData("{\"Theme\":\"unknown\"}")]
    [InlineData("{\"Language\":\"fr\"}")]
    [InlineData("{\"Unknown\":true}")]
    [InlineData("null")]
    [InlineData("broken")]
    public async Task InvalidSavedValuesAreRejected(string json)
    {
        var settings = new WindowsDesktopPreferences(new Store { Bytes = Encoding.UTF8.GetBytes(json) });
        await Assert.ThrowsAnyAsync<Exception>(() => settings.ReadAsync(CancellationToken.None));
    }

    [Fact]
    public async Task FailedWriteKeepsPreviousPreferenceAndCancellationDoesNotWrite()
    {
        var store = new Store(); var settings = new WindowsDesktopPreferences(store);
        await settings.SaveAsync(new("en-US", "light"), CancellationToken.None);
        store.FailWrite = true;
        await Assert.ThrowsAsync<IOException>(() => settings.SaveAsync(new("zh-CN", "dark"), CancellationToken.None));
        Assert.Equal("light", (await settings.ReadAsync(CancellationToken.None)).Theme);
        using var stopped = new CancellationTokenSource(); stopped.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => settings.SaveAsync(new(), stopped.Token));
        Assert.Equal("light", (await settings.ReadAsync(CancellationToken.None)).Theme);
    }
}
