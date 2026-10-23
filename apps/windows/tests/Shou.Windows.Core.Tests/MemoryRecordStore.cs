using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

internal sealed class MemoryRecordStore : IRecordStore, IRecordTransaction
{
    public Dictionary<string, byte[]> Records { get; } = new(StringComparer.Ordinal);
    public bool FailWrite { get; set; }
    public bool Busy { get; set; }
    public Func<string, byte[], bool>? FailPublication { get; set; }
    public int Writes { get; private set; }
    private bool leased;

    public async Task<IRecordReadLease?> AcquireReadLeaseAsync(CancellationToken cancellationToken) =>
        await AcquireLeaseAsync(cancellationToken);

    public ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Busy || leased) throw new ShouException("store_busy", "The fixture store is busy.");
        return ValueTask.FromResult(Read(key, maximumBytes));
    }

    public Task<T> UpdateAsync<T>(Func<IRecordTransaction, T> update, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Busy || leased) throw new ShouException("store_busy", "The fixture store is busy.");
        return Task.FromResult(update(this));
    }

    public Task<IRecordLease> AcquireLeaseAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Busy || leased) throw new ShouException("store_busy", "The fixture store is busy.");
        leased = true;
        return Task.FromResult<IRecordLease>(new Lease(this));
    }

    public byte[]? Read(string key, int maximumBytes)
    {
        RecordKey.Validate(key);
        if (!Records.TryGetValue(key, out var bytes)) return null;
        if (bytes.Length > maximumBytes) throw new ShouException("resource_limit", "The fixture record exceeds the read limit.");
        return bytes.ToArray();
    }

    public void Write(string key, ReadOnlyMemory<byte> bytes)
    {
        RecordKey.Validate(key);
        if (FailWrite || FailPublication?.Invoke(key, bytes.ToArray()) == true) throw new ShouException("io_error", "The fixture disk is full.");
        Records[key] = bytes.ToArray();
        Writes++;
    }

    private sealed class Lease(MemoryRecordStore store) : IRecordLease
    {
        private bool disposed;
        public Task<string[]> ListKeysAsync(string prefix, int maximumDirectoryEntries, CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            cancellationToken.ThrowIfCancellationRequested();
            RecordKey.Validate(prefix);
            if (store.Records.Count > maximumDirectoryEntries) throw new ShouException("resource_limit", "The directory exceeds its entry budget.");
            return Task.FromResult(store.Records.Keys.Where(key => key.StartsWith(prefix + "_", StringComparison.Ordinal)).Order(StringComparer.Ordinal).ToArray());
        }
        public ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(store.Read(key, maximumBytes));
        }
        public Task WriteAsync(string key, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            cancellationToken.ThrowIfCancellationRequested();
            store.Write(key, bytes);
            return Task.CompletedTask;
        }
        public ValueTask DisposeAsync()
        {
            if (!disposed) { disposed = true; store.leased = false; }
            return ValueTask.CompletedTask;
        }
    }
}
