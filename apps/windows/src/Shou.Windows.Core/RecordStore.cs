namespace Shou.Windows.Core;

/// <summary>The platform owns private storage, atomic publication and the cross-process lease.</summary>
public interface IRecordStore
{
    ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken cancellationToken);
    Task<T> UpdateAsync<T>(Func<IRecordTransaction, T> update, CancellationToken cancellationToken);
    Task<IRecordLease> AcquireLeaseAsync(CancellationToken cancellationToken);
    Task<IRecordReadLease?> AcquireReadLeaseAsync(CancellationToken cancellationToken);
}

/// <summary>Reads a consistent set of records without creating a missing data root.</summary>
public interface IRecordReadLease : IAsyncDisposable
{
    ValueTask<byte[]?> ReadAsync(string key, int maximumBytes, CancellationToken cancellationToken);
    Task<string[]> ListKeysAsync(string prefix, int maximumDirectoryEntries, CancellationToken cancellationToken);
}

/// <summary>Holds the cross-process lease across asynchronous validation and native operations.</summary>
public interface IRecordLease : IRecordReadLease
{
    Task WriteAsync(string key, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken);
}

public interface IRecordTransaction
{
    byte[]? Read(string key, int maximumBytes);
    void Write(string key, ReadOnlyMemory<byte> bytes);
}

public static class RecordKey
{
    public static void Validate(string key)
    {
        if (string.IsNullOrEmpty(key) || key.Length > 100 || !char.IsAsciiLetterLower(key[0]) ||
            key.Any(character => !char.IsAsciiLetterLower(character) && !char.IsAsciiDigit(character) && character != '_'))
            throw new ShouException("invalid_argument", "The record identifier is invalid.");
    }

    public static string New(string prefix) => prefix + "_" + Guid.NewGuid().ToString("N");

    public static bool IsId(string value, string prefix) => value is not null &&
        value.StartsWith(prefix + "_", StringComparison.Ordinal) && value.Length == prefix.Length + 33 &&
        value[(prefix.Length + 1)..].All(character => char.IsAsciiDigit(character) || character is >= 'a' and <= 'f');
}
