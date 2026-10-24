using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text.Json;

namespace Shou.Windows.Core;

internal sealed record FileManifestPage(string Key, int Count, string Digest);
internal sealed record FileManifestReference(int Count, ImmutableArray<FileManifestPage> Pages);

/// <summary>Immutable pages shared by scan evidence, plans and history. Metadata is published last.</summary>
internal static class FileManifestRecords
{
    internal const int PageSize = 4096;
    internal const int MaximumPageBytes = 16_777_216;

    internal static FileManifestReference Write<T>(ImmutableArray<T> entries, string prefix,
        Action<string, byte[]> write, CancellationToken token)
    {
        var pages = ImmutableArray.CreateBuilder<FileManifestPage>();
        foreach (var (page, bytes) in Pages(entries, prefix, token))
        {
            write(page.Key, bytes);
            pages.Add(page);
        }
        return new(entries.Length, pages.ToImmutable());
    }

    internal static async Task<FileManifestReference> WriteAsync<T>(ImmutableArray<T> entries, string prefix,
        IRecordLease lease, CancellationToken token)
    {
        var pages = ImmutableArray.CreateBuilder<FileManifestPage>();
        foreach (var (page, bytes) in Pages(entries, prefix, token))
        {
            await lease.WriteAsync(page.Key, bytes, token).ConfigureAwait(false);
            pages.Add(page);
        }
        return new(entries.Length, pages.ToImmutable());
    }

    private static IEnumerable<(FileManifestPage Page, byte[] Bytes)> Pages<T>(ImmutableArray<T> entries, string prefix, CancellationToken token)
    {
        for (var offset = 0; offset < entries.Length; offset += PageSize)
        {
            token.ThrowIfCancellationRequested();
            var count = Math.Min(PageSize, entries.Length - offset);
            var bytes = RecordJson.Encode(entries.Slice(offset, count), MaximumPageBytes);
            var digest = Digest(bytes);
            yield return (new(Key(prefix, offset / PageSize, digest), count, digest), bytes);
        }
    }

    internal static async Task<ImmutableArray<T>> ReadAsync<T>(FileManifestReference reference, string prefix,
        IRecordReadLease lease, CancellationToken token)
    {
        if (reference is null || reference.Count is < 1 or > 1_000_000 || reference.Pages.IsDefault ||
            reference.Pages.Length != (reference.Count + PageSize - 1) / PageSize) throw Corrupt();
        var result = ImmutableArray.CreateBuilder<T>(reference.Count);
        for (var index = 0; index < reference.Pages.Length; index++)
        {
            token.ThrowIfCancellationRequested();
            var page = reference.Pages[index];
            if (page is null || !RecordJson.IsDigest(page.Digest) || page.Count != Math.Min(PageSize, reference.Count - index * PageSize) ||
                page.Key != Key(prefix, index, page.Digest)) throw Corrupt();
            var bytes = await lease.ReadAsync(page.Key, MaximumPageBytes, token).ConfigureAwait(false);
            if (bytes is null || Digest(bytes) != page.Digest) throw Corrupt();
            var values = JsonSerializer.Deserialize<ImmutableArray<T>>(bytes, ContractJson.Options);
            if (values.IsDefault || values.Length != page.Count) throw Corrupt();
            result.AddRange(values);
        }
        return result.MoveToImmutable();
    }

    internal static string Digest(byte[] bytes) => "sha256:" + Convert.ToHexStringLower(SHA256.HashData(bytes));
    private static string Key(string prefix, int index, string digest) => prefix + "_p" + index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "_" + digest.Substring(7, 24);
    internal static ShouException Corrupt(Exception? error = null) => new("store_corrupt", "File manifest pages are missing or inconsistent.", error);
}
