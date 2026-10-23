using System.Collections.Immutable;

namespace Shou.Windows.Core;

public enum EntryKind { File, Directory, ReparsePoint, Unsupported }
public enum ScanState { Complete, Partial, Cancelled }

public sealed record FileIdentity
{
    [System.Text.Json.Serialization.JsonNumberHandling(System.Text.Json.Serialization.JsonNumberHandling.WriteAsString | System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString)]
    public ulong VolumeSerialNumber { get; }
    public string FileId { get; }
    public string OwnerSid { get; }

    public FileIdentity(ulong volumeSerialNumber, string fileId, string ownerSid)
    {
        if (fileId is not { Length: 32 } || !fileId.All(char.IsAsciiHexDigit) ||
            string.IsNullOrEmpty(ownerSid) || ownerSid.Length > 184 ||
            !System.Text.RegularExpressions.Regex.IsMatch(ownerSid, @"^S-1-\d+(?:-\d+)+$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
            throw new ShouException("unsupported_metadata", "The native file identity or owner SID is unavailable.");
        VolumeSerialNumber = volumeSerialNumber;
        FileId = fileId.ToUpperInvariant();
        OwnerSid = ownerSid;
    }
}

public sealed record FileEntry(
    WindowsPath Path,
    FileIdentity Identity,
    EntryKind Kind,
    long LogicalBytes,
    long AllocatedBytes,
    DateTimeOffset LastWriteUtc,
    DateTimeOffset ChangeUtc,
    uint LinkCount = 1,
    bool IsCaseSensitive = false);

public interface IWindowsFileSystem
{
    ValueTask<FileEntry> InspectAsync(WindowsPath path, CancellationToken cancellationToken);
    IAsyncEnumerable<DirectoryReadItem> ReadDirectoryAsync(WindowsPath directory, CancellationToken cancellationToken);
}

public sealed record DirectoryReadItem(WindowsPath Path, FileEntry? Entry, string? ErrorCode)
{
    public static DirectoryReadItem Found(FileEntry entry) => new(entry.Path, entry, null);
    public static DirectoryReadItem Unavailable(WindowsPath path, string errorCode) => new(path, null, errorCode);
}

public sealed record ScanBudget(int MaxEntries = 100_000, int MaxDepth = 32, TimeSpan? MaxDuration = null)
{
    public TimeSpan Duration => MaxDuration ?? TimeSpan.FromMinutes(2);
    public void Validate()
    {
        if (MaxEntries is < 1 or > 1_000_000 || MaxDepth is < 1 or > 64 || Duration <= TimeSpan.Zero || Duration > TimeSpan.FromHours(1))
            throw new ShouException("invalid_argument", "The scan budget is outside the supported range.");
    }
}

public sealed record ScanIssue(WindowsPath Path, string Code);
public sealed record MeasuredEntry(FileEntry Entry, long AttributedAllocatedBytes);
public sealed record ScanProgress(int MeasuredEntries, WindowsPath CurrentPath);

public sealed record ScanSnapshot(
    string Id,
    WindowsPath Root,
    FileIdentity RootIdentity,
    DateTimeOffset StartedUtc,
    ScanState State,
    ImmutableArray<MeasuredEntry> Entries,
    ImmutableArray<ScanIssue> Issues,
    ImmutableArray<WindowsPath> CompletedDirectories)
{
    public long AllocatedBytes => Entries.Sum(item => item.AttributedAllocatedBytes);
    public long LogicalBytes => Entries.Sum(item => item.Entry.LogicalBytes);
    public bool IsComplete => State == ScanState.Complete;
    public bool IsCompleteAt(WindowsPath directory) => !CompletedDirectories.IsDefault && CompletedDirectories.Contains(directory);
}

public interface IStorageScanner
{
    Task<ScanSnapshot> ScanAsync(WindowsPath root, ScanBudget budget,
        IProgress<ScanProgress>? progress, CancellationToken cancellationToken);
}
