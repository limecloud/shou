using System.Buffers.Binary;
using System.Threading.Channels;
using Shou.Windows.Core;

namespace Shou.Windows.Platform.Tests;

public sealed class WindowsSystemAuthorizationTests
{
    [Fact]
    public async Task AuthenticatedSessionReusesOneChannelAndNeverReplaysLostResults()
    {
        var (client, server) = Pair(); using var session = new WindowsSystemAuthorization(client);
        var requests = new List<Guid>();
        var responding = Task.Run(async () =>
        {
            using (server)
                for (var index = 0; index < 3; index++)
                {
                    var request = await WindowsAuthorizationChannel.ReadAsync<AuthorizationRequest>(server, default); requests.Add(request.Id);
                    if (index < 2) await WindowsAuthorizationChannel.WriteAsync(server, new AuthorizationReply(request.Id), default);
                }
        });
        await session.AuthorizeAdministratorAsync();
        var path = WindowsPath.Parse("C:/Users/generated/cache");
        _ = await session.PerformAsync(new(Guid.NewGuid(), AuthorizationOperation.Inspect, path), default);
        _ = await session.PerformAsync(new(Guid.NewGuid(), AuthorizationOperation.ReadDirectory, path), default);
        Assert.Equal(SystemAuthorizationState.Authorized, session.AdministratorState);
        Assert.Equal("authorization_channel_lost", (await Assert.ThrowsAsync<ShouException>(() => session.PerformAsync(new(Guid.NewGuid(), AuthorizationOperation.Cleanup, path), default))).Code);
        await responding; Assert.Equal(3, requests.Distinct().Count());
        Assert.Equal(SystemAuthorizationState.Unavailable, session.AdministratorState);
    }

    [Fact]
    public async Task CancellationWaitsForTerminalOutcomeWithoutReplayingOrEndingSession()
    {
        var (client, server) = Pair(); using var session = new WindowsSystemAuthorization(client); using var stopped = new CancellationTokenSource();
        var responding = Task.Run(async () =>
        {
            using (server)
            {
                var request = await WindowsAuthorizationChannel.ReadAsync<AuthorizationRequest>(server, default);
                await WindowsAuthorizationChannel.WriteAsync(server, new AuthorizationReply(request.Id, Progress:true), default);
                var cancel = await WindowsAuthorizationChannel.ReadAsync<AuthorizationRequest>(server, default);
                WindowsSystemAuthorizationWorker.ValidateCancel(cancel); Assert.Equal(request.Id, cancel.Id);
                await WindowsAuthorizationChannel.WriteAsync(server, new AuthorizationReply(request.Id, Error:"cancelled"), default);
            }
        });
        var error = await Assert.ThrowsAsync<ShouException>(() => session.PerformAsync(new(Guid.NewGuid(), AuthorizationOperation.ReadDirectory, WindowsPath.Parse("C:/generated")), stopped.Token,
            _ => { stopped.Cancel(); return Task.CompletedTask; }));
        Assert.Equal("cancelled", error.Code); Assert.Equal(SystemAuthorizationState.Authorized, session.AdministratorState);
        await responding;
    }

    [Fact]
    public async Task FramesRejectOversizeTruncationAndUnexpectedMembers()
    {
        var header = new byte[4]; BinaryPrimitives.WriteInt32BigEndian(header, WindowsAuthorizationChannel.MaximumFrameBytes + 1);
        Assert.Equal("authorization_channel_lost", (await Assert.ThrowsAsync<ShouException>(() => WindowsAuthorizationChannel.ReadAsync<AuthorizationRequest>(new MemoryStream(header), default))).Code);
        await Assert.ThrowsAsync<EndOfStreamException>(() => WindowsAuthorizationChannel.ReadAsync<AuthorizationRequest>(new MemoryStream([0, 0]), default));
    }

    [Theory]
    [InlineData("C:/Users/other/private")]
    [InlineData("C:/Users/generated/.ssh/key")]
    public void AuthorizationDoesNotGrantAccessToProtectedContent(string path)
    {
        var operation = path.Contains("other", StringComparison.Ordinal) ? AuthorizationOperation.Inspect : AuthorizationOperation.Cleanup;
        Assert.Throws<ShouException>(() => WindowsSystemAuthorizationWorker.ValidateRequest(new(Guid.NewGuid(), operation, WindowsPath.Parse(path)), "C:/Users/generated"));
    }

    [Fact]
    public void CapabilitiesRejectUnrelatedPayloadAndMalformedCancel()
    {
        var path = WindowsPath.Parse("C:/Users/generated/cache");
        WindowsSystemAuthorizationWorker.ValidateRequest(new(Guid.NewGuid(), AuthorizationOperation.Inspect, path), "C:/Users/generated");
        Assert.Throws<ShouException>(() => WindowsSystemAuthorizationWorker.ValidateRequest(new(Guid.NewGuid(), AuthorizationOperation.Inspect, path, ExpiresAt:DateTimeOffset.UtcNow), "C:/Users/generated"));
        Assert.Throws<ShouException>(() => WindowsSystemAuthorizationWorker.ValidateCancel(new(Guid.NewGuid(), AuthorizationOperation.Cancel, path)));
        Assert.Throws<ShouException>(() => WindowsSystemAuthorizationWorker.ValidateRequest(new(Guid.NewGuid(), AuthorizationOperation.StartupInspect, TaskPath:"not-an-exact-task"), "C:/Users/generated"));
    }

    private static (Stream, Stream) Pair()
    {
        var forward = Channel.CreateUnbounded<byte[]>(); var back = Channel.CreateUnbounded<byte[]>();
        return (new Duplex(back.Reader, forward.Writer), new Duplex(forward.Reader, back.Writer));
    }
    private sealed class Duplex(ChannelReader<byte[]> input, ChannelWriter<byte[]> output) : Stream
    {
        private byte[] bytes = []; private int offset;
        public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override Task FlushAsync(CancellationToken token) => Task.CompletedTask;
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException(); public override void SetLength(long value) => throw new NotSupportedException();
        public override int Read(byte[] buffer, int start, int count) => ReadAsync(buffer.AsMemory(start, count)).AsTask().GetAwaiter().GetResult();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            if (offset == bytes.Length) { try { bytes = await input.ReadAsync(token); offset = 0; } catch (ChannelClosedException) { return 0; } }
            var count = Math.Min(buffer.Length, bytes.Length - offset); bytes.AsMemory(offset, count).CopyTo(buffer); offset += count; return count;
        }
        public override void Write(byte[] buffer, int start, int count) => WriteAsync(buffer.AsMemory(start, count)).AsTask().GetAwaiter().GetResult();
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default) => output.WriteAsync(buffer.ToArray(), token);
        protected override void Dispose(bool disposing) { if (disposing) output.TryComplete(); base.Dispose(disposing); }
    }
}
