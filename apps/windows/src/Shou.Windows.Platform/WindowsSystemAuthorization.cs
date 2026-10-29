using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>One native UAC authentication per process session. No password or arbitrary command is accepted.</summary>
public sealed class WindowsSystemAuthorization : ISystemAuthorization, IDisposable
{
    public static WindowsSystemAuthorization Shared { get; } = new();
    private readonly SemaphoreSlim operations = new(1, 1);
    private Stream? channel;
    private Process? worker;
    private ulong sequence;
    private volatile SystemAuthorizationState state;
    internal static bool IsWorker { get; private set; }
    public SystemAuthorizationState AdministratorState => state;
    internal bool IsAuthorized => !IsWorker && state == SystemAuthorizationState.Authorized;
    public WindowsSystemAuthorization() { }
    internal WindowsSystemAuthorization(Stream authenticatedChannel) { channel = authenticatedChannel; state = SystemAuthorizationState.Authorized; }

    public Task AuthorizeAdministratorAsync(CancellationToken cancellationToken = default) => AuthorizeAsync(true, cancellationToken);
    public Task PrepareAdministratorAuthorizationAsync(CancellationToken cancellationToken = default) => AuthorizeAsync(false, cancellationToken);
    private async Task AuthorizeAsync(bool allowInteraction, CancellationToken cancellationToken)
    {
        await operations.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { await ConnectAsync(cancellationToken, allowInteraction).ConfigureAwait(false); }
        finally { operations.Release(); }
    }
    private async Task ConnectAsync(CancellationToken token, bool allowInteraction)
    {
        token.ThrowIfCancellationRequested();
        if (state == SystemAuthorizationState.Authorized && channel is not null && (worker is null || !worker.HasExited)) return;
        var previouslyRequested = state != SystemAuthorizationState.NotRequested;
        channel?.Dispose(); channel = null; worker?.Dispose(); worker = null; sequence = 0;
        // All failures, including cancelled consent, require an explicit recovery action.
        state = SystemAuthorizationState.Unavailable;
        if (!allowInteraction && previouslyRequested)
            throw new ShouException("authorization_unavailable", "Administrator authorization could not be completed. Try again.");
        if (!NativeWindowsSupport.IsSupported || IsWorker || Environment.ProcessPath is not { } executable ||
            !new[] { "Shou.Windows.App.exe", "shou.exe" }.Contains(Path.GetFileName(executable), StringComparer.OrdinalIgnoreCase))
            throw new ShouException("authorization_unavailable", "Administrator access requires the packaged Shou application or CLI.");
        var parent = WindowsAuthorizationPeer.Read(Environment.ProcessId);
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var name = "shou-authorization-" + Guid.NewGuid().ToString("N");
        var security = new PipeSecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { parent.Sid, "S-1-5-18", "S-1-5-32-544" }.Distinct())
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid), PipeAccessRights.FullControl, AccessControlType.Allow));
        var pipe = NamedPipeServerStreamAcl.Create(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance, 65_536, 65_536, security);
        try
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = true, Verb = "runas", WorkingDirectory = AppContext.BaseDirectory };
            foreach (var argument in new[] { "--system-authorization-worker-v2", name, nonce, parent.Pid.ToString(System.Globalization.CultureInfo.InvariantCulture), parent.Started.ToString(System.Globalization.CultureInfo.InvariantCulture) }) start.ArgumentList.Add(argument);
            worker = Process.Start(start) ?? throw WindowsAuthorizationChannel.Failure();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromMinutes(2));
            await pipe.WaitForConnectionAsync(deadline.Token).ConfigureAwait(false);
            if (WindowsAuthorizationPeer.PipePeer(pipe.SafePipeHandle, client:true) != worker.Id) throw WindowsAuthorizationChannel.Failure();
            var peer = WindowsAuthorizationPeer.Read(worker.Id);
            if (!peer.Elevated || !string.Equals(peer.Executable, executable, StringComparison.OrdinalIgnoreCase)) throw WindowsAuthorizationChannel.Failure();
            var hello = await WindowsAuthorizationChannel.ReadAsync<AuthorizationHello>(pipe, deadline.Token).ConfigureAwait(false);
            if (hello.Version != 2 || hello.Nonce != nonce || !peer.IsCurrent || !parent.IsCurrent) throw WindowsAuthorizationChannel.Failure();
            channel = pipe; state = SystemAuthorizationState.Authorized;
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        { pipe.Dispose(); throw new ShouException("authorization_cancelled", "Administrator authorization was cancelled.", error); }
        catch { pipe.Dispose(); state = SystemAuthorizationState.Unavailable; throw; }
    }

    internal async Task<AuthorizationReply> PerformAsync(AuthorizationRequest request, CancellationToken token,
        Func<AuthorizationReply, Task>? progress = null)
    {
        await operations.WaitAsync(token).ConfigureAwait(false);
        try
        {
            await ConnectAsync(token, allowInteraction: false).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            if (sequence == ulong.MaxValue) throw WindowsAuthorizationChannel.Failure();
            request = request with { Sequence = ++sequence };
            var stream = channel ?? throw WindowsAuthorizationChannel.Failure();
            using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(11));
            token.ThrowIfCancellationRequested();
            await WindowsAuthorizationChannel.WriteAsync(stream, request, deadline.Token).ConfigureAwait(false);
            // Await the terminal response even after cooperative cancellation. Never replay a dispatched mutation.
            var cancelled = false;
            while (true)
            {
                var reading = WindowsAuthorizationChannel.ReadAsync<AuthorizationReply>(stream, deadline.Token);
                while (!reading.IsCompleted)
                {
                    if (token.IsCancellationRequested && !cancelled)
                    {
                        await WindowsAuthorizationChannel.WriteAsync(stream, new AuthorizationRequest(request.Id, AuthorizationOperation.Cancel, Sequence: request.Sequence), deadline.Token).ConfigureAwait(false);
                        cancelled = true;
                    }
                    await Task.WhenAny(reading, Task.Delay(100, deadline.Token)).ConfigureAwait(false);
                    deadline.Token.ThrowIfCancellationRequested();
                }
                var reply = await reading.ConfigureAwait(false);
                if (reply.Id != request.Id) throw WindowsAuthorizationChannel.Failure();
                deadline.CancelAfter(TimeSpan.FromMinutes(11));
                if (reply.Progress) { if (progress is not null) await progress(reply).ConfigureAwait(false); continue; }
                if (reply.Error is { } code) throw new ShouException(code, "The authorized operation could not finish. Review its current scope before retrying.");
                return reply;
            }
        }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException or OperationCanceledException || error is ShouException { Code:"authorization_channel_lost" })
        {
            channel?.Dispose(); channel = null; state = SystemAuthorizationState.Unavailable;
            throw WindowsAuthorizationChannel.Failure();
        }
        finally { operations.Release(); }
    }

    public void Dispose() { channel?.Dispose(); channel = null; worker?.Dispose(); state = SystemAuthorizationState.Unavailable; }
    internal static void EnterWorker() => IsWorker = true;
}
