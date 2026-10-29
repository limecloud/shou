using System.Buffers.Binary;
using System.Text.Json;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

internal enum AuthorizationOperation { Inspect, ReadDirectory, VerifyRoot, Cleanup, Uninstall, StartupInspect, StartupToggle, Cancel }
internal sealed record AuthorizationRequest(Guid Id, AuthorizationOperation Operation, WindowsPath? Path = null,
    FileEntry? Root = null, WindowsPath? Anchor = null, Workspace? Workspace = null, CleanupPlanItem? Item = null,
    ApplicationUninstallReview? Uninstall = null, DateTimeOffset? ExpiresAt = null, string? TaskPath = null, StartupControlReview? Startup = null, ulong Sequence = 0);
internal sealed record AuthorizationReply(Guid Id, bool Progress = false, FileEntry? Entry = null,
    DirectoryReadItem[]? Entries = null, CleanupMutationResult? Mutation = null, CleanupMutationProgress? MutationProgress = null,
    string? Error = null, ApplicationUninstallResult? Uninstall = null, StartupControlTask? Startup = null, StartupControlNativeResult? StartupResult = null);
/// <summary>Rejects replay with constant storage across arbitrarily long sessions.</summary>
internal sealed class AuthorizationRequestOrder
{
    private ulong sequence;
    private Guid id;
    internal void Accept(AuthorizationRequest request)
    {
        if (request.Operation == AuthorizationOperation.Cancel || request.Id == Guid.Empty || request.Id == id ||
            sequence == ulong.MaxValue || request.Sequence != sequence + 1) throw WindowsAuthorizationChannel.Failure();
        sequence = request.Sequence; id = request.Id;
    }
}
internal sealed record AuthorizationHello(int Version, string Nonce);

/// <summary>Bounded typed frames; a lost response never causes reconnection or replay.</summary>
internal static class WindowsAuthorizationChannel
{
    internal const int MaximumFrameBytes = 64 * 1024 * 1024;
    internal static async Task WriteAsync<T>(Stream stream, T value, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, ContractJson.Options);
        if (bytes.Length is < 1 or > MaximumFrameBytes) throw Failure();
        var header = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(header, bytes.Length);
        await stream.WriteAsync(header, token).ConfigureAwait(false);
        await stream.WriteAsync(bytes, token).ConfigureAwait(false);
        await stream.FlushAsync(token).ConfigureAwait(false);
    }
    internal static async Task<T> ReadAsync<T>(Stream stream, CancellationToken token)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, token).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32BigEndian(header);
        if (length is < 1 or > MaximumFrameBytes) throw Failure();
        var bytes = new byte[length]; await stream.ReadExactlyAsync(bytes, token).ConfigureAwait(false);
        return JsonSerializer.Deserialize<T>(bytes, ContractJson.Options) ?? throw Failure();
    }
    internal static ShouException Failure() => new("authorization_channel_lost", "The administrator session ended. Review the last result before authorizing again.");
}
