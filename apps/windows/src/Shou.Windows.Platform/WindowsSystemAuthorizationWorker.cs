using System.IO.Pipes;
using System.Threading.Channels;
using Shou.Windows.Core;

namespace Shou.Windows.Platform;

/// <summary>Finite native capabilities, bound to one caller PID and process lifetime. No user record store is opened elevated.</summary>
public static class WindowsSystemAuthorizationWorker
{
    public static async Task<int?> RunIfRequestedAsync(string[] args)
    {
        if (args.Length == 0 || !args[0].StartsWith("--system-authorization-worker", StringComparison.Ordinal)) return null;
        if (!NativeWindowsSupport.IsSupported || args.Length != 5 || args[0] != "--system-authorization-worker-v2" ||
            !args[1].StartsWith("shou-authorization-", StringComparison.Ordinal) || !Guid.TryParseExact(args[1][19..], "N", out _) ||
            args[2].Length != 64 || !args[2].All(char.IsAsciiHexDigit) || !int.TryParse(args[3], out var pid) || !long.TryParse(args[4], out var started)) return 77;
        WindowsSystemAuthorization.EnterWorker();
        try
        {
            var parent = WindowsAuthorizationPeer.Read(pid); var self = WindowsAuthorizationPeer.Read(Environment.ProcessId);
            if (!self.Elevated || parent.Started != started || !string.Equals(parent.Executable, self.Executable, StringComparison.OrdinalIgnoreCase)) return 77;
            using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.Asynchronous);
            using var lifetime = new CancellationTokenSource();
            await pipe.ConnectAsync(30_000, lifetime.Token).ConfigureAwait(false);
            if (WindowsAuthorizationPeer.PipePeer(pipe.SafePipeHandle, client:false) != pid || !parent.IsCurrent) return 77;
            await WindowsAuthorizationChannel.WriteAsync(pipe, new AuthorizationHello(2, args[2]), lifetime.Token).ConfigureAwait(false);
            var queue = Channel.CreateBounded<AuthorizationRequest>(1);
            var gate = new object(); Guid active = Guid.Empty, completed = Guid.Empty;
            CancellationTokenSource? operation = null;
            var order = new AuthorizationRequestOrder();
            ulong activeSequence = 0, completedSequence = 0;
            var reader = Task.Run(async () =>
            {
                try
                {
                    while (!lifetime.IsCancellationRequested)
                    {
                        var request = await WindowsAuthorizationChannel.ReadAsync<AuthorizationRequest>(pipe, lifetime.Token).ConfigureAwait(false);
                        lock (gate)
                        {
                            if (request.Operation == AuthorizationOperation.Cancel)
                            {
                                ValidateCancel(request);
                                if (request.Id == active && request.Sequence == activeSequence) operation?.Cancel();
                                else if (request.Id != completed || request.Sequence != completedSequence) throw WindowsAuthorizationChannel.Failure();
                                continue;
                            }
                            if (active != Guid.Empty) throw WindowsAuthorizationChannel.Failure();
                            order.Accept(request);
                            active = request.Id; activeSequence = request.Sequence; operation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                        }
                        await queue.Writer.WriteAsync(request, lifetime.Token).ConfigureAwait(false);
                    }
                }
                catch (Exception error) when (error is IOException or OperationCanceledException or System.Text.Json.JsonException or ShouException)
                { lifetime.Cancel(); queue.Writer.TryComplete(); }
            });
            var monitor = Task.Run(async () =>
            {
                try { while (!lifetime.IsCancellationRequested) { await Task.Delay(500, lifetime.Token).ConfigureAwait(false); if (!parent.IsCurrent) lifetime.Cancel(); } }
                catch (OperationCanceledException) { }
            });
            try
            {
                await foreach (var request in queue.Reader.ReadAllAsync(lifetime.Token).ConfigureAwait(false))
                {
                    AuthorizationReply reply;
                    CancellationToken token; lock (gate) token = operation!.Token;
                    try { reply = await PerformAsync(request, parent, pipe, token).ConfigureAwait(false); }
                    catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or OperationCanceledException)
                    { reply = new(request.Id, Error:error is ShouException known ? known.Code : error is OperationCanceledException ? "cancelled" : error is UnauthorizedAccessException ? "permission_denied" : "io_error"); }
                    lock (gate) { completed = active; completedSequence = activeSequence; active = Guid.Empty; operation?.Dispose(); operation = null; }
                    if (!parent.IsCurrent) break;
                    await WindowsAuthorizationChannel.WriteAsync(pipe, reply, lifetime.Token).ConfigureAwait(false);
                }
            }
            finally { lifetime.Cancel(); pipe.Dispose(); await Task.WhenAll(reader, monitor).ConfigureAwait(false); operation?.Dispose(); }
            return 0;
        }
        catch (Exception error) when (error is ShouException or IOException or UnauthorizedAccessException or OperationCanceledException or System.ComponentModel.Win32Exception or ArgumentException or InvalidOperationException) { return 77; }
    }

    internal static void ValidateCancel(AuthorizationRequest request)
    {
        if (request.Operation != AuthorizationOperation.Cancel || request.Path is not null || request.Root is not null || request.Anchor is not null || request.Workspace is not null || request.Item is not null || request.Uninstall is not null || request.ExpiresAt is not null || request.TaskPath is not null || request.Startup is not null) throw WindowsAuthorizationChannel.Failure();
    }
    internal static void ValidateRequest(AuthorizationRequest request, string home)
    {
        if (request.Operation is AuthorizationOperation.Uninstall or AuthorizationOperation.StartupInspect or AuthorizationOperation.StartupToggle)
        {
            if (request.Path is not null || request.Root is not null || request.Anchor is not null || request.Workspace is not null || request.Item is not null) throw WindowsAuthorizationChannel.Failure();
            switch (request.Operation)
            {
                case AuthorizationOperation.Uninstall when request.Uninstall is { CanPreparePlan:true } review && review.Installation.Identity?.Kind == ApplicationInstallerKind.Msi && request.ExpiresAt is not null && request.TaskPath is null && request.Startup is null: return;
                case AuthorizationOperation.StartupInspect when StartupControlReviewer.ValidTaskPath(request.TaskPath!) && request.Uninstall is null && request.ExpiresAt is null && request.Startup is null: return;
                case AuthorizationOperation.StartupToggle when request.Startup is { CanChange:true } && request.ExpiresAt is not null && request.TaskPath is null && request.Uninstall is null: return;
                default: throw WindowsAuthorizationChannel.Failure();
            }
        }
        if (request.Uninstall is not null || request.ExpiresAt is not null || request.TaskPath is not null || request.Startup is not null) throw WindowsAuthorizationChannel.Failure();
        if (request.Path is not { } path || request.Operation == AuthorizationOperation.Cancel || !Enum.IsDefined(request.Operation)) throw WindowsAuthorizationChannel.Failure();
        var profile = WindowsPath.Parse(home);
        if (profile.Parent is { } users && path.IsWithin(users, includeRoot:false) && !path.IsWithin(profile) &&
            !path.IsWithin(users.Append("Public"))) throw new ShouException("protected_content", "Other users' private directories remain protected.");
        switch (request.Operation)
        {
            case AuthorizationOperation.Inspect or AuthorizationOperation.ReadDirectory:
                if (request.Root is not null || request.Anchor is not null || request.Workspace is not null || request.Item is not null) throw WindowsAuthorizationChannel.Failure();
                break;
            case AuthorizationOperation.VerifyRoot:
                if (request.Root?.Path != path || request.Anchor is null || request.Workspace is not null || request.Item is not null) throw WindowsAuthorizationChannel.Failure();
                if (!new[] { profile, profile.Append("AppData/Local"), profile.Append("AppData/Roaming") }.Contains(request.Anchor)) throw WindowsAuthorizationChannel.Failure();
                break;
            case AuthorizationOperation.Cleanup:
                if (request.Workspace is not { } workspace || request.Item?.Path != path || request.Root is not null || request.Anchor is not null ||
                    workspace.Path.IsVolumeRoot || !path.IsWithin(workspace.Path, includeRoot:false)) throw WindowsAuthorizationChannel.Failure();
                var protectedRoots = new[] { "AppData/Local/Shou", ".ssh", ".gnupg", ".aws", ".kube", "OneDrive" }.Select(profile.Append);
                if (protectedRoots.Any(root => root.IsWithin(path) || path.IsWithin(root))) throw new ShouException("protected_content", "Administrator access does not grant permission to change protected data.");
                break;
            default: throw WindowsAuthorizationChannel.Failure();
        }
    }

    private static async Task<AuthorizationReply> PerformAsync(AuthorizationRequest request, WindowsAuthorizationPeer caller, Stream stream, CancellationToken token)
    {
        ValidateRequest(request, caller.Home); token.ThrowIfCancellationRequested();
        if (request.Operation == AuthorizationOperation.Uninstall)
            return new(request.Id, Uninstall:await new WindowsApplicationUninstallMutation().ApplyAuthorizedAsync(request.Uninstall!, caller.Sid, request.ExpiresAt!.Value, token).ConfigureAwait(false));
        if (request.Operation == AuthorizationOperation.StartupInspect)
        {
            using var task = new LocalStartupTaskControlHandle(request.TaskPath!);
            return new(request.Id, Startup:WindowsStartupControlInspector.Read(task, caller.Sid, token));
        }
        if (request.Operation == AuthorizationOperation.StartupToggle)
        {
            using var task = new LocalStartupTaskControlHandle(request.Startup!.Task.TaskPath);
            return new(request.Id, StartupResult:WindowsStartupControlMutation.Apply(task, () => caller.Sid, request.Startup, request.ExpiresAt!.Value, TimeProvider.System, token));
        }
        var files = new WindowsFileSystem(); var path = request.Path!;
        switch (request.Operation)
        {
            case AuthorizationOperation.Inspect:
                return new(request.Id, Entry:await files.InspectAsync(path, token).ConfigureAwait(false));
            case AuthorizationOperation.ReadDirectory:
                var batch = new List<DirectoryReadItem>(128); var count = 0;
                await foreach (var entry in files.ReadDirectoryAsync(path, token).ConfigureAwait(false))
                {
                    if (++count > 1_000_000) throw new ShouException("resource_limit", "The directory exceeds its scan budget.");
                    batch.Add(entry);
                    if (batch.Count < 128) continue;
                    await WindowsAuthorizationChannel.WriteAsync(stream, new AuthorizationReply(request.Id, Progress:true, Entries:batch.ToArray()), token).ConfigureAwait(false); batch.Clear();
                }
                if (batch.Count > 0) await WindowsAuthorizationChannel.WriteAsync(stream, new AuthorizationReply(request.Id, Progress:true, Entries:batch.ToArray()), token).ConfigureAwait(false);
                return new(request.Id);
            case AuthorizationOperation.VerifyRoot:
                WindowsProvisionedScanAccess.VerifyPinnedRoot(request.Root!, request.Anchor!, caller.Sid, token);
                return new(request.Id);
            case AuthorizationOperation.Cleanup:
                var system = new[] { Environment.SpecialFolder.Windows, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.CommonApplicationData }
                    .Select(Environment.GetFolderPath).Where(value => !string.IsNullOrEmpty(value)).Select(WindowsPath.Parse);
                if (system.Any(root => root.IsWithin(path) || path.IsWithin(root))) throw new ShouException("protected_content", "System-managed locations remain protected.");
                var progress = new AuthorizationMutationProgress(update => WindowsAuthorizationChannel.WriteAsync(stream, new AuthorizationReply(request.Id, Progress:true, MutationProgress:update), CancellationToken.None).GetAwaiter().GetResult());
                var result = await WindowsCleanupMutation.ApplyAuthorizedAsync(request.Workspace!, request.Item!, caller.Sid, progress, token).ConfigureAwait(false);
                return new(request.Id, Mutation:result);
            default: throw WindowsAuthorizationChannel.Failure();
        }
    }
    private sealed class AuthorizationMutationProgress(Action<CleanupMutationProgress> report) : IProgress<CleanupMutationProgress>
    { public void Report(CleanupMutationProgress value) => report(value); }
}
