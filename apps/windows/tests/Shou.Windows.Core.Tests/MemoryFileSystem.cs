using System.Runtime.CompilerServices;
using Shou.Windows.Core;

namespace Shou.Windows.Core.Tests;

internal sealed class MemoryFileSystem : IWindowsFileSystem
{
    private int nextId;
    public Dictionary<string, FileEntry> Entries { get; } = new(StringComparer.Ordinal);
    public HashSet<string> Denied { get; } = new(StringComparer.Ordinal);
    public List<string> Enumerated { get; } = [];
    public Func<WindowsPath, CancellationToken, Task>? BeforeRead { get; set; }
    public Func<FileEntry, FileEntry>? OnInspect { get; set; }
    public List<FileEntry> InjectedChildren { get; } = [];
    public Dictionary<string, string> Unavailable { get; } = new(StringComparer.Ordinal);

    public FileEntry Add(string path, EntryKind kind = EntryKind.File, long bytes = 10, long allocated = 4096,
        FileIdentity? identity = null, bool caseSensitive = false)
    {
        var entry = new FileEntry(WindowsPath.Parse(path), identity ?? new(1, (++nextId).ToString("x32"), "S-1-5-21-1000"),
            kind, kind == EntryKind.Directory ? 0 : bytes, kind == EntryKind.Directory ? 0 : allocated,
            DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, IsCaseSensitive: caseSensitive);
        Entries.Add(entry.Path.Value, entry);
        return entry;
    }

    public ValueTask<FileEntry> InspectAsync(WindowsPath path, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!Entries.TryGetValue(path.Value, out var entry)) throw new ShouException("not_found", "The fixture path does not exist.");
        return ValueTask.FromResult(OnInspect?.Invoke(entry) ?? entry);
    }

    public async IAsyncEnumerable<DirectoryReadItem> ReadDirectoryAsync(WindowsPath directory, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        Enumerated.Add(directory.Value);
        if (BeforeRead is { } before) await before(directory, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (Denied.Contains(directory.Value)) throw new UnauthorizedAccessException();
        foreach (var entry in Entries.Values.Where(entry => entry.Path.Parent?.SamePath(directory, caseSensitive: true) == true).Concat(InjectedChildren))
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return Unavailable.TryGetValue(entry.Path.Value, out var code)
                ? DirectoryReadItem.Unavailable(entry.Path, code) : DirectoryReadItem.Found(entry);
        }
    }
}
